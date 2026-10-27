#!/usr/bin/env bash
# loop-write-guard-test.sh — battery for core/hooks/loop-write-guard.py (L-2).
#
# Verifies the loop write-ban: INERT outside a loop session; inside a session it
# escalates (ask) writes to the grader/verifier surface (core/tests/, evals/) and
# non-append rewrites of the ledger, while allowing TARGET edits and pure appends.
# Also proves the realpath containment cannot be dodged by a symlink into the
# guarded dir, and that ask reasons carry the WHY:/FIX: teaching tags.
# Sections (u)-(z) cover the Bash residuals the hook's own comment listed: deletion
# verbs, glob / split-string / brace / dot-segment spellings of a guarded path,
# padding, the hook's own deadline, and a pin that nothing the original table asked
# about is relaxed.
#
# Usage: bash core/tests/loop-write-guard-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/core/hooks/loop-write-guard.py"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

ROOT="$TMP_ROOT/proj"
mkdir -p "$ROOT/core/tests" "$ROOT/evals" "$ROOT/agents" "$ROOT/.agent/loop"

# run_hook <tool> <file_path> <content> [extra env assignments...] -> sets OUT
# loop is forced active via AGENT_LOOP_ACTIVE unless a case overrides it.
run_hook() {
  local tool="$1" fp="$2" content="$3"; shift 3
  local event
  event=$(TOOL="$tool" FP="$fp" C="$content" python3 -c 'import os,json; print(json.dumps({"event":"PreToolUse","tool_name":os.environ["TOOL"],"tool_input":{"file_path":os.environ["FP"],"content":os.environ["C"]}}))')
  OUT="$(printf '%s' "$event" | env AGENT_PROJECT_DIR="$ROOT" "$@" python3 "$HOOK" 2>/dev/null || true)"
}
is_ask() { printf '%s' "$OUT" | grep -q '"permissionDecision": "ask"'; }
is_quiet() { [[ -z "$OUT" ]]; }
# An ask the verdict itself gave. A crash or an expired deadline also asks ("could not
# evaluate"), which would let a broken matcher pass every ask-case below.
is_verdict_ask() { is_ask && ! printf '%s' "$OUT" | grep -q 'could not evaluate'; }

echo "=== (a) INERT outside a loop session: grader edit passes untouched ==="
run_hook Write "$ROOT/core/tests/grade.sh" "x"   # no AGENT_LOOP_ACTIVE
[[ -z "$OUT" ]]; check "inert-no-loop-no-output" $?

echo
echo "=== (b) active loop: write under core/tests/ -> ask ==="
run_hook Write "$ROOT/core/tests/grade.sh" "tampered" AGENT_LOOP_ACTIVE=1
is_ask; check "coretests-write-ask" $?
printf '%s' "$OUT" | grep -q 'WHY:'; check "ask-has-WHY" $?
printf '%s' "$OUT" | grep -q 'FIX:'; check "ask-has-FIX" $?

echo
echo "=== (c) active loop: write under evals/ -> ask ==="
run_hook Write "$ROOT/evals/failure-modes.yaml" "weakened" AGENT_LOOP_ACTIVE=1
is_ask; check "evals-write-ask" $?

echo
echo "=== (d) active loop: TARGET edit (agents/) -> allow ==="
run_hook Edit "$ROOT/agents/code-reviewer.md" "improved prompt" AGENT_LOOP_ACTIVE=1
[[ -z "$OUT" ]]; check "target-edit-allowed" $?

echo
echo "=== (e) active loop: pure append to the ledger -> allow ==="
LEDG="$ROOT/.agent/loop/results.tsv"
printf 'commit\tharness_score\tduration_s\tstatus\tdescription\n' > "$LEDG"
# preserve the trailing newline that $(cat) would strip, so this is a TRUE byte-prefix
old="$(cat "$LEDG"; printf x)"; old="${old%x}"
run_hook Write "$LEDG" "${old}c1\t1.0\t1\tkeep\trow1data" AGENT_LOOP_ACTIVE=1
[[ -z "$OUT" ]]; check "ledger-pure-append-allowed" $?

echo
echo "=== (f) active loop: ledger rewrite (not a prefix of old) -> ask ==="
run_hook Write "$LEDG" "totally different content" AGENT_LOOP_ACTIVE=1
is_ask; check "ledger-rewrite-ask" $?

echo
echo "=== (g) active loop: Edit on the ledger (mutates existing bytes) -> ask ==="
run_hook Edit "$LEDG" "anything" AGENT_LOOP_ACTIVE=1
is_ask; check "ledger-edit-ask" $?

echo
echo "=== (h) loop marked active via FLAG FILE (not env) -> ask ==="
FLAG="$ROOT/.agent/loop/active"; : > "$FLAG"
run_hook Write "$ROOT/core/tests/x.sh" "y" AGENT_LOOP_FLAG="$FLAG"
is_ask; check "flag-file-activates-guard" $?
rm -f "$FLAG"

echo
echo "=== (i) realpath containment: a symlink INTO core/tests cannot dodge the guard ==="
ln -s "$ROOT/core/tests" "$ROOT/sneaky"     # $ROOT/sneaky -> core/tests
run_hook Write "$ROOT/sneaky/grade.sh" "tampered-via-symlink" AGENT_LOOP_ACTIVE=1
is_ask; check "symlink-into-guarded-dir-ask" $?
# a not-yet-existing leaf under the symlinked dir is contained too (parent realpath)
run_hook Write "$ROOT/sneaky/brand-new.sh" "z" AGENT_LOOP_ACTIVE=1
is_ask; check "symlink-nonexistent-leaf-ask" $?

echo
echo "=== (j) non-Write/Edit tool -> allow (exit 0, no decision) ==="
event='{"event":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo hi"}}'
OUT="$(printf '%s' "$event" | env AGENT_PROJECT_DIR="$ROOT" AGENT_LOOP_ACTIVE=1 python3 "$HOOK" 2>/dev/null || true)"
[[ -z "$OUT" ]]; check "bash-tool-allowed" $?

echo
echo "=== (k) active loop: unrelated file (docs/) -> allow ==="
mkdir -p "$ROOT/docs"
run_hook Write "$ROOT/docs/note.md" "hi" AGENT_LOOP_ACTIVE=1
[[ -z "$OUT" ]]; check "unrelated-file-allowed" $?

