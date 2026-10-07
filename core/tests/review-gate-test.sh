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

# summary: the matching reviews.jsonl row (by capture path) wins over backends.json
rm -f "$IDX"
mkcap "$WORK/c6.md" r6 codex complete; mkcap "$WORK/c7.md" r7 mystery complete
printf '{"role":"r6","backend":"codex","vendor":"anthropic","status":"complete","diff_key":"k","capture":"%s"}\n' "$WORK/c6.md" >> "$IDX"
out="$(AGENT_BACKENDS_FILE="$BK" python3 "$EVID" summary "$WORK/c6.md")"
printf '%s\n' "$out" | head -n 1 | grep -q "single-vendor" \
    && ok "u5-index-row-vendor-overrides-backends-json" || bad "u5" "$out"
printf '{"role":"r7","backend":"mystery","vendor":"openai","status":"complete","diff_key":"k","capture":"%s"}\n' "$WORK/c7.md" >> "$IDX"
out="$(AGENT_BACKENDS_FILE="$BK" python3 "$EVID" summary "$WORK/c7.md")"
printf '%s\n' "$out" | grep -q "single-vendor" \
    && bad "u6" "$out" || ok "u6-index-row-vendor-for-unknown-backend-counts-external"
printf '{"role":"advisor-free","backend":"mystery","vendor":"openai","status":"complete","diff_key":"k","capture":"%s"}\n' "$WORK/c7.md" >> "$IDX"
out="$(AGENT_BACKENDS_FILE="$BK" python3 "$EVID" summary "$WORK/c7.md")"
printf '%s\n' "$out" | head -n 1 | grep -q "single-vendor" \
    && ok "u7-index-row-advisor-role-excluded" || bad "u7" "$out"
out="$(AGENT_BACKENDS_FILE="$BK" python3 "$EVID" summary "$WORK/c4.md")"
printf '%s\n' "$out" | grep -q "single-vendor" \
    && bad "u8" "$out" || ok "u8-capture-without-index-row-falls-back-to-backends"
# status also comes from the matching row; the row path may be spelled differently
mkcap "$WORK/c8.md" r8 codex failed
mkdir -p "$WORK/lnk"; ln -sfn "$WORK" "$WORK/lnk/w"
printf '{"role":"r8","backend":"codex","vendor":"openai","status":"complete","diff_key":"k","capture":"%s"}\n' "$WORK/lnk/w/c8.md" >> "$IDX"
out="$(AGENT_BACKENDS_FILE="$BK" python3 "$EVID" summary "$WORK/c8.md")"
printf '%s\n' "$out" | grep -q "codex ✓ (complete)" && ! printf '%s\n' "$out" | grep -q single-vendor \
    && ok "u9-index-row-status-and-symlinked-path-match" || bad "u9" "$out"
rm -f "$IDX"

echo "=== auth risk class through the commit gate ==="
reset; mkdir -p "$REPO/src/auth"; echo "tok $RANDOM" > "$REPO/src/auth/session.py"; git -C "$REPO" add -A
expect_rc "a1-staged-auth-file-without-evidence-blocked" 1
grep -q "src/auth/session.py" "$WORK/err.txt" && ok "a1a-message-lists-auth-file" || bad "a1a" "$(cat "$WORK/err.txt")"
row openai complete
expect_rc "a2-staged-auth-file-with-external-review-passes" 0
reset; mkdir -p "$REPO/docs"; echo x > "$REPO/docs/author.md"; git -C "$REPO" add -A
expect_rc "a3-author-doc-not-risk-passes" 0

echo "=== merge commits: risk files equal to a parent contained in the remote DEFAULT branch are not re-gated ==="
MAIN_BR="$(git -C "$REPO" symbolic-ref --short HEAD)"
G() { git -C "$REPO" "$@"; }
gp() { echo "$REPO/$(G rev-parse --git-path "$1")"; }  # git-path is relative to the repo
reset; mkdir -p "$REPO/billing" "$REPO/src"
seq 1 40 > "$REPO/billing/x.py"; echo old > "$REPO/billing/old.py"
G add -A; G commit -q -m "base risk"; BASE="$(G rev-parse HEAD)"
ORIGIN="$WORK/origin.git"; rm -rf "$ORIGIN"; git init -q --bare "$ORIGIN"
G remote remove origin 2>/dev/null; G remote add origin "$ORIGIN"
# publish <rev>: make <rev> the tip of the remote default branch (origin/$MAIN_BR + origin/HEAD)
publish() { G push -q -f origin "$1:refs/heads/$MAIN_BR" && G remote set-head origin "$MAIN_BR" >/dev/null; }
G checkout -q -b side
echo "pay side" > "$REPO/billing/pay.py"; sed -i.bak '2s/.*/side-edit/' "$REPO/billing/x.py"; rm -f "$REPO/billing/x.py.bak"
G rm -q billing/old.py; G add -A; G commit -q -m "side risk"
G checkout -q "$MAIN_BR"
echo plain > "$REPO/src/b2.py"; sed -i.bak '38s/.*/main-edit/' "$REPO/billing/x.py"; rm -f "$REPO/billing/x.py.bak"
G add -A; G commit -q -m "main edit"
publish side   # the remote default branch now contains the parent
G merge -q --no-commit --no-ff side >/dev/null 2>&1
G diff --cached --name-only | grep -q "billing/pay.py" || bad "g0" "merge not in expected state"
# x.py differs from both parents -> risky; pay.py (added) and old.py (deleted) equal MERGE_HEAD -> dropped
expect_rc "g1-merge-with-fresh-merged-risk-content-blocked" 1
grep -q "billing/x.py" "$WORK/err.txt" && ! grep -q "billing/pay.py" "$WORK/err.txt" && ! grep -q "billing/old.py" "$WORK/err.txt" \
    && ok "g1a-only-the-unreviewed-risk-file-listed" || bad "g1a" "$(cat "$WORK/err.txt")"
