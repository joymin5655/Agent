#!/usr/bin/env bash
# council-threshold-test.sh — verify core/infra/council-threshold.sh.
#
# The SSOT judgment behind council-escalation-gate.py: a diff is
# "council-scale" (exit 10) when changed-line total >= AGENT_COUNCIL_LINES
# (default 200) OR changed-file count >= AGENT_COUNCIL_FILES (default 10) OR
# any changed path matches a risk-area pattern (spec-gate.py:72
# GUARD_PATTERNS mirror). Otherwise exit 0. stdout is always exactly one
# summary line: "lines=<N> files=<M> risk=<comma-list|none>".
#
# Fixture: one throwaway git repo, reset to a clean baseline commit between
# scenarios (call-worker-test.sh pattern: mktemp -d, trap cleanup, PATH-free
# assertions on exit code + stdout).
#
# Usage: bash core/tests/council-threshold-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/core/infra/council-threshold.sh"

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
echo "baseline" > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m "baseline"

# reset_repo — clean working tree + index back to the baseline commit.
reset_repo() {
  git -C "$REPO" reset --hard -q HEAD
  git -C "$REPO" clean -fdq
}

gen_lines() { local n="$1"; for ((i = 0; i < n; i++)); do echo "line $i"; done; }

# run <extra-env...> -- <args...>  -> sets OUT, RC (cwd = fixture repo)
run() {
  local envs=()
  while [[ "${1:-}" != "--" ]]; do envs+=("$1"); shift; done
  shift  # drop --
  # ${envs[@]+...} guard: expanding an empty array under `set -u` is an
  # error on bash 3.2 (macOS default) — verify-all.sh's own convention.
  OUT="$(cd "$REPO" && env ${envs[@]+"${envs[@]}"} bash "$SCRIPT" "$@" 2>/dev/null)"
  RC=$?
}

echo "=== clean tree, single commit (no HEAD~1 yet): not council-scale ==="
reset_repo
run -- --staged
if [[ "$RC" -eq 0 && "$OUT" == "lines=0 files=0 risk=none" ]]; then
  ok "clean tree — exit 0, zeroed summary"
else
  bad "clean tree" "rc=$RC out='$OUT'"
fi

echo
echo "=== small diff: not council-scale ==="
reset_repo
echo "a small tweak" >> "$REPO/README.md"
git -C "$REPO" add README.md
run -- --staged
if [[ "$RC" -eq 0 && "$OUT" == "lines=1 files=1 risk=none" ]]; then
  ok "small diff — exit 0, summary line exact"
else
  bad "small diff" "rc=$RC out='$OUT'"
fi

echo
echo "=== large diff: line threshold alone (single file, >=200 lines) ==="
reset_repo
gen_lines 250 > "$REPO/big.txt"
git -C "$REPO" add big.txt
run -- --staged
if [[ "$RC" -eq 10 && "$OUT" == "lines=250 files=1 risk=none" ]]; then
  ok "large lines — exit 10 on line threshold alone"
else
  bad "large lines" "rc=$RC out='$OUT'"
fi

echo
echo "=== large diff: file-count threshold alone (12 tiny files) ==="
reset_repo
for i in $(seq 1 12); do echo "x" > "$REPO/f$i.txt"; done
git -C "$REPO" add f*.txt
run -- --staged
if [[ "$RC" -eq 10 && "$OUT" == "lines=12 files=12 risk=none" ]]; then
  ok "file-count — exit 10 on file threshold alone"
else
  bad "file-count" "rc=$RC out='$OUT'"
fi

echo
echo "=== risk-path: secret (small diff, still escalates) ==="
reset_repo
mkdir -p "$REPO/secrets"
echo "TOKEN=x" > "$REPO/secrets/prod.env"
git -C "$REPO" add secrets/prod.env
run -- --staged
if [[ "$RC" -eq 10 && "$OUT" == "lines=1 files=1 risk=secret" ]]; then
  ok "risk-path secret — exit 10, risk=secret despite tiny diff"
else
  bad "risk-path secret" "rc=$RC out='$OUT'"
fi

echo
echo "=== risk-path: production-migration ==="
reset_repo
mkdir -p "$REPO/migrations"
echo "ALTER TABLE x ADD COLUMN y int;" > "$REPO/migrations/0001_add_y.sql"
git -C "$REPO" add migrations/0001_add_y.sql
run -- --staged
if [[ "$RC" -eq 10 && "$OUT" == "lines=1 files=1 risk=production-migration" ]]; then
  ok "risk-path migration — exit 10, risk=production-migration"
else
  bad "risk-path migration" "rc=$RC out='$OUT'"
fi