# run a Bash event through the hook: sets OUT
run_bash() {
  local command="$1"; shift
  local event
  event=$(C="$command" python3 -c 'import os,json; print(json.dumps({"event":"PreToolUse","tool_name":"Bash","tool_input":{"command":os.environ["C"]}}))')
  OUT="$(printf '%s' "$event" | env AGENT_PROJECT_DIR="$ROOT" "$@" python3 "$HOOK" 2>/dev/null || true)"
}

echo
echo "=== (l) active loop: Bash WRITE into guarded surface -> ask (the Bash bypass) ==="
run_bash "sed -i '' 's/FAIL/PASS/' core/tests/grade.sh" AGENT_LOOP_ACTIVE=1
is_ask; check "bash-sed-i-coretests-ask" $?
run_bash "echo forged > evals/failure-modes.yaml" AGENT_LOOP_ACTIVE=1
is_ask; check "bash-redirect-evals-ask" $?
run_bash "cp /tmp/fake core/tests/pre-tool-guard-test.sh" AGENT_LOOP_ACTIVE=1
is_ask; check "bash-cp-coretests-ask" $?
run_bash "rm .agent/loop/results.tsv" AGENT_LOOP_ACTIVE=1
is_ask; check "bash-rm-ledger-ask" $?
run_bash "git checkout HEAD -- core/tests/grade.sh" AGENT_LOOP_ACTIVE=1
is_ask; check "bash-git-checkout-coretests-ask" $?
run_bash "python3 -c \"open('core/tests/x.sh','w').write('exit 0')\"" AGENT_LOOP_ACTIVE=1
is_ask; check "bash-python-open-w-ask" $?

echo
echo "=== (m) active loop: Bash READ / unrelated -> allow (no false-ask) ==="
run_bash "cat core/tests/grade.sh" AGENT_LOOP_ACTIVE=1
[[ -z "$OUT" ]]; check "bash-cat-coretests-allowed" $?
run_bash "grep -r FAIL core/tests/" AGENT_LOOP_ACTIVE=1
[[ -z "$OUT" ]]; check "bash-grep-coretests-allowed" $?
run_bash "bash core/tests/grade.sh --base HEAD~1" AGENT_LOOP_ACTIVE=1
[[ -z "$OUT" ]]; check "bash-run-grade-allowed" $?
# Bash write to guarded surface is INERT outside a loop
run_bash "echo x > core/tests/y.sh"    # no AGENT_LOOP_ACTIVE
[[ -z "$OUT" ]]; check "bash-write-inert-no-loop" $?

echo
echo "=== (n) self-protection: editing the guard's OWN enforcement code -> ask ==="
run_hook Write "$ROOT/core/hooks/loop-write-guard.py" "sys.exit(0)" AGENT_LOOP_ACTIVE=1
is_ask; check "self-edit-guard-ask" $?
mkdir -p "$ROOT/hooks"
run_hook Edit "$ROOT/hooks/hooks.json" "{}" AGENT_LOOP_ACTIVE=1
is_ask; check "edit-hooks-json-ask" $?

echo
echo "=== (o) MultiEdit into guarded surface -> ask (matcher covers MultiEdit) ==="
run_hook MultiEdit "$ROOT/core/tests/grade.sh" "patch" AGENT_LOOP_ACTIVE=1
is_ask; check "multiedit-coretests-ask" $?

echo
echo "=== (p) fail-closed: non-string ledger content cannot prove append -> ask ==="
: > "$LEDG"; printf 'header\n' > "$LEDG"
event='{"event":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"'"$LEDG"'","content":12345}}'
OUT="$(printf '%s' "$event" | env AGENT_PROJECT_DIR="$ROOT" AGENT_LOOP_ACTIVE=1 python3 "$HOOK" 2>/dev/null || true)"
is_ask; check "ledger-nonstring-content-ask" $?

echo
echo "=== (i) active loop: recreate deleted ledger while .witness survives -> ask ==="
rm -f "$LEDG"; printf 'notarized\n' > "$LEDG.witness"
run_hook Write "$LEDG" "commit\tharness_score\tduration_s\tstatus\tdescription" AGENT_LOOP_ACTIVE=1
is_ask; check "delete-recreate-with-witness-ask" $?
# with NO witness either, first creation is still a legitimate append -> allow
rm -f "$LEDG.witness"
run_hook Write "$LEDG" "commit\tharness_score\tduration_s\tstatus\tdescription" AGENT_LOOP_ACTIVE=1
[[ -z "$OUT" ]]; check "true-first-creation-still-allowed" $?

echo
echo "=== (j) active loop: hand-writing the witness itself -> ask ==="
run_hook Write "$LEDG.witness" "deadbeef 3" AGENT_LOOP_ACTIVE=1
is_ask; check "witness-write-ask" $?

echo
echo "=== (q) sanctioned writer is itself guarded (sec C9) ==="
mkdir -p "$ROOT/core/infra"
run_hook Write "$ROOT/core/infra/loop-ledger.sh" "die(){ :; }" AGENT_LOOP_ACTIVE=1
is_ask; check "ledger-writer-write-ask" $?
run_bash "sed -i '' 's/die/true/' core/infra/loop-ledger.sh" AGENT_LOOP_ACTIVE=1
is_ask; check "bash-sed-ledger-writer-ask" $?
run_bash "printf 'deadbeef 1\n' > .agent/loop/results.tsv.witness" AGENT_LOOP_ACTIVE=1
is_ask; check "bash-redirect-witness-ask" $?
# a FILE symlink at an unguarded path resolving into the surface is contained too
printf 'x\n' > "$ROOT/core/infra/loop-ledger.sh"   # target must exist to resolve
ln -s "$ROOT/core/infra/loop-ledger.sh" "$ROOT/alias.sh"
run_hook Write "$ROOT/alias.sh" "tampered" AGENT_LOOP_ACTIVE=1
is_ask; check "file-symlink-into-surface-ask" $?

