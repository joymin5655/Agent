#!/usr/bin/env python3
"""parse_findings.py — pull one critique JSON out of a worker capture and vet it.

usage: parse_findings.py CAPTURE --draft DRAFT [--label A]
stdout: {"ok", "error", "verdict", "findings", "dropped": {"total", "reasons"}}
exit:   0 parsed and valid shape | 1 no usable JSON (ok=false)

Checks: a JSON object with verdict + findings; each finding has the six fields in range
(one malformed finding is dropped as invalid_format, the rest survive). `changes_fact`
absent means true. A quote must be 8-300 chars on one line (quote_too_short / quote_too_long /
quote_multiline) and found in the draft (whitespace-normalised, else quote_not_in_draft).
Findings with the same quote and category merge (the higher severity's wording wins,
changes_fact is OR-ed); capped at 12, worst first.
When several JSON objects appear (a CLI may echo the prompt's example), the LAST valid one wins
(valid = verdict ok|revise with a findings list). Only the last MAX_SCAN characters are read
and bare objects are tried newest first, at most MAX_TRIES of them, so a long or hostile
capture costs bounded time.
"""
import argparse
import json
import re
import sys

CATS = {"fact", "logic", "reader", "fluency", "request", "format"}
SEVS = ["critical", "major", "minor"]
LIMIT = 12
MAX_SCAN = 400_000  # characters from the end of the capture: the answer comes last
MAX_TRIES = 400  # decode attempts; a failed one can scan to the end, so this bounds the work


def norm(s):
    return re.sub(r"\s+", " ", s).strip()


def strip_front_matter(text):
    m = re.match(r"\A---\n.*?\n---\n", text, re.S)
    return text[m.end():] if m else text


def valid(v):
    return (isinstance(v, dict) and v.get("verdict") in ("ok", "revise")
            and isinstance(v.get("findings"), list))


def pick(text):
    """The valid critique that starts last: fenced blocks, then bare objects from the end back."""
    text = text[-MAX_SCAN:]
    best = None
    for n, m in enumerate(re.finditer(r"```(?:json|JSON)?\s*\n(.*?)```", text, re.S)):
        if n >= MAX_TRIES:
            break
        try:
            v = json.loads(m.group(1))
        except ValueError:
            continue
        if valid(v):
            best = (m.start(), v)
    dec, end = json.JSONDecoder(), len(text)
    for _ in range(MAX_TRIES):
        i = text.rfind("{", 0, end)
        if i < 0 or (best is not None and i < best[0]):
            break
        end = i
        try:
            v, _ = dec.raw_decode(text, i)
        except ValueError:
            continue
        if valid(v):
            best = (i, v)
            break
    return best[1] if best else None


QUOTE_MIN, QUOTE_MAX = 8, 300


def vet(f):
    """Return (finding, None) or (None, reason). Never raises on a malformed value."""
    if not isinstance(f, dict):
        return None, "invalid_format"
    q, p = f.get("quote"), f.get("problem")
    if not (isinstance(q, str) and q.strip() and isinstance(p, str) and p.strip()):
        return None, "invalid_format"
    s = f.get("suggestion", "")
    cf = f.get("changes_fact", True)  # absent = unknown: treat as changing a fact (no apply without a source)
    cat, sev = f.get("category"), f.get("severity")
    if (not isinstance(cat, str) or cat not in CATS or not isinstance(sev, str) or sev not in SEVS
            or not isinstance(s, str) or not isinstance(cf, bool)):
        return None, "invalid_format"
    q = q.strip()
    if "\n" in q or "\r" in q:
        return None, "quote_multiline"
    if len(q) < QUOTE_MIN:
        return None, "quote_too_short"
    if len(q) > QUOTE_MAX:
        return None, "quote_too_long"
    return {"quote": q, "problem": p.strip(), "suggestion": s.strip(),
            "category": cat, "severity": sev, "changes_fact": cf}, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("--draft", required=True)
    ap.add_argument("--label", default="")
    a = ap.parse_args()
    reasons = {}

    def drop(why, n=1):
        reasons[why] = reasons.get(why, 0) + n

    def emit(ok, error, verdict="", findings=()):
        print(json.dumps({"ok": ok, "error": error, "verdict": verdict, "findings": list(findings),
                          "dropped": {"total": sum(reasons.values()), "reasons": reasons}},
                         ensure_ascii=False))
        return 0 if ok else 1

    try:
        raw = open(a.capture, encoding="utf-8", errors="replace").read()
        draft = norm(open(a.draft, encoding="utf-8").read())
    except OSError as e:
        return emit(False, f"unreadable input: {e.strerror}")
    obj = pick(strip_front_matter(raw))
    if obj is None:
        return emit(False, "no JSON object with verdict and findings")
    verdict = obj["verdict"]
    if verdict not in ("ok", "revise"):
        return emit(False, "verdict is not ok|revise")

    kept = {}
    for f in obj["findings"]:
        v, why = vet(f)
        if v is None:
            drop(why)
        elif norm(v["quote"]) not in draft:
            drop("quote_not_in_draft")
        else:
            key = (norm(v["quote"]), v["category"])
            if key in kept:
                drop("duplicate_merged")
                old = kept[key]
                cf = old["changes_fact"] or v["changes_fact"]
                if SEVS.index(v["severity"]) < SEVS.index(old["severity"]):
                    old = kept[key] = v  # the higher severity brings its own wording
                old["changes_fact"] = cf
            else:
                kept[key] = v
    out = sorted(kept.values(), key=lambda x: SEVS.index(x["severity"]))  # stable: worst first
    if len(out) > LIMIT:
        drop("over_limit", len(out) - LIMIT)
        out = out[:LIMIT]
    for n, f in enumerate(out, 1):
        f["id"] = f"{a.label}{n}"
    return emit(True, "", verdict, out)


if __name__ == "__main__":
    sys.exit(main())
