#!/usr/bin/env bash
# core/hooks/agent-proxy.sh
#
# Universal Agent Harness Proxy
# Purpose: Allows non-native CLI agents (Gemini, Codex, etc.) to execute commands
# safely by routing them through the native PreToolUse security hooks.

set -euo pipefail

if [ $# -eq 0 ]; then
  echo "Usage: $0 <command_to_execute>"
  exit 1
fi

COMMAND_TO_RUN="$1"
AGENT_NAME="${AGENT_NAME:-unknown-agent}"

# Find the project root
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

# 1. Construct the mock JSON payload
JSON_PAYLOAD=$(python3 -c "
import sys, json
command = sys.argv[1]
payload = {"hookEventName": "PreToolUse", "tool_input": {"command": command}}
print(json.dumps(payload))
" "$COMMAND_TO_RUN")

# 2. Define the security hook pipeline
HOOKS_DIR="$PROJECT_ROOT/.claude/hooks"
if [ ! -d "$HOOKS_DIR" ]; then
    HOOKS_DIR="$PROJECT_ROOT/core/hooks" # Fallback to framework core
fi

HOOKS_TO_RUN=(
  "$HOOKS_DIR/pre-tool-guard.sh"
  "$HOOKS_DIR/context-mode-guard.sh"
  "$HOOKS_DIR/r4-mutex-check.sh"
  "$HOOKS_DIR/secret-content-scan.py"
  "$HOOKS_DIR/check-hardcoding.py"
)

for hook in "${HOOKS_TO_RUN[@]}"; do
  if [ -x "$hook" ]; then
    HOOK_OUTPUT=$(echo "$JSON_PAYLOAD" | "$hook" 2>/dev/null || true)
    
    if echo "$HOOK_OUTPUT" | grep -q ""permissionDecision":\s*"deny""; then
      REASON=$(echo "$HOOK_OUTPUT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get("hookSpecificOutput", {}).get("permissionDecisionReason", "Unknown reason"))
except Exception:
    print("Failed to parse hook reason.")
" 2>/dev/null || echo "Blocked by security hook.")
      
      echo -e "\n🛑 [HARNESS BLOCK] Command rejected by $(basename "$hook")"
      echo -e "Reason: $REASON\n"
      echo "AI Agent Action Required: Do NOT attempt to bypass this. Rethink your approach to comply with project rules."
      exit 1
    fi
  fi
done

# 3. If all hooks pass, execute the actual command
echo "🟢 [HARNESS] Security checks passed. Executing command..."
eval "$COMMAND_TO_RUN"
