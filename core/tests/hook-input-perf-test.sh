#!/usr/bin/env bash
# hook-input-perf-test.sh — AG22: big hook events must be handled in linear time.
#
# Two bash substitutions on a whole event were super-linear in a UTF-8 locale with multibyte text
# (bash 3.2 on macOS even for plain text):
#   - event_decode.sh   [[ -z "${INPUT//[[:space:]]/}" ]]      (every jq hook, r4-mutex-check runs for "*")
#   - pre-tool-guard.sh _CMD_FLAT=${COMMAND//$'\n'/ }           (every Bash command)
# A 64 KB Write took half a minute; a hook that outlives its timeout is cancelled and the call goes
# through undecided. This battery pins, per hook, that a large event finishes inside a generous cap
# (the linear code takes well under a second; the cap only has to separate that from tens of seconds),
# and that the two replacements (hook_input_is_blank, hook_flatten_lines) return exactly what the
# substitutions returned.
#
# Usage: bash core/tests/hook-input-perf-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOKS="$REPO_ROOT/core/hooks"
CAP="${HOOK_PERF_CAP_SECONDS:-12}"

PASS=0
FAIL=0
ok()  { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL [$1] $2"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap '[[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"' EXIT
export AGENT_GATE_SINK_DIR="$WORK/gate-sink"
export AGENT_PROJECT_DIR="$WORK/proj"
mkdir -p "$AGENT_PROJECT_DIR/.agent"
cat > "$AGENT_PROJECT_DIR/.agent/hook-config.yml" <<'YML'
risk_areas:
  secrets:
    paths:
      - 'vault/**'
    decision: deny
YML

# The slow path needs a UTF-8 locale; pick one that exists.
LOC=""
for cand in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
  if LC_ALL="$cand" bash -c ':' 2>/dev/null && [[ "$(LC_ALL="$cand" locale charmap 2>/dev/null)" == UTF-8 ]]; then LOC="$cand"; break; fi
done
[[ -n "$LOC" ]] || echo "  note: no UTF-8 locale installed; the multibyte slow path is not exercised"

# --- fixtures -------------------------------------------------------------------------------------------
python3 - "$WORK" <<'PY'
import json
import sys
work = sys.argv[1]
src = "".join("    값_%d = 함수(%d,  %d)  # 주석  입니다\n\tif  a  and  b:\n        pass\n" % (i, i, i)
              for i in range(1100))
heredoc = "\n".join("echo  줄 %d   공백   많음  한글" % i for i in range(3000))
# bash 5.x needs far more lines than bash 3.2 before the newline substitution hurts (bash 5.2: ~10 s at
# 10000 short lines, 1 s at 3000), so a second, line-dense heredoc keeps the guard case failing on 5.x.
dense = "\n".join("값 %d  끝" % i for i in range(15000))
events = {
    "bash-dense": {"tool_name": "Bash", "tool_input": {"command": "cat <<'EOF'\n" + dense + "\nEOF"}},
    "write": {"tool_name": "Write", "tool_input": {"file_path": "src/a.py", "content": src}},
    "ctx": {"tool_name": "mcp__context-mode__ctx_execute", "tool_input": {"code": src}},
    "bash-heredoc": {"tool_name": "Bash", "tool_input": {"command": "cat <<'EOF'\n" + heredoc + "\nEOF"}},
}
for name, ev in events.items():
    with open("%s/%s.json" % (work, name), "w", encoding="utf-8") as fh:
        fh.write(json.dumps(ev, ensure_ascii=False))
    print(name, len(json.dumps(ev, ensure_ascii=False).encode()), file=sys.stderr)
PY

# timed <name> <hook> <event-file> <expect: allow|deny|ask>
timed() {
  local name="$1" hook="$2" ev="$3" expect="$4" s e out rc got
  s=$(date +%s)
  out=$(LC_ALL="${LOC:-C}" timeout "$((CAP * 3))" bash "$hook" < "$ev" 2>/dev/null); rc=$?
  e=$(date +%s)
  case "$out" in
    *'"permissionDecision": "deny"'*) got=deny ;;
    *'"permissionDecision": "ask"'*)  got=ask ;;
    "") got=allow ;;
    *) got=other ;;
  esac
  if [[ $rc -eq 124 || $((e - s)) -gt $CAP ]]; then
    bad "$name" "took $((e - s))s (rc=$rc), cap ${CAP}s"
  elif [[ $rc -ne 0 || "$got" != "$expect" ]]; then
    bad "$name" "rc=$rc expected=$expect got=$got"
  else
    ok "$name $((e - s))s"
  fi
}

timed "perf/r4-mutex/write-64k"       "$HOOKS/r4-mutex-check.sh"       "$WORK/write.json"        allow
timed "perf/r4-file/write-64k"        "$HOOKS/r4-file-mutex-check.sh"  "$WORK/write.json"        allow
timed "perf/ctx-guard/write-64k"      "$HOOKS/context-mode-guard.sh"   "$WORK/ctx.json"          allow
timed "perf/guard/heredoc-3000-lines" "$HOOKS/pre-tool-guard.sh"       "$WORK/bash-heredoc.json" allow
timed "perf/guard/heredoc-15000-lines" "$HOOKS/pre-tool-guard.sh"      "$WORK/bash-dense.json"   allow

# --- equivalence of the two replacements with the substitutions they replace ---------------------------
# shellcheck source=../hooks/event_decode.sh
source "$HOOKS/event_decode.sh"
old_blank() { [[ -z "${1//[[:space:]]/}" ]]; }
old_flat() { local f=${1//\\$'\n'/}; printf '%s' "${f//$'\n'/ }"; }

declare -a CASES=(
  ''
  ' '
  $' \t\r\n '
  $'\n\n\n'
  'x'
  $' \n x \n'
  $'a\\\nb'
  $'a\\\\\nb'
  $'a\\\n\\\nb'
  $'a\r\nb\r\n'
  $'tab\there\tand\nnewline'
  $'python3 -c "\nopen(\'p\')\n"'
  '한글 공백  줄바꿈'
  $'한글\n둘째 줄\\\n이어짐'
  '😀 emoji'
  'sur \ud800 rogate'
  $'sur \\ud800\nrogate\\\n\\udfff'
  $'trailing newline\n'
  $'trailing backslash\\'
  $'\\\n'
)
for c in "${CASES[@]}"; do
  label=$(printf '%q' "$c")
  o=0; n=0
  old_blank "$c" && o=1
  hook_input_is_blank "$c" && n=1
  [[ $o -eq $n ]] && ok "equiv/blank $label" || bad "equiv/blank $label" "old=$o new=$n"
  o=$(old_flat "$c"; printf x); n=$(hook_flatten_lines "$c"; printf x)
  [[ "$o" == "$n" ]] && ok "equiv/flat $label" || bad "equiv/flat $label" "old=$(printf '%q' "${o%x}") new=$(printf '%q' "${n%x}")"
done

echo
echo "hook-input-perf-test: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
