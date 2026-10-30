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
#   author-vendor <- every company that wrote the change, sorted and comma-joined: the union of
#                   AGENT_AUTHOR_VENDOR (adds only; an unknown name is exit 2), branch prefix,
#                   working-copy folder prefix, every AI Co-Authored-By trailer of
#                   merge-base..HEAD and <git dir>/agent-author-vendors; only when all are
#                   empty the runtime profile, else anthropic
#   check --staged / summary <- a review by any author's company is not external; a
#                   reviews.jsonl row's own author_vendor only adds authors
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
# Hermetic: an inherited author or this machine's runtime profile must not decide anything.
unset AGENT_AUTHOR_VENDOR AGENT_REVIEW_OVERRIDE
export AGENT_PROFILE_FILE="$WORK/no-profile.json"
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
[[ "$out" == "lines=3 files=3 risk=billing,production-migration excluded=0" || "$out" == "lines=3 files=3 risk=production-migration,billing excluded=0" ]] \
    && ok "default summary line unchanged (plus the appended excluded= field)" || bad "default summary" "got=[$out]"
th --staged >/dev/null; rc=$?
[[ $rc -eq 10 ]] && ok "default exit 10 on risk path unchanged" || bad "default exit" "rc=$rc"
reset_repo
echo x > "$REPO/src/plain.py"; git -C "$REPO" add -A
out="$(th --list-risk-files --staged)"
[[ -z "$out" ]] && ok "--list-risk-files empty when no risk path" || bad "--list-risk-files none" "got=[$out]"
out="$(th --staged)"; th --staged >/dev/null; rc=$?
[[ "$out" == "lines=1 files=1 risk=none excluded=0" && $rc -eq 0 ]] \
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

# --- 6. author-vendor: which company wrote the change --------------------------------
# One throwaway repo per case; the branch is set with symbolic-ref so the test does not
# depend on init.defaultBranch. A profile is only used where a case names one.
AV="$WORK/av"; mkdir -p "$AV"
printf '{"main_vendor":"google"}\n' > "$WORK/p-google.json"
printf '{"main_vendor":"xai"}\n' > "$WORK/p-bogus.json"
printf 'not json\n' > "$WORK/p-broken.json"
printf '{"main_vendor":["google"]}\n' > "$WORK/p-list.json"
mk_repo() {  # mk_repo <dir> <branch> [commit message]
    local d="$1" br="$2" msg="${3:-base}"
    rm -rf "$d"; mkdir -p "$d"
    git -C "$d" init -q
    git -C "$d" symbolic-ref HEAD "refs/heads/$br"
    git -C "$d" config user.email "test@example.com"
    git -C "$d" config user.name "test"
    echo base > "$d/README.md"
    git -C "$d" add -A
    git -C "$d" commit -q -m "$msg"
}
av() {  # av <dir> [VAR=value...] — what `author-vendor` prints from inside <dir>
    local d="$1"; shift
    (cd "$d" && env -u AGENT_PROJECT_DIR -u CLAUDE_PROJECT_DIR "$@" python3 "$EVID" author-vendor 2>/dev/null)
}
expect_av() {  # expect_av <name> <want> <dir> [VAR=value...]
    local name="$1" want="$2" got; shift 2
    got="$(av "$@")"
    [[ "$got" == "$want" ]] && ok "author-vendor — $name" || bad "author-vendor $name" "got=[$got] want=[$want]"
}

mk_repo "$AV/plain" feat/x
expect_av "no hint at all is anthropic (what the gate assumed before the author was tracked)" anthropic "$AV/plain"
expect_av "AGENT_AUTHOR_VENDOR is read, trimmed and lowercased" openai "$AV/plain" AGENT_AUTHOR_VENDOR=" OpenAI "
expect_av "AGENT_AUTHOR_VENDOR takes a comma list" "anthropic,openai" "$AV/plain" AGENT_AUTHOR_VENDOR="openai, anthropic"
mk_repo "$AV/envwins" codex/x $'work\n\nCo-Authored-By: Claude <noreply@anthropic.com>'
expect_av "AGENT_AUTHOR_VENDOR only adds to branch and trailer" "anthropic,google,openai" "$AV/envwins" AGENT_AUTHOR_VENDOR=google
for bogus in acme "openai,acme"; do
    (cd "$AV/plain" && AGENT_AUTHOR_VENDOR="$bogus" python3 "$EVID" author-vendor >/dev/null 2>"$WORK/av.err"); rc=$?
    [[ $rc -eq 2 ]] && grep -q "unknown vendor" "$WORK/av.err" \
        && ok "author-vendor — AGENT_AUTHOR_VENDOR='$bogus' is exit 2" \
        || bad "author-vendor unknown '$bogus'" "rc=$rc"