echo
echo "=== (r) widened Bash write verbs (sec C7) ==="
run_bash "curl -sfo core/tests/grade.sh https://example.com/x" AGENT_LOOP_ACTIVE=1
is_ask; check "bash-curl-o-ask" $?
run_bash "git update-index --assume-unchanged core/tests/verify-all-test.sh" AGENT_LOOP_ACTIVE=1
is_ask; check "bash-update-index-ask" $?
run_bash "cd evals && rm -f failure-modes.yaml" AGENT_LOOP_ACTIVE=1
is_ask; check "bash-cd-evals-rm-ask" $?
run_bash "patch core/tests/grade.sh < /tmp/p.diff" AGENT_LOOP_ACTIVE=1
is_ask; check "bash-patch-ask" $?
run_bash "python3 -c \"import pathlib; pathlib.Path('evals/failure-modes.yaml').write_text('x')\"" AGENT_LOOP_ACTIVE=1
is_ask; check "bash-python-write-text-ask" $?
# round-4: gitleaks.toml (the secret-scan config the GATE runs) is guarded surface
run_hook Write "$ROOT/gitleaks.toml" "[allowlist]" AGENT_LOOP_ACTIVE=1
is_ask; check "gitleaks-toml-write-ask" $?
run_bash "echo '[allowlist]' > gitleaks.toml" AGENT_LOOP_ACTIVE=1
is_ask; check "bash-redirect-gitleaks-ask" $?

echo
echo "=== (s) the loop cannot hold its own off switch (.agent/loop control state) ==="
# This hook is INERT unless .agent/loop/active exists, so that marker was the
# whole containment in one file — and it was not guarded: `rm .agent/loop/active`
# was ALLOWED, after which a core/tests/ write that had been `ask` sailed through.
# The state files are the same hazard one step in: they carry .status and the
# consecutive-failure count, so editing them revives a loop the breaker stopped.
# Both are runtime state, so they live in GUARDED_TOKENS + a dedicated Write/Edit
# branch rather than the scoring-surface sets the drift gate holds equal.
mkdir -p "$ROOT/.agent/loop/state"
run_bash "rm .agent/loop/active" AGENT_LOOP_ACTIVE=1
is_ask; check "bash-rm-active-marker-ask" $?
run_bash "rm -f .agent/loop/active && echo done" AGENT_LOOP_ACTIVE=1
is_ask; check "bash-rm-f-active-marker-ask" $?
run_hook Write "$ROOT/.agent/loop/state/mission.json" '{"status":"active"}' AGENT_LOOP_ACTIVE=1
is_ask; check "write-loop-state-ask" $?
run_hook Edit "$ROOT/.agent/loop/state/mission.json" '{"status":"active"}' AGENT_LOOP_ACTIVE=1
is_ask; check "edit-loop-state-ask" $?
run_bash "jq '.status=\"active\"' .agent/loop/state/mission.json > /tmp/s && mv /tmp/s .agent/loop/state/mission.json" AGENT_LOOP_ACTIVE=1
is_ask; check "bash-rewrite-loop-state-ask" $?
# the reason must name the actual hazard, not the generic surface message
printf '%s' "$OUT" | grep -q 'control state'; check "loop-state-reason-names-control-state" $?
# and reading the same paths must NOT ask (no false-ask on inspection)
run_bash "cat .agent/loop/state/mission.json" AGENT_LOOP_ACTIVE=1
[[ -z "$OUT" ]]; check "bash-read-loop-state-allowed" $?
# outside a loop session the whole hook stays inert (loop-run.sh itself writes
# these files, and a human stopping a loop must not be nagged)
run_bash "rm .agent/loop/active"
[[ -z "$OUT" ]]; check "loop-state-inert-outside-loop" $?

echo
echo "=== (t) control tokens must survive the cd-split idiom and cover the goal DB ==="
# Round-2 review CRITICAL: path-level tokens (".agent/loop/active") missed
# `cd .agent/loop && rm active`, which mentions neither token — the marker went
# away with no ask and the guard was inert from then on. Matching at DIRECTORY
# granularity catches the split. The goal DB under .agent/locks/ was unguarded
# entirely, so `sqlite3 <db> "UPDATE ..."` rewrote the authoritative status that
# cmd_attempt cross-checks — the other half of an end-to-end resurrection.
mkdir -p "$ROOT/.agent/loop/state" "$ROOT/.agent/locks"
run_bash "cd .agent/loop && rm active" AGENT_LOOP_ACTIVE=1
is_ask; check "bash-cd-split-rm-marker-ask" $?
# the split can be taken a level HIGHER, which directory-granularity tokens still
# missed — hence the token set bottoms out at ".agent", the shallowest path any
# cd-chain to this state must still name somewhere in the command.
run_bash "cd .agent && rm loop/active" AGENT_LOOP_ACTIVE=1
is_ask; check "bash-cd-split-one-level-higher-ask" $?
run_bash "cd .agent && cd loop && rm active" AGENT_LOOP_ACTIVE=1
is_ask; check "bash-cd-chain-rm-marker-ask" $?
run_bash "(cd .agent/loop && rm -f active)" AGENT_LOOP_ACTIVE=1
is_ask; check "bash-subshell-cd-rm-marker-ask" $?
run_bash "cd .agent/loop/state && jq '.status=\"active\"' m.json > m2.json" AGENT_LOOP_ACTIVE=1
is_ask; check "bash-cd-split-state-rewrite-ask" $?
run_bash "sqlite3 .agent/locks/goal-state.db \"UPDATE goals SET status='active'\"" AGENT_LOOP_ACTIVE=1
is_ask; check "bash-sqlite-update-goal-db-ask" $?
run_bash "sqlite3 .agent/locks/goal-state.db \"update goals set status='active'\"" AGENT_LOOP_ACTIVE=1
is_ask; check "bash-sqlite-lowercase-update-ask" $?
# reads must stay quiet — a guard that asks on inspection trains people to click through
run_bash "sqlite3 .agent/locks/goal-state.db 'SELECT * FROM goals'" AGENT_LOOP_ACTIVE=1
[[ -z "$OUT" ]]; check "bash-sqlite-select-allowed" $?
run_bash "ls .agent/loop" AGENT_LOOP_ACTIVE=1
[[ -z "$OUT" ]]; check "bash-ls-loop-dir-allowed" $?
# The ".agent" token is broad on purpose, so pin that it does not turn into
# background noise: a guard that asks on ordinary work gets clicked through.
run_bash "npm run build --state=production" AGENT_LOOP_ACTIVE=1
[[ -z "$OUT" ]]; check "bash-unrelated-state-flag-allowed" $?
run_bash "grep -r active src/" AGENT_LOOP_ACTIVE=1
[[ -z "$OUT" ]]; check "bash-grep-active-allowed" $?
run_bash "echo hi > docs/note.md" AGENT_LOOP_ACTIVE=1
[[ -z "$OUT" ]]; check "bash-unrelated-write-allowed" $?

