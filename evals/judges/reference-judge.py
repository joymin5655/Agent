#!/usr/bin/env python3
"""reference-judge.py — deterministic floor of the SEMANTIC eval layer (E-1).

A pluggable judge that conforms to the same CLI/verdict contract as
core/infra/completion-verify.py, so evals/run-evals.py can grade it against a
labeled dataset (`--verifier evals/judges/reference-judge.py`). Where the
completion verifier checks that cited tests *exit 0*, this judge checks the prior
question the "passing tests != actually working" lesson names: is the cited test
MEANINGFUL, or is it green-by-construction? It catches the failure
skills/verify-completion/SKILL.md step 2 calls out: "tests that are
green-by-construction (asserting `true`, testing nothing)".

It consumes a claim of the shape
    { "summary": "...", "test_sources": ["rel/path/to/x-test.sh", ...] }
and, for each cited test source (a path RELATIVE to --root), classifies the file
MEANINGFUL iff it contains >=1 REAL assertion that is NOT trivially-constant.

    CONFIRMED  iff  total > 0  AND  every cited source is meaningful.
    REFUTED    otherwise (a non-meaningful source, a missing/unsafe path, an
               empty/malformed claim). Refute-by-default: anything unverifiable
               resolves to REFUTED, never a crash — a top-level try/except turns
               any internal error into a REFUTED verdict with the error as a
               refutation. Reads are bounded; no path escapes --root.

DELIBERATE BIAS — false-REFUTED over false-CONFIRMED. A completion GATE must
NEVER bless a green-by-construction test, so on ambiguity the classifier declines
to count a line as a real assertion. Concretely: (a) a line that matches BOTH a
real-assertion pattern AND a trivial-constant tell is counted as TRIVIAL, not
real; (b) an output line (echo/printf/cat/print ...) is inert — never a real
assertion — so a test that merely PRINTS assertion-looking text does not confirm;
(c) the real-assertion pattern set is intentionally narrow (the specific bash and
python assert idioms), so an unrecognized idiom under-counts (a false-REFUTED, the
safe direction) rather than over-counts.

CEILING — this is the SYNTACTIC floor. It catches "no real assertion / only
constant assertions" via specific enumerated idioms (constant literal comparison,
assert True/1, assertTrue(True), identical-operand assertEqual, and the bash
equivalents). It CANNOT enumerate every always-true expression: an arbitrary
boolean combination (`assert True and cond`, `assert 1 == 1 or x`) or a
container-literal comparison (`assert [] == []`) is not recognized as constant and
counts as real (a residual false-CONFIRMED — the safe *documented* gap, not a
silent one). Nor does it catch SEMANTIC triviality: a real-looking assertion that
never exercises the changed code path (asserting on a mock, or `assert x == x` for
a computed x). That deeper judgment needs a real model and runs via
skills/verify-completion (the semantic pass) or a pluggable real `--verifier` —
NOT deterministically in CI. See evals/README.md.

Usage:
  reference-judge.py [--root DIR] <claim-file>
    <claim-file>   JSON claim (bare `{...}` or `{"claim": {...}}` wrapper)
    --root DIR     project root the claim's test_sources resolve against
                   (default: CWD)
  Exit 0 iff CONFIRMED; exit 1 otherwise — usable as a CI / wave GATE.

Python 3 stdlib only (no jq/PyYAML/pytest); portable to BSD/macOS and GNU/ubuntu.
See docs/scoring-convention.md for the verdict schema.
"""
import argparse
import json
import os
import re
import sys

SCHEMA_VERSION = "1.0.0"

# Bounds — a claim can never make the judge do unbounded work.
_MAX_SOURCES = 100          # cited test files considered (excess is refuted, not verified)
_MAX_READ_BYTES = 256 * 1024  # per-file bounded read (256 KB); a needle past it does not match

