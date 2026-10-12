#!/usr/bin/env bash
# oob-label-guard-test.sh — X-2 guard: no measurement label in model-visible hook text.
#
# Principle (docs/hook-protocol.md § Out-of-band labels): experiment / holdout /
# cohort / variant ids and sink-aggregation fields live in the jsonl sink, never in
# `additionalContext` / `systemMessage`. This runs core/tests/oob-label-guard.py over
# the shipped core/hooks and over fixtures. The fixtures keep the guard from being
# green-by-blindness: each label class must be CAUGHT in a bad hook, and a clean hook
# with ordinary guidance text must pass.
#
# Usage: bash core/tests/oob-label-guard-test.sh   (exit 0 = all pass)
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="$REPO_ROOT/core/tests/oob-label-guard.py"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/oob-label-guard-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()  { echo "  ok   [$1] $2"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL [$1] $2"; FAIL=$((FAIL + 1)); }

echo "=== A. shipped core/hooks ==="
OUT=$(python3 "$GUARD" --root "$REPO_ROOT" 2>&1); RC=$?
if [[ $RC -eq 0 ]]; then ok "shipped-hooks-clean" "$(printf '%s' "$OUT" | tail -1)"; else bad "shipped-hooks-clean" "$OUT"; fi
SITES=$(printf '%s' "$OUT" | sed -n 's/^sites=\([0-9]*\).*/\1/p')
if [[ "${SITES:-0}" -ge 8 ]]; then ok "guard-sees-sites" "sites=$SITES"; else bad "guard-sees-sites" "sites=${SITES:-0} (<8: resolver is blind)"; fi

mkroot() {  # mkroot <name> -> fixture root with core/hooks/
  mkdir -p "$WORK/$1/core/hooks"
  echo "$WORK/$1"
}

# py_case <name> <context-expr> <want: caught|clean>
py_case() {
  local name="$1" expr="$2" want="$3" root rc
  root=$(mkroot "$name")
  printf 'import json\nmsg = %s\nprint(json.dumps({"hookSpecificOutput": {"additionalContext": msg}}))\n' \
    "$expr" > "$root/core/hooks/fx.py"
  python3 "$GUARD" --root "$root" >/dev/null 2>&1; rc=$?
  if [[ "$want" == caught && $rc -ne 0 ]] || [[ "$want" == clean && $rc -eq 0 ]]; then
    ok "$name" "want=$want"
  else
    bad "$name" "want=$want rc=$rc"
  fi
}

echo
echo "=== B. label classes are caught (python) ==="
py_case "holdout-word"      '"gate OFF for holdout arm"'                 caught
py_case "cohort-word"       '"session cohort 7"'                         caught
py_case "variant-word"      '"prompt variant B active"'                  caught
py_case "experiment-id"     '"experiment_id=42"'                         caught
py_case "arm-id"            '"arm id: control"'                          caught
py_case "guard-field"       '"fired guard=secrets"'                      caught
py_case "reproduce-field"   '"reproduce_test: true"'                     caught
py_case "via-fstring"       'f"count {1} cohort"'                        caught
py_case "via-concat"        '"a " + "variant" + " b"'                    caught

echo
echo "=== C. ordinary guidance text is not a label ==="
py_case "plain-advice"      '"Circuit Breaker: change your approach."'   clean
py_case "guard-prose"       '"the guard rejected this write; fix and retry"' clean
py_case "tdd-prose"         '"tdd-guard: write the failing test first"'  clean

echo
echo "=== D. systemMessage key + shell hook ==="
root=$(mkroot sysmsg)
printf 'import json\nprint(json.dumps({"systemMessage": "holdout arm B"}))\n' > "$root/core/hooks/fx.py"
python3 "$GUARD" --root "$root" >/dev/null 2>&1 && bad "systemMessage-caught" "not caught" || ok "systemMessage-caught" "rc!=0"

root=$(mkroot shbad)
cat > "$root/core/hooks/fx.sh" <<'SH'
#!/usr/bin/env bash
CTX_PARTS+=("session cohort 3")
CTX="$(printf '%s\n' "${CTX_PARTS[@]}")"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
python3 "$GUARD" --root "$root" >/dev/null 2>&1 && bad "shell-hook-caught" "not caught" || ok "shell-hook-caught" "rc!=0"

root=$(mkroot shgood)
cat > "$root/core/hooks/fx.sh" <<'SH'
#!/usr/bin/env bash
CTX_PARTS+=("2 active sessions in this repo")
CTX="$(printf '%s\n' "${CTX_PARTS[@]}")"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
python3 "$GUARD" --root "$root" >/dev/null 2>&1 && ok "shell-hook-clean" "rc=0" || bad "shell-hook-clean" "false positive"

echo
echo "=== E. a site with unresolvable text fails (no silent blindness) ==="
root=$(mkroot blind)
printf 'import json, sys\nprint(json.dumps({"additionalContext": sys.argv[1]}))\n' > "$root/core/hooks/fx.py"
python3 "$GUARD" --root "$root" >/dev/null 2>&1 && bad "unresolved-fails" "passed blind" || ok "unresolved-fails" "rc!=0"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
