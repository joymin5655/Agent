#!/usr/bin/env bash
# review-gate-test.sh — W3 commit gate: review-evidence.py check --staged / summary
# and the pre-commit "review completeness" step.
#
# Matrix: risk/non-risk x external complete 0/1 (anthropic-only, external failed/timeout)
# x AGENT_REVIEW_OVERRIDE (none, 9 chars, 10+ chars); stale review; pre-commit end-to-end.
#
# Usage: bash core/tests/review-gate-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EVID="$REPO_ROOT/core/infra/review-evidence.py"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1 — $2"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
export AGENT_WORKERS_DIR="$WORK/workers"
export AGENT_LOGS_DIR="$WORK/logs"
unset AGENT_REVIEW_OVERRIDE
mkdir -p "$REPO/billing" "$REPO/src" "$AGENT_WORKERS_DIR"
git -C "$REPO" init -q
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "test"
echo base > "$REPO/README.md"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m base

IDX="$AGENT_WORKERS_DIR/reviews.jsonl"
OVR="$AGENT_LOGS_DIR/review-override.jsonl"

reset() {
    git -C "$REPO" reset -q --hard HEAD
    git -C "$REPO" clean -fdq
    rm -f "$IDX" "$OVR"
}
stage_risk()    { mkdir -p "$REPO/billing"; echo "pay $RANDOM" > "$REPO/billing/pay.py"; git -C "$REPO" add -A; }
stage_nonrisk() { mkdir -p "$REPO/src"; echo "x $RANDOM" > "$REPO/src/a.py"; git -C "$REPO" add -A; }
chk() { (cd "$REPO" && python3 "$EVID" check --staged 2>"$WORK/err.txt"); }
# row <vendor|null> <status> [key] — index row bound to the current staged key
row() {
    local key="${3:-$(cd "$REPO" && python3 "$EVID" key --staged)}" v="$1"
    [[ "$v" == null ]] && v='null' || v="\"$v\""
    printf '{"ts":"t","role":"r","backend":"b","vendor":%s,"status":"%s","diff_key":"%s","capture":"c"}\n' \
        "$v" "$2" "$key" >> "$IDX"
}
expect_rc() {  # expect_rc <name> <want-rc>
    chk >/dev/null; local rc=$?
    [[ $rc -eq $2 ]] && ok "$1" || bad "$1" "rc=$rc want=$2 err=$(cat "$WORK/err.txt")"
}

echo "=== check --staged matrix ==="
reset; stage_nonrisk
expect_rc "m1-non-risk-no-evidence-passes" 0
reset; stage_risk
expect_rc "m2-risk-no-evidence-blocked" 1
grep -q "billing/pay.py" "$WORK/err.txt" && grep -q "council-review --staged" "$WORK/err.txt" \
    && grep -q "AGENT_REVIEW_OVERRIDE" "$WORK/err.txt" \
    && ok "m2a-message-lists-files-and-remedies" || bad "m2a-message" "$(cat "$WORK/err.txt")"
reset; stage_risk; row openai complete
expect_rc "m3-risk-external-complete-passes" 0
reset; stage_risk; row anthropic complete
expect_rc "m4-risk-anthropic-only-blocked" 1
reset; stage_risk; row null complete
expect_rc "m4b-risk-null-vendor-blocked" 1
reset; stage_risk; row openai failed; row google timeout; row xai unavailable
expect_rc "m5-risk-external-non-complete-blocked" 1
reset; stage_risk; row anthropic complete; row openai complete
expect_rc "m6-risk-claude-plus-external-passes" 0
reset; stage_risk; printf 'not json\n{"diff_key"\n' > "$IDX"; row openai complete
expect_rc "m7-malformed-lines-tolerated" 0
reset; stage_risk; printf 'garbage\n' > "$IDX"
expect_rc "m7b-only-malformed-lines-blocked" 1
reset; stage_risk
printf '{"ts":"t","role":"advisor-free","backend":"openrouter","vendor":"openrouter","status":"complete","diff_key":"%s","capture":"c"}\n' \
    "$(cd "$REPO" && python3 "$EVID" key --staged)" >> "$IDX"
