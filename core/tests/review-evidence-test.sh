#!/usr/bin/env bash
# review-evidence-test.sh — verify core/infra/review-evidence.py and the
# council-threshold.sh --list-risk-files mode it builds on.
#
# Contract under test:
#   project-key  <- same key as council-escalation-gate.py's state_dir() for one root
#   key --staged <- sha256 over staged blob ids of risk-path files only: changes when
#                   a risk file's content changes, stable when only a non-risk file
#                   changes, empty line when no risk file is staged, deleted handled
#   --list-risk-files <- one risk path per line (same risk_area_for SSOT);
#                   the default summary line + exit contract is unchanged
#
# Usage: bash core/tests/review-evidence-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EVID="$REPO_ROOT/core/infra/review-evidence.py"
THRESH="$REPO_ROOT/core/infra/council-threshold.sh"
GATE="$REPO_ROOT/core/hooks/council-escalation-gate.py"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1 — $2"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "test"
echo base > "$REPO/README.md"
mkdir -p "$REPO/billing" "$REPO/src"
echo base > "$REPO/billing/keep.py"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m baseline

reset_repo() {
    git -C "$REPO" reset -q --hard HEAD
    git -C "$REPO" clean -qfd
    mkdir -p "$REPO/src"
}
ev() { (cd "$REPO" && env -u AGENT_PROJECT_DIR -u CLAUDE_PROJECT_DIR python3 "$EVID" "$@"); }
th() { (cd "$REPO" && env -u AGENT_PROJECT_DIR -u CLAUDE_PROJECT_DIR bash "$THRESH" "$@"); }

# --- 1. project-key parity with the gate's state_dir key -------------------
gate_key="$(python3 - "$GATE" "$REPO" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("gate", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
root = m.canonical_root(sys.argv[2])
print(os.path.basename(m.state_dir(root)))
PY
)"
k1="$(ev project-key)"
k2="$(ev project-key --root "$REPO")"
mkdir -p "$REPO/src/deep"
k3="$(cd "$REPO/src/deep" && python3 "$EVID" project-key)"
if [[ -n "$gate_key" && "$k1" == "$gate_key" && "$k2" == "$gate_key" && "$k3" == "$gate_key" ]]; then
    ok "project-key == council gate state key (cwd, --root, subdir)"
else
    bad "project-key parity" "gate=$gate_key cwd=$k1 root=$k2 subdir=$k3"
fi
k4="$(cd "$REPO/src" && AGENT_PROJECT_DIR="$REPO" python3 "$EVID" project-key)"
[[ "$k4" == "$gate_key" ]] && ok "project-key honors AGENT_PROJECT_DIR" \
    || bad "project-key env" "got=$k4 want=$gate_key"

# --- 2. --list-risk-files ----------------------------------------------------
reset_repo
echo x > "$REPO/billing/a.py"; echo x > "$REPO/src/plain.py"
mkdir -p "$REPO/migrations"; echo x > "$REPO/migrations/1.sql"
git -C "$REPO" add -A
out="$(th --list-risk-files --staged | tr '\0' '\n' | LC_ALL=C sort | tr '\n' ' ')"
[[ "$out" == "billing/a.py migrations/1.sql " ]] \
    && ok "--list-risk-files --staged lists only risk paths" \
    || bad "--list-risk-files" "got=[$out]"
out="$(th --staged)"; rc=$?
[[ "$out" == "lines=3 files=3 risk=billing,production-migration" || "$out" == "lines=3 files=3 risk=production-migration,billing" ]] \
    && ok "default summary line unchanged" || bad "default summary" "got=[$out]"
th --staged >/dev/null; rc=$?
[[ $rc -eq 10 ]] && ok "default exit 10 on risk path unchanged" || bad "default exit" "rc=$rc"
reset_repo
echo x > "$REPO/src/plain.py"; git -C "$REPO" add -A
out="$(th --list-risk-files --staged)"
[[ -z "$out" ]] && ok "--list-risk-files empty when no risk path" || bad "--list-risk-files none" "got=[$out]"
out="$(th --staged)"; th --staged >/dev/null; rc=$?
[[ "$out" == "lines=1 files=1 risk=none" && $rc -eq 0 ]] \
    && ok "non-risk default contract unchanged (rc 0)" || bad "non-risk default" "out=[$out] rc=$rc"

