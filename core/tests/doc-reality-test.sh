#!/usr/bin/env bash
# doc-reality-test.sh — verify P1-1: core/tests/doc-reality.sh detects doc↔reality
# drift, passes a clean tree, and does not false-positive on legitimate phrasings.
#
# Each case builds an isolated temp doc-tree and runs the gate against it via its
# target-dir argument (mirrors supply-chain-scan-test.sh).
#
# Contract covered:
#   (a) phantom path ref in a current-state doc          -> detected (exit 1), named
#   (b) a clean doc-tree whose refs all resolve          -> PASS (exit 0)
#   (c) URL / ~/home / <placeholder> / glob / .agent      -> NOT flagged (exclusions)
#   (d) a listed-segment path under legacy/ (missing)     -> NOT flagged (legacy)
#   (e) backlog-count mismatch (declared != live P-rows)  -> detected (exit 1)
#   (f) artifact-count mismatch (declared != live skills) -> detected (exit 1)
#   (g) the REAL repo tree                                -> PASS (exit 0)
#   (h) fenced-code-block example phantom path            -> NOT flagged (fence rule)
#   (h2) same phantom in PROSE                            -> flagged (proves fence rule)
#   (i) backlog-count MATCH                               -> PASS (no false-positive)
#   (j) artifact-count MATCH                              -> PASS (no false-positive)
#   (h6) 4-space INDENTED code block (non-fence) phantom  -> flagged (contract: not stripped)
#   (h7) phantom between two >=4-space-indented ``` lines  -> flagged (>=4-indent is NOT a fence)
#   (l) UNTERMINATED (unclosed) fence                     -> flagged (malformed-doc)
#   (l2) doc ABOUT fences (4-backtick wrapping 3-backtick) -> NOT flagged (CommonMark tracker)
#   (m) ./-prefixed phantom in prose                      -> flagged (leading-./ normalized)
#   (n) phantom in a nested */README.md                   -> flagged (recursive scan)
#   (o) phantom in a nested docs/** subdir doc            -> flagged (docs recursive)
#   (p) phantom in CHANGELOG.md                           -> NOT flagged (excluded history)
#   (k) doc naming the gate's own script (self-exempt)    -> NOT flagged
#
# Usage: bash core/tests/doc-reality-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$REPO_ROOT/core/tests/doc-reality.sh"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# fresh_tree — a new isolated doc-tree root; echoes its path (mktemp, not a shared
# counter, because T=$(fresh_tree) runs in a subshell).
fresh_tree() { mktemp -d "$TMP_ROOT/tXXXXXX"; }

# gate <dir> — run the gate against <dir>; sets RC and OUT
OUT=""; RC=0
gate() { OUT="$(bash "$GATE" "$1" 2>&1)"; RC=$?; }

# helper: write a fixture plan doc declaring a P-row count
plan_prows() { # $1=dir $2=declared-number  (creates 2 real P-rows)
  mkdir -p "$1/docs"
  {
    printf '%s\n' '# plan'
    printf '%s\n' '| P0-1 | task | why | done | S |'
    printf '%s\n' '| P1-1 | task | why | done | S |'
    printf '%s\n' "count: \`grep -cE '^\\| P[0-3]-[0-9]+' docs/harness-improvement-plan.md\` = **$2**."
  } > "$1/docs/harness-improvement-plan.md"
}

echo "=== (a) phantom path ref in a current-state doc -> detected + named ==="
T=$(fresh_tree)
printf '%s\n' '# readme' 'See `core/tests/nonexistent.sh` for the reproduce.' > "$T/README.md"
gate "$T"; [[ $RC -eq 1 ]]; check "phantom-detected" $?
printf '%s' "$OUT" | grep -qF 'core/tests/nonexistent.sh'; check "phantom-named-in-hit" $?

echo
echo "=== (b) clean doc-tree whose refs resolve -> PASS ==="
T=$(fresh_tree); mkdir -p "$T/core/tests"
: > "$T/core/tests/real.sh"
printf '%s\n' 'Run the gate: `core/tests/real.sh`.' > "$T/README.md"
gate "$T"; [[ $RC -eq 0 ]]; check "clean-refs-pass" $?

echo
echo "=== (c) exclusions: URL / ~home / placeholder / glob / .agent -> NOT flagged ==="
T=$(fresh_tree)
printf '%s\n' 'Repo: github.com/foo/bar , video https://youtu.be/abc .' > "$T/README.md"
gate "$T"; [[ $RC -eq 0 ]]; check "url-not-flagged" $?

T=$(fresh_tree)
printf '%s\n' 'Installed to `~/.claude/hooks/foo.sh` and `$HOME/.agent/x.sh` at runtime.' > "$T/README.md"
gate "$T"; [[ $RC -eq 0 ]]; check "home-path-not-flagged" $?

T=$(fresh_tree)
printf '%s\n' 'First write `core/tests/<hook-name>-test.sh` (placeholder).' > "$T/AGENTS.md"
gate "$T"; [[ $RC -eq 0 ]]; check "placeholder-not-flagged" $?