# ── real-vs-trivial line heuristics (portable `re`; no catastrophic backtracking) ──
#
# TRIVIAL tells — green-by-construction. A line matching any of these asserts
# nothing about the code under test (a constant expression, or an always-true
# form). Checked FIRST; a trivial line is never counted as real (the bias).
_TRIVIAL = [
    # python: assert on a bare constant / always-true expression
    r'\bassert\s*\(?\s*(True|1)\b\s*\)?\s*(,|$)',      # assert True | assert 1 | assert(True) | assert True, "m"
    r'\bassert\b[^#\n]*\bor\s+True\b',                  # assert <anything> or True   (short-circuits true)
    r'\bassert\s+True\s+or\b',                          # assert True or <anything>
    r'\bassertTrue\s*\(\s*(True|1)\s*\)',              # assertTrue(True) | assertTrue(1)
    r'\bassertFalse\s*\(\s*(False|0)\s*\)',            # assertFalse(False) | assertFalse(0)
    r'\bassert(Equal|Is|IsNot)\s*\(\s*([^,()]+?)\s*,\s*\2\s*\)',  # assertEqual(x, x) — identical operands
    # python: literal-vs-literal comparison — every operand is a constant, so it
    # tests nothing about the code (mirror of the bash `[[ 1 -eq 1 ]]` tell below).
    # Catches assert 1 == 1 | 2 == 3 | "x" == "x" | 0x1F == 31 | 1_000 == 1000 |
    # 1e3 == 1000 | True == True | 1 == 1 == 1 (chained) | assert(1==1) | trailing ,;#.
    # A single NON-literal operand (assert f(x) == 3, assert x == 1) is not constant,
    # so the first-operand or a chain step fails to match and it falls through to _REAL.
    # (Number = decimal/hex/octal/binary with `_` separators and optional exponent.)
    r'\bassert\s*\(?\s*'
    r'(?:[+-]?(?:0[xX][0-9a-fA-F_]+|0[oO][0-7_]+|0[bB][01_]+|[0-9][0-9_]*(?:\.[0-9_]+)?(?:[eE][+-]?[0-9_]+)?)|["\'][^"\']*["\']|True|False|None)'
    r'(?:\s*(?:==|!=|<=|>=|<|>|is\s+not|is)\s*'
    r'(?:[+-]?(?:0[xX][0-9a-fA-F_]+|0[oO][0-7_]+|0[bB][01_]+|[0-9][0-9_]*(?:\.[0-9_]+)?(?:[eE][+-]?[0-9_]+)?)|["\'][^"\']*["\']|True|False|None))+'
    r'\s*\)?\s*(?:[,#;]|$)',
    # bash: constant comparisons / always-true test
    r'^:\s*$',                                          # `:` no-op line (whole line)
    r'\[\[?\s*(true|false)\s*\]\]?',                   # [[ true ]] | [ true ]
    r'\[\[?\s*[0-9]+\s*(-eq|-ne|-lt|-gt|-le|-ge|==|=|!=)\s*[0-9]+\s*\]\]?',  # [[ 1 -eq 1 ]] | [ 1 = 1 ]
    r'\btest\s+[0-9]+\s+(-eq|-ne|-lt|-gt|-le|-ge)\s+[0-9]+\b',               # test 1 -eq 1
    r'\[\[?\s*(["\'][^"\']*["\'])\s*(==|=|!=)\s*\2\s*\]\]?',                 # [[ "a" == "a" ]] identical strings
]

