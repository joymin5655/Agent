#!/usr/bin/env bash
# council-threshold-test.sh — verify core/infra/council-threshold.sh.
#
# The SSOT judgment behind council-escalation-gate.py: a diff is
# "council-scale" (exit 10) when changed-line total >= AGENT_COUNCIL_LINES
# (default 200) OR changed-file count >= AGENT_COUNCIL_FILES (default 10) OR
# any changed path matches a risk-area pattern (spec-gate.py:72
# GUARD_PATTERNS mirror, plus the auth class, which exists only here —
# spec-gate and plan-scope-allow do not have it). Otherwise exit 0. stdout is always exactly one
# summary line: "lines=<N> files=<M> risk=<comma-list|none> excluded=<K>".
# lines/files EXCLUDE test and docs paths (core/infra/path-kinds.sh); K counts them.
# The risk signal still sees every path (a risk file under tests/ escalates).
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
# keep call-worker.sh evidence/lane rows out of the real ~/.agent logs
export AGENT_LOGS_DIR="$WORK/agent-logs"
export AGENT_WORKERS_DIR="${AGENT_WORKERS_DIR:-$WORK/agent-workers}"
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
if [[ "$RC" -eq 0 && "$OUT" == "lines=0 files=0 risk=none excluded=0" ]]; then
  ok "clean tree — exit 0, zeroed summary"
else
  bad "clean tree" "rc=$RC out='$OUT'"
fi

echo
echo "=== small diff: not council-scale ==="
reset_repo
echo "a small tweak" > "$REPO/small.py"
git -C "$REPO" add small.py
run -- --staged
if [[ "$RC" -eq 0 && "$OUT" == "lines=1 files=1 risk=none excluded=0" ]]; then
  ok "small diff — exit 0, summary line exact"
else
  bad "small diff" "rc=$RC out='$OUT'"
fi

echo
echo "=== large diff: line threshold alone (single file, >=200 lines) ==="
reset_repo
gen_lines 250 > "$REPO/big.dat"
git -C "$REPO" add big.dat
run -- --staged
if [[ "$RC" -eq 10 && "$OUT" == "lines=250 files=1 risk=none excluded=0" ]]; then
  ok "large lines — exit 10 on line threshold alone"
else
  bad "large lines" "rc=$RC out='$OUT'"
fi

echo
echo "=== large diff: file-count threshold alone (12 tiny files) ==="
reset_repo
for i in $(seq 1 12); do echo "x" > "$REPO/f$i.dat"; done
git -C "$REPO" add f*.dat
run -- --staged
if [[ "$RC" -eq 10 && "$OUT" == "lines=12 files=12 risk=none excluded=0" ]]; then
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
if [[ "$RC" -eq 10 && "$OUT" == "lines=1 files=1 risk=secret excluded=0" ]]; then
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
if [[ "$RC" -eq 10 && "$OUT" == "lines=1 files=1 risk=production-migration excluded=0" ]]; then
  ok "risk-path migration — exit 10, risk=production-migration"
else
  bad "risk-path migration" "rc=$RC out='$OUT'"
fi

echo
echo "=== env override: raising AGENT_COUNCIL_LINES clears a line-only escalation ==="
reset_repo
gen_lines 250 > "$REPO/big.dat"
git -C "$REPO" add big.dat
run "AGENT_COUNCIL_LINES=1000" -- --staged
if [[ "$RC" -eq 0 && "$OUT" == "lines=250 files=1 risk=none excluded=0" ]]; then
  ok "env override — raised threshold un-escalates the same diff"
else
  bad "env override" "rc=$RC out='$OUT'"
fi

echo
echo "=== HEAD fallback: nothing staged, falls back to HEAD~1..HEAD ==="
reset_repo
gen_lines 250 > "$REPO/big.dat"
git -C "$REPO" add big.dat
git -C "$REPO" commit -q -m "big commit"
run -- --staged
if [[ "$RC" -eq 10 && "$OUT" == "lines=250 files=1 risk=none excluded=0" ]]; then
  ok "HEAD fallback — judges the last commit when staging is empty"
