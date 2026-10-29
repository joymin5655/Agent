#!/usr/bin/env python3
"""goal-spec-check.py — gate a /supervise --goal-mode goal definition before it starts.

Usage: goal-spec-check.py <goal.json>
Exit:  0 = spec passes, 2 = spec invalid (each problem is printed on stderr as `field: reason`).

Required fields: outcome, verify, threshold, scope_in, scope_out, stop_when. `budget` is
optional (set only when the user gave one); when present it must be an object whose `waves`
and/or `tokens` are positive integers.

This is a shape check, not a judgement: a well-formed spec can still describe a poor goal.
It rejects empty or mistyped fields, an outcome that only names an activity, a threshold
with nothing measurable in it, and a verify command on the completion-verify.py deny list.
"""
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

LIST_FIELDS = ("scope_in", "scope_out", "stop_when")

# An outcome that opens with an activity verb and names no end state is a to-do, not a goal.
_ACTIVITY = re.compile(
    r"^\s*(?:(?:keep|continue|continuing|start|begin|proceed|go on|carry on)\b"
    r"|(?:work(?:ing)?\s+on|look(?:ing)?\s+(?:into|at)|make\s+progress|move\s+forward"
    r"|improv\w*|enhanc\w*|optimi[sz]\w*|investigat\w*|research\w*|explor\w*|polish\w*"
    r"|clean(?:ing)?\s+up|tidy\w*|iterat\w*)\b)",
    re.I,
)
# Words that state a condition which can be true or false at the end.
_END_STATE = re.compile(
    r"\b(?:exits?|returns?|passes|pass(?:ed)?|fails?|exists?|contains?|equals?|matches"
    r"|is|are|has|have|no|zero|none|all|every|only|merged|green|clean|removed|deleted"
    r"|reports?|prints?|rejects?|accepts?|reaches?|under|below|above|at least|at most)\b"
    r"|\d",
    re.I,
)
# A threshold is a true/false condition, or a number (with a unit or a count).
_MEASURABLE = re.compile(
    r"\d|\b(?:exit|exits|pass|passes|fail|fails|true|false|zero|none|all|every|no)\b", re.I
)


def _nonempty_str(v):
    return isinstance(v, str) and v.strip() != ""


def _denied(cmd):
    try:
        r = subprocess.run(
            [sys.executable, os.path.join(HERE, "completion-verify.py"), "--check-command", cmd],
            capture_output=True, text=True, timeout=30,
        )
    except (OSError, subprocess.SubprocessError) as e:
        return "deny-list screen failed: %s" % e
    if r.returncode == 0:
        return None
    return (r.stdout.strip() or "denied").replace("denied: ", "", 1)


def check(spec):
    errs = []
    if not isinstance(spec, dict):
        return ["spec: top level must be a JSON object"]

    outcome = spec.get("outcome")
    if not _nonempty_str(outcome):
        errs.append("outcome: required, one non-empty sentence describing the end state")
    elif _ACTIVITY.match(outcome) and not _END_STATE.search(outcome):
        errs.append("outcome: names an activity, not an end state — rewrite as what is true when done")

    verify = spec.get("verify")
    if not isinstance(verify, list) or not verify:
        errs.append("verify: required, a list of at least one runnable check command")
    else:
        for i, cmd in enumerate(verify):
            if not _nonempty_str(cmd):
                errs.append("verify[%d]: must be a non-empty command string" % i)
                continue
            why = _denied(cmd)
            if why:
                errs.append("verify[%d]: command refused by the deny list (%s)" % (i, why))

    thr = spec.get("threshold")
    if not _nonempty_str(thr):
        errs.append("threshold: required, a true/false condition or a number with unit and count")
    elif not _MEASURABLE.search(thr):
        errs.append("threshold: nothing measurable — state a pass/fail condition or a number")

    for f in LIST_FIELDS:
        v = spec.get(f)
        if not isinstance(v, list) or not v or not all(_nonempty_str(x) for x in v):
            errs.append("%s: required, a non-empty list of non-empty strings" % f)

    if spec.get("budget") is not None:
        b = spec["budget"]
        keys = ("waves", "tokens")
        if not isinstance(b, dict) or not b or any(k not in keys for k in b):
            errs.append("budget: when given, an object with `waves` and/or `tokens`")
        else:
            for k, v in b.items():
                if isinstance(v, bool) or not isinstance(v, int) or v <= 0:
                    errs.append("budget.%s: must be a positive integer" % k)
    return errs


def main(argv):
    if len(argv) != 2:
        print("usage: goal-spec-check.py <goal.json>", file=sys.stderr)
        return 2
    try:
        with open(argv[1], "r", encoding="utf-8") as fh:
            spec = json.load(fh)
    except (OSError, ValueError) as e:
        print("spec: cannot read %s: %s" % (argv[1], e), file=sys.stderr)
        return 2
    errs = check(spec)
    for e in errs:
        print("goal-spec: " + e, file=sys.stderr)
    if errs:
        return 2
    print("goal-spec: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