# REAL tells — a genuine, non-constant assertion / failure path. Counted only
# when the line is NOT trivial and NOT an inert output line.
_REAL = [
    # bash
    r'\bgrep\s+-[A-Za-z]*q',                            # grep -q / -qE / -qF  (quiet-match assertion)
    r'\bdiff\s+\S',                                     # diff a b
    r'\bcmp\s+\S',                                      # cmp a b
    r'\|\|\s*(exit|return)\s+[1-9]',                   # ... || exit 1 | ... || return 1
    r'\|\|\s*fail\b',                                   # ... || fail
    r'\bcheck\s+["\']',                                 # check "name" $?  (repo's own assertion helper)
    r'\[\[?[^]]*(-eq|-ne|-lt|-gt|-le|-ge|==|!=)[^]]*\]\]?',  # [[ "$out" == exp ]] comparison in a bracket test
    r'\[\[?\s*-[a-zA-Z]\b',                             # [[ -f file ]] | [[ -n "$x" ]] file/string tests
    r'\btest\s+[^0-9\s][^;|&]*\s(-eq|-ne|-lt|-gt|-le|-ge)\s',  # test "$x" -eq N  (non-constant lhs)
    # python
    r'\bself\.assert[A-Za-z]+\s*\(',                    # self.assertEqual( ... ), self.assertIn( ... ), ...
    r'\bassert(Equal|True|False|In|NotIn|Is|IsNot|Raises|Greater|Less|IsNone|IsNotNone|AlmostEqual)\s*\(',
    r'\bpytest\.raises\s*\(',                           # pytest.raises(Err)
    r'\bwith\s+[^#\n]*\braises\s*\(',                   # with pytest.raises(Err):
    r'\bassert\s+\S',                                   # assert <expr>  (narrowest; trivial ones filtered above)
]

_TRIVIAL_RE = [re.compile(p) for p in _TRIVIAL]
_REAL_RE = [re.compile(p) for p in _REAL]

# inert output lines — never a real assertion. A test that only PRINTS
# assertion-looking text is not meaningful (guards the print/echo false-CONFIRMED).
_OUTPUT_RE = re.compile(r'^(echo|printf|cat|print)\b')


def _strip_comment(line):
    """Strip a trailing comment. Approximation (documented): a tiny quote-state
    machine strips from the first `#` that is at line start or preceded by
    whitespace AND lies OUTSIDE a single/double-quoted span — so a `#` inside
    "a #b" or 'a #b' is kept, and a shebang / whole-line comment becomes empty.
    It does NOT parse escapes or heredoc bodies (out of scope for the floor)."""
    quote = None
    for i, c in enumerate(line):
        if quote:
            if c == quote:
                quote = None
        elif c in ('"', "'"):
            quote = c
        elif c == '#' and (i == 0 or line[i - 1] in ' \t'):
            return line[:i]
    return line


def classify_lines(text):
    """Return (real, trivial): counts of real vs trivially-constant assertion
    lines in `text`. Line-based; comments stripped, output lines inert, trivial
    checked before real so a line that looks real but is constant counts trivial."""
    real = trivial = 0
    for raw in text.splitlines():
        line = _strip_comment(raw).strip()
        if not line or _OUTPUT_RE.match(line):
            continue
        if any(r.search(line) for r in _TRIVIAL_RE):
            trivial += 1
            continue
        if any(r.search(line) for r in _REAL_RE):
            real += 1
    return real, trivial


def _safe_rel(p):
    """Lexical first gate: a test_source must be a non-empty RELATIVE path with no
    '..' segment. This alone does NOT prove containment (a symlink under --root can
    still point outside); judge() additionally realpath-checks that the resolved
    file stays under --root, so no path — lexical or symlinked — escapes it."""
    return (isinstance(p, str) and p != "" and not os.path.isabs(p)
            and ".." not in p.replace("\\", "/").split("/"))


def _within_root(full, root):
    """True iff `full` resolves (following symlinks) to a path at or under `root`.
    Closes the symlink-escape hole _safe_rel's lexical check cannot: a symlinked
    test_source pointing outside the project is refused, not read."""
    base = os.path.realpath(root or os.getcwd())
    real = os.path.realpath(full)
    return real == base or real.startswith(base + os.sep)


def load_claim(path):
    """Parse the JSON claim and return its inner `claim` mapping. A bare top-level
    mapping is accepted, as is a `{"claim": {...}}` wrapper. Raises on
    unparseable / ill-shaped input; the caller turns a raise into REFUTED."""
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read(_MAX_READ_BYTES + 1)
    doc = json.loads(text)
    if not isinstance(doc, dict):
        raise ValueError("claim root is not a mapping")
    claim = doc.get("claim", doc)
    if not isinstance(claim, dict):
        raise ValueError("`claim` is not a mapping")
    return claim