# --- the Bash residuals the guard's own comment listed: verbs and spellings ---------
# ask_table / quiet_table read `name@@command` lines from stdin (`@ROOT@` = the temp
# project root) and check each one: a hundred spellings stay readable, and a new
# bypass is one more line. The tables are quoted heredocs, so `$`, `\`, quotes and
# braces reach the hook exactly as written.
ask_table() {
  local line name cmd
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    name="${line%%@@*}"; cmd="${line#*@@}"; cmd="${cmd//@ROOT@/$ROOT}"
    run_bash "$cmd" AGENT_LOOP_ACTIVE=1
    is_verdict_ask; check "$name" $?
  done
}
quiet_table() {
  local line name cmd
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    name="${line%%@@*}"; cmd="${line#*@@}"; cmd="${cmd//@ROOT@/$ROOT}"
    run_bash "$cmd" AGENT_LOOP_ACTIVE=1
    is_quiet; check "$name" $?
  done
}

echo
echo "=== (u) VERB LIST residual: deletion/in-place verbs the table lacked all ask ==="
# `rm` was the only deleter, so find -delete, unlink, shred, git clean, a perl/node/
# ruby/php one-liner or a g-prefixed GNU tool removed guarded files with no ask.
ask_table <<'EOF'
u-find-delete-marker@@find .agent -name active -delete
u-find-delete-coretests@@find core/tests -name '*.sh' -delete
u-find-delete-after-exec-semicolon@@find evals -type f -exec true \; -delete
u-find-delete-absolute-binary@@/usr/bin/find .agent/loop -name active -delete
u-find-fprint-evals@@find . -maxdepth 0 -fprint evals/x.yaml
u-gfind-delete@@gfind .agent -delete
u-unlink-marker@@unlink .agent/loop/active
u-unlink-ledger@@unlink .agent/loop/results.tsv
u-shred-marker@@shred -u .agent/loop/active
u-rmdir-state@@rmdir .agent/loop/state
u-git-clean-agent@@git clean -fdx .agent
u-git-clean-coretests@@git clean -fd core/tests
u-git-C-clean@@git -C . clean -fdx .agent
u-git-C-checkout@@git -C . checkout HEAD -- core/tests/grade.sh
u-git-c-option-checkout@@git -c core.x=1 checkout -- core/tests/grade.sh
u-git-no-pager-restore@@git --no-pager restore core/tests/grade.sh
u-git-gitdir-equals-clean@@git --git-dir=.git clean -fd core/tests
u-git-gitdir-worktree-clean@@git --git-dir .git --work-tree . clean -fd evals
u-perl-unlink@@perl -e 'unlink ".agent/loop/active"'
u-perl-pi@@perl -pi -e 's/a/b/' core/tests/grade.sh
u-perl-rename@@perl -e 'rename "core/tests/a", "/tmp/a"'
u-ruby-pi@@ruby -pi -e 'gsub(/a/, "b")' core/tests/grade.sh
u-pathlib-unlink@@python3 -c "import pathlib; pathlib.Path('.agent/loop/active').unlink()"
u-pathlib-rename@@python3 -c "import pathlib; pathlib.Path('core/tests/a').rename('/tmp/a')"
u-python-open-exclusive@@python3 -c "open('core/tests/new.sh', 'x')"
u-python-open-read-write@@python3 -c "open('core/tests/grade.sh', 'r+').write('x')"
u-python-os-symlink@@python3 -c "import os; os.symlink('/tmp/x', 'core/tests/x')"
u-node-unlinksync@@node -e "require('fs').unlinkSync('.agent/loop/active')"
u-node-writefilesync@@node -e "require('fs').writeFileSync('core/tests/x.sh', '')"
u-node-rmsync@@node -e "require('fs').rmSync('evals', {recursive: true})"
u-node-renamesync@@node -e "require('fs').renameSync('core/tests/a', '/tmp/a')"
u-nodejs-copyfilesync@@nodejs -e "require('fs').copyFileSync('/tmp/a', 'core/tests/a')"
u-node-createwritestream@@node -e "require('fs').createWriteStream('evals/x.yaml')"
u-node-opensync-w@@node -e "require('fs').openSync('evals/x.yaml', 'w')"
u-deno-write@@deno eval "Deno.writeTextFileSync('evals/x.yaml', '')"
u-deno-remove@@deno eval "Deno.removeSync('.agent/loop/active')"
u-bun-write@@bun -e "Bun.write('core/tests/x.sh', '')"
u-ruby-file-delete@@ruby -e "File.delete('.agent/loop/active')"
u-ruby-file-write-no-parens@@ruby -e 'File.write "core/tests/x.sh", ""'
u-ruby-fileutils-rm-rf@@ruby -rfileutils -e 'FileUtils.rm_rf "evals"'
u-ruby-fileutils-cp-r@@ruby -rfileutils -e 'FileUtils.cp_r "/tmp/x", "core/tests/x"'
u-php-unlink@@php -r "unlink('.agent/loop/active');"
u-php-file-put-contents@@php -r "file_put_contents('evals/x.yaml', '');"
u-php-fopen@@php -r "fopen('evals/x.yaml', 'w');"
u-gnu-grm@@grm -rf core/tests
u-gnu-gmv@@gmv core/tests/a /tmp/a
u-gnu-gcp@@gcp /tmp/x evals/y.yaml
u-gnu-gunlink@@gunlink .agent/loop/active
u-gnu-gshred@@gshred -u evals/x.yaml
u-gnu-gtruncate@@gtruncate -s 0 core/tests/grade.sh
u-gnu-gtee-after-pipe@@echo x | gtee evals/x.yaml
u-gnu-grm-after-xargs@@echo core/tests/a | xargs grm
u-gnu-grm-after-sudo@@sudo grm -rf evals
u-gnu-grm-in-find-exec@@find core/tests -name a -exec grm {} +
u-gnu-grm-after-semicolon@@echo hi; grm -rf core/tests
u-perl-rmtree@@perl -MFile::Path=rmtree -e 'rmtree(".agent/loop")'
u-perl-file-move@@perl -MFile::Copy -e 'move("/tmp/a", "core/tests/a")'
u-python-open-read-write-binary@@python3 -c "open('core/tests/grade.sh', 'rb+').write(b'')"
u-python-open-mode-letters-in-any-order@@python3 -c "open('core/tests/grade.sh', 'bw')"
u-ruby-file-open-no-parens@@ruby -e 'File.open ".agent/loop/active", "w"'
u-node-opensync-read-write@@node -e "require('fs').openSync('evals/x.yaml', 'r+')"
u-php-fopen-append-plus@@php -r "fopen('evals/x.yaml', 'a+');"
u-gnu-grm-in-bash-c@@bash -c 'grm -rf core/tests'
u-gnu-grm-after-env-assignment@@env A=1 grm -rf core/tests
u-gnu-grm-after-do@@for f in a; do grm -rf core/tests; done
u-gnu-grm-in-brace-group@@{ grm -rf core/tests; }
u-gnu-grm-after-if@@if grm -rf core/tests; then echo; fi
u-gnu-grm-after-nohup@@nohup grm -rf core/tests
u-gnu-grm-after-time@@time grm -rf core/tests
# open() modes beyond the first letter (Node flags, PHP modes, Ruby encodings), a mode held in
# a variable, and a nested call in front of the mode
u-node-opensync-exclusive@@node -e "require('fs').openSync('evals/x.yaml', 'wx')"
u-node-opensync-exclusive-first@@node -e "require('fs').openSync('evals/x.yaml', 'xw')"
u-node-opensync-append-exclusive-plus@@node -e "require('fs').openSync('evals/x.yaml', 'ax+')"
u-node-opensync-sync-append@@node -e "require('fs').openSync('evals/x.yaml', 'sa')"
u-ruby-file-open-encoding@@ruby -e 'File.open ".agent/loop/active", "w:UTF-8"'
u-ruby-file-open-encoding-parens@@ruby -e 'File.open(".agent/loop/active", "w:UTF-8")'
u-ruby-file-open-read-write-encoding@@ruby -e 'File.open("core/tests/x.sh", "r+:UTF-8")'
u-ruby-file-open-binary-encoding@@ruby -e 'File.open("core/tests/x.sh", "wb:BINARY")'
u-ruby-file-open-exclusive@@ruby -e 'File.open("core/tests/x.sh", "wx")'
u-php-fopen-exclusive-binary@@php -r "fopen('evals/x.yaml', 'xb');"
u-php-fopen-write-binary-cloexec@@php -r "fopen('evals/x.yaml', 'wbe');"
u-php-fopen-variable-mode@@php -r '$m = "w"; fopen("evals/x.yaml", $m);'
u-php-fopen-mode-from-argv@@php -r 'fopen("evals/x.yaml", $argv[1]);' w
u-php-fopen-variable-path-and-mode@@php -r '$p = "evals/x.yaml"; $m = "w"; fopen($p, $m);'
u-perl-open-read-write@@perl -e 'open(F, "+<", "core/tests/x.sh")'
u-node-opensync-nested-call@@node -e "require('fs').openSync(require('path').join('evals', 'out.json'), 'w')"
u-python-open-nested-call@@python3 -c "import os; open(os.path.join('evals', 'out.json'), 'w')"
u-ruby-file-open-nested-call@@ruby -e 'File.open(File.join("evals", "out.json"), "w")'
u-php-fopen-nested-call@@php -r "fopen(dirname('evals/x') . '/out.json', 'w');"
EOF
# the reason names what the command actually hits
run_bash "find .agent -name active -delete" AGENT_LOOP_ACTIVE=1
printf '%s' "$OUT" | grep -q 'control state'; check "u-find-delete-marker-reason-names-control-state" $?
run_bash "find core/tests -name '*.sh' -delete" AGENT_LOOP_ACTIVE=1
printf '%s' "$OUT" | grep -q 'grader/verifier surface'; check "u-find-delete-surface-reason-names-surface" $?

