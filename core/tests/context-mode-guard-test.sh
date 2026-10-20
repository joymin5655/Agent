#!/usr/bin/env bash
# context-mode-guard-test.sh — verify core/hooks/context-mode-guard.sh and how it is wired.
#
# The guard used to sit under the PreToolUse "*" matcher, so Claude spawned bash + jq for EVERY
# tool call only for the script to exit 0 on any tool that is not a Context-Mode sandbox tool.
# It now has its own entry with a regex matcher. This battery pins both halves:
#   (1) wiring — in hooks/hooks.json AND adapters/claude-code/settings.json.template: "*" no longer lists the guard
#       (r4-mutex-check.sh sits under a narrowed Bash|mcp matcher); exactly one dedicated entry lists it; its
#       matcher is a regex that selects every sandbox tool name the script's own `case` handles
#       (context-mode / context_mode spellings, plugin-prefixed names included) and nothing else;
#   (2) behaviour — through the real Claude adapter: a secret-path reference in the sandbox code is
#       denied, a production migration asks, benign code and non-sandbox tools pass silently.
# The matcher is tested with Python's re.search: Claude evaluates a matcher that contains any
# character beyond [A-Za-z0-9_-, |] as an UNANCHORED JavaScript regex (docs/hook-protocol.md §12).
#
# Usage: bash core/tests/context-mode-guard-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ADAPTER="$REPO_ROOT/adapters/claude-code/adapter.sh"
GUARD="$REPO_ROOT/core/hooks/context-mode-guard.sh"
MANIFESTS=("$REPO_ROOT/hooks/hooks.json" "$REPO_ROOT/adapters/claude-code/settings.json.template")