done
mk_repo "$AV/codex-env" codex/x
expect_av "codex/ branch + AGENT_AUTHOR_VENDOR=anthropic keeps openai" "anthropic,openai" "$AV/codex-env" AGENT_AUTHOR_VENDOR=anthropic
expect_av "the runtime profile's main vendor is the last resort" google "$AV/plain" AGENT_PROFILE_FILE="$WORK/p-google.json"
expect_av "a profile naming an unknown vendor is ignored" anthropic "$AV/plain" AGENT_PROFILE_FILE="$WORK/p-bogus.json"
expect_av "an unparsable profile is ignored" anthropic "$AV/plain" AGENT_PROFILE_FILE="$WORK/p-broken.json"
expect_av "a profile whose main_vendor is not a string is ignored" anthropic "$AV/plain" AGENT_PROFILE_FILE="$WORK/p-list.json"
out="$(cd "$WORK" && python3 "$EVID" author-vendor 2>/dev/null)"
[[ "$out" == anthropic ]] && ok "author-vendor — outside a git repo it is the default" || bad "author-vendor no repo" "got=[$out]"
expect_av "outside a git repo the profile still applies" google "$WORK" AGENT_PROFILE_FILE="$WORK/p-google.json"
(cd "$AV/plain" && python3 "$EVID" author-vendor extra >/dev/null 2>&1); rc=$?
[[ $rc -eq 2 ]] && ok "author-vendor — an extra argument is a usage error (exit 2)" || bad "author-vendor usage" "rc=$rc"

# branch prefix: claude/ codex/ gemini/ agy/ (the profile says google, so anthropic can only come from the branch)
for pair in "claude/x:anthropic" "codex/fix-y:openai" "gemini/z:google" "agy/z:google" "Codex/x:openai"; do
    br="${pair%%:*}"; want="${pair##*:}"
    mk_repo "$AV/br" "$br"
    if [[ "$want" == anthropic ]]; then
        expect_av "branch $br" "$want" "$AV/br" AGENT_PROFILE_FILE="$WORK/p-google.json"
    else
        expect_av "branch $br" "$want" "$AV/br"
    fi
done
# a name that merely contains a tool name is not a prefix: it falls through to the profile (google)
for br in codex-x feature/codex-x codexx/y claude; do
    mk_repo "$AV/br" "$br"
    expect_av "branch $br names no tool" google "$AV/br" AGENT_PROFILE_FILE="$WORK/p-google.json"
done

# working-copy folder prefix: claude- codex- gemini- agy-
for pair in "claude-work:anthropic" "codex-work:openai" "gemini-work:google" "agy-work:google"; do
    d="${pair%%:*}"; want="${pair##*:}"
    mk_repo "$AV/$d" feat/x
    if [[ "$want" == anthropic ]]; then
        expect_av "folder $d" "$want" "$AV/$d" AGENT_PROFILE_FILE="$WORK/p-google.json"
    else
        expect_av "folder $d" "$want" "$AV/$d"
    fi
done
mk_repo "$AV/codexwork" feat/x
expect_av "folder codexwork (no dash) names no tool" google "$AV/codexwork" AGENT_PROFILE_FILE="$WORK/p-google.json"
mk_repo "$AV/codex-both" gemini/x
expect_av "branch and folder both count" "google,openai" "$AV/codex-both"

