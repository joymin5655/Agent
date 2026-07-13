#!/usr/bin/env bash
# supervisor-dispatch-test.sh — reproduce suite for the dispatch-not-advise supervisor.
#
# Feeds canonical UserPromptSubmit / PreToolUse / PostToolUse event JSON to
# core/hooks/supervisor.py and asserts the v0.2 dispatcher contract:
#   - a keyword match on UserPromptSubmit records an intent + jsonl "match"
#   - the next Write/Edit raises a `permissionDecision: "ask"` naming the specialist
#   - the ask fires ONCE per intent (no repeat nag)
#   - dispatching the specialist (Task/Agent) resolves the intent (namespace-agnostic)
#     and preserves the security_asked_paths dedup (M-2)
#   - ghost specialists (registry id with no sibling <id>.md) never ask — stderr hint only
#   - a security file-glob matcher asks independently of intent, once per path (Write/Edit/MultiEdit)
#   - domain-anchored keywords do NOT false-match generic "review" sentences (Lesson 1)
#   - native Claude Code field shapes (hook_event_name / prompt) work via fallbacks (M-4)
#   - AGENT_SUPERVISOR_MODE=observe downgrades ask -> stderr
#   - broken stdin / absent registry is fail-open (exit 0, empty stdout)
#
# Every scenario runs against a throwaway git fixture in $(mktemp -d) with an
# isolated .agent/ — the real repo is never touched. Env is scoped per-run.
#
# Usage: bash core/tests/supervisor-dispatch-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/core/hooks/supervisor.py"

PASS=0
FAIL=0
FIXTURES=()

