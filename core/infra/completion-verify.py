#!/usr/bin/env python3
"""completion-verify.py — independent completion-claim verifier (P3-5).

Re-checks a completion CLAIM in a SEPARATE context (the deterministic layer of
the hooks-mastery builder-validator pattern) and emits a shared-convention
verdict JSON. It structures the "테스트 통과 ≠ 실제 동작 / passing tests ≠ actually
working" lesson: a claim is CONFIRMED only when every cited file exists (and
contains its declared substring), every cited test exits 0, and every cited
assertion exits 0.

Refute-by-default: anything unverifiable — a malformed claim, an empty claim, a
missing file, a spawn error — resolves to REFUTED, never a crash and never a
silent pass. This is the deterministic seed of the LLM-output-quality eval
harness; the semantic layer on top is skills/verify-completion/SKILL.md, which
emits the same verdict schema.

Usage:
  completion-verify.py [--root DIR] <claim-file>
    <claim-file>   YAML (.yml/.yaml, when PyYAML is importable) or JSON (.json)
    --root DIR     project root the claim's paths/commands resolve against
                   (default: CWD)
  Exit 0 iff CONFIRMED; exit 1 otherwise — usable as a CI / wave GATE.

See docs/scoring-convention.md for the verdict schema and its relation to the
supervisor-goal-audit 25-point scorer.
"""
import argparse
import json
import os
import subprocess
import sys

SCHEMA_VERSION = "1.0.0"

# Bounds — a claim can never make the verifier do unbounded work.
_MAX_FILES = 50
_MAX_TESTS = 20
_MAX_ASSERTIONS = 20
_MAX_CMD_LEN = 500
# Cap the bytes read for a `contains` check so a claim citing a huge regular file
# can't slurp it whole and OOM the verifier. 5 MB is generous for source; a needle
# past it does not match (refute-by-default's safe direction — a false REFUTED, not
# a crash or a false CONFIRMED).
_MAX_CONTAINS_BYTES = 5_000_000


def _parse_timeout(raw):
    """Per-command wall-clock bound (seconds); degrade to 60 on any bad value so
    a typo like '2m' can never crash the verifier."""
    try:
        v = int(raw)
    except (TypeError, ValueError):
        return 60
    return v if v > 0 else 60


CMD_TIMEOUT = _parse_timeout(os.environ.get("AGENT_VERIFY_CMD_TIMEOUT", "60"))


def load_claim(path):
    """Parse the claim file (JSON always; YAML when PyYAML is importable) and
    return its inner `claim` mapping. Raises on unparseable / ill-shaped input;
    the caller turns a raise into a REFUTED verdict rather than crashing."""
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    if path.endswith((".yml", ".yaml")):
        try:
            import yaml  # optional dependency, same policy as hook_config
        except ImportError:
            raise ValueError("claim is YAML but PyYAML is not importable")
        doc = yaml.safe_load(text)
    else:
        doc = json.loads(text)
    if not isinstance(doc, dict):
        raise ValueError("claim root is not a mapping")
    claim = doc.get("claim", doc)  # a bare top-level mapping is accepted too
    if not isinstance(claim, dict):
        raise ValueError("`claim` is not a mapping")
    return claim


def _run(cmd, root):
    """Run a claim command; return True iff it exits 0. Never raises — a spawn
    error, timeout, or signal all count as failure. `start_new_session=True`
    isolates the command's process group so a teardown idiom that signals its
    group (`kill 0`, `trap 'kill 0' EXIT`) reaches only the command, never this
    verifier.

    Output is discarded to DEVNULL, not captured: only the exit code decides the
    verdict, and capturing a chatty command's stdout would let it accumulate
    unboundedly in the verifier's memory (a timeout bounds time, not memory) and
    OOM-kill the gate before it can refute."""
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


def _label(cmd):
    return cmd if isinstance(cmd, str) else repr(cmd)