else
  bad "HEAD fallback" "rc=$RC out='$OUT'"
fi

echo
echo "=== --head explicit: same as fallback, addressable directly ==="
run -- --head
if [[ "$RC" -eq 10 && "$OUT" == "lines=250 files=1 risk=none excluded=0" ]]; then
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
if [[ "$RC" -eq 10 && "$OUT" == "lines=1 files=1 risk=edge-fn excluded=0" ]]; then
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
if [[ "$RC" -eq 10 && "$OUT" == "lines=1 files=1 risk=billing excluded=0" ]]; then
  ok "risk-path billing — exit 10, risk=billing"
else
  bad "risk-path billing" "rc=$RC out='$OUT'"
fi

echo
echo "=== env override: raising AGENT_COUNCIL_FILES clears a file-count-only escalation ==="
reset_repo
for i in $(seq 1 12); do echo "x" > "$REPO/f$i.dat"; done
git -C "$REPO" add f*.dat
run "AGENT_COUNCIL_FILES=100" -- --staged
if [[ "$RC" -eq 0 && "$OUT" == "lines=12 files=12 risk=none excluded=0" ]]; then
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
if [[ "$RC" -eq 0 && "$OUT" == "lines=0 files=1 risk=none excluded=0" ]]; then
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
# path. Measured empirically (2026-08-21, git 2.50.1): src/plain.dat (1
# line) moved to billing/charge.ts numstats as TWO plain entries —
# "1 0 billing/charge.ts" + "0 1 src/plain.dat" — so risk_area_for()'s
# ordinary anchor-on-slash regex matches directly, no rename-shorthand
# parsing needed at all.
reset_repo
mkdir -p "$REPO/src" "$REPO/billing"
echo "hello world" > "$REPO/src/plain.dat"
git -C "$REPO" add src/plain.dat
git -C "$REPO" commit -q -m "add plain file"
git -C "$REPO" mv src/plain.dat billing/charge.ts
run -- --staged
if [[ "$RC" -eq 10 && "$OUT" == "lines=2 files=2 risk=billing excluded=0" ]]; then
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
if [[ "$RC" -eq 10 && "$OUT" == "lines=2 files=2 risk=billing excluded=0" ]]; then
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
for i in $(seq 1 40); do echo "line $i"; done > "$REPO/movesrc/big.dat"
git -C "$REPO" add movesrc/big.dat
git -C "$REPO" commit -q -m "add 40-line file"
git -C "$REPO" mv movesrc/big.dat movedst/big.dat
echo "extra line" >> "$REPO/movedst/big.dat"
git -C "$REPO" add -A
run -- --staged
if [[ "$RC" -eq 0 && "$OUT" == "lines=81 files=2 risk=none excluded=0" ]]; then
  ok "rename+edit line accounting — 81, not 1 (F12 line-collapse fix)"
else
  bad "rename+edit line accounting" "rc=$RC out='$OUT'"
fi

echo
echo "=== non-repo cwd: no git repo at all -> zeroed summary, exit 0, no crash ==="
NOGIT="$WORK/not-a-repo"
mkdir -p "$NOGIT"
OUT="$(cd "$NOGIT" && bash "$SCRIPT" --staged 2>/dev/null)"; RC=$?
if [[ "$RC" -eq 0 && "$OUT" == "lines=0 files=0 risk=none excluded=0" ]]; then
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
echo "x" > "$REPO/vault/token.dat"
git -C "$REPO" add vault/token.dat
run -- --staged
if [[ "$RC" -eq 10 && "$OUT" == "lines=1 files=1 risk=secret excluded=0" ]]; then
  ok "project-declared secret path (hook-config.json) — exit 10, risk=secret"
else
  bad "project-declared secret path" "rc=$RC out='$OUT'"