def judge(claim, root):
    """Deterministically judge each cited test source for meaningfulness; return a
    verdict dict. CONFIRMED iff there is something to judge and every source holds
    a real, non-constant assertion."""
    refutations = []
    passed = total = 0

    raw = claim.get("test_sources")
    if raw is None:
        raw = []
    if not isinstance(raw, list):
        return _verdict(claim, 0, 0, ["`test_sources` must be a list"])
    if len(raw) > _MAX_SOURCES:
        refutations.append(
            "claim declares %d test_sources — exceeds the %d cap; the excess is not judged"
            % (len(raw), _MAX_SOURCES))
        raw = raw[:_MAX_SOURCES]
    if not raw:
        return _verdict(claim, 0, 0, ["no test_sources to judge"])

    for item in raw:
        total += 1
        if not _safe_rel(item):
            # never read an unsafe path — reject on the path alone (no leak)
            refutations.append(
                "unsafe test_source path rejected (must be relative, no '..'): %r"
                % (item if isinstance(item, str) else type(item).__name__))
            continue
        full = os.path.join(root, item) if root else item
        if not _within_root(full, root):
            # a symlink (or link chain) that resolves outside --root — never read it
            refutations.append(
                "%s: resolved path escapes --root (symlink/link) — rejected (no read)" % item)
            continue
        if not os.path.isfile(full):
            refutations.append("%s: missing or unreadable test source (no evidence)" % item)
            continue
        try:
            with open(full, "r", encoding="utf-8", errors="replace") as fh:
                text = fh.read(_MAX_READ_BYTES)
        except OSError as e:
            refutations.append("%s: could not read test source (%s)" % (item, e))
            continue
        real, trivial = classify_lines(text)
        if real >= 1:
            passed += 1
        elif trivial > 0:
            refutations.append(
                "%s: green-by-construction — only constant assertion(s) (%d), no real assertion"
                % (item, trivial))
        else:
            refutations.append(
                "%s: no real assertion — only output/no-op commands (echo/print/exit)" % item)

    return _verdict(claim, passed, total, refutations)


def _verdict(claim, passed, total, refutations):
    score = round(passed / total, 4) if total else 0.0
    confirmed = total > 0 and not refutations
    return {
        "verdict": "CONFIRMED" if confirmed else "REFUTED",
        "score": score,
        "target": str(claim.get("summary") or claim.get("slug") or "(unnamed claim)")[:200],
        "dimensions": {"test_meaningfulness": {"passed": passed, "total": total}},
        "refutations": refutations[:50],
        "schema_version": SCHEMA_VERSION,
    }


def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="reference-judge.py",
        description="Deterministic semantic-track judge — catches green-by-construction tests (E-1).",
    )
    ap.add_argument("claim", help="path to a JSON completion claim")
    ap.add_argument("--root", default=None,
                    help="project root the claim's test_sources resolve against (default: CWD)")
    args = ap.parse_args(argv)
    root = args.root or os.getcwd()

    try:
        claim = load_claim(args.claim)
    except Exception as e:  # refute-by-default: unverifiable => REFUTED, no crash
        verdict = {
            "verdict": "REFUTED", "score": 0.0,
            "target": os.path.basename(args.claim),
            "dimensions": {"test_meaningfulness": {"passed": 0, "total": 0}},
            "refutations": ["unverifiable claim: %s" % e],
            "schema_version": SCHEMA_VERSION,
        }
        print(json.dumps(verdict, ensure_ascii=False))
        return 1

    try:
        verdict = judge(claim, root)
    except Exception as e:  # any internal error degrades to REFUTED, never a crash
        verdict = {
            "verdict": "REFUTED", "score": 0.0,
            "target": str(claim.get("summary") or "(unnamed claim)")[:200],
            "dimensions": {"test_meaningfulness": {"passed": 0, "total": 0}},
            "refutations": ["judge error: %s" % e],
            "schema_version": SCHEMA_VERSION,
        }
    print(json.dumps(verdict, ensure_ascii=False))
    return 0 if verdict["verdict"] == "CONFIRMED" else 1


if __name__ == "__main__":
    sys.exit(main())