# last commit's Co-Authored-By trailer (the profile says google, so only the trailer can give the other answers)
mk_repo "$AV/t-codex" feat/x $'work\n\nCo-Authored-By: Codex <noreply@openai.com>'
expect_av "trailer naming Codex" openai "$AV/t-codex"
mk_repo "$AV/t-claude" feat/x $'work\n\nCo-Authored-By: Claude Opus <noreply@anthropic.com>'
expect_av "trailer naming Claude" anthropic "$AV/t-claude" AGENT_PROFILE_FILE="$WORK/p-google.json"
mk_repo "$AV/t-gemini" feat/x $'work\n\nCo-Authored-By: Gemini <noreply@google.com>'
expect_av "trailer naming Gemini" google "$AV/t-gemini"
mk_repo "$AV/t-lower" feat/x $'work\n\nco-authored-by: codex <noreply@openai.com>'
expect_av "trailer key is case-insensitive" openai "$AV/t-lower"
mk_repo "$AV/t-human" feat/x $'work\n\nCo-Authored-By: Jane Doe <jane@example.com>'
expect_av "a human co-author is skipped (falls through to the profile)" google "$AV/t-human" AGENT_PROFILE_FILE="$WORK/p-google.json"
mk_repo "$AV/t-two" feat/x $'work\n\nCo-Authored-By: Claude <noreply@anthropic.com>\nCo-Authored-By: Codex <noreply@openai.com>'
expect_av "two AI trailers on one commit both count" "anthropic,openai" "$AV/t-two"
mk_repo "$AV/t-head" feat/x $'first\n\nCo-Authored-By: Codex <noreply@openai.com>'
echo more >> "$AV/t-head/README.md"; git -C "$AV/t-head" commit -q -am "second, no trailer"
expect_av "without a merge-base only HEAD's trailers are read" anthropic "$AV/t-head"
# with a default branch: every commit of merge-base..HEAD counts, commits before it do not
mk_repo "$AV/t-range" main $'base\n\nCo-Authored-By: Gemini <noreply@google.com>'
git -C "$AV/t-range" checkout -q -b feat/x
echo a >> "$AV/t-range/README.md"; git -C "$AV/t-range" commit -q -am $'one\n\nCo-Authored-By: Codex <noreply@openai.com>'
echo b >> "$AV/t-range/README.md"; git -C "$AV/t-range" commit -q -am "two, no trailer"
expect_av "an earlier commit of the branch still counts; the default branch's own commits do not" openai "$AV/t-range"
mk_repo "$AV/codex-trailer" feat/x $'work\n\nCo-Authored-By: Claude <noreply@anthropic.com>'
expect_av "folder prefix and trailer both count" "anthropic,openai" "$AV/codex-trailer"
mk_repo "$AV/gemini-trailer" codex/x $'work\n\nCo-Authored-By: Claude <noreply@anthropic.com>'
expect_av "branch, folder and trailer all count" "anthropic,google,openai" "$AV/gemini-trailer"

# <git dir>/agent-author-vendors (call-worker.sh writing lanes): known names count, others are ignored
mk_repo "$AV/rec" claude/x
printf 'openai\nacme\n' > "$AV/rec/.git/agent-author-vendors"
expect_av "a recorded openai writing lane on a claude/ branch counts too" "anthropic,openai" "$AV/rec"
# a record line is "<vendor>\t<branch>" ("@<commit>" when detached), and every line counts on
# every branch: a branch switch or rename carries the uncommitted change along, so it must not
# drop the company that wrote it
mk_repo "$AV/rec-br" feat/x
printf 'openai\tfeat/x\n' > "$AV/rec-br/.git/agent-author-vendors"
expect_av "a record for the current branch counts" openai "$AV/rec-br" AGENT_PROFILE_FILE="$WORK/p-google.json"
printf 'openai\tfeat/old\n' > "$AV/rec-br/.git/agent-author-vendors"
expect_av "a record for another branch counts too" openai "$AV/rec-br" AGENT_PROFILE_FILE="$WORK/p-google.json"
printf 'openai\tfeat/x-2\nanthropic\tfeat/x\n' > "$AV/rec-br/.git/agent-author-vendors"
expect_av "the records of every branch are joined" "anthropic,openai" "$AV/rec-br" AGENT_PROFILE_FILE="$WORK/p-google.json"
printf 'openai\n' > "$AV/rec-br/.git/agent-author-vendors"
expect_av "a line without a branch counts" openai "$AV/rec-br" AGENT_PROFILE_FILE="$WORK/p-google.json"
printf 'openai\tfeat/x\n' > "$AV/rec-br/.git/agent-author-vendors"
git -C "$AV/rec-br" branch -m feat/y
expect_av "renaming the branch keeps the record" openai "$AV/rec-br" AGENT_PROFILE_FILE="$WORK/p-google.json"
git -C "$AV/rec-br" checkout -q -b feat/z
expect_av "switching to a new branch keeps the record" openai "$AV/rec-br" AGENT_PROFILE_FILE="$WORK/p-google.json"
mk_repo "$AV/rec-det" feat/x
git -C "$AV/rec-det" checkout -q --detach
rec_head="$(git -C "$AV/rec-det" rev-parse HEAD)"
printf 'openai\t@%s\n' "$rec_head" > "$AV/rec-det/.git/agent-author-vendors"
expect_av "detached HEAD: a record for this commit counts" openai "$AV/rec-det" AGENT_PROFILE_FILE="$WORK/p-google.json"
printf 'openai\t@0000000000000000000000000000000000000000\n' > "$AV/rec-det/.git/agent-author-vendors"
expect_av "detached HEAD: a record for another commit counts too" openai "$AV/rec-det" AGENT_PROFILE_FILE="$WORK/p-google.json"