expect_rc "m8-advisory-lane-alone-blocked" 1
reset; stage_risk
LEX="$WORK/fwlink"; rm -f "$LEX"; ln -s "$REPO_ROOT/core/git-hooks" "$LEX"
(cd "$REPO" && python3 "$LEX/../infra/review-evidence.py" key --staged >/dev/null 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "m9-lexical-dotdot-symlink-path-resolves" || bad "m9" "rc=$rc"

echo "=== override ==="
reset; stage_risk
AGENT_REVIEW_OVERRIDE="123456789" chk >/dev/null; rc=$?
[[ $rc -eq 1 && ! -e "$OVR" ]] && ok "o1-9-char-override-rejected-no-log" || bad "o1" "rc=$rc"
AGENT_REVIEW_OVERRIDE="         x         " chk >/dev/null; rc=$?
[[ $rc -eq 1 ]] && ok "o1b-padded-override-rejected" || bad "o1b" "rc=$rc"
AGENT_REVIEW_OVERRIDE="all external lanes down" chk >/dev/null; rc=$?
if [[ $rc -eq 0 && "$(wc -l < "$OVR" | tr -d ' ')" == 1 ]] \
    && python3 - "$OVR" <<'PY'
import json, sys
r = json.loads(open(sys.argv[1]).readline())
assert r["reason"] == "all external lanes down" and r["diff_key"] and r["project_key"] and "ts" in r and "user" in r
PY
then ok "o2-10+-char-override-passes-and-logs-one-row"; else bad "o2" "rc=$rc"; fi
grep -qi "override" "$WORK/err.txt" && ok "o2a-stderr-notes-override" || bad "o2a" "$(cat "$WORK/err.txt")"
long="$(python3 -c 'print("y"*500)')"
rm -f "$OVR"; AGENT_REVIEW_OVERRIDE="$long" chk >/dev/null
[[ "$(python3 -c 'import json,sys;print(len(json.loads(open(sys.argv[1]).readline())["reason"]))' "$OVR")" == 300 ]] \
    && ok "o3-reason-truncated-to-300" || bad "o3" "len"
reset; stage_risk; row openai complete; AGENT_REVIEW_OVERRIDE="long enough reason" chk >/dev/null
[[ ! -e "$OVR" ]] && ok "o4-no-log-when-review-passes" || bad "o4" "override logged despite evidence"
reset; stage_nonrisk; AGENT_REVIEW_OVERRIDE="long enough reason" chk >/dev/null
[[ ! -e "$OVR" ]] && ok "o5-no-log-when-no-risk-files" || bad "o5" "logged"

echo "=== stale review ==="
reset; stage_risk; row openai complete
echo "changed" >> "$REPO/billing/pay.py"; git -C "$REPO" add -A
expect_rc "s1-risk-file-edited-after-review-blocked" 1
reset; stage_risk; row openai complete
mkdir -p "$REPO/src"; echo "doc" > "$REPO/src/plain.py"; git -C "$REPO" add -A
expect_rc "s2-non-risk-edit-after-review-passes" 0

echo "=== key error is fail-closed, but the logged user override still applies ==="
out="$(cd "$WORK" && python3 "$EVID" check --staged 2>&1)"; rc=$?
[[ $rc -eq 1 && -n "$out" ]] && ok "k1-outside-repo-exit1-with-message" || bad "k1" "rc=$rc"
KLOG="$WORK/klogs"; rm -rf "$KLOG"
(cd "$WORK" && AGENT_LOGS_DIR="$KLOG" AGENT_REVIEW_OVERRIDE="long enough reason" \
    python3 "$EVID" check --staged >/dev/null 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -q '"diff_key": null' "$KLOG/review-override.jsonl" 2>/dev/null \
    && ok "k2-key-error-override-passes-and-logs-null-key" || bad "k2" "rc=$rc"

echo "=== summary ==="
mkcap() {  # mkcap <file> <role> <backend> <status>
    printf -- '---\nrole: %s\nbackend: %s\nstatus: %s\ncaptured: t\n---\n\nbody\n' "$2" "$3" "$4" > "$1"
}
BK="$WORK/backends.json"
echo '{"backends":{"codex":{"vendor":"openai"},"claude":{"vendor":"anthropic"},"agy":{"vendor":"google"},"openrouter":{"vendor":"openrouter"}}}' > "$BK"
mkcap "$WORK/c1.md" r1 claude complete; mkcap "$WORK/c2.md" r2 codex failed; mkcap "$WORK/c3.md" r3 agy timeout
out="$(AGENT_BACKENDS_FILE="$BK" python3 "$EVID" summary "$WORK/c1.md" "$WORK/c2.md" "$WORK/c3.md")"; rc=$?
first="$(printf '%s\n' "$out" | head -n 1)"
[[ $rc -eq 0 && "$first" == "single-vendor review — not a council (no external lane returned)" ]] \
    && ok "u1-single-vendor-first-line" || bad "u1" "rc=$rc out=$out"
printf '%s\n' "$out" | grep -q "^Lane status: claude ✓ (complete) | codex ✗ (failed) | agy ✗ (timeout)$" \
    && ok "u1a-lane-status-line" || bad "u1a" "$out"
mkcap "$WORK/c4.md" r4 codex complete
out="$(AGENT_BACKENDS_FILE="$BK" python3 "$EVID" summary "$WORK/c1.md" "$WORK/c4.md")"
if ! printf '%s\n' "$out" | grep -q "single-vendor" && printf '%s\n' "$out" | grep -q "codex ✓ (complete)"; then
    ok "u2-no-warning-with-one-external-complete"
else bad "u2" "$out"; fi
out="$(AGENT_BACKENDS_FILE="$BK" python3 "$EVID" summary)"
printf '%s\n' "$out" | head -n 1 | grep -q "single-vendor" && ok "u3-no-captures-is-single-vendor" || bad "u3" "$out"
mkcap "$WORK/c5.md" advisor-free openrouter complete
out="$(AGENT_BACKENDS_FILE="$BK" python3 "$EVID" summary "$WORK/c1.md" "$WORK/c5.md")"
printf '%s\n' "$out" | head -n 1 | grep -q "single-vendor" && ok "u4-advisory-lane-not-external" || bad "u4" "$out"

echo "=== pre-commit end-to-end ==="
reset
git -C "$REPO" config core.hooksPath "$REPO_ROOT/core/git-hooks"
export PATH="$WORK/nobin:$PATH"   # gitleaks may or may not exist; hook tolerates both
stage_risk
git -C "$REPO" commit -q -m risky >"$WORK/c.out" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q "council-review --staged" "$WORK/c.out" \
    && ok "p1-risk-commit-without-evidence-rejected" || bad "p1" "rc=$rc $(tail -n 5 "$WORK/c.out")"
row openai complete
git -C "$REPO" commit -q -m risky >"$WORK/c.out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "p2-risk-commit-with-evidence-accepted" || bad "p2" "rc=$rc $(tail -n 5 "$WORK/c.out")"
mkdir -p "$REPO/src"; echo "x $RANDOM" > "$REPO/src/b.py"; git -C "$REPO" add -A
git -C "$REPO" commit -q -m plain >"$WORK/c.out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "p3-non-risk-commit-accepted" || bad "p3" "rc=$rc $(tail -n 5 "$WORK/c.out")"
stage_risk
AGENT_REVIEW_OVERRIDE="every external lane is down" git -C "$REPO" commit -q -m ovr >"$WORK/c.out" 2>&1; rc=$?
[[ $rc -eq 0 && -s "$OVR" ]] && ok "p4-override-commit-accepted-and-logged" || bad "p4" "rc=$rc"
# consumer layout: hook copied into a repo that does not vendor core/infra
CONS="$WORK/consumer"; mkdir -p "$CONS/hooks"
cp "$REPO_ROOT/core/git-hooks/pre-commit" "$CONS/hooks/pre-commit"
git -C "$REPO" config core.hooksPath "$CONS/hooks"
reset; stage_risk
git -C "$REPO" commit -q -m risky >"$WORK/c.out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q "review-evidence.py missing" "$WORK/c.out" \
    && ok "p5-relocated-hook-without-script-warns-and-skips" || bad "p5" "rc=$rc $(tail -n 5 "$WORK/c.out")"

# setup.sh --project layout: core.hooksPath points at a .git-hooks-framework SYMLINK to
# the framework's core/git-hooks; the hook must still find ../infra and enforce.
reset
ln -s "$REPO_ROOT/core/git-hooks" "$REPO/.git-hooks-framework"
git -C "$REPO" config core.hooksPath .git-hooks-framework
stage_risk
git -C "$REPO" commit -q -m risky >"$WORK/c.out" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q "council-review --staged" "$WORK/c.out" \
    && ok "p6-symlinked-hooks-dir-still-enforces" || bad "p6" "rc=$rc $(tail -n 5 "$WORK/c.out")"
rm -f "$REPO/.git-hooks-framework"

echo
echo "review-gate-test: $PASS pass, $FAIL fail"
[[ $FAIL -eq 0 ]]
