#!/usr/bin/env bash
# guard-feed-quiet-test.sh — the security guards record a block without writing the work feed.
#
# pre-tool-guard.sh, secret-content-scan.py and context-mode-guard.sh used to call
# `core/infra/agent-session.sh broadcast blocked "[security] ..."` on every deny or ask, which
# filled .agent/locks/work-feed.jsonl (the cross-session news other sessions read) with block
# noise, test-battery runs included. The block is already in security-violations.jsonl.
# Each case runs one guard against a scratch project root whose core/infra/agent-session.sh is
# a stand-in that leaves a marker file when called, and asserts three things: the decision is
# the expected deny/ask, the violation record was written, and the stand-in was never called.
# r4-mutex-check.sh keeps its broadcast (a mutex collision is coordination news between
# sessions) and is not covered here.
#
# Usage: bash core/tests/guard-feed-quiet-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -euo pipefail

# An inherited GIT_DIR / GIT_WORK_TREE would make a guard's git lookup land in that repository
# instead of the scratch root, and its real feed would take the broadcast unseen here.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_CEILING_DIRECTORIES

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOKS="$REPO_ROOT/core/hooks"

PASS=0
FAIL=0
ok()  { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL [$1] $2"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap '[[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"' EXIT

# make_root <name>: a scratch project root (its own git toplevel, so a guard that asks git for
# the root lands here) with a stand-in agent-session.sh; prints the root path.
make_root() {
  local root="$WORK/$1"
  mkdir -p "$root/core/infra" "$root/src"
  git init -q "$root" >/dev/null || { echo "guard-feed-quiet: git init failed in $root" >&2; exit 1; }
  cat > "$root/core/infra/agent-session.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(cd "$(dirname "$0")/../.." && pwd)/broadcast-called"
SH
  chmod +x "$root/core/infra/agent-session.sh"
  printf '%s' "$root"
}

# check_quiet <name> <root> <expect: deny|ask> <event-json> <hook command...>
check_quiet() {
  local name="$1" root="$2" expect="$3" event="$4"
  shift 4
  local out
  out=$(cd "$root" && printf '%s' "$event" \
    | env -u CLAUDE_PROJECT_DIR AGENT_PROJECT_DIR="$root" AGENT_GATE_SINK_DIR="$root/sink" \
      "$@" 2>/dev/null) || true
  if [[ "$out" == *"\"permissionDecision\": \"$expect\""* \
     || "$out" == *"\"permissionDecision\":\"$expect\""* ]]; then
    ok "$name/$expect"
  else
    bad "$name/$expect" "expected a $expect decision :: $out"
  fi
  if [[ -s "$root/sink/security-violations.jsonl" ]]; then
    ok "$name/violation-recorded"
  else
    bad "$name/violation-recorded" "no security-violations.jsonl record was written"
  fi
  if [[ -e "$root/broadcast-called" ]]; then
    bad "$name/no-broadcast" "agent-session.sh was called: $(cat "$root/broadcast-called")"
  else
    ok "$name/no-broadcast"
  fi
}

bash_event() {  # bash_event <command> <cwd>
  python3 -c 'import json, sys
print(json.dumps({"event": "PreToolUse", "tool_name": "Bash",
                  "tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2]}))' "$1" "$2"
}

write_event() {  # write_event <file_path> <content>
  python3 -c 'import json, sys
print(json.dumps({"event": "PreToolUse", "tool_name": "Write",
                  "tool_input": {"file_path": sys.argv[1], "content": sys.argv[2]}}))' "$1" "$2"
}

ctx_event() {  # ctx_event <code>
  python3 -c 'import json, sys
print(json.dumps({"event": "PreToolUse",
                  "tool_name": "mcp__plugin_context-mode_context-mode__ctx_execute",
                  "tool_input": {"language": "shell", "code": sys.argv[1]}}))' "$1"
}

echo "=== pre-tool-guard.sh: a block does not broadcast ==="
R="$(make_root ptg-secrets)"
check_quiet "pre-tool-guard-secrets" "$R" deny \
  "$(bash_event 'cat secrets/api.key' "$R")" bash "$HOOKS/pre-tool-guard.sh"
R="$(make_root ptg-policy)"
check_quiet "pre-tool-guard-policy-unset" "$R" deny \
  "$(bash_event 'unset AGENT_WORKER_POLICY_CMD' "$R")" bash "$HOOKS/pre-tool-guard.sh"
R="$(make_root ptg-drop)"
check_quiet "pre-tool-guard-drop-table-ask" "$R" ask \
  "$(bash_event 'psql -c "DROP TABLE users"' "$R")" bash "$HOOKS/pre-tool-guard.sh"

echo
echo "=== secret-content-scan.py: a block does not broadcast ==="
R="$(make_root scs-open)"
check_quiet "secret-content-scan-open" "$R" deny \
  "$(write_event "$R/src/app.py" 'data = open("secrets/api.key").read()')" \
  python3 "$HOOKS/secret-content-scan.py"
R="$(make_root scs-ledger)"
check_quiet "secret-content-scan-ledger" "$R" deny \
  "$(write_event "$R/.git/agent-author-vendors" '')" \
  python3 "$HOOKS/secret-content-scan.py"

echo
echo "=== context-mode-guard.sh: a block does not broadcast ==="
if command -v jq >/dev/null 2>&1; then
  R="$(make_root cmg-secrets)"
  check_quiet "context-mode-guard-secrets" "$R" deny \
    "$(ctx_event 'cat secrets/api.key')" bash "$HOOKS/context-mode-guard.sh"
  R="$(make_root cmg-migrate)"
  check_quiet "context-mode-guard-migrate-ask" "$R" ask \
    "$(ctx_event 'alembic upgrade head')" bash "$HOOKS/context-mode-guard.sh"
else
  echo "  SKIP [context-mode-guard] jq unavailable (the guard itself exits early without it)"
fi

echo
echo "=== guard-feed-quiet: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