echo
echo "=== (v) LITERAL SUBSTRING residual: globs, split strings, braces, dot segments ==="
# The token check was a substring match on the command text, so anything the shell
# rewrites before running defeated it. The hook now also judges the post-expansion
# view: quotes/escapes stripped, braces expanded, each word's globs matched
# segment-wise against the guarded paths from the project root.
ask_table <<'EOF'
v-glob-age-star@@rm .age*/loop/active
v-glob-a-star@@rm .a*/loop/active
v-glob-question-mark@@rm -rf .ag?nt/loop
v-glob-bracket-literal@@rm .[a]gent/loop/active
v-glob-bracket-range@@rm .[a-b]gent/loop/active
v-glob-bracket-negated@@rm -rf .[^x]gent/loop
v-split-double-quotes@@rm ".age""nt/loop/active"
v-split-ansi-c-quote@@rm .$'a'gent/loop/active
v-split-empty-single-quotes@@rm .age''nt/loop/active
v-split-backslash@@rm .a\gent/loop/active
v-split-ansi-c-hex@@rm $'\x2eagent'/loop/active
v-split-ansi-c-octal@@rm .$'\141'gent/loop/active
v-split-verb-double-quotes@@r""m .agent/loop/active
v-split-verb-single-quote@@'r'm .agent/loop/active
v-split-single-quotes-mid-word@@rm .age'nt'/loop/active
v-brace-list@@rm .ag{e,}nt/loop/active
v-brace-dirs@@rm -rf core/{tests,docs}
v-brace-range@@rm .agen{s..u}/loop/active
v-brace-nested@@rm -rf core/{x,{tests,y}}
v-surface-glob-te-star@@rm core/te*/grade.sh
v-surface-glob-t-star@@rm -rf core/t*
v-surface-glob-dir-star@@rm -rf c*/tests
v-surface-glob-evals-question@@rm -rf ev?ls
v-surface-glob-evals-star@@rm -rf ev*
v-surface-glob-evals-slash@@rm -rf ev*/
v-surface-glob-e-star@@rm -rf e*
v-surface-glob-evals-bracket@@rm -rf [e]vals
v-surface-glob-gitleaks@@rm gitleaks.t*
v-surface-glob-toml@@rm *.toml
v-surface-glob-hooks-json@@rm hooks/hooks.js*
v-surface-glob-ledger-writer@@rm core/infra/loop-led*.sh
v-surface-glob-guard-itself@@sed -i s/a/b/ core/hooks/loop-write-*.py
v-surface-glob-pre-tool-guard@@rm core/hooks/pre-tool-g*.sh
v-surface-glob-adapter@@rm adapters/claude-code/adapt*.sh
v-surface-glob-core-star@@rm -rf core/*
v-surface-glob-star-tests@@rm -rf */tests
v-surface-globstar@@rm **/tests/grade.sh
v-cd-glob-then-rm@@cd .age*/loop && rm active
v-dot-segment@@rm core/./tests/grade.sh
v-double-slash@@rm core//tests/grade.sh
v-dotdot-segment@@rm core/x/../tests/grade.sh
v-absolute-root-glob@@rm @ROOT@/core/te*
v-absolute-root-brace@@rm -rf @ROOT@/core/{tests,x}
v-absolute-root-dot-segment@@rm @ROOT@/core/./tests
v-project-dir-variable-glob@@rm "$CLAUDE_PROJECT_DIR"/core/te*
v-project-dir-variable-brace@@rm ${ROOT}/core/{tests,x}
v-sed-i-glob@@sed -i '' s/a/b/ core/te*/grade.sh
v-redirect-glob@@echo x > ev*/failure-modes.yaml
v-cp-glob-destination@@cp /tmp/x core/te*/
v-dotglob-star-gent@@shopt -s dotglob; rm -rf *gent
v-keyvalue-dd-dot-segment@@dd if=/dev/zero of=core/./tests/x
v-keyvalue-dd-brace@@dd if=x of=core/{tests,y}/f
v-keyvalue-target-directory-dot-segment@@cp --target-directory=core/./tests /tmp/x
v-infix-glob-over-two-segments@@rm -rf *or*/*
EOF
# macOS hands out /var/... temp dirs that are /private/var/... once resolved: the
# resolved spelling of the root must match too
read -r REAL_ROOT < <(cd "$ROOT" && pwd -P)
run_bash "rm -rf $REAL_ROOT/core/te*" AGENT_LOOP_ACTIVE=1
is_verdict_ask; check "v-absolute-realpath-root-glob" $?
run_bash "rm .age*/loop/active" AGENT_LOOP_ACTIVE=1
printf '%s' "$OUT" | grep -q 'control state'; check "v-glob-marker-reason-names-control-state" $?

