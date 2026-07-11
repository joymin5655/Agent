#!/usr/bin/env bash
# plan-scope-allow-test.sh — verify core/hooks/plan-scope-allow.py auto-allow accelerator.
#
# Feeds canonical PreToolUse (Write/Edit/MultiEdit) event JSON on stdin and asserts:
#   allow   == permissionDecision "allow" (mode on + plan flag + in-workspace non-risk path)
#   silent  == empty stdout               (every other branch — the hook NEVER denies/asks;
#                                          pass-through leaves the native prompt + other hooks in charge)
#
# Polarity note: this is the harness's first permission-WEAKENING hook, so its fail-open
# direction is SILENCE (keep asking) — the opposite of the deny-gates' fail-open-allow.
#
# The hook hardcodes the shared /tmp/agent-plan-approved flag (reader coupled to
# plan-gate.py's writer, same contract as spec-gate.py), so the battery toggles the REAL
# path and save/restores any live session's flag. Workspace root is pinned via
# AGENT_PROJECT_DIR to the mktemp workdir; the sink is redirected via
# AGENT_PLAN_ALLOW_SINK so the repo stays clean.
#
# Usage: bash core/tests/plan-scope-allow-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/core/hooks/plan-scope-allow.py"

PASS=0
FAIL=0

WORK="$(mktemp -d)"
SINK="$WORK/plan-scope-allow.jsonl"
FLAG="/tmp/agent-plan-approved"

