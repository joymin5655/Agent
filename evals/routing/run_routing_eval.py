#!/usr/bin/env python3
"""Deterministic, model-free skill-routing eval (stdlib only).

Tier 1  structural lint of every SKILL.md (frontmatter, description length, size).
Tier 2  lexical routing proxy: for each case prompt, rank all model-invocable skills
        by TF-IDF cosine against "name + description + when_to_use". Positive prompts
        should rank their skill high; negative prompts must not rank it first.
        Also reports pairwise description near-collisions.

The mechanism (structural lint + stemmed TF-IDF ranking + near-collision scan) follows
addyosmani/agent-skills (MIT); this is an independent implementation with a
Korean-aware tokenizer. It measures description discriminability, NOT model behavior.

Rank semantics: tied scores share the best rank of the tie, so a tie for first counts
as rank 1. That is optimistic for positive prompts and strict for negative ones (a tie
for first is a violation). A prompt with no lexical overlap ranks last.
"""
import argparse
import json
import math
import os
import re
import sys
from collections import Counter

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
DEFAULT_SKILLS = os.path.join(REPO, "skills")
DEFAULT_CASES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cases.json")

MAX_DESC = 1024      # Agent Skills spec
TRUNC_DESC = 1536    # Claude truncates the listing entry (description + when_to_use) here
MAX_LINES = 500

STOP = set("""a an and are as at be by for from has have in is it its of on or that the this to
use used using when with not no do does your you can will into via per than then also any all
skill skills user users""".split())
HANGUL = re.compile(r"[가-힣]+")
WORD = re.compile(r"[a-z0-9]+")


def stem(w):
    """Light suffix stripper (not Porter): enough to fold plurals and -ing/-ed forms."""
    if w.endswith("ss"):
        return w
    for suf in ("ations", "ation", "ings", "ing", "edly", "ied", "ed", "ies", "es", "ly", "s"):
        if w.endswith(suf) and len(w) - len(suf) >= 3:
            return w[: -len(suf)] + ("y" if suf in ("ies", "ied") else "")
    return w


def tokenize(text):
    text = text.lower()
    toks = []
    for w in WORD.findall(text):
        if len(w) >= 2 and w not in STOP:
            toks.append(stem(w))
    for run in HANGUL.findall(text):
        for n in (2, 3):
            toks += ["k:" + run[i:i + n] for i in range(len(run) - n + 1)]
        if len(run) == 1:
            toks.append("k:" + run)
    return toks


def parse_frontmatter(text):
    """Minimal YAML subset: `key: value`, quoted values, and >/| block scalars."""
    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        return None
    fm, i, key = {}, 1, None
    while i < len(lines) and lines[i].strip() != "---":
        ln = lines[i]
        m = re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", ln)
        if m and not ln.startswith((" ", "\t")):
            key, val = m.group(1), m.group(2).strip()
            if val in (">", "|", ">-", "|-"):
                val = ""
            fm[key] = val
        elif key and ln.strip():
            fm[key] = (fm[key] + " " + ln.strip()).strip()
        i += 1
    if i >= len(lines):
        return None
    for k, v in list(fm.items()):
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            fm[k] = v[1:-1]
    return fm


def load_skills(dirs):
    skills, seen = [], {}
    for d in dirs:
        d = os.path.expanduser(d)
        if not os.path.isdir(d):
            print(f"warn: skills dir not found: {d}", file=sys.stderr)
            continue
        for entry in sorted(os.listdir(d)):
            path = os.path.join(d, entry, "SKILL.md")
            if not os.path.isfile(path):
                continue
            with open(path, encoding="utf-8", errors="replace") as f:
                text = f.read()
            fm = parse_frontmatter(text)
            s = {"dir": entry, "path": path, "fm": fm, "lines": len(text.splitlines()),
                 "root": d}
            if fm and fm.get("name") in seen and seen[fm["name"]] != d:
                s["dup_of"] = seen[fm["name"]]
            if fm and fm.get("name"):
                seen.setdefault(fm["name"], d)
            skills.append(s)
    return skills


def lint(skills):
    issues = []  # (severity, skill, msg)
    for s in skills:
        label, fm = s["dir"], s["fm"]
        if fm is None:
            issues.append(("error", label, "missing or unterminated frontmatter"))
            continue
        name, desc = fm.get("name", ""), fm.get("description", "")
        if not name:
            issues.append(("error", label, "frontmatter name missing"))
        elif name != s["dir"]:
            issues.append(("error", label, f"name '{name}' does not match directory"))
        if not desc:
            issues.append(("error", label, "frontmatter description missing"))
        if len(desc) > MAX_DESC:
            issues.append(("error", label, f"description {len(desc)} chars > {MAX_DESC} (spec)"))
        combined = len(desc) + len(fm.get("when_to_use", ""))
        if combined > TRUNC_DESC:
            issues.append(("warn", label, f"description+when_to_use {combined} chars > {TRUNC_DESC} (listing truncation)"))
        if s["lines"] > MAX_LINES:
            issues.append(("error", label, f"SKILL.md {s['lines']} lines > {MAX_LINES}"))
        if "dup_of" in s:
            issues.append(("warn", label, f"name shadows a skill from {s['dup_of']}"))
    return issues