# detached HEAD: the branch name is gone, so the rest of the chain decides
mk_repo "$AV/detached" codex/x
git -C "$AV/detached" checkout -q --detach
expect_av "detached HEAD ignores the old branch name (falls through to the profile)" google "$AV/detached" AGENT_PROFILE_FILE="$WORK/p-google.json"

# --- 7. the commit gate and the council summary use the author --------------------------
GW="$WORK/gate-workers"; GL="$WORK/gate-logs"; mkdir -p "$GW"
gate_reset() { rm -f "$GW/reviews.jsonl"; }
gate_repo() {  # gate_repo <dir> <branch> [commit message] — a repo with billing/pay.py staged, no reviews yet
    mk_repo "$@"
    mkdir -p "$1/billing"; echo "pay $RANDOM" > "$1/billing/pay.py"
    git -C "$1" add -A
    gate_reset
}
gate_row() {  # gate_row <dir> <vendor|null> <status> [author: omit | null | name] [role]
    local d="$1" vendor="$2" status="$3" author="${4:-}" role="${5:-r}" key v af=""
    key="$(cd "$d" && python3 "$EVID" key --staged)"
    if [[ "$vendor" == null ]]; then v=null; else v="\"$vendor\""; fi
    if [[ "$author" == null ]]; then af=',"author_vendor":null'; elif [[ -n "$author" ]]; then af=",\"author_vendor\":\"$author\""; fi
    printf '{"ts":"t","role":"%s","backend":"b","vendor":%s,"status":"%s","diff_key":"%s"%s,"capture":"c"}\n' \
        "$role" "$v" "$status" "$key" "$af" >> "$GW/reviews.jsonl"
}
expect_gate() {  # expect_gate <name> <want-rc> <dir> [VAR=value...] — exit code of `check --staged`
    local name="$1" want="$2" d="$3" rc; shift 3
    (cd "$d" && env -u AGENT_PROJECT_DIR -u CLAUDE_PROJECT_DIR AGENT_WORKERS_DIR="$GW" AGENT_LOGS_DIR="$GL" \
        "$@" python3 "$EVID" check --staged >/dev/null 2>"$WORK/gate.err")
    rc=$?
    [[ $rc -eq $want ]] && ok "gate — $name" || bad "gate $name" "rc=$rc want=$want err=$(head -n 2 "$WORK/gate.err")"
}

# an openai-written change (branch codex/): an openai review is the author's own company
gate_repo "$AV/g1" codex/x
gate_row "$AV/g1" openai complete
expect_gate "openai author, openai review: not external, blocked" 1 "$AV/g1"
grep -q "by a company other than the authors 'openai'" "$WORK/gate.err" \
    && ok "gate — the refusal names the author it compared against" || bad "gate message" "$(head -n 3 "$WORK/gate.err")"