PASS=0
FAIL=0
ok()  { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL [$1] $2"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap '[[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"' EXIT
# X-5: keep this battery's gate records out of the live .agent/logs sink (caller-set seam wins)
export AGENT_GATE_SINK_DIR="${AGENT_GATE_SINK_DIR:-$WORK/gate-sink}"

# A function (not a <( ) substitution): bash 3.2 mis-parses quote characters inside a heredoc that
# sits within a process/command substitution.
wiring_report() {  # wiring_report <manifest> -> TSV: OK|BAD <check> <detail>
  python3 - "$1" "$GUARD" <<'PY'
import json
import re
import sys

manifest, guard = sys.argv[1], sys.argv[2]
groups = json.load(open(manifest, encoding="utf-8"))["hooks"]["PreToolUse"]


def hook_names(group):
    return [h["command"].split()[-1].strip('"') for h in group.get("hooks", [])]


def emit(ok, name, detail=""):
    print(f"{'OK' if ok else 'BAD'}\t{name}\t{detail}")


star = [g for g in groups if g.get("matcher") == "*"]
own = [g for g in groups if "context-mode-guard.sh" in hook_names(g)]
r4 = [g for g in groups if "r4-mutex-check.sh" in hook_names(g)]
emit(len(r4) == 1 and r4[0].get("matcher") not in ("", "*"), "r4-mutex-narrowed",
     "r4-mutex-check.sh must sit under a narrowed matcher (Bash + MCP tools), not the * matcher")
emit(not any("context-mode-guard.sh" in hook_names(g) for g in star), "star-drops-guard",
     "context-mode-guard.sh is still under the * matcher (bash + jq on every tool call)")
emit(len(own) == 1 and hook_names(own[0]) == ["context-mode-guard.sh"], "own-entry",
     f"want exactly one entry listing only the guard, got {[hook_names(g) for g in own]}")
matcher = own[0].get("matcher", "") if own else ""
exact_set = re.fullmatch(r"[A-Za-z0-9_\- ,|]*", matcher) is not None
emit(matcher not in ("", "*") and not exact_set, "matcher-is-a-regex",
     f"matcher {matcher!r} would be compared as an exact tool name")
sandbox = []
for spelling in ("context-mode", "context_mode"):
    for tool in ("ctx_execute", "ctx_execute_file", "ctx_batch_execute"):
        sandbox.append(f"mcp__{spelling}__{tool}")
        sandbox.append(f"mcp__plugin_{spelling}_{spelling}__{tool}")
others = ["Bash", "Read", "Write", "Edit", "mcp__supabase__execute_sql",
          "mcp__plugin_context-mode_context-mode__ctx_search",
          "mcp__plugin_context-mode_context-mode__ctx_index",
          "mcp__context_mode__ctx_stats", "mcp__other__execute", "mcp__other__batch_execute_file"]
try:
    rx = re.compile(matcher)
    miss = [n for n in sandbox if not rx.search(n)]
    extra = [n for n in others if rx.search(n)]
except re.error as exc:
    rx, miss, extra = None, [f"bad regex: {exc}"], []
emit(not miss, "matcher-selects-every-sandbox-tool", f"not matched: {miss}")
emit(not extra, "matcher-ignores-other-tools", f"wrongly matched: {extra}")
# every tool name the script's own case handles must be reachable through the matcher
script = open(guard, encoding="utf-8").read()
handled = sorted(set(re.findall(r"\*(context[-_]mode__ctx_[a-z_]+)", script)))
unreachable = [h for h in handled if not (rx and rx.search("mcp__plugin_x_" + h))]
emit(bool(handled) and not unreachable, "matcher-covers-script-case",
     f"script handles {handled}; matcher misses {unreachable}")
PY
}

echo "=== (1) wiring: dedicated entry with a narrow matcher, not the \"*\" group ==="
for manifest in "${MANIFESTS[@]}"; do
  label="$(basename "$manifest")"
  wiring_report "$manifest" > "$WORK/wiring.tsv"
  while IFS=$'\t' read -r verdict name detail; do
    [[ -z "$verdict" ]] && continue
    if [[ "$verdict" == "OK" ]]; then ok "$label/$name"; else bad "$label/$name" "$detail"; fi
  done < "$WORK/wiring.tsv"
done

echo
echo "=== (2) behaviour through the Claude adapter ==="
SEC="secr""ets/"   # assembled: keeps a literal secrets/ read out of this file's source text
event() {  # event <tool_name> <tool_input-json>
  python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","tool_name":sys.argv[1],"tool_input":json.loads(sys.argv[2])}))' "$1" "$2"
}
decision() {  # decision <tool_name> <tool_input-json> -> deny|ask|allow
  local out
  out=$(event "$1" "$2" | bash "$ADAPTER" context-mode-guard.sh 2>/dev/null || true)
  case "$out" in
    *'"permissionDecision": "deny"'*) echo deny ;;
    *'"permissionDecision": "ask"'*)  echo ask ;;
    *)                                echo allow ;;
  esac
}
expect() {  # expect <case-name> <want> <tool_name> <tool_input-json>
  local got
  got=$(decision "$3" "$4")
  if [[ "$got" == "$2" ]]; then ok "$1"; else bad "$1" "want=$2 got=$got"; fi
}

if ! command -v jq >/dev/null 2>&1; then
  echo "  skip (jq unavailable: the guard itself skips without it)"
else
  for tool in mcp__context-mode__ctx_execute mcp__context_mode__ctx_execute \
              mcp__plugin_context-mode_context-mode__ctx_execute; do
    expect "execute-secret-path-deny/$tool" deny "$tool" "{\"language\":\"shell\",\"code\":\"cat ${SEC}app.key\"}"
  done
  expect "execute-file-secret-path-deny" deny mcp__plugin_context-mode_context-mode__ctx_execute_file \
    "{\"path\":\"config/${SEC}app.env\",\"code\":\"print(1)\"}"
  expect "batch-secret-path-deny" deny mcp__plugin_context-mode_context-mode__ctx_batch_execute \
    "{\"commands\":[{\"label\":\"a\",\"command\":\"ls\"},{\"label\":\"b\",\"command\":\"head -n1 ${SEC}app.key\"}]}"
  expect "execute-prod-migration-ask" ask mcp__context-mode__ctx_execute \
    '{"language":"shell","code":"npx supabase db push"}'
  expect "execute-benign-allow" allow mcp__context-mode__ctx_execute '{"language":"shell","code":"echo hello"}'
  expect "other-tool-ignored-allow" allow mcp__plugin_context-mode_context-mode__ctx_search \
    "{\"code\":\"cat ${SEC}app.key\"}"
  expect "non-mcp-tool-ignored-allow" allow Bash "{\"command\":\"cat ${SEC}app.key\"}"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