G checkout -q side -- billing/x.py
expect_rc "g2-merge-risk-files-equal-merge-head-passes-without-evidence" 0
[[ -z "$(cd "$REPO" && python3 "$EVID" key --staged)" ]] && ok "g2a-key-staged-agrees-empty" || bad "g2a" "key not empty"
G update-index --chmod=+x billing/pay.py
expect_rc "g3-mode-only-change-vs-merge-head-blocked" 1
G update-index --chmod=-x billing/pay.py
# same content outside a merge needs review
G merge --abort >/dev/null 2>&1; reset
G checkout -q side -- billing/pay.py
expect_rc "g4-same-content-outside-merge-blocked" 1
# cherry-pick is not covered: CHERRY_PICK_HEAD never relaxes the gate
G rev-parse side > "$(gp CHERRY_PICK_HEAD)"
expect_rc "g5-cherry-pick-head-stays-gated" 1
rm -f "$(gp CHERRY_PICK_HEAD)"; reset
# merge inside a linked worktree (MERGE_HEAD lives under .git/worktrees/<name>/)
WT="$WORK/wt"
G worktree add -q -b wtb "$WT" "$MAIN_BR"
git -C "$WT" checkout -q -b side2 "$BASE"; echo n > "$WT/billing/n.py"; git -C "$WT" add -A; git -C "$WT" commit -q -m n
publish side2
git -C "$WT" checkout -q wtb; git -C "$WT" merge -q --no-commit --no-ff side2 >/dev/null 2>&1
(cd "$WT" && python3 "$EVID" check --staged 2>"$WORK/err.txt"); rc=$?
[[ $rc -eq 0 ]] && ok "g6-merge-in-linked-worktree-passes" || bad "g6" "rc=$rc $(cat "$WORK/err.txt")"
git -C "$WT" merge --abort >/dev/null 2>&1
echo "wt edit" > "$WT/billing/n.py"; git -C "$WT" add -A
(cd "$WT" && python3 "$EVID" check --staged 2>/dev/null); rc=$?
[[ $rc -eq 1 ]] && ok "g6a-linked-worktree-non-merge-risk-blocked" || bad "g6a" "rc=$rc"
G worktree remove --force "$WT"
# octopus: a risk file equal to ANY listed parent is dropped
G checkout -q -b o1 "$BASE"; echo a1 > "$REPO/billing/a1.py"; G add -A; G commit -q -m o1
G checkout -q -b o2 "$BASE"; echo a2 > "$REPO/billing/a2.py"; G add -A; G commit -q -m o2
G checkout -q -b o3 "$BASE"; echo a3 > "$REPO/billing/a3.py"; G add -A; G commit -q -m o3   # NOT pushed
G checkout -q "$MAIN_BR"
publish "$(G commit-tree -p o1 -p o2 -m tip "o1^{tree}")"
G merge -q --no-commit o1 o2 >/dev/null 2>&1
[[ "$(wc -l < "$(gp MERGE_HEAD)" | tr -d ' ')" == 2 ]] || bad "g7-0" "not an octopus merge"
expect_rc "g7-octopus-each-file-equals-one-parent-passes" 0
echo changed >> "$REPO/billing/a1.py"; G add -A
expect_rc "g7a-octopus-file-differing-from-all-parents-blocked" 1
reset
# octopus with one unpublished parent: its file earns no exemption, the published one still does
publish o1
G merge -q --no-commit o1 o3 >/dev/null 2>&1
expect_rc "g7b-octopus-unpublished-parent-file-blocked" 1
grep -q "billing/a3.py" "$WORK/err.txt" && ! grep -q "billing/a1.py" "$WORK/err.txt" \
    && ok "g7c-only-unpublished-parent-file-listed" || bad "g7c" "$(cat "$WORK/err.txt")"