echo
echo "=== (w) the wider matching stays quiet on reads, prose and unrelated work ==="
# A guard that asks on inspection or on prose trains people to click through: each of
# these carries a glob, a brace, a verb word or a guarded path, and none writes one.
quiet_table <<'EOF'
w-read-glob-cat@@cat core/te*/grade.sh
w-read-glob-ls@@ls core/te*
w-read-ls-dirs@@ls -d */
w-read-glob-grep@@grep -rn FAIL core/te*
w-read-find-name@@find core/tests -name '*.sh'
w-read-find-not-path@@find . -not -path '*/node_modules/*' -name '*.md'
w-read-git-status@@git -C . status --short core/tests
w-read-git-diff@@git -C . diff -- core/tests
w-read-git-log@@git --no-pager log --oneline -- evals
w-read-star-gent-without-dotglob@@ls -d *gent
w-markdown-emphasis@@echo '**bold** and *it*' >> agents/notes.md
w-regex-dot-star@@grep -E '.*foo' agents/x.md
w-regex-dot-star-lazy@@grep -E '.*?bar' agents/x.md
w-grep-include-glob@@grep -rn --include=*.toml foo docs
w-find-delete-elsewhere@@find . -name '*.pyc' -delete
w-rm-elsewhere@@rm -rf build dist
w-unlink-elsewhere@@unlink /tmp/stale.lock
w-gnu-name-inside-grep-pattern@@grep -E 'aws|gcp|azure' core/tests/cloud.sh
w-gnu-name-as-grep-argument@@grep -rn gcp core/tests
w-pandas-rename-is-not-pathlib@@python3 -c "s = df.stack().rename('x'); print(s)" core/tests/data.csv
w-prose-mentions-node-and-write@@git commit -m "each write of a node is checked by core/tests"
w-prose-echo-node-write@@echo "the node will write core/tests results"
w-node-console-log@@node -e "console.log(1)" core/tests/x.json
w-node-reads-a-file@@node -e "console.log(require('fs').readFileSync('core/tests/x.json', 'utf8'))"
w-git-clean-names-nothing@@git clean -n
w-brace-mkdir-elsewhere@@mkdir -p docs/{a,b,c}
w-quoted-args-elsewhere@@cp 'a b' "c d" docs/
w-url-with-double-slash@@curl -s https://example.com/a//b
w-dotted-path-elsewhere@@ls ./docs/../docs/x
# the cases above that carry no write verb stay quiet whatever the path matcher says;
# these carry one, so only the matcher keeps them quiet
w-rsync-include-glob-is-a-pattern@@rsync -a --include=*.toml src/ docs/
w-dd-value-with-a-glob-is-not-resolved@@dd if=x of=core/te*/x
w-glob-near-a-guarded-name@@rm -rf docs/te*
w-star-gent-without-dotglob-rm@@rm -rf *gent
w-python-open-read-binary@@python3 -c "open('core/tests/x.json', 'rb').read()"
w-python-open-filename-starting-with-b@@python3 -c "open('bar.txt')" core/tests
w-node-opensync-read@@node -e "require('fs').openSync('evals/a.json', 'r')"
w-ruby-open-read-no-parens@@ruby -e 'File.open "evals/a.json"'
w-ruby-open-read-encoding@@ruby -e 'File.open "evals/a.json", "r:UTF-8"'
w-ruby-open-read-encoding-parens@@ruby -e 'File.open("evals/a.json", "r:UTF-8").read'
w-ruby-open-block-with-common-words@@ruby -e 'File.open "evals/a.json" do |f| puts "text case access extract cat" end'
w-php-fopen-read@@php -r "fopen('evals/a.json', 'r');"
w-php-fopen-read-binary@@php -r "fopen('evals/a.json', 'rb');"
w-php-fopen-read-inside-another-call@@php -r "echo fread(fopen('evals/a.json', 'rt'), 10);"
w-node-opensync-read-sync@@node -e "require('fs').openSync('evals/a.json', 'rs')"
w-node-opensync-read-nested-call@@node -e "require('fs').openSync(require('path').join('evals', 'data.json'), 'r')"
w-python-open-read-nested-call@@python3 -c "import os; open(os.path.join('evals', 'data.json'), 'r').read()"
w-php-fopen-read-nested-call@@php -r "fopen(dirname('evals/data.json') . '/data.json', 'r');"
EOF

