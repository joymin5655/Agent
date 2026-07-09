#!/usr/bin/env python3
"""run-evals.py — the eval harness runner (E-1, deterministic layer).

Grades the completion verifier (core/infra/completion-verify.py) against a
LABELED dataset: each case pairs a claim with the verdict it MUST produce
(expect: CONFIRMED | REFUTED). The runner feeds every claim through the real
verifier in a hermetic tmp root and checks the verdict matches its label — it
evaluates the grader, not the code under test, so a regression in the verifier's
judgement (or a mislabeled case) shows up as a dropped accuracy.

Two rigor conventions layer on top of a plain pass/fail, both standard for evals:
  - Pass^k  — the whole suite is run k independent times (default 3); EVERY case
              must be correct in EVERY run AND the per-case verdicts must be
              identical across runs. A flaky/nondeterministic grader diverges and
              fails, even if a single run happened to pass.
  - baseline — evals/baseline.json declares a coverage floor (min_cases) and the
              accuracy bar (correct must equal total). Fewer cases than the floor,
              or any case now graded wrong, is a REGRESSION and fails CI.

Exit 0 iff every run is perfect, Pass^k holds, and there is no regression —
usable directly as a CI gate. Python 3 stdlib only (no jq, no PyYAML): the
dataset and baseline are JSON, and the verdict is parsed with json.

The semantic (LLM-judge) layer and the skill A/B dataset are later increments;
this file is the deterministic foundation they plug into (docs/scoring-convention.md).

Usage:
  run-evals.py [--dataset F] [--baseline F] [--repeat N] [--verifier PATH] [--quiet]
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
DEFAULT_DATASET = os.path.join(HERE, "datasets", "completion-verify.jsonl")
DEFAULT_BASELINE = os.path.join(HERE, "baseline.json")
DEFAULT_VERIFIER = os.path.join(REPO, "core", "infra", "completion-verify.py")

VALID_LABELS = ("CONFIRMED", "REFUTED")


def _safe_rel(p):
    """A fixture key must be a non-empty RELATIVE path with no '..' segment, so a
    materialized fixture cannot escape the hermetic tmp root (an absolute or ../
    key would write outside it and survive cleanup)."""
    return (isinstance(p, str) and p != "" and not os.path.isabs(p)
            and ".." not in p.replace("\\", "/").split("/"))


def load_cases(path):
    """Read the JSONL dataset -> list of case dicts. A malformed line or a case
    missing its label/claim is a dataset defect surfaced as a load error (the
    runner fails loudly rather than silently skipping a case)."""
    cases, errors, seen = [], [], set()
    with open(path, "r", encoding="utf-8") as fh:
        for n, line in enumerate(fh, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            try:
                case = json.loads(line)
            except ValueError as e:
                errors.append("line %d: not valid JSON (%s)" % (n, e))
                continue
            slug = case.get("slug")
            if not isinstance(slug, str) or not slug:
                errors.append("line %d: missing 'slug'" % n)
                continue
            if slug in seen:
                errors.append("line %d: duplicate slug %r" % (n, slug))
                continue
            seen.add(slug)
            if case.get("expect") not in VALID_LABELS:
                errors.append("case %s: 'expect' must be one of %s" % (slug, VALID_LABELS))
                continue
            if "claim" not in case:
                errors.append("case %s: missing 'claim'" % slug)
                continue
            fixture = case.get("fixture")
            if fixture is not None:
                if not isinstance(fixture, dict):
                    errors.append("case %s: 'fixture' must be an object" % slug)
                    continue
                unsafe = sorted(k for k in fixture if not _safe_rel(k))
                if unsafe:
                    errors.append("case %s: unsafe fixture path(s) %s — must be relative, no '..'"
                                  % (slug, unsafe))
                    continue
            cases.append(case)
    return cases, errors


def grade_case(case, verifier):
    """Run one case's claim through the verifier in a hermetic tmp root and
    return (actual_verdict, ok, detail). Any failure to run/parse the verifier
    resolves to actual='ERROR' (incorrect) — never a crash, never a silent pass."""
    expected = case["expect"]
    with tempfile.TemporaryDirectory(prefix="eval-") as root:
        try:
            # fixture keys are validated safe at load time; writing here is inside the
            # try so any residual OS error grades this case ERROR, never a crash.
            for rel, content in (case.get("fixture") or {}).items():
                dest = os.path.join(root, rel)
                os.makedirs(os.path.dirname(dest) or root, exist_ok=True)
                with open(dest, "w", encoding="utf-8") as fh:
                    fh.write("" if content is None else str(content))
            claim_path = os.path.join(root, "__eval_claim__.json")
            with open(claim_path, "w", encoding="utf-8") as fh:
                json.dump(case["claim"], fh)
            proc = subprocess.run(
                [sys.executable, verifier, "--root", root, claim_path],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                timeout=120, text=True,
            )
            verdict = json.loads(proc.stdout)
            actual = verdict.get("verdict", "ERROR")
        except Exception as e:  # fixture/claim write error, spawn error, timeout, unparseable output
            return "ERROR", False, "case could not be graded: %s" % e
    if actual not in VALID_LABELS:
        return actual, False, "verifier emitted a non-gate verdict: %r" % actual
    return actual, actual == expected, ""


def run_suite(cases, verifier):
    """Grade every case once; return {slug: (actual, ok, detail)}."""
    return {c["slug"]: grade_case(c, verifier) for c in cases}


def load_baseline(path):
    """Coverage floor. Fail-CLOSED: a missing/malformed baseline or a non-integer
    min_cases returns (None, error) so the caller fails the run rather than
    silently dropping the coverage floor to 0 (which would let a real case-count
    regression pass whenever the baseline is also broken). To run with no floor,
    ship a baseline with an explicit min_cases of 0."""
    try:
        with open(path, "r", encoding="utf-8") as fh:
            b = json.load(fh)
    except (OSError, ValueError) as e:
        return None, "baseline unreadable: %s" % e
    if not isinstance(b, dict):
        return None, "baseline is not an object"
    # Strict: min_cases must be a genuine JSON integer. A float (12.9) or numeric
    # string ("12") is NOT silently coerced via int() — the fail-closed contract
    # above covers "non-integer", and a truncated fractional floor is a footgun.
    # bool is an int subclass, so exclude it explicitly (true/false is not a count).
    mc = b.get("min_cases", 0)
    if isinstance(mc, bool) or not isinstance(mc, int):
        return None, "baseline min_cases is not an integer: %r" % mc
    return mc, None


def main(argv=None):
    ap = argparse.ArgumentParser(prog="run-evals.py", description="Eval harness runner (E-1).")
    ap.add_argument("--dataset", default=DEFAULT_DATASET)
    ap.add_argument("--baseline", default=DEFAULT_BASELINE)
    ap.add_argument("--repeat", type=int, default=3, help="Pass^k repetitions (default 3)")
    ap.add_argument("--verifier", default=DEFAULT_VERIFIER)
    ap.add_argument("--quiet", action="store_true", help="suppress the per-case report")
    args = ap.parse_args(argv)

    def emit(msg=""):
        if not args.quiet:
            print(msg)

    repeats = args.repeat if args.repeat and args.repeat > 0 else 1
    if not os.path.isfile(args.verifier):
        print("EVALS FAIL — verifier not found: %s" % args.verifier)
        return 1

    cases, errors = load_cases(args.dataset)
    if errors:
        print("EVALS FAIL — dataset has %d defect(s):" % len(errors))
        for e in errors:
            print("  - %s" % e)
        return 1
    if not cases:
        print("EVALS FAIL — dataset is empty: %s" % args.dataset)
        return 1

    min_cases, berr = load_baseline(args.baseline)
    if berr is not None:  # fail-closed: an unreadable coverage gate is a failed gate
        print("EVALS FAIL — %s" % berr)
        return 1

    total = len(cases)
    runs = []          # per-run {slug: (actual, ok, detail)}
    for k in range(1, repeats + 1):
        result = run_suite(cases, args.verifier)
        runs.append(result)
        correct = sum(1 for _, ok, _ in result.values() if ok)
        emit("run %d/%d: %d/%d correct" % (k, repeats, correct, total))
        if k == 1:
            for c in cases:
                actual, ok, detail = result[c["slug"]]
                tag = "ok" if ok else "MISMATCH"
                line = "  [%s] %s (expected %s, got %s)" % (tag, c["slug"], c["expect"], actual)
                emit(line + (("  -- " + detail) if detail else ""))

    # Pass^k: every run perfect AND identical per-case verdicts across runs.
    run1 = runs[0]
    failures = [s for s, (_, ok, _) in run1.items() if not ok]
    diverged = []
    for k in range(1, len(runs)):
        for slug in run1:
            if runs[k][slug][0] != run1[slug][0]:
                diverged.append("%s: run1=%s run%d=%s" % (slug, run1[slug][0], k + 1, runs[k][slug][0]))
    passk_ok = not failures and not diverged
    if diverged:
        emit("pass^%d: FAIL — nondeterministic across runs: %s" % (repeats, "; ".join(diverged[:5])))
    elif failures:
        emit("pass^%d: FAIL — %d case(s) graded wrong: %s" % (repeats, len(failures), ", ".join(failures[:8])))
    else:
        emit("pass^%d: OK (%d/%d runs perfect, verdicts identical)" % (repeats, repeats, repeats))

    # Regression vs baseline (min_cases loaded fail-closed above).
    correct1 = total - len(failures)
    coverage_ok = total >= min_cases
    accuracy_ok = correct1 == total
    emit("baseline: min_cases=%d (%d present), require correct==total (%d/%d) -> %s"
         % (min_cases, total, correct1, total,
            "ok" if (coverage_ok and accuracy_ok) else "REGRESSION"))

    ok = passk_ok and coverage_ok and accuracy_ok
    print("EVALS PASS" if ok else "EVALS FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