cleanup() {
  local d
  for d in ${FIXTURES[@]+"${FIXTURES[@]}"}; do
    [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
  done
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------

# make_default_fixture — git repo with the shipped registry + both real agent .md
make_default_fixture() {
  local d; d="$(mktemp -d)"
  (
    cd "$d" || exit 1
    git init -q
    git config user.email "t@example.com"
    git config user.name "supervisor test"
    mkdir -p agents
  )
  cp "$REPO_ROOT/agents/master-registry.json" "$d/agents/"
  cp "$REPO_ROOT/agents/code-reviewer.md" "$d/agents/"
  cp "$REPO_ROOT/agents/security-reviewer.md" "$d/agents/"
  FIXTURES+=("$d")
  echo "$d"
}

# make_ghost_fixture — registry names a specialist with NO sibling .md (a ghost)
make_ghost_fixture() {
  local d; d="$(mktemp -d)"
  (
    cd "$d" || exit 1
    git init -q
    git config user.email "t@example.com"
    git config user.name "supervisor test"
    mkdir -p agents
  )
  cat > "$d/agents/master-registry.json" <<'EOF'
{
  "version": 1,
  "agents": [
    {
      "id": "ghost-reviewer",
      "description": "phantom specialist — reference only, no provider",
      "matches": { "keywords": ["ectoplasm"], "tools": [], "file_globs": [] },
      "aliases": [],
      "model": "sonnet",
      "memory_scope": "local"
    }
  ]
}
EOF
  # Intentionally NO agents/ghost-reviewer.md → ghost.
  FIXTURES+=("$d")
  echo "$d"
}

# make_ghost_glob_fixture — a ghost that GUARDS A PATH, listed ahead of a real
# agent guarding the same path. The keyword ghost above can never reach the
# file-glob matcher (it declares no globs), yet a path-guarding specialist is
# exactly the shape the live deadlock took (a retired `edge-fn-dev` guarding
# **/functions/**). Ghost-first is deliberate: it pins the skip as `continue`,
# not `return` — a ghost must not swallow the real guard behind it.
make_ghost_glob_fixture() {
  local d; d="$(mktemp -d)"
  (
    cd "$d" || exit 1
    git init -q
    git config user.email "t@example.com"
    git config user.name "supervisor test"
    mkdir -p agents
  )
  cat > "$d/agents/master-registry.json" <<'EOF'
{
  "version": 1,
  "agents": [
    {
      "id": "edge-fn-dev",
      "description": "retired path-guarding specialist — no provider ships for it",
      "matches": { "keywords": [], "tools": ["Write", "Edit"], "file_globs": ["**/functions/**"] },
      "aliases": [],
      "model": "sonnet",
      "memory_scope": "local"
    },
    {
      "id": "security-reviewer",
      "description": "real specialist guarding the same path",
      "matches": { "keywords": [], "tools": ["Write", "Edit"], "file_globs": ["**/functions/**"] },
      "aliases": [],
      "model": "opus",
      "memory_scope": "local"
    }
  ]
}
EOF
  # Only the real one gets a provider; edge-fn-dev deliberately gets none.
  cp "$REPO_ROOT/agents/security-reviewer.md" "$d/agents/"
  FIXTURES+=("$d")
  echo "$d"
}

# make_bare_fixture — git repo with NO registry at all
make_bare_fixture() {
  local d; d="$(mktemp -d)"
  (
    cd "$d" || exit 1
    git init -q
    git config user.email "t@example.com"
    git config user.name "supervisor test"
  )
  FIXTURES+=("$d")
  echo "$d"
}

# ---------------------------------------------------------------------------
# event builders + runner
# ---------------------------------------------------------------------------

ups_event()  { printf '{"event":"UserPromptSubmit","user_prompt":"%s"}' "$1"; }
pre_event()  { printf '{"event":"PreToolUse","tool_name":"%s","tool_input":{"file_path":"%s"}}' "$1" "$2"; }
post_event() { printf '{"event":"PostToolUse","tool_name":"Agent","tool_input":{"subagent_type":"%s"}}' "$1"; }

# run_hook <fixture> <json> [ENV=VAL ...]  → sets OUT, RC, STDERR
run_hook() {
  local fix="$1" json="$2"; shift 2
  local errf; errf="$(mktemp)"
  OUT="$(printf '%s' "$json" | ( cd "$fix" && env AGENT_SESSION_ID=test "$@" python3 "$HOOK" ) 2>"$errf")"
  RC=$?
  STDERR="$(cat "$errf")"
  rm -f "$errf"
}

STATE_REL=".agent/state/supervisor-intent.json"
JSONL_REL=".agent/logs/supervisor.jsonl"

# ---------------------------------------------------------------------------
# assertions
# ---------------------------------------------------------------------------

ok()   { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL [$1] $2"; FAIL=$((FAIL + 1)); }

assert_empty_stdout() { # <label>
  if [[ -z "$OUT" ]]; then ok "$1 (empty stdout)"; else bad "$1" "expected empty stdout, got: $OUT"; fi
}
assert_stdout_has() {   # <label> <needle>
  if [[ "$OUT" == *"$2"* ]]; then ok "$1 (stdout has '$2')"; else bad "$1" "stdout missing '$2': $OUT"; fi
}
assert_stderr_has() {   # <label> <needle>
  if [[ "$STDERR" == *"$2"* ]]; then ok "$1 (stderr has '$2')"; else bad "$1" "stderr missing '$2': $STDERR"; fi
}
assert_rc_zero() {      # <label>
  if [[ "$RC" -eq 0 ]]; then ok "$1 (exit 0)"; else bad "$1" "expected exit 0, got $RC"; fi
}
assert_state_exists() { # <label> <fixture> <needle>
  local f="$2/$STATE_REL"
  if [[ -f "$f" ]] && grep -q "$3" "$f"; then ok "$1 (state has '$3')"; else bad "$1" "state file missing or lacks '$3' ($f)"; fi
}
assert_no_state() {     # <label> <fixture>
  local f="$2/$STATE_REL"
  if [[ ! -f "$f" ]]; then ok "$1 (no state file)"; else bad "$1" "unexpected state file: $(cat "$f")"; fi
}
assert_jsonl_has() {    # <label> <fixture> <needle>
  local f="$2/$JSONL_REL"
  if [[ -f "$f" ]] && grep -q "$3" "$f"; then ok "$1 (jsonl has '$3')"; else bad "$1" "jsonl missing '$3' ($f)"; fi
}

# ---------------------------------------------------------------------------
# scenarios
# ---------------------------------------------------------------------------

echo "=== 1. UPS keyword match records intent + jsonl match + empty stdout ==="
F1="$(make_default_fixture)"
run_hook "$F1" "$(ups_event 'please review this code before I merge')"
assert_empty_stdout "1"
assert_state_exists "1" "$F1" "code-reviewer"
assert_jsonl_has    "1" "$F1" '"action": "match"'

echo "=== 2. Next Edit -> ask naming code-reviewer ==="
run_hook "$F1" "$(pre_event Edit 'src/widget.ts')"
assert_stdout_has "2" '"permissionDecision": "ask"'
assert_stdout_has "2" 'code-reviewer'

echo "=== 3. Same Edit re-sent -> ask fires once (empty stdout) ==="
run_hook "$F1" "$(pre_event Edit 'src/widget.ts')"
assert_empty_stdout "3"

echo "=== 4. UPS match -> dispatch Agent(code-reviewer) -> Edit is clear ==="
F4="$(make_default_fixture)"
run_hook "$F4" "$(ups_event 'can you code review this diff')"
assert_state_exists "4-match" "$F4" "code-reviewer"
run_hook "$F4" "$(post_event 'code-reviewer')"
assert_no_state    "4-dispatched" "$F4"
assert_jsonl_has   "4-dispatched" "$F4" '"action": "dispatched"'
run_hook "$F4" "$(pre_event Edit 'src/widget.ts')"
assert_empty_stdout "4-edit-clear"

echo "=== 5. Namespaced subagent_type (acme:code-reviewer) also resolves ==="
F5="$(make_default_fixture)"
run_hook "$F5" "$(ups_event 'please review this code')"
run_hook "$F5" "$(post_event 'acme:code-reviewer')"
assert_no_state "5" "$F5"

echo "=== 6. Non-matching prompt -> no intent, Edit stays clear ==="
F6="$(make_default_fixture)"
run_hook "$F6" "$(ups_event 'hello there how are you today')"
assert_no_state "6-nostate" "$F6"
run_hook "$F6" "$(pre_event Edit 'src/widget.ts')"
assert_empty_stdout "6-edit-clear"

echo "=== 7. Ghost specialist -> no intent, stderr fallback hint, no ask ==="
F7="$(make_ghost_fixture)"
run_hook "$F7" "$(ups_event 'summon the ectoplasm now')"
assert_no_state    "7-nostate" "$F7"
assert_empty_stdout "7-ups-empty"
assert_stderr_has  "7-hint" "ghost-reviewer"
assert_jsonl_has   "7-log"  "$F7" '"action": "ghost"'
run_hook "$F7" "$(pre_event Edit 'src/widget.ts')"
assert_empty_stdout "7-edit-clear"

echo "=== 8. Security glob matcher asks on **/auth/**, once per path ==="
F8="$(make_default_fixture)"
run_hook "$F8" "$(pre_event Write 'src/auth/login.ts')"
assert_stdout_has "8-ask" '"permissionDecision": "ask"'
assert_stdout_has "8-ask" 'security-reviewer'
run_hook "$F8" "$(pre_event Write 'src/auth/login.ts')"
assert_empty_stdout "8-once-per-path"

echo "=== 9. observe mode downgrades ask -> stderr, empty stdout ==="
F9="$(make_default_fixture)"
run_hook "$F9" "$(ups_event 'please review this code')"
run_hook "$F9" "$(pre_event Edit 'src/widget.ts')" AGENT_SUPERVISOR_MODE=observe
assert_empty_stdout "9-no-ask"
assert_stderr_has   "9-stderr" 'code-reviewer'

echo "=== 10. Fail-open: broken stdin + absent registry -> exit 0, empty stdout ==="
F10="$(make_bare_fixture)"
run_hook "$F10" ''
assert_rc_zero      "10-empty-stdin"
assert_empty_stdout "10-empty-stdin"
run_hook "$F10" 'this is not json {['
assert_rc_zero      "10-bad-json"
assert_empty_stdout "10-bad-json"
run_hook "$F10" "$(ups_event 'please review this code')"
assert_rc_zero      "10-no-registry"
assert_empty_stdout "10-no-registry"
assert_no_state     "10-no-registry" "$F10"

echo "=== 11. Lesson 1: generic 'review' sentences do NOT match (domain anchors) ==="
F11="$(make_default_fixture)"
run_hook "$F11" "$(ups_event 'review my plan for tomorrow')"
assert_no_state "11-plan" "$F11"
run_hook "$F11" "$(ups_event 'let me review the options')"
assert_no_state "11-options" "$F11"

echo "=== 12. M-2: dispatch clears intent but preserves security dedup ==="
F12="$(make_default_fixture)"
run_hook "$F12" "$(pre_event Write 'src/auth/login.ts')"
assert_stdout_has "12-sec-ask" 'security-reviewer'
run_hook "$F12" "$(ups_event 'please review this code')"
run_hook "$F12" "$(post_event 'code-reviewer')"
assert_state_exists "12-sec-preserved" "$F12" 'security_asked_paths'
run_hook "$F12" "$(pre_event Write 'src/auth/login.ts')"
assert_empty_stdout "12-sec-still-deduped"

echo "=== 13. M-3: MultiEdit on **/auth/** triggers security ask (tools include MultiEdit) ==="
F13="$(make_default_fixture)"
run_hook "$F13" "$(pre_event MultiEdit 'src/auth/session.ts')"
assert_stdout_has "13-multiedit-ask" '"permissionDecision": "ask"'
assert_stdout_has "13-multiedit-ask" 'security-reviewer'

echo "=== 14. M-4: native shape (hook_event_name + prompt) records intent + native ask ==="
F14="$(make_default_fixture)"
run_hook "$F14" '{"hook_event_name":"UserPromptSubmit","prompt":"please review this code"}'
assert_state_exists "14-native-intent" "$F14" "code-reviewer"
run_hook "$F14" '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"src/widget.ts"}}'
assert_stdout_has "14-native-ask" '"permissionDecision": "ask"'
assert_stdout_has "14-native-ask" 'code-reviewer'

echo "=== 15. Ghost guarding a file_glob -> hinted + skipped, real guard behind it still asks ==="
F15="$(make_ghost_glob_fixture)"
run_hook "$F15" "$(pre_event Write 'supabase/functions/hello.ts')"
assert_stderr_has "15-ghost-hint"  'edge-fn-dev'                    # ghost is named, not demanded
assert_jsonl_has  "15-ghost-log"   "$F15" '"action": "ghost"'
assert_stdout_has "15-no-deadlock" '"permissionDecision": "ask"'    # continue, not return...
assert_stdout_has "15-real-guard"  'security-reviewer'              # ...so the real guard survives
if [[ "$OUT" != *"edge-fn-dev"* ]]; then
  ok "15-never-demanded (no ask names the ghost)"
else
  bad "15-never-demanded" "the ask demands an undispatchable specialist: $OUT"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