gate_reset; gate_row "$AV/g1" " OpenAI " complete
expect_gate "the lane's vendor is compared trimmed and lowercased too: ' OpenAI ' is still openai" 1 "$AV/g1"
gate_reset; gate_row "$AV/g1" openai complete
gate_row "$AV/g1" anthropic complete
expect_gate "openai author, openai + anthropic reviews: passes" 0 "$AV/g1"
gate_reset; gate_row "$AV/g1" google complete
expect_gate "openai author, google review: passes" 0 "$AV/g1"
# an anthropic-written change (branch claude/)
gate_repo "$AV/g2" claude/x
gate_row "$AV/g2" anthropic complete
expect_gate "anthropic author, anthropic review: blocked" 1 "$AV/g2"
gate_reset; gate_row "$AV/g2" openai complete
expect_gate "anthropic author, openai review: passes" 0 "$AV/g2"
# no hint: the default author is anthropic, exactly as before the author was tracked
gate_repo "$AV/g3" feat/x
gate_row "$AV/g3" anthropic complete
expect_gate "no author hint, anthropic review: blocked (unchanged behavior)" 1 "$AV/g3"
gate_reset; gate_row "$AV/g3" openai complete
expect_gate "no author hint, openai review: passes (unchanged behavior)" 0 "$AV/g3"
gate_reset; gate_row "$AV/g3" anthropic complete
expect_gate "AGENT_AUTHOR_VENDOR=openai at commit time makes that anthropic review external" 0 "$AV/g3" AGENT_AUTHOR_VENDOR=openai
# folder and trailer hints
gate_repo "$AV/codex-g4" feat/x
gate_row "$AV/codex-g4" openai complete
expect_gate "folder prefix codex-: an openai review is not external" 1 "$AV/codex-g4"
gate_reset; gate_row "$AV/codex-g4" anthropic complete
expect_gate "folder prefix codex-: an anthropic review passes" 0 "$AV/codex-g4"
gate_repo "$AV/g5" feat/x $'work\n\nCo-Authored-By: Codex <noreply@openai.com>'
gate_row "$AV/g5" openai complete
expect_gate "Codex co-author trailer: an openai review is not external" 1 "$AV/g5"
gate_reset; gate_row "$AV/g5" google complete
expect_gate "Codex co-author trailer: a google review passes" 0 "$AV/g5"
# the row's own author_vendor (written by call-worker.sh at review time) only adds authors:
# it can narrow what counts as external, never widen it past the commit-time set
gate_repo "$AV/g6" claude/x
gate_row "$AV/g6" anthropic complete openai
expect_gate "row author_vendor=openai does not clear the claude/ author: an anthropic review stays blocked" 1 "$AV/g6"
gate_reset; gate_row "$AV/g6" anthropic complete anthropic
expect_gate "row author_vendor=anthropic agrees with the guess: blocked" 1 "$AV/g6"
gate_reset; gate_row "$AV/g6" anthropic complete null
expect_gate "row author_vendor=null falls back to the guess: blocked" 1 "$AV/g6"
gate_reset; gate_row "$AV/g6" anthropic complete
expect_gate "a row without the field (older index) falls back to the guess: blocked" 1 "$AV/g6"
gate_reset; gate_row "$AV/g6" openai complete openai
expect_gate "row author_vendor=openai narrows: that openai review of a claude/ change is blocked" 1 "$AV/g6"
gate_reset; gate_row "$AV/g6" google complete "anthropic,openai"
expect_gate "row author_vendor as a list: a google review is still external" 0 "$AV/g6"
gate_repo "$AV/g7" codex/x
gate_row "$AV/g7" openai complete anthropic
expect_gate "row author_vendor=anthropic does not clear the codex/ author: an openai review stays blocked" 1 "$AV/g7"
gate_reset; gate_row "$AV/g7" openai complete " OpenAI "
expect_gate "row author_vendor is compared trimmed and lowercased: blocked" 1 "$AV/g7"
# the holes the union closes
gate_reset; gate_row "$AV/g7" openai complete
expect_gate "codex/ branch + AGENT_AUTHOR_VENDOR=anthropic: an openai review is still the author's own" 1 "$AV/g7" AGENT_AUTHOR_VENDOR=anthropic
expect_gate "an unknown AGENT_AUTHOR_VENDOR name is exit 2" 2 "$AV/g7" AGENT_AUTHOR_VENDOR=nobody
gate_repo "$AV/g9" claude/x
printf 'openai\n' > "$AV/g9/.git/agent-author-vendors"
gate_row "$AV/g9" openai complete
expect_gate "claude/ branch with a recorded openai implementer: an openai review is not external" 1 "$AV/g9"
gate_reset; gate_row "$AV/g9" google complete
expect_gate "claude/ branch with a recorded openai implementer: a google review passes" 0 "$AV/g9"
gate_repo "$AV/g10" feat/x $'work\n\nCo-Authored-By: Claude <noreply@anthropic.com>\nCo-Authored-By: Codex <noreply@openai.com>'
gate_row "$AV/g10" anthropic complete
expect_gate "two co-authors: an anthropic review is blocked" 1 "$AV/g10"
gate_reset; gate_row "$AV/g10" openai complete
expect_gate "two co-authors: an openai review is blocked too" 1 "$AV/g10"
gate_reset; gate_row "$AV/g10" google complete
expect_gate "two co-authors: a google review passes" 0 "$AV/g10"
# what never counted still does not
gate_repo "$AV/g8" feat/x
gate_row "$AV/g8" google complete "" advisor-free
expect_gate "an advisor-* lane never counts as external" 1 "$AV/g8"
gate_reset; gate_row "$AV/g8" google failed
expect_gate "a failed lane never counts" 1 "$AV/g8"
gate_reset; gate_row "$AV/g8" "" complete
expect_gate "an empty vendor never counts" 1 "$AV/g8"
gate_reset; gate_row "$AV/g8" null complete
expect_gate "a null vendor never counts" 1 "$AV/g8"