reset

echo "=== merge exemption needs a parent contained in the remote DEFAULT branch ==="
publish "$BASE"
# local-only branch: same shape as g2, but never pushed
G checkout -q -b localonly "$BASE"; echo lo > "$REPO/billing/lo.py"; G add -A; G commit -q -m lo
G checkout -q "$MAIN_BR"
G merge -q --no-commit --no-ff localonly >/dev/null 2>&1
expect_rc "h1-merge-of-unpublished-branch-blocked" 1
reset
# a scratch branch pushed to the remote is NOT the default branch: no exemption
G push -q origin localonly:refs/heads/scratch
G merge -q --no-commit --no-ff localonly >/dev/null 2>&1
expect_rc "h1b-pushed-scratch-branch-not-trusted-blocked" 1
reset
# stash laundering: stage risk content, stash it, merge the stash commit
mkdir -p "$REPO/billing"; echo "laundered $RANDOM" > "$REPO/billing/laun.py"; G add -A; G stash push -q -m launder
G merge -q --no-commit --no-ff 'stash@{0}' >/dev/null 2>&1
expect_rc "h2-stash-laundering-chain-blocked" 1
reset; G stash drop -q 2>/dev/null
# hand-written MERGE_HEAD pointing at a stash-create commit
echo "forged $RANDOM" > "$REPO/billing/forged.py"; G add -A
G stash create > "$(gp MERGE_HEAD)"
expect_rc "h3-forged-merge-head-stash-create-blocked" 1
rm -f "$(gp MERGE_HEAD)"; reset
# MERGE_HEAD naming a sha that does not exist: no exemption, still blocked
echo "forged $RANDOM" > "$REPO/billing/forged.py"; G add -A
echo 0123456789012345678901234567890123456789 > "$(gp MERGE_HEAD)"
expect_rc "h4-bogus-merge-head-blocked" 1
rm -f "$(gp MERGE_HEAD)"; reset

# GITHEAD_<sha> in the environment of a plain commit must not inject a parent
publish side
G checkout -q side -- billing/pay.py
export "GITHEAD_$(G rev-parse side)=side"
expect_rc "h5-githead-env-on-plain-commit-blocked" 1
unset "GITHEAD_$(G rev-parse side)"
reset
# default branch resolved without refs/remotes/origin/HEAD: falls back to origin/$MAIN_BR
G remote set-head origin -d >/dev/null 2>&1
G merge -q --no-commit --no-ff side >/dev/null 2>&1; G checkout -q side -- billing/x.py
expect_rc "h6-fallback-to-origin-main-when-remote-head-unset-passes" 0
reset; G remote set-head origin "$MAIN_BR" >/dev/null

echo "=== pre-merge-commit hook: auto-merge commits are gated too ==="
G config core.hooksPath "$REPO_ROOT/core/git-hooks"
[[ -x "$REPO_ROOT/core/git-hooks/pre-merge-commit" ]] && ok "m0-pre-merge-commit-hook-executable" || bad "m0" "missing or not executable"
G checkout -q "$MAIN_BR"
G merge -q --no-ff -m "merge unpublished" localonly >"$WORK/c.out" 2>&1; rc=$?
[[ $rc -ne 0 && "$(G rev-parse HEAD)" != "$(G rev-parse localonly)" ]] && grep -q "council-review --staged" "$WORK/c.out" \
    && ok "m1-auto-merge-of-unpublished-risk-branch-blocked" || bad "m1" "rc=$rc $(tail -n 5 "$WORK/c.out")"
G merge --abort >/dev/null 2>&1; reset
publish side2
G merge -q --no-ff -m "merge published" side2 >"$WORK/c.out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && ok "m2-auto-merge-of-published-branch-passes" || bad "m2" "rc=$rc $(tail -n 5 "$WORK/c.out")"
# cherry-pick / rebase replay commits without running pre-commit: observed, documented gap
G checkout -q -b cp-target "$BASE"
G cherry-pick localonly >"$WORK/c.out" 2>&1; rc=$?
[[ $rc -eq 0 && -f "$REPO/billing/lo.py" ]] && ok "cp1-cherry-pick-of-risk-commit-skips-pre-commit-documented-gap" \
    || bad "cp1" "rc=$rc $(tail -n 3 "$WORK/c.out")"
G checkout -q "$MAIN_BR"; G branch -q -D cp-target
G config --unset core.hooksPath
G reset -q --hard "$BASE"
G branch -q -D side side2 o1 o2 o3 localonly wtb 2>/dev/null
G checkout -q -f "$MAIN_BR"
reset

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