fi

echo
echo "=== option injection: a pass-through range starting with '-' cannot be consumed as a git option (F6) ==="
reset_repo
CANARY="$WORK/canary-should-not-exist"
OUT="$(cd "$REPO" && bash "$SCRIPT" "--output=$CANARY" 2>/dev/null)"; RC=$?
if [[ ! -e "$CANARY" && "$OUT" == "lines=0 files=0 risk=none excluded=0" ]]; then
  ok "option injection — --end-of-options blocks it, no canary file created"
else
  bad "option injection" "canary_exists=$([[ -e "$CANARY" ]] && echo yes || echo no) rc=$RC out='$OUT'"
fi

echo
echo "=== auth risk class (--classify) ==="
classify() { printf '%s\0' "$@" | (cd "$REPO" && bash "$SCRIPT" --classify | tr '\0' '|'); }
for p in src/auth/session.py lib/OAuth/token.go app/authz/policy.rs src/authn/a.ts web/login.tsx \
         api/auth_middleware.js pkg/user-auth.py src/auth.py oauth_client.py authorize.py \
         authorization_service.ts user_login.py authmiddleware.go auth0.ts src/auth.c src/auth.cpp \
         src/login.vue UserAuth.ts auth-service/handler.go authlib/x.py src/auth/schema.sql \
         svc/Authentication/x.ts 'app/(auth)/login/page.tsx' 'src/[auth]/x.ts' src/user_auth/x.py \
         src/UserAuth/x.ts policy/auth.rego 'app/(auth)/layout.tsx'; do
  [[ "$(classify "$p")" == "$p|" ]] && ok "auth risk: $p" || bad "auth risk: $p" "got=[$(classify "$p")]"
done
for p in author.py authors.go authority.ts authorities.py authored.java co-author.py \
         authorship_utils.py docs/author.md AUTHORS authors.txt src/oauthlib_vendor_notes.md \
         README_auth.md tests/fixtures/auth_sample.json src/login.md notes/auth.txt auth/README.md \
         svc/Authentication/x.md src/co-author/x.py src/authorities/x.py src/authorship/y.ts \
         policy/README.rego.md; do
  [[ -z "$(classify "$p")" ]] && ok "not auth risk: $p" || bad "not auth risk: $p" "got=[$(classify "$p")]"
done
# non-UTF-8 byte in the path under a UTF-8 locale must not blind the classifier (LC_ALL=C)
bad_utf8="$(printf 'src/auth/\377.py')"
[[ "$(printf '%s\0' "$bad_utf8" | (cd "$REPO" && env -u LC_ALL LANG=en_US.UTF-8 bash "$SCRIPT" --classify | LC_ALL=C tr '\0' '|'))" == "$bad_utf8|" ]] \
  && ok "auth classify survives a non-UTF-8 byte under a UTF-8 locale" || bad "non-UTF-8 path" "not classified"
# NUL roundtrip with a space and non-ASCII char in an auth path
[[ "$(classify "src/auth/my file é.py" docs/author.md)" == "src/auth/my file é.py|" ]] \
  && ok "auth classify NUL roundtrip (space + non-ASCII)" || bad "auth NUL roundtrip" "got=[$(classify "src/auth/my file é.py" docs/author.md)]"
reset_repo
mkdir -p "$REPO/src/auth"; echo x > "$REPO/src/auth/session.py"; git -C "$REPO" add -A
run -- --staged
[[ "$RC" -eq 10 && "$OUT" == "lines=1 files=1 risk=auth excluded=0" ]] && ok "staged auth file -> council-scale, risk=auth" || bad "staged auth summary" "rc=$RC out='$OUT'"
reset_repo