# council summary: the warning appears unless a lane of another company than the author completed
BK="$WORK/backends.json"
echo '{"backends":{"codex":{"vendor":"openai"},"claude":{"vendor":"anthropic"},"agy":{"vendor":"google"}}}' > "$BK"
mkcap() {  # mkcap <file> <backend> [status]
    printf -- '---\nrole: r\nbackend: %s\nstatus: %s\ncaptured: t\n---\n\nbody\n' "$2" "${3:-complete}" > "$1"
}
mkcap "$WORK/s-claude.md" claude; mkcap "$WORK/s-codex.md" codex; mkcap "$WORK/s-agy.md" agy
summ() {  # summ [VAR=value...] -- <capture>... — the summary text, run from a repo with no author hint
    local envs=()
    while [[ $# -gt 0 && "$1" != -- ]]; do envs+=("$1"); shift; done
    shift
    (cd "$AV/plain" && env AGENT_BACKENDS_FILE="$BK" AGENT_WORKERS_DIR="$GW" ${envs[@]+"${envs[@]}"} \
        python3 "$EVID" summary "$@")
}
expect_single() {  # expect_single <name> <yes|no> [VAR=value...] -- <capture>...
    local name="$1" want="$2" out got=no; shift 2
    out="$(summ "$@")"
    [[ "$(printf '%s\n' "$out" | head -n 1)" == "single-vendor review"* ]] && got=yes
    [[ "$got" == "$want" ]] && ok "summary — $name" || bad "summary $name" "single-vendor=$got want=$want out=$out"
}
gate_reset
expect_single "default author: a claude-only council warns" yes -- "$WORK/s-claude.md"
expect_single "default author: a codex lane completing is external" no -- "$WORK/s-claude.md" "$WORK/s-codex.md"
expect_single "openai author: a codex-only council warns (same company)" yes AGENT_AUTHOR_VENDOR=openai -- "$WORK/s-codex.md"
expect_single "openai author: a claude lane completing is external" no AGENT_AUTHOR_VENDOR=openai -- "$WORK/s-claude.md"
expect_single "openai author: codex + agy completing counts via agy" no AGENT_AUTHOR_VENDOR=openai -- "$WORK/s-codex.md" "$WORK/s-agy.md"
mkcap "$WORK/s-codex-failed.md" codex failed
expect_single "a failed external lane still does not count" yes -- "$WORK/s-claude.md" "$WORK/s-codex-failed.md"
printf '{"role":"r","backend":"codex","vendor":"openai","author_vendor":"anthropic","status":"complete","diff_key":"k","capture":"%s"}\n' \
    "$WORK/s-codex.md" > "$GW/reviews.jsonl"
expect_single "the index row's author_vendor=anthropic adds to an openai AGENT_AUTHOR_VENDOR: codex stays the author's own" yes AGENT_AUTHOR_VENDOR=openai -- "$WORK/s-codex.md"
printf '{"role":"r","backend":"claude","vendor":"anthropic","author_vendor":"openai","status":"complete","diff_key":"k","capture":"%s"}\n' \
    "$WORK/s-claude.md" > "$GW/reviews.jsonl"
expect_single "the index row's author_vendor=openai does not clear the default anthropic author" yes -- "$WORK/s-claude.md"
printf '{"role":"r","backend":"agy","vendor":"google","author_vendor":"google","status":"complete","diff_key":"k","capture":"%s"}\n' \
    "$WORK/s-agy.md" > "$GW/reviews.jsonl"
expect_single "the index row's author_vendor=google makes an agy lane the author's own" yes -- "$WORK/s-agy.md"
gate_reset
summ AGENT_AUTHOR_VENDOR=nobody -- "$WORK/s-codex.md" >/dev/null 2>&1; rc=$?
[[ $rc -eq 2 ]] && ok "summary — an unknown AGENT_AUTHOR_VENDOR name is exit 2" || bad "summary unknown author" "rc=$rc"


echo
echo "review-evidence-test: $PASS pass, $FAIL fail"
[[ $FAIL -eq 0 ]]
