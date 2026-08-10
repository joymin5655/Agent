#!/usr/bin/env python3
"""rubric-score.py — deterministic project-rubric scorer.

Scores a change against a project-supplied rubric (`.agent/rubric.yml` by
convention) and emits the shared-convention verdict JSON
(docs/scoring-convention.md). This is the DETERMINISTIC layer: each rubric
dimension carries a `grader_check` shell command, and the dimension passes iff
that command exits 0. It is the sibling of core/infra/completion-verify.py —
same refute-by-default discipline, same verdict schema — but it scores against a
reusable, project-owned rubric asset instead of a one-off completion claim.

Two things consume the rubric: this scorer (run per commit by the
rubric-commit-judge hook, advisory) and skills/verify-completion (which folds the
dimensions into its semantic, on-demand judge). A dimension whose `grader_check`
is absent/null is SEMANTIC-ONLY — skipped here, left to verify-completion.

Refute-by-default: a malformed/empty/unparseable rubric, a missing file, or a
failing check all resolve to REFUTED — never a crash, never a silent pass. A
dimension is CONFIRMED-worthy only when it has a check and that check passes.

Usage:
  rubric-score.py [--root DIR] [--rubric FILE]
    --rubric FILE  the rubric (YAML .yml/.yaml when PyYAML is importable, or JSON
                   .json). Default: .agent/rubric.yml under --root.
    --root DIR     project root the grader_check commands resolve against
                   (default: CWD).
  Exit 0 iff CONFIRMED; exit 1 otherwise — usable as a CI / commit advisory.

See docs/scoring-convention.md for the verdict schema and the producers table.
"""
import argparse
import json
import os
import subprocess
import sys
import time

SCHEMA_VERSION = "1.0.0"

# Bounds — a rubric can never make the scorer do unbounded work.
_MAX_DIMS = 50
_MAX_CMD_LEN = 500


def _parse_timeout(raw):
    """Per-check wall-clock bound (seconds); degrade to 60 on any bad value."""
    try:
        v = int(raw)
    except (TypeError, ValueError):
        return 60
    return v if v > 0 else 60


CMD_TIMEOUT = _parse_timeout(os.environ.get("AGENT_RUBRIC_CMD_TIMEOUT", "60"))
# Aggregate wall-clock ceiling across ALL dimensions. Per-check timeouts alone do
# not bound total time (50 dims x 60s each = 50 min), and the commit hook runs the
# scorer synchronously — so an aggregate cap keeps a heavy/hostile rubric from
# stalling every commit. Checks stop starting once this is exceeded; the rest are
# refuted (refute-by-default).
_MAX_TOTAL = _parse_timeout(os.environ.get("AGENT_RUBRIC_TOTAL_TIMEOUT", "120"))


def load_rubric(path):
    """Parse the rubric file (JSON always; YAML when PyYAML is importable) and
    return its list of dimension mappings. Raises on unparseable / ill-shaped
    input; the caller turns a raise into a REFUTED verdict rather than crashing."""
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    if path.endswith((".yml", ".yaml")):
        try:
            import yaml  # optional dependency, same policy as completion-verify
        except ImportError:
            raise ValueError("rubric is YAML but PyYAML is not importable")
        doc = yaml.safe_load(text)
    else:
        doc = json.loads(text)
    if not isinstance(doc, dict):
        raise ValueError("rubric root is not a mapping")
    dims = doc.get("dimensions")
    if not isinstance(dims, list):
        raise ValueError("`dimensions` is not a list")
    return doc.get("target"), dims


def _run(cmd, root):
    """Run a grader_check; return True iff it exits 0. Never raises — a spawn
    error, timeout, or signal all count as failure. Mirrors completion-verify._run
    (process-group isolation, discarded output, bounded time)."""
    if not isinstance(cmd, str) or not cmd.strip() or len(cmd) > _MAX_CMD_LEN:
        return False
    try:
        r = subprocess.run(
            cmd, shell=True, cwd=root or None,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=CMD_TIMEOUT, start_new_session=True,
        )
        return r.returncode == 0
    except Exception:
        return False