def verify(claim, root):
    """Deterministically check the claim against `root`; return a verdict dict.
    Refute-by-default: any unmet cited fact appends a refutation, and a claim is
    CONFIRMED only when there is something to verify and nothing was refuted."""
    refutations = []
    dims = {
        "files": {"passed": 0, "total": 0},
        "tests": {"passed": 0, "total": 0},
        "assertions": {"passed": 0, "total": 0},
    }

    def _section(name, cap, kind):
        # Normalize a claim section to a bounded list. A present-but-wrong-type
        # section (`"tests": "false"`) is REFUTED, not silently dropped — else a
        # malformed section would let the rest of the claim CONFIRM. Exceeding the
        # cap is itself a refutation so padding can't hide a failing item past the
        # bound; the verdict can never be CONFIRMED by volume.
        raw = claim.get(name)
        if raw is None:
            return []
        if not isinstance(raw, list):
            refutations.append("`%s` must be a list" % name)
            return []
        if len(raw) > cap:
            refutations.append(
                "claim declares %d %s — exceeds the %d cap; the excess is not verified"
                % (len(raw), kind, cap)
            )
        return raw[:cap]

    for item in _section("files", _MAX_FILES, "files"):
        if isinstance(item, str):
            path, contains = item, None
        elif isinstance(item, dict):
            path, contains = item.get("path"), item.get("contains")
        else:
            path, contains = None, None
        dims["files"]["total"] += 1
        if not isinstance(path, str) or not path:
            refutations.append("files: an entry declares no `path`")
            continue
        full = os.path.join(root, path) if root else path
        if not os.path.isfile(full):
            refutations.append("file does not exist: %s" % path)
            continue
        if contains:
            try:
                with open(full, "r", encoding="utf-8", errors="replace") as fh:
                    body = fh.read(_MAX_CONTAINS_BYTES)
            except OSError:
                body = ""
            if str(contains) not in body:
                refutations.append("file %s lacks claimed content: %r" % (path, contains))
                continue
        dims["files"]["passed"] += 1

    for cmd in _section("tests", _MAX_TESTS, "tests"):
        dims["tests"]["total"] += 1
        if _run(cmd, root):
            dims["tests"]["passed"] += 1
        else:
            refutations.append("test did not pass: %s" % _label(cmd))

    for cmd in _section("assertions", _MAX_ASSERTIONS, "assertions"):
        dims["assertions"]["total"] += 1
        if _run(cmd, root):
            dims["assertions"]["passed"] += 1
        else:
            refutations.append("assertion did not hold: %s" % _label(cmd))

    total = sum(d["total"] for d in dims.values())
    passed = sum(d["passed"] for d in dims.values())
    if total == 0:
        refutations.append("nothing to verify — the claim cites no files, tests, or assertions")
    score = round(passed / total, 4) if total else 0.0
    confirmed = total > 0 and not refutations
    return {
        "verdict": "CONFIRMED" if confirmed else "REFUTED",
        "score": score,
        "target": str(claim.get("summary") or claim.get("slug") or "(unnamed claim)")[:200],
        "dimensions": dims,
        "refutations": refutations[:50],
        "schema_version": SCHEMA_VERSION,
    }


def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="completion-verify.py",
        description="Independent completion-claim verifier (P3-5).",
    )
    ap.add_argument("claim", help="path to a JSON/YAML completion claim")
    ap.add_argument("--root", default=None,
                    help="project root the claim resolves against (default: CWD)")
    args = ap.parse_args(argv)
    root = args.root or os.getcwd()

    try:
        claim = load_claim(args.claim)
    except Exception as e:  # refute-by-default: unverifiable => REFUTED, no crash
        verdict = {
            "verdict": "REFUTED", "score": 0.0,
            "target": os.path.basename(args.claim),
            "dimensions": {}, "refutations": ["unverifiable claim: %s" % e],
            "schema_version": SCHEMA_VERSION,
        }
        print(json.dumps(verdict, ensure_ascii=False))
        return 1

    verdict = verify(claim, root)
    print(json.dumps(verdict, ensure_ascii=False))
    return 0 if verdict["verdict"] == "CONFIRMED" else 1


if __name__ == "__main__":
    sys.exit(main())