# --- 3. key --staged -----------------------------------------------------------
reset_repo
echo v1 > "$REPO/billing/a.py"; echo p1 > "$REPO/src/plain.py"; git -C "$REPO" add -A
ka="$(ev key --staged)"
echo p2 > "$REPO/src/plain.py"; git -C "$REPO" add -A
kb="$(ev key --staged)"
[[ -n "$ka" && "$ka" == "$kb" ]] && ok "key stable when only a non-risk file changes" \
    || bad "key non-risk stability" "a=$ka b=$kb"
echo v2 > "$REPO/billing/a.py"; git -C "$REPO" add -A
kc="$(ev key --staged)"
[[ -n "$kc" && "$kc" != "$ka" ]] && ok "key changes when a risk file's content changes" \
    || bad "key risk sensitivity" "a=$ka c=$kc"
[[ "$ka" =~ ^[0-9a-f]{64}$ ]] && ok "key is a sha256 hex digest" || bad "key format" "got=$ka"

reset_repo
echo x > "$REPO/src/plain.py"; git -C "$REPO" add -A
out="$(ev key --staged)"; rc=$?
[[ $rc -eq 0 && -z "$out" ]] && ok "key empty (rc 0) when no risk file staged" \
    || bad "key no risk" "rc=$rc out=[$out]"

reset_repo
git -C "$REPO" rm -q billing/keep.py
out="$(ev key --staged)"; rc=$?
[[ $rc -eq 0 && "$out" =~ ^[0-9a-f]{64}$ ]] && ok "deleted risk file yields a key" \
    || bad "key deleted" "rc=$rc out=[$out]"
git -C "$REPO" reset -q --hard HEAD
echo changed > "$REPO/billing/keep.py"; git -C "$REPO" add -A
kmod="$(ev key --staged)"
[[ -n "$kmod" && "$kmod" != "$out" ]] && ok "deleted key differs from modified key" \
    || bad "deleted vs modified" "del=$out mod=$kmod"

# --- 4. hardening: subdir, glob metachars, non-ASCII, nothing staged, mode, git failure ---
reset_repo
echo v1 > "$REPO/billing/a.py"; git -C "$REPO" add -A
k_top="$(ev key --staged)"
k_sub="$(cd "$REPO/src" && python3 "$EVID" key --staged)"
[[ -n "$k_top" && "$k_top" == "$k_sub" ]] && ok "key identical from a subdirectory" \
    || bad "key subdir" "top=$k_top sub=$k_sub"

reset_repo
echo one > "$REPO/billing/a0.py"; echo two > "$REPO/billing/a[0].py"; git -C "$REPO" add -A
kg1="$(ev key --staged)"
echo two-changed > "$REPO/billing/a[0].py"; git -C "$REPO" add -A
kg2="$(ev key --staged)"
reset_repo
echo one > "$REPO/billing/a0.py"; echo two > "$REPO/billing/a[0].py"; git -C "$REPO" add -A
echo one-changed > "$REPO/billing/a0.py"; git -C "$REPO" add -A
kg3="$(ev key --staged)"
[[ "$kg1" != "$kg2" && "$kg1" != "$kg3" && "$kg2" != "$kg3" ]] \
    && ok "glob-metachar filename hashes its own blob (a[0].py vs a0.py)" \
    || bad "glob metachar" "1=$kg1 2=$kg2 3=$kg3"

reset_repo
echo x > "$REPO/billing/é.py"; git -C "$REPO" add -A
out="$(th --list-risk-files --staged | tr '\0' '\n')"
[[ "$out" == "billing/é.py" ]] && ok "non-ASCII risk path listed unquoted" || bad "non-ASCII list" "got=[$out]"
th --staged | grep -q "risk=billing" && ok "non-ASCII risk path trips the summary" || bad "non-ASCII summary" "$(th --staged)"
ke1="$(ev key --staged)"
echo y > "$REPO/billing/é.py"; git -C "$REPO" add -A
ke2="$(ev key --staged)"
[[ -n "$ke1" && "$ke1" != "$ke2" ]] && ok "non-ASCII risk path is keyed" || bad "non-ASCII key" "$ke1 $ke2"