T=$(fresh_tree)
printf '%s\n' 'Count with `ls core/hooks/*.py core/hooks/*.sh`.' > "$T/AGENTS.md"
gate "$T"; [[ $RC -eq 0 ]]; check "glob-not-flagged" $?

T=$(fresh_tree)
printf '%s\n' 'Runtime log goes to `.agent/logs/supervisor.jsonl` (never committed).' > "$T/README.md"
gate "$T"; [[ $RC -eq 0 ]]; check "runtime-path-not-flagged" $?

echo
echo "=== (d) a listed-segment path under legacy/ (missing) -> NOT flagged ==="
T=$(fresh_tree)
printf '%s\n' 'Old notes archived at `docs/legacy/old-thing.md` (removed).' > "$T/README.md"
gate "$T"; [[ $RC -eq 0 ]]; check "legacy-not-flagged" $?

echo
echo "=== (e) backlog-count mismatch (declares 29, live P-rows = 2) -> detected ==="
T=$(fresh_tree); plan_prows "$T" 29
gate "$T"; [[ $RC -eq 1 ]]; check "backlog-mismatch-detected" $?
printf '%s' "$OUT" | grep -qi 'backlog count'; check "backlog-mismatch-named-in-hit" $?

echo
echo "=== (f) artifact-count mismatch (declares 5 skills, live = 2) -> detected ==="
T=$(fresh_tree); mkdir -p "$T/docs" "$T/skills/one" "$T/skills/two"
: > "$T/skills/one/SKILL.md"; : > "$T/skills/two/SKILL.md"
printf '%s\n' '# plan' 'skills: `ls skills/*/SKILL.md | wc -l` = **5** (stale).' > "$T/docs/harness-improvement-plan.md"
gate "$T"; [[ $RC -eq 1 ]]; check "artifact-mismatch-detected" $?
printf '%s' "$OUT" | grep -qi 'artifact count'; check "artifact-mismatch-named-in-hit" $?

echo
echo "=== (h) fenced-code-block example phantom -> NOT flagged ==="
T=$(fresh_tree)
{ printf '%s\n' '# doc' 'Example:' '```bash' 'bash core/tests/example-only.sh --demo' '```' 'Done.'; } > "$T/README.md"
gate "$T"; [[ $RC -eq 0 ]]; check "fenced-example-not-flagged" $?

echo
echo "=== (h2) same phantom in PROSE -> flagged (proves the fence rule is load-bearing) ==="
T=$(fresh_tree)
printf '%s\n' 'Inline prose ref `core/tests/example-only.sh` here.' > "$T/README.md"
gate "$T"; [[ $RC -eq 1 ]]; check "prose-phantom-flagged" $?

echo
echo '=== (h4) INDENTED bash fence (3-space) example phantom -> NOT flagged (indented-fence strip) ==='
T=$(fresh_tree)
{ printf '%s\n' '# doc' 'Example (fence indented 3 spaces per CommonMark):' '   ```bash' '   bash core/tests/indented-only.sh --demo' '   ```' 'Done.'; } > "$T/README.md"
gate "$T"; [[ $RC -eq 0 ]]; check "indented-fence-not-flagged" $?

echo
echo "=== (h5) ~~~ fence example phantom -> NOT flagged (tilde-fence strip) ==="
T=$(fresh_tree)
{ printf '%s\n' '# doc' 'Example:' '~~~' 'bash core/tests/tilde-only.sh --demo' '~~~' 'Done.'; } > "$T/README.md"
gate "$T"; [[ $RC -eq 0 ]]; check "tilde-fence-not-flagged" $?

echo
echo "=== (h3) bare-prose phantom ending a sentence -> flagged (trailing-period strip) ==="
T=$(fresh_tree)
printf '%s\n' 'The missing runner is core/tests/ghost-runner.sh.' > "$T/README.md"
gate "$T"; [[ $RC -eq 1 ]]; check "sentence-end-phantom-flagged" $?
printf '%s' "$OUT" | grep -qF 'core/tests/ghost-runner.sh'; check "sentence-end-phantom-named" $?

echo
echo "=== (h6) 4-space INDENTED code block (non-fence) phantom -> flagged (contract: indented blocks NOT stripped) ==="
T=$(fresh_tree)
{ printf '%s\n' '# doc' 'Indented example follows:' '' '    bash core/tests/indented-block-phantom.sh --demo' 'End.'; } > "$T/README.md"
gate "$T"; [[ $RC -eq 1 ]]; check "indented-block-phantom-flagged" $?
printf '%s' "$OUT" | grep -qF 'core/tests/indented-block-phantom.sh'; check "indented-block-phantom-named" $?