echo
echo "=== (x) padding cannot hide a path, and a huge command cannot exhaust the check ==="
# A brace word too big to enumerate used to come back as written, so padding the braces
# hid the path behind it; now it is unevaluable, which fails closed to ask.
pad7=""; for _ in 1 2 3 4 5 6 7; do pad7="${pad7}{,}"; done
pad13=""; for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13; do pad13="${pad13}{,}"; done
pad200=""; for ((i = 0; i < 200; i++)); do pad200="${pad200}{,}"; done
many=""; for ((i = 0; i < 70; i++)); do many="${many},x${i}"; done
run_bash "rm -rf ${pad7}.ag{e,}nt/loop/active" AGENT_LOOP_ACTIVE=1
is_verdict_ask; check "x-brace-padded-seven-empty-groups-ask" $?
run_bash "rm -rf ${pad13}.ag{e,}nt/loop/active" AGENT_LOOP_ACTIVE=1
is_verdict_ask; check "x-brace-padded-past-the-enumeration-limit-ask" $?
run_bash "rm -rf ${pad200}.ag{e,}nt/loop/active" AGENT_LOOP_ACTIVE=1
is_verdict_ask; check "x-brace-padded-long-word-ask" $?
run_bash "rm -rf ${pad7}core/te{s,}ts" AGENT_LOOP_ACTIVE=1
is_verdict_ask; check "x-brace-padded-surface-ask" $?
run_bash "rm -rf ${pad7}ev*" AGENT_LOOP_ACTIVE=1
is_verdict_ask; check "x-brace-padded-glob-ask" $?
run_bash "rm -rf {${many#,},.ag{e,}nt}/loop/active" AGENT_LOOP_ACTIVE=1
is_verdict_ask; check "x-brace-hidden-in-a-seventy-name-list-ask" $?
run_bash "rm -rf {core/te{s,}ts${many}}" AGENT_LOOP_ACTIVE=1
is_verdict_ask; check "x-brace-wide-list-spelling-surface-ask" $?
# a long list that hits nothing must stay quiet
run_bash "rm -rf {${many#,}}" AGENT_LOOP_ACTIVE=1
is_quiet; check "x-brace-seventy-names-hitting-nothing-allowed" $?
run_bash "cp a.txt docs/{${many#,}}" AGENT_LOOP_ACTIVE=1
is_quiet; check "x-brace-wide-list-elsewhere-allowed" $?
json='{"k":['; for ((i = 0; i < 400; i++)); do json="${json}1,"; done; json="${json}1]}"
run_bash "curl -s -d '$json' https://example.com -o /tmp/out" AGENT_LOOP_ACTIVE=1
is_quiet; check "x-long-json-argument-allowed" $?
# the work one command may cost is capped: past the cap it asks rather than stalls
words=""; for ((i = 0; i < 700; i++)); do words="$words {a,b,c,d}{e,f,g,h}x*"; done
run_bash "rm$words" AGENT_LOOP_ACTIVE=1
is_verdict_ask; check "x-work-budget-exhausted-asks" $?
words=""; for ((i = 0; i < 20; i++)); do words="$words {a,b,c,d}{e,f,g,h}x*"; done
run_bash "rm$words" AGENT_LOOP_ACTIVE=1
is_quiet; check "x-work-under-budget-allowed" $?

echo
echo "=== (y) the hook keeps its own deadline: a stalled evaluation asks, it is not killed ==="
# The harness kills a hook at its timeout and a killed hook decides nothing, which
# reads as allow — and a command long enough to stall the verb regexes (they scan to
# the end of the command from every `python3`) outlived it. The deadline is a test
# seam here; the shipped default is 20s against hooks.json's 30s.
stall="python3 "; for ((i = 0; i < 13; i++)); do stall="${stall}${stall}"; done; stall="${stall}core/tests"
run_bash "$stall" AGENT_LOOP_ACTIVE=1 AGENT_LOOP_GUARD_TIMEOUT=0.5
is_ask; check "y-stalled-evaluation-asks" $?
printf '%s' "$OUT" | grep -q 'could not evaluate'; check "y-stalled-evaluation-reason-says-unevaluable" $?
run_bash "cat core/tests/grade.sh" AGENT_LOOP_ACTIVE=1 AGENT_LOOP_GUARD_TIMEOUT=5
is_quiet; check "y-quick-read-unaffected-by-deadline" $?
# The open-call matcher is one pass over the command. Scanning on from every open word to
# the end took seconds for 80 KB, past the 2 s deadline used here, and would have asked
# "could not evaluate" instead of giving the verdict.
opens="open "; for ((i = 0; i < 14; i++)); do opens="${opens}${opens}"; done
run_bash "node -e ${opens}evals/x.yaml" AGENT_LOOP_ACTIVE=1 AGENT_LOOP_GUARD_TIMEOUT=2
is_quiet; check "y-long-run-of-open-words-stays-quiet-within-the-deadline" $?
fopens="fopen( "; for ((i = 0; i < 14; i++)); do fopens="${fopens}${fopens}"; done
run_bash "php -r ${fopens}evals/x.yaml" AGENT_LOOP_ACTIVE=1 AGENT_LOOP_GUARD_TIMEOUT=2
is_verdict_ask; check "y-long-run-of-fopen-calls-asks-within-the-deadline" $?
run_bash "echo x > core/tests/y.sh" AGENT_LOOP_ACTIVE=1 AGENT_LOOP_GUARD_TIMEOUT=banana
is_verdict_ask; check "y-garbage-deadline-value-ignored" $?
# The seam can only SHORTEN the deadline: a value that is not a number, or is zero,
# negative, or past the default, leaves the default armed. Read off the timer itself.
# -B: importing the hook must not leave core/hooks/__pycache__ behind (grade-test.sh imports
# it without -B, so the bytecode does appear in a full run).
seam_left() {
  AGENT_LOOP_GUARD_TIMEOUT="$1" python3 -I -B - "$HOOK" <<'PY'
import importlib.util, signal, sys
spec = importlib.util.spec_from_file_location("lwg", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mod._arm_deadline()
print(round(signal.getitimer(signal.ITIMER_REAL)[0]))
PY
}
# seam_is <seconds expected on the timer> <seam value>
seam_is() {
  local got
  read -r got < <(seam_left "$2")
  [[ "$got" == "$1" ]]
}
seam_is 2 2; check "y-seam-shortens-the-deadline" $?
seam_is 20 20; check "y-seam-equal-to-default-is-the-default" $?
for bad in banana nan inf 0 -5 100 1e9 ""; do
  seam_is 20 "$bad"; check "y-bad-seam-keeps-the-default-[$bad]" $?
done
# supply-chain-scan greps core/hooks/__pycache__ as well as the source, and bytecode cannot
# carry the scan's per-line allow marker: a daemon word in this file would fail the scan in
# any run where a test has imported the hook first. Judged on the compiled code, not the text.
daemon_words_in_bytecode() {   # <file> -> exit 3 when its compiled code holds one, 0 when clean
  python3 -I -B - "$1" <<'PY'
import marshal, re, sys
blob = marshal.dumps(compile(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1], "exec"))
sys.exit(3 if re.search(rb"nohup|setsid|disown|crontab\s+-", blob) else 0)
PY
}
printf 'WORD = "no" "hup"\n' > "$TMP_ROOT/folded.py"
daemon_words_in_bytecode "$TMP_ROOT/folded.py"; bc_rc=$?
[[ "$bc_rc" -eq 3 ]]; check "y-bytecode-probe-sees-a-folded-literal" $?
daemon_words_in_bytecode "$HOOK"; bc_rc=$?
[[ "$bc_rc" -eq 0 ]]; check "y-compiled-hook-carries-no-daemon-word" $?