class Index:
    def __init__(self, skills):
        self.names, docs = [], []
        for s in skills:
            fm = s["fm"] or {}
            if fm.get("disable-model-invocation", "").lower() == "true" or not fm.get("description"):
                continue
            name = fm.get("name") or s["dir"]
            if name in self.names:
                continue
            self.names.append(name)
            docs.append(tokenize(name) + tokenize(fm["description"] + " " + fm.get("when_to_use", "")))
        n = len(docs)
        df = Counter(t for d in docs for t in set(d))
        self.idf = {t: math.log((n + 1) / (c + 1)) + 1 for t, c in df.items()}
        self.vecs = [self._vec(d) for d in docs]

    def _vec(self, toks):
        tf = Counter(toks)
        v = {t: (1 + math.log(c)) * self.idf.get(t, 0.0) for t, c in tf.items() if t in self.idf}
        norm = math.sqrt(sum(x * x for x in v.values()))
        return {t: x / norm for t, x in v.items()} if norm else {}

    @staticmethod
    def cos(a, b):
        if len(a) > len(b):
            a, b = b, a
        return sum(x * b.get(t, 0.0) for t, x in a.items())

    def rank(self, prompt):
        """Return [(name, rank)] best-first. Ties share a rank; a zero score is
        "no lexical match" and ranks last (never rank 1 by alphabetical accident)."""
        q = self._vec(tokenize(prompt))
        scored = sorted(((self.cos(q, v), n) for n, v in zip(self.names, self.vecs)),
                        key=lambda x: (-x[0], x[1]))
        out = []
        for sc, n in scored:
            out.append((n, 1 + sum(1 for s2, _ in scored if s2 > sc) if sc > 0 else len(scored)))
        return out

    def pair_similarities(self):
        """Every skill pair with its description cosine, best first."""
        out = []
        for i in range(len(self.names)):
            for j in range(i + 1, len(self.names)):
                out.append((self.cos(self.vecs[i], self.vecs[j]), self.names[i], self.names[j]))
        return sorted(out, reverse=True)


def apply_floors(args):
    """Fill floors not given on the command line from the shared floors file."""
    if not args.floors:
        return
    with open(args.floors, encoding="utf-8") as f:
        fl = json.load(f)
    for key in ("min_rank1", "min_top3", "max_negative_violations"):
        if getattr(args, key) is None and key in fl:
            setattr(args, key, fl[key])