echo
echo "=== env override: raising AGENT_COUNCIL_LINES clears a line-only escalation ==="
reset_repo
gen_lines 250 > "$REPO/big.txt"
git -C "$REPO" add big.txt
run "AGENT_COUNCIL_LINES=1000" -- --staged
if [[ "$RC" -eq 0 && "$OUT" == "lines=250 files=1 risk=none" ]]; then
  ok "env override — raised threshold un-escalates the same diff"
else
  bad "env override" "rc=$RC out='$OUT'"
fi

echo
echo "=== HEAD fallback: nothing staged, falls back to HEAD~1..HEAD ==="
reset_repo
gen_lines 250 > "$REPO/big.txt"
git -C "$REPO" add big.txt
git -C "$REPO" commit -q -m "big commit"
run -- --staged
if [[ "$RC" -eq 10 && "$OUT" == "lines=250 files=1 risk=none" ]]; then
  ok "HEAD fallback — judges the last commit when staging is empty"
else
  bad "HEAD fallback" "rc=$RC out='$OUT'"
fi

echo
echo "=== --head explicit: same as fallback, addressable directly ==="
run -- --head
if [[ "$RC" -eq 10 && "$OUT" == "lines=250 files=1 risk=none" ]]; then
  ok "--head explicit — same verdict as the fallback path"
else
  bad "--head explicit" "rc=$RC out='$OUT'"
fi

echo
echo "=== risk-path: edge-fn ==="
reset_repo
mkdir -p "$REPO/functions/on-signup"
echo "export default () => {}" > "$REPO/functions/on-signup/index.ts"
git -C "$REPO" add functions/on-signup/index.ts
run -- --staged
if [[ "$RC" -eq 10 && "$OUT" == "lines=1 files=1 risk=edge-fn" ]]; then
  ok "risk-path edge-fn — exit 10, risk=edge-fn"
else
  bad "risk-path edge-fn" "rc=$RC out='$OUT'"
fi

echo
echo "=== risk-path: billing ==="
reset_repo
mkdir -p "$REPO/billing"
echo "x" > "$REPO/billing/invoice.ts"
git -C "$REPO" add billing/invoice.ts
run -- --staged
if [[ "$RC" -eq 10 && "$OUT" == "lines=1 files=1 risk=billing" ]]; then
  ok "risk-path billing — exit 10, risk=billing"
else
  bad "risk-path billing" "rc=$RC out='$OUT'"
fi

echo
echo "=== env override: raising AGENT_COUNCIL_FILES clears a file-count-only escalation ==="
reset_repo
for i in $(seq 1 12); do echo "x" > "$REPO/f$i.txt"; done
git -C "$REPO" add f*.txt
run "AGENT_COUNCIL_FILES=100" -- --staged
if [[ "$RC" -eq 0 && "$OUT" == "lines=12 files=12 risk=none" ]]; then
  ok "env override — raised file threshold un-escalates the same diff"
else
  bad "env override files" "rc=$RC out='$OUT'"
fi

echo
echo "=== binary file: numstat '-'/'-' counts as a file but adds no lines ==="
reset_repo
printf '\x00\x01\x02\xff\xfe' > "$REPO/blob.bin"
git -C "$REPO" add blob.bin
run -- --staged
if [[ "$RC" -eq 0 && "$OUT" == "lines=0 files=1 risk=none" ]]; then
  ok "binary file — non-numeric add/del counted as a file, zero lines"
else
  bad "binary file" "rc=$RC out='$OUT'"
fi

echo
echo "=== --no-renames (F12): rename into a risk-area path, no common prefix ==="
# F11's original fix (a resolve_new_path() parser for git's "old => new" /
# "a/{old => new}/b" rename shorthand) was replaced by F12: pass
# --no-renames to every numstat call instead, so git never emits rename
# notation in the first place and every path field is always a single plain
# path. Measured empirically (2026-08-21, git 2.50.1): src/plain.txt (1
# line) moved to billing/charge.ts numstats as TWO plain entries —
# "1 0 billing/charge.ts" + "0 1 src/plain.txt" — so risk_area_for()'s
# ordinary anchor-on-slash regex matches directly, no rename-shorthand
# parsing needed at all.
reset_repo
mkdir -p "$REPO/src" "$REPO/billing"
echo "hello world" > "$REPO/src/plain.txt"
git -C "$REPO" add src/plain.txt
git -C "$REPO" commit -q -m "add plain file"
git -C "$REPO" mv src/plain.txt billing/charge.ts
run -- --staged
if [[ "$RC" -eq 10 && "$OUT" == "lines=2 files=2 risk=billing" ]]; then
  ok "rename no-common-prefix into billing/ — detected via --no-renames"