echo
echo "=== (z) no relaxing: every verb the ORIGINAL table knew still asks ==="
# The new verbs and spellings only ADD asks. This pins the old table so a future edit
# that narrows one of its alternatives fails here, not in a loop.
ask_table <<'EOF'
z-redirect@@echo x > core/tests/x.sh
z-append@@echo x >> core/tests/x.sh
z-tee@@echo x | tee core/tests/x.sh
z-sed-i@@sed -i '' s/a/b/ core/tests/x.sh
z-gsed-i@@gsed -i s/a/b/ core/tests/x.sh
z-awk-i@@awk -i inplace 1 core/tests/x.sh
z-cp@@cp /tmp/x core/tests/x.sh
z-mv@@mv core/tests/x.sh /tmp/x
z-dd@@dd if=/dev/zero of=core/tests/x.sh
z-install@@install -m 644 /tmp/x core/tests/x.sh
z-rm@@rm core/tests/x.sh
z-truncate@@truncate -s 0 core/tests/x.sh
z-rsync@@rsync -a /tmp/x core/tests/
z-tar@@tar xf /tmp/x.tar -C core/tests
z-ditto@@ditto /tmp/x core/tests
z-patch@@patch core/tests/x.sh < /tmp/p.diff
z-unzip@@unzip /tmp/x.zip -d core/tests
z-curl-o@@curl -o core/tests/x.sh https://example.com/x
z-wget@@wget -O core/tests/x.sh https://example.com/x
z-ed@@ed core/tests/x.sh
z-ex@@ex core/tests/x.sh
z-git-checkout@@git checkout HEAD -- core/tests/x.sh
z-git-restore@@git restore core/tests/x.sh
z-git-apply@@git apply core/tests/x.sh
z-git-rm@@git rm core/tests/x.sh
z-git-mv@@git mv core/tests/x.sh /tmp/x
z-git-stash-pop@@git stash pop core/tests/x.sh
z-git-update-index@@git update-index --assume-unchanged core/tests/x.sh
z-python-open-w@@python3 -c "open('core/tests/x.sh','w')"
z-python-open-a@@python3 -c "open('core/tests/x.sh','a')"
z-python-write-text@@python3 -c "import pathlib; pathlib.Path('core/tests/x.sh').write_text('x')"
z-python-write-bytes@@python3 -c "import pathlib; pathlib.Path('core/tests/x.sh').write_bytes(b'x')"
z-python-shutil@@python3 -c "import shutil; shutil.copy('/tmp/x','core/tests/x.sh')"
z-python-os-replace@@python3 -c "import os; os.replace('/tmp/x','core/tests/x.sh')"
z-python-os-rename@@python3 -c "import os; os.rename('/tmp/x','core/tests/x.sh')"
z-python-os-remove@@python3 -c "import os; os.remove('core/tests/x.sh')"
z-python-os-unlink@@python3 -c "import os; os.unlink('core/tests/x.sh')"
z-perl-redirect@@perl -e 'print 1' > core/tests/x.sh
z-chmod@@chmod 000 core/tests/x.sh
z-gchmod@@gchmod 000 core/tests/x.sh
z-ln@@ln -sf /tmp/x core/tests/x.sh
z-sqlite-update@@sqlite3 .agent/locks/g.db "UPDATE g SET s=1"
z-sqlite-insert-lowercase@@sqlite3 .agent/locks/g.db "insert into g values (1)"
z-sqlite-delete@@sqlite3 .agent/locks/g.db "DELETE FROM g"
z-sqlite-drop@@sqlite3 .agent/locks/g.db "DROP TABLE g"
z-find-exec-rm@@find core/tests -name x.sh -exec rm {} \;
z-xargs-rm@@echo core/tests/x.sh | xargs rm
z-control-rm-marker@@rm .agent/loop/active
z-control-cd-split@@cd .agent/loop && rm active
z-ledger-redirect@@echo x > .agent/loop/results.tsv
z-witness-redirect@@echo x > .agent/loop/results.tsv.witness
z-hooks-json-sed@@sed -i '' s/a/b/ hooks/hooks.json
z-gitleaks-toml-redirect@@echo x > gitleaks.toml
z-pre-tool-guard-cp@@cp /tmp/x core/hooks/pre-tool-guard.sh
z-adapter-mv@@mv /tmp/x adapters/claude-code/adapter.sh
z-ledger-writer-rm@@rm core/infra/loop-ledger.sh
z-guard-itself-redirect@@echo x > core/hooks/loop-write-guard.py
EOF

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