def run(args):
    apply_floors(args)
    args.min_rank1 = 0.0 if args.min_rank1 is None else args.min_rank1
    args.min_top3 = 0.0 if args.min_top3 is None else args.min_top3
    if args.max_negative_violations is None:
        args.max_negative_violations = 10**9
    skills = load_skills(args.skills_dir or [DEFAULT_SKILLS])
    issues = lint(skills)
    idx = Index(skills)
    with open(args.cases, encoding="utf-8") as f:
        cases = json.load(f)["cases"]

    present, pos, neg, skipped = set(idx.names), [], [], []
    for c in cases:
        sk = c["skill"]
        if sk not in present:
            skipped.append(sk)
            continue
        for p in c.get("positive", []):
            ranked = idx.rank(p)
            top = ranked[0][0] if ranked[0][1] == 1 else "(no lexical match)"
            pos.append({"skill": sk, "prompt": p, "rank": dict(ranked)[sk], "top": top,
                        "lang": "ko" if HANGUL.search(p) else "en"})
        for p in c.get("negative", []):
            ranked = idx.rank(p)
            neg.append({"skill": sk, "prompt": p, "rank": dict(ranked)[sk], "top": ranked[0][0]})
    def pct(rows, k):
        return 100.0 * sum(1 for r in rows if r["rank"] <= k) / len(rows) if rows else 0.0

    rank1, top3 = pct(pos, 1), pct(pos, 3)
    by_lang = {lg: {"n": len([r for r in pos if r["lang"] == lg]),
                    "rank1_pct": round(pct([r for r in pos if r["lang"] == lg], 1), 1),
                    "top3_pct": round(pct([r for r in pos if r["lang"] == lg], 3), 1)} for lg in ("en", "ko")}
    violations = [r for r in neg if r["rank"] == 1]
    pairs = idx.pair_similarities()
    coll = [p for p in pairs if p[0] > args.collision_threshold]
    top_pairs = pairs[:5]
    errors = [i for i in issues if i[0] == "error"]

    result = {
        "skills_ranked": len(idx.names), "skills_linted": len(skills),
        "positive_cases": len(pos), "negative_cases": len(neg),
        "rank1_pct": round(rank1, 1), "top3_pct": round(top3, 1), "by_lang": by_lang,
        "negative_violations": len(violations),
        "collision_threshold": args.collision_threshold,
        "collisions": [{"sim": round(s, 3), "a": a, "b": b} for s, a, b in coll],
        "top_pairs": [{"sim": round(s, 3), "a": a, "b": b} for s, a, b in top_pairs],
        "lint": [{"severity": a, "skill": b, "msg": c} for a, b, c in issues],
        "positive_misses": [r for r in pos if r["rank"] > 1],
        "negative_violation_list": violations,
        "skipped_case_skills": sorted(set(skipped)),
    }
    fails = []
    if not idx.names:
        fails.append("no model-invocable skills loaded")
    strict = args.skills_dir is None or args.strict_coverage
    if strict:
        covered = {c["skill"] for c in cases}
        uncovered = sorted(set(idx.names) - covered)
        result["uncovered_skills"] = uncovered
        if result["skipped_case_skills"]:
            fails.append("cases reference skills not in the pool: " + ", ".join(result["skipped_case_skills"]))
        if uncovered:
            fails.append("ranked skills without cases: " + ", ".join(uncovered))
    if errors:
        fails.append(f"{len(errors)} lint error(s)")
    if rank1 < args.min_rank1:
        fails.append(f"rank-1 {result['rank1_pct']}% < {args.min_rank1}%")
    if top3 < args.min_top3:
        fails.append(f"top-3 {result['top3_pct']}% < {args.min_top3}%")
    if len(violations) > args.max_negative_violations:
        fails.append(f"{len(violations)} negative violation(s) > {args.max_negative_violations}")
    result["failures"] = fails

    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        report(result, args)
    return 1 if fails else 0


def report(r, args):
    print(f"routing eval: {r['skills_ranked']} skills ranked / {r['skills_linted']} linted; "
          f"{r['positive_cases']} positive, {r['negative_cases']} negative prompts")
    print(f"  rank-1 {r['rank1_pct']}%  top-3 {r['top3_pct']}%  negative violations {r['negative_violations']}")
    for lg, d in r["by_lang"].items():
        print(f"    {lg}: n={d['n']} rank-1 {d['rank1_pct']}%  top-3 {d['top3_pct']}%")
    for i in r["lint"]:
        print(f"  lint {i['severity']:5} {i['skill']}: {i['msg']}")
    for m in r["positive_misses"]:
        if args.verbose or m["rank"] > 3:
            print(f"  miss  [{m['skill']}] rank {m['rank']} (top: {m['top']}): {m['prompt']}")
    for v in r["negative_violation_list"]:
        print(f"  negviol [{v['skill']}] ranked first: {v['prompt']}")
    print(f"  near-collisions (cosine > {r['collision_threshold']}): {len(r['collisions'])}")
    for c in r["collisions"][:15]:
        print(f"    {c['sim']:.3f}  {c['a']} <-> {c['b']}")
    print("  closest pairs regardless of threshold: " + ", ".join(
        f"{c['a']}<->{c['b']} {c['sim']:.2f}" for c in r["top_pairs"]))
    if r["skipped_case_skills"]:
        print(f"  cases skipped (skill not in scanned dirs): {', '.join(r['skipped_case_skills'])}")
    print("ROUTING EVAL " + ("FAIL: " + "; ".join(r["failures"]) if r["failures"] else "PASS"))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--skills-dir", action="append", help="repeatable; default: repo skills/")
    ap.add_argument("--cases", default=DEFAULT_CASES)
    ap.add_argument("--floors", help="JSON file with min_rank1/min_top3/max_negative_violations "
                    "(single source for CI, the test and the README); CLI flags override it")
    ap.add_argument("--min-rank1", type=float, help="percent floor")
    ap.add_argument("--min-top3", type=float, help="percent floor")
    ap.add_argument("--max-negative-violations", type=int)
    ap.add_argument("--strict-coverage", action="store_true",
                    help="fail on cases for absent skills or ranked skills without cases "
                    "(always on for the default repo skills/ run)")
    ap.add_argument("--collision-threshold", type=float, default=0.5)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--verbose", action="store_true")
    sys.exit(run(ap.parse_args()))


if __name__ == "__main__":
    main()