# nothing staged: HEAD~1 fallback must not leak into the key
reset_repo
echo x > "$REPO/billing/c.py"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m risky
out="$(ev key --staged)"; rc=$?
[[ $rc -eq 0 && -z "$out" ]] && ok "nothing staged -> empty key (no HEAD~1 fallback)" || bad "nothing staged" "rc=$rc out=[$out]"
git -C "$REPO" reset -q --hard HEAD~1

reset_repo
echo v > "$REPO/billing/m.sh"; git -C "$REPO" add -A; git -C "$REPO" commit -q -m m
chmod +x "$REPO/billing/m.sh"; git -C "$REPO" add -A
km1="$(ev key --staged)"
git -C "$REPO" reset -q --hard HEAD
echo v2 > "$REPO/billing/m.sh"; git -C "$REPO" add -A
km2="$(ev key --staged)"
git -C "$REPO" reset -q --hard HEAD
chmod +x "$REPO/billing/m.sh"; echo v2 > "$REPO/billing/m.sh"; git -C "$REPO" add -A
km3="$(ev key --staged)"
[[ -n "$km1" && "$km2" != "$km3" && "$km1" != "$km2" ]] \
    && ok "mode-only change changes the key (same blob, different mode)" || bad "mode key" "1=$km1 2=$km2 3=$km3"
git -C "$REPO" reset -q --hard HEAD~1

# git failure -> exit 2, never a key
out="$(cd "$WORK" && python3 "$EVID" key --staged 2>"$WORK/err.txt")"; rc=$?
[[ $rc -eq 2 && -z "$out" && -s "$WORK/err.txt" ]] && ok "outside a repo -> exit 2 + stderr, no key" \
    || bad "git failure" "rc=$rc out=[$out]"
out="$(cd "$REPO" && PATH=/nonexistent /usr/bin/python3 "$EVID" key --staged 2>/dev/null)"; rc=$?
[[ $rc -eq 2 && -z "$out" ]] && ok "git unavailable -> exit 2, no key" || bad "git missing" "rc=$rc out=[$out]"

# --- 5. worktree gets its own key -----------------------------------------------
git -C "$REPO" worktree add -q "$WORK/wt" -b wt-branch >/dev/null 2>&1
kw="$(cd "$WORK/wt" && python3 "$EVID" project-key)"
kr="$(ev project-key)"
[[ -n "$kw" && "$kw" != "$kr" ]] && ok "linked worktree has its own project key" || bad "worktree key" "wt=$kw main=$kr"
k5="$(cd "$REPO/src" && AGENT_PROJECT_DIR="$WORK/wt" python3 "$EVID" project-key)"
[[ "$k5" == "$kr" ]] && ok "cwd repo wins over AGENT_PROJECT_DIR (gate order)" || bad "cwd precedence" "got=$k5 want=$kr"
k6="$(cd "$WORK" && AGENT_PROJECT_DIR="$REPO" python3 "$EVID" project-key)"
[[ "$k6" == "$kr" ]] && ok "env dir used when cwd is not in a repo" || bad "env fallback" "got=$k6 want=$kr"


# --- abbreviation stability: the key must not depend on core.abbrev (raw output
# abbreviates blob ids by default, and the abbreviation grows with object count).
AB="$WORK/abbrev"; mkdir -p "$AB/billing"
( cd "$AB" && git init -q && printf 'x\n' > billing/a.py && git add -A ) >/dev/null 2>&1
ka="$(cd "$AB" && git config core.abbrev 7 && python3 "$EVID" key --staged)"
kb="$(cd "$AB" && git config core.abbrev 12 && python3 "$EVID" key --staged)"
[[ -n "$ka" && "$ka" == "$kb" ]] && ok "key independent of core.abbrev" || bad "abbrev stability" "7=$ka 12=$kb"


echo
echo "review-evidence-test: $PASS pass, $FAIL fail"
[[ $FAIL -eq 0 ]]