# Save any live session's real flag; restore on exit.
FLAG_BACKUP="$WORK/flag.bak"; HAD_FLAG=0
[[ -e "$FLAG" ]] && { cp "$FLAG" "$FLAG_BACKUP" && HAD_FLAG=1; }
cleanup() {
  rm -f "$FLAG"
  [[ "$HAD_FLAG" -eq 1 ]] && mv "$FLAG_BACKUP" "$FLAG"
  [[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK/src" "$WORK/.agent" "$WORK/.git"

# outside-the-workspace dir + a symlink inside pointing out (escape attempt)
OUTSIDE="$(mktemp -d)"
trap 'rm -rf "$OUTSIDE"; cleanup' EXIT
ln -s "$OUTSIDE" "$WORK/src/linkout"

# ---------------------------------------------------------------------------
# event builders + runner
# ---------------------------------------------------------------------------

# evt <tool_name> <file_path>
evt() { printf '{"event":"PreToolUse","tool_name":"%s","tool_input":{"file_path":"%s"},"cwd":"%s"}' "$1" "$2" "$WORK"; }

# run <mode: on|off|unset> <flag: present|absent> <json>  -> sets OUT, RC
run() {
  local mode="$1" flagstate="$2" json="$3"
  if [[ "$flagstate" == present ]]; then : > "$FLAG"; else rm -f "$FLAG"; fi
  if [[ "$mode" == unset ]]; then
    OUT="$(printf '%s' "$json" | ( cd "$WORK" && env -u AGENT_PLAN_ALLOW_MODE \
      AGENT_PROJECT_DIR="$WORK" \
      AGENT_PLAN_ALLOW_SINK="$SINK" \
      AGENT_SESSION_ID=test \
      python3 "$HOOK" ) 2>/dev/null)"
  else
    OUT="$(printf '%s' "$json" | ( cd "$WORK" && env \
      AGENT_PLAN_ALLOW_MODE="$mode" \
      AGENT_PROJECT_DIR="$WORK" \
      AGENT_PLAN_ALLOW_SINK="$SINK" \
      AGENT_SESSION_ID=test \
      python3 "$HOOK" ) 2>/dev/null)"
  fi
  RC=$?
}

classify() {
  if [[ "$OUT" == *'"permissionDecision": "allow"'* || "$OUT" == *'"permissionDecision":"allow"'* ]]; then
    GOT=allow
  elif [[ -z "$OUT" ]]; then
    GOT=silent
  else
    GOT=other
  fi
}

ok()  { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL [$1] $2"; FAIL=$((FAIL + 1)); }

# expect <name> <mode> <flagstate> <tool> <file_path> <allow|silent>
expect() {
  local name="$1" mode="$2" flagstate="$3" tool="$4" fp="$5" want="$6"
  run "$mode" "$flagstate" "$(evt "$tool" "$fp")"
  classify
  if [[ "$GOT" == "$want" && "$RC" -eq 0 ]]; then
    ok "$name (expected=$want)"
  else
    bad "$name" "expected=$want got=$GOT rc=$RC :: $OUT"
  fi
}

assert_rc_zero() { if [[ "$RC" -eq 0 ]]; then ok "$1"; else bad "$1" "expected exit 0, got $RC"; fi; }
assert_empty()   { if [[ -z "$OUT" ]]; then ok "$1"; else bad "$1" "expected empty stdout, got: $OUT"; fi; }
sink_lines()     { [[ -f "$SINK" ]] && wc -l < "$SINK" | tr -d ' ' || echo 0; }

# ---------------------------------------------------------------------------
# scenarios
# ---------------------------------------------------------------------------

echo "=== mode gating: default off, first weakening hook ships dark ==="
expect "a1-mode-off-silent"        off   present Write "$WORK/src/x.ts" silent
expect "a2-mode-unset-silent"      unset present Write "$WORK/src/x.ts" silent

echo
echo "=== flag gating: no approved plan, no acceleration ==="
expect "b1-noflag-silent"          on    absent  Write "$WORK/src/x.ts" silent

echo
echo "=== the allow path: mode on + flag + in-workspace non-risk ==="
expect "c1-write-allows"           on    present Write "$WORK/src/x.ts"      allow
expect "c2-edit-allows"            on    present Edit  "$WORK/src/y.py"      allow
expect "c3-multiedit-allows"       on    present MultiEdit "$WORK/src/z.tsx" allow
expect "c4-relative-inside-allows" on    present Write "src/rel.ts"          allow

echo
echo "=== NEVER-ALLOW screens: risk areas stay with their own guards + native prompt ==="
expect "d1-migration-silent"       on present Write "$WORK/migrations/m.sql"        silent
expect "d2-dotenv-silent"          on present Write "$WORK/.env"                    silent
expect "d3-dotenv-local-silent"    on present Write "$WORK/.env.local"              silent
expect "d4-secrets-silent"         on present Write "$WORK/secrets/k.json"          silent
expect "d5-function-silent"        on present Write "$WORK/functions/pay/index.ts"  silent
expect "d6-billing-silent"         on present Write "$WORK/billing/a.ts"            silent
expect "d7-uppercase-evasion"      on present Write "$WORK/SECRETS/k.json"          silent

echo
echo "=== self-tamper surfaces ==="
expect "e1-hook-config-silent"     on present Write "$WORK/.agent/hook-config.yml" silent
expect "e2-git-dir-silent"         on present Write "$WORK/.git/config"            silent

echo
echo "=== workspace containment (realpath) ==="
expect "f1-outside-abs-silent"     on present Write "$OUTSIDE/x.ts"          silent
expect "f2-symlink-escape-silent"  on present Write "$WORK/src/linkout/x.ts" silent
expect "f3-dotdot-escape-silent"   on present Write "$WORK/src/../../x.ts"   silent

echo
echo "=== fail-open direction is SILENCE ==="
run on present 'this is not json {['
assert_rc_zero "g1-malformed-stdin-rc0"
assert_empty   "g1-malformed-stdin-silent"
run on present '{"event":"PreToolUse","tool_name":"Write","tool_input":{}}'
assert_rc_zero "g2-missing-filepath-rc0"
assert_empty   "g2-missing-filepath-silent"
run on present '{"event":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
assert_rc_zero "g3-nonedit-tool-rc0"
assert_empty   "g3-nonedit-tool-silent"

echo
echo "=== telemetry: only real allows hit the sink ==="
rm -f "$SINK"
run on present "$(evt Write "$WORK/src/sinkcase.ts")"
if [[ "$(sink_lines)" == "1" ]]; then ok "h1-allow-writes-one-sink-line"; else bad "h1-allow-writes-one-sink-line" "sink lines=$(sink_lines)"; fi
run on present "$(evt Write "$WORK/migrations/m.sql")"
if [[ "$(sink_lines)" == "1" ]]; then ok "h2-passthrough-writes-none"; else bad "h2-passthrough-writes-none" "sink lines=$(sink_lines)"; fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