echo
echo "=== test/docs paths are excluded from the size signals (excluded=<n>), risk still sees them ==="
# 2026-10: 53% of recent commits were tier 2 purely on test/doc line counts. lines/files now
# count non-test, non-docs paths only; classify_path (risk) still runs on every path.
reset_repo
mkdir -p "$REPO/tests" "$REPO/src"
gen_lines 300 > "$REPO/tests/big-test.sh"
gen_lines 20 > "$REPO/src/feature.py"
git -C "$REPO" add -A
run -- --staged
[[ "$RC" -eq 0 && "$OUT" == "lines=20 files=1 risk=none excluded=1" ]] \
  && ok "300 test lines + 20 code lines -> not council-scale, test excluded" \
  || bad "300 test + 20 code" "rc=$RC out='$OUT'"

reset_repo
mkdir -p "$REPO/src"
gen_lines 200 > "$REPO/src/feature.py"
git -C "$REPO" add -A
run -- --staged
[[ "$RC" -eq 10 && "$OUT" == "lines=200 files=1 risk=none excluded=0" ]] \
  && ok "200 code lines -> council-scale (exit 10)" || bad "200 code lines" "rc=$RC out='$OUT'"

reset_repo
mkdir -p "$REPO/tests"
echo "x = 1" > "$REPO/tests/auth_helper.py"
git -C "$REPO" add -A
run -- --staged
[[ "$RC" -eq 10 && "$OUT" == "lines=0 files=0 risk=auth excluded=1" ]] \
  && ok "tests/auth_helper.py (1 line) -> still escalates on risk=auth, counted as excluded" \
  || bad "risk file under tests/" "rc=$RC out='$OUT'"

reset_repo
mkdir -p "$REPO/tests" "$REPO/src"
for i in $(seq 1 15); do echo "t$i" > "$REPO/tests/case$i-test.sh"; done
echo "a" > "$REPO/src/a.py"; echo "b" > "$REPO/src/b.py"
git -C "$REPO" add -A
run -- --staged
[[ "$RC" -eq 0 && "$OUT" == "lines=2 files=2 risk=none excluded=15" ]] \
  && ok "15 test files + 2 code files -> not council-scale" || bad "15 test + 2 code files" "rc=$RC out='$OUT'"

reset_repo
mkdir -p "$REPO/docs"
gen_lines 250 > "$REPO/docs/guide.md"
git -C "$REPO" add -A
run -- --staged
[[ "$RC" -eq 0 && "$OUT" == "lines=0 files=0 risk=none excluded=1" ]] \
  && ok "250 docs lines -> not council-scale" || bad "250 docs lines" "rc=$RC out='$OUT'"

# every test-shaped name in the spec is excluded; look-alikes are code
reset_repo
mkdir -p "$REPO/src"
for f in a-test.sh b_test.go c.test.ts d.spec.ts test_e.py; do echo x > "$REPO/src/$f"; done
for d in test __tests__ spec evals tests; do mkdir -p "$REPO/$d"; echo x > "$REPO/$d/f.py"; done
git -C "$REPO" add -A
run -- --staged
[[ "$RC" -eq 0 && "$OUT" == "lines=0 files=0 risk=none excluded=10" ]] \
  && ok "all test-name/dir shapes (*-test.* *_test.* *.test.* *.spec.* test_*.py, test/ __tests__/ spec/ evals/ tests/) excluded" \
  || bad "test shapes" "rc=$RC out='$OUT'"
reset_repo
mkdir -p "$REPO/src"
for f in attest.py contest.py latest_v2.py testing.py spec.py protest.sh; do echo x > "$REPO/src/$f"; done
mkdir -p "$REPO/src/testdata" "$REPO/src/specs"; echo x > "$REPO/src/testdata/a.py"; echo x > "$REPO/src/specs/a.py"
git -C "$REPO" add -A
run -- --staged
[[ "$RC" -eq 0 && "$OUT" == "lines=8 files=8 risk=none excluded=0" ]] \
  && ok "look-alikes (attest.py, testdata/, specs/, ...) stay counted as code" || bad "test look-alikes" "rc=$RC out='$OUT'"
reset_repo

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