else
  bad "rename no-common-prefix into billing/" "rc=$RC out='$OUT'"
fi

echo
echo "=== --no-renames (F12): rename into a risk-area path, common prefix ==="
# The shared-prefix case that used to compact to "app/{old => billing}/f.ts"
# under default rename detection. --no-renames means this shape never
# occurs at all — it numstats as the same two-plain-entries form as above.
reset_repo
mkdir -p "$REPO/app/old"
echo "hello" > "$REPO/app/old/f.ts"
git -C "$REPO" add app/old/f.ts
git -C "$REPO" commit -q -m "add nested file"
mkdir -p "$REPO/app/billing"
git -C "$REPO" mv app/old/f.ts app/billing/f.ts
run -- --staged
if [[ "$RC" -eq 10 && "$OUT" == "lines=2 files=2 risk=billing" ]]; then
  ok "rename common-prefix into billing/ — detected via --no-renames"
else
  bad "rename common-prefix into billing/" "rc=$RC out='$OUT'"
fi

echo
echo "=== --no-renames (F12): rename+edit line accounting is not collapsed ==="
# The third, more severe defect default rename detection caused: moving a
# file (even alone, with ZERO content change) numstats as "0 0" — the file's
# size never counts toward AGENT_COUNCIL_LINES at all. Add one line on top
# of a 40-line move and default rename detection reports only "1 0" (the
# edit), not the file's real size. Measured empirically: --no-renames
# reports the honest "41 0" (new path, full new content) + "0 40" (old path,
# full old content) = 81 total, so a large file-reorganization refactor can
# still cross the line threshold as it should.
reset_repo
mkdir -p "$REPO/movesrc" "$REPO/movedst"
for i in $(seq 1 40); do echo "line $i"; done > "$REPO/movesrc/big.txt"
git -C "$REPO" add movesrc/big.txt
git -C "$REPO" commit -q -m "add 40-line file"
git -C "$REPO" mv movesrc/big.txt movedst/big.txt
echo "extra line" >> "$REPO/movedst/big.txt"
git -C "$REPO" add -A
run -- --staged
if [[ "$RC" -eq 0 && "$OUT" == "lines=81 files=2 risk=none" ]]; then
  ok "rename+edit line accounting — 81, not 1 (F12 line-collapse fix)"
else
  bad "rename+edit line accounting" "rc=$RC out='$OUT'"
fi

echo
echo "=== non-repo cwd: no git repo at all -> zeroed summary, exit 0, no crash ==="
NOGIT="$WORK/not-a-repo"
mkdir -p "$NOGIT"
OUT="$(cd "$NOGIT" && bash "$SCRIPT" --staged 2>/dev/null)"; RC=$?
if [[ "$RC" -eq 0 && "$OUT" == "lines=0 files=0 risk=none" ]]; then
  ok "non-repo cwd — degrades to zeroed summary, never crashes"
else
  bad "non-repo cwd" "rc=$RC out='$OUT'"
fi

echo
echo "=== project hook-config: risk_areas.secrets.paths (F1 — project root, not framework root) ==="
# Before F1, PROJECT_SECRET_TOKENS was loaded with the FRAMEWORK's own root
# (this repo) as argv[1], not the fixture project's — so a project's
# .agent/hook-config.json declaring an extra secret path never fired. This
# assertion is expected to FAIL before F1 and PASS after.
reset_repo
mkdir -p "$REPO/.agent"
cat > "$REPO/.agent/hook-config.json" <<'JSON'
{"risk_areas": {"secrets": {"paths": ["vault/"]}}}
JSON
mkdir -p "$REPO/vault"
echo "x" > "$REPO/vault/token.txt"
git -C "$REPO" add vault/token.txt
run -- --staged
if [[ "$RC" -eq 10 && "$OUT" == "lines=1 files=1 risk=secret" ]]; then
  ok "project-declared secret path (hook-config.json) — exit 10, risk=secret"
else
  bad "project-declared secret path" "rc=$RC out='$OUT'"
fi

echo
echo "=== option injection: a pass-through range starting with '-' cannot be consumed as a git option (F6) ==="
reset_repo
CANARY="$WORK/canary-should-not-exist"
OUT="$(cd "$REPO" && bash "$SCRIPT" "--output=$CANARY" 2>/dev/null)"; RC=$?
if [[ ! -e "$CANARY" && "$OUT" == "lines=0 files=0 risk=none" ]]; then
  ok "option injection — --end-of-options blocks it, no canary file created"
else
  bad "option injection" "canary_exists=$([[ -e "$CANARY" ]] && echo yes || echo no) rc=$RC out='$OUT'"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