def score(target, dims, root):
    """Deterministically score the rubric's dimensions against `root`; return a
    verdict dict. Refute-by-default: a checkable dimension whose check fails is a
    refutation; a dimension with no check is semantic-only and neither passes nor
    fails here. CONFIRMED only when at least one dimension was checked and none
    was refuted."""
    refutations = []
    dimensions = {}
    weighted_passed = 0.0
    weighted_total = 0.0
    checked = 0
    deadline = time.monotonic() + _MAX_TOTAL

    if len(dims) > _MAX_DIMS:
        refutations.append(
            "rubric declares %d dimensions — exceeds the %d cap; the excess is not scored"
            % (len(dims), _MAX_DIMS)
        )
        dims = dims[:_MAX_DIMS]

    for i, dim in enumerate(dims):
        if not isinstance(dim, dict):
            refutations.append("dimension %d is not a mapping" % i)
            continue
        did = dim.get("id") or dim.get("name") or ("dim%d" % i)
        did = str(did)[:60]
        # Keep EVERY dimension in the audit trail: a duplicate id would otherwise
        # overwrite the earlier entry in `dimensions`, silently under-reporting how
        # many were checked (the score stays correct — weights are summed
        # independently — but .agent/logs/rubric-score.jsonl would hide one). Loop,
        # not a single rename, so a synthesized "id#n" cannot itself collide with a
        # literal later id of that exact shape.
        if did in dimensions:
            base, n = did, 1
            while did in dimensions:
                did = "%s#%d" % (base, n)
                n += 1
        check = dim.get("grader_check")
        try:
            weight = float(dim.get("weight", 1))
        except (TypeError, ValueError):
            weight = 1.0
        # A non-positive weight coerces to 1.0 (never 0 — an all-zero rubric would
        # divide by zero). Weight cannot zero a dimension out of scoring; to make a
        # dimension score-neutral, drop its grader_check (semantic-only) instead.
        if weight <= 0:
            weight = 1.0
        # A semantic-only dimension (no deterministic check) is recorded with
        # total 0 so a reader sees it exists, but it neither scores nor gates here.
        if check is None:
            dimensions[did] = {"passed": 0, "total": 0}
            continue
        if time.monotonic() > deadline:
            refutations.append(
                "rubric scoring exceeded the %ds total budget — remaining dimensions not scored"
                % _MAX_TOTAL
            )
            break
        checked += 1
        weighted_total += weight
        if _run(check, root):
            dimensions[did] = {"passed": 1, "total": 1}
            weighted_passed += weight
        else:
            dimensions[did] = {"passed": 0, "total": 1}
            refutations.append("dimension %s failed its grader_check: %s" % (did, str(check)[:200]))

    if checked == 0:
        refutations.append("nothing to score — no dimension declares a grader_check")

    sc = round(weighted_passed / weighted_total, 4) if weighted_total else 0.0
    confirmed = checked > 0 and not refutations
    return {
        "verdict": "CONFIRMED" if confirmed else "REFUTED",
        "score": sc,
        "target": str(target or "(unnamed rubric)")[:200],
        "dimensions": dimensions,
        "refutations": refutations[:50],
        "schema_version": SCHEMA_VERSION,
    }


def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="rubric-score.py",
        description="Deterministic project-rubric scorer.",
    )
    ap.add_argument("--root", default=None,
                    help="project root the grader_check commands resolve against (default: CWD)")
    ap.add_argument("--rubric", default=None,
                    help="rubric file (default: .agent/rubric.yml under --root)")
    args = ap.parse_args(argv)
    root = args.root or os.getcwd()
    rubric_path = args.rubric or os.path.join(root, ".agent", "rubric.yml")

    if not os.path.isfile(rubric_path):
        verdict = {
            "verdict": "REFUTED", "score": 0.0,
            "target": os.path.basename(rubric_path),
            "dimensions": {}, "refutations": ["no rubric file at: %s" % rubric_path],
            "schema_version": SCHEMA_VERSION,
        }
        print(json.dumps(verdict, ensure_ascii=False))
        return 1

    try:
        target, dims = load_rubric(rubric_path)
    except Exception as e:  # refute-by-default: unparseable => REFUTED, no crash
        verdict = {
            "verdict": "REFUTED", "score": 0.0,
            "target": os.path.basename(rubric_path),
            "dimensions": {}, "refutations": ["unscorable rubric: %s" % e],
            "schema_version": SCHEMA_VERSION,
        }
        print(json.dumps(verdict, ensure_ascii=False))
        return 1

    verdict = score(target, dims, root)
    print(json.dumps(verdict, ensure_ascii=False))
    return 0 if verdict["verdict"] == "CONFIRMED" else 1


if __name__ == "__main__":
    sys.exit(main())