echo
echo '=== (h7) phantom between two >=4-space-indented ``` markers -> flagged (CommonMark: >=4-indent is NOT a fence) ==='
T=$(fresh_tree)
{ printf '%s\n' '# doc' '' '    ```' 'Prose phantom core/tests/deep-indent-phantom.sh here.' '    ```' 'End.'; } > "$T/README.md"
gate "$T"; [[ $RC -eq 1 ]]; check "deep-indent-not-a-fence-flagged" $?
printf '%s' "$OUT" | grep -qF 'core/tests/deep-indent-phantom.sh'; check "deep-indent-phantom-named" $?

echo
echo "=== (i) backlog-count MATCH (declares 2, live = 2) -> PASS ==="
T=$(fresh_tree); plan_prows "$T" 2
gate "$T"; [[ $RC -eq 0 ]]; check "backlog-match-pass" $?

echo
echo "=== (j) artifact-count MATCH (declares 2 agents, live = 2) -> PASS ==="
T=$(fresh_tree); mkdir -p "$T/docs" "$T/agents"
: > "$T/agents/x.md"; : > "$T/agents/y.md"
printf '%s\n' '# plan' 'agents: `ls agents/*.md | wc -l` = **2**.' > "$T/docs/harness-improvement-plan.md"
gate "$T"; [[ $RC -eq 0 ]]; check "artifact-match-pass" $?

echo
echo "=== (l) UNTERMINATED (unclosed) fence -> flagged (malformed-doc; else it blinds the scan) ==="
T=$(fresh_tree)
{ printf '%s\n' '# doc' '```bash' 'echo hi' 'See core/tests/hidden-phantom.sh below the never-closed fence.'; } > "$T/README.md"
gate "$T"; [[ $RC -eq 1 ]]; check "unterminated-fence-flagged" $?
printf '%s' "$OUT" | grep -qi 'unterminated'; check "unterminated-fence-named-in-hit" $?

echo
echo "=== (l2) a doc ABOUT fences (4-backtick fence wrapping a literal 3-backtick line) -> NOT flagged (CommonMark tracker) ==="
T=$(fresh_tree); mkdir -p "$T/core/tests"; : > "$T/core/tests/real-l2.sh"
{ printf '%s\n' '# how to write a fence' '````markdown' '```' '````' 'Prose ref `core/tests/real-l2.sh` resolves.'; } > "$T/README.md"
gate "$T"; [[ $RC -eq 0 ]]; check "doc-about-fences-not-flagged" $?

echo
echo "=== (m) ./-prefixed phantom in prose -> flagged (leading-./ normalized off) ==="
T=$(fresh_tree)
printf '%s\n' 'Run `./core/tests/dotslash-phantom.sh` now.' > "$T/README.md"
gate "$T"; [[ $RC -eq 1 ]]; check "dotslash-phantom-flagged" $?
printf '%s' "$OUT" | grep -qF 'core/tests/dotslash-phantom.sh'; check "dotslash-phantom-named" $?

echo
echo "=== (n) phantom in a NESTED */README.md -> flagged (recursive doc scan) ==="
T=$(fresh_tree); mkdir -p "$T/core/hooks"
printf '%s\n' '# hooks' 'Run `core/tests/nested-phantom.sh` to smoke-test.' > "$T/core/hooks/README.md"
gate "$T"; [[ $RC -eq 1 ]]; check "nested-readme-phantom-flagged" $?
printf '%s' "$OUT" | grep -qF 'core/tests/nested-phantom.sh'; check "nested-readme-phantom-named" $?

echo
echo "=== (o) phantom in a nested docs/** subdir doc -> flagged (docs recursive) ==="
T=$(fresh_tree); mkdir -p "$T/docs/concepts"
printf '%s\n' '# concept' 'Ref `core/tests/deep-doc-phantom.sh`.' > "$T/docs/concepts/foo.md"
gate "$T"; [[ $RC -eq 1 ]]; check "recursive-docs-phantom-flagged" $?
printf '%s' "$OUT" | grep -qF 'core/tests/deep-doc-phantom.sh'; check "recursive-docs-phantom-named" $?

echo
echo "=== (p) phantom in CHANGELOG.md (backward-looking history) -> NOT flagged (excluded) ==="
T=$(fresh_tree)
printf '%s\n' '# changelog' 'Removed `core/tests/cross-ai-parity.sh` (renamed to adapter-parity.sh).' > "$T/CHANGELOG.md"
printf '%s\n' '# readme' 'All refs resolve.' > "$T/README.md"
gate "$T"; [[ $RC -eq 0 ]]; check "changelog-phantom-excluded" $?

echo
echo "=== (k) doc naming the gate's own script (self-exempt, absent here) -> NOT flagged ==="
T=$(fresh_tree)
printf '%s\n' 'The gate lives at `core/tests/doc-reality.sh`.' > "$T/README.md"
gate "$T"; [[ $RC -eq 0 ]]; check "self-exempt-not-flagged" $?

echo
echo "=== (g) the REAL repo tree -> PASS ==="
gate "$REPO_ROOT"; [[ $RC -eq 0 ]]; check "real-tree-pass" $?
[[ $RC -eq 0 ]] || printf '%s\n' "$OUT" | sed 's/^/      /'

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
