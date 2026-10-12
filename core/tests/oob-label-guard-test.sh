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
  rm -rf "$WORK/$1"; mkdir -p "$WORK/$1/core/hooks"
  echo "$WORK/$1"
}

# src_case <name> <python source> <caught|clean> [guard-path]
src_case() {
  local name="$1" src="$2" want="$3" g="${4:-$GUARD}" root rc
  root=$(mkroot "$name")
  printf '%s\n' "$src" > "$root/core/hooks/fx.py"
  python3 "$g" --root "$root" >/dev/null 2>&1; rc=$?
  if [[ "$want" == caught && $rc -ne 0 ]] || [[ "$want" == clean && $rc -eq 0 ]]; then
    ok "$name" "want=$want"
  else
    bad "$name" "want=$want rc=$rc"
  fi
}
# py_case <name> <context-expr> <want> — the expression flows into a dict literal
py_case() {
  src_case "$1" "import json
msg = $2
print(json.dumps({\"hookSpecificOutput\": {\"additionalContext\": msg}}))" "$3"
}

echo
echo "=== B. label classes are caught (dict literal) ==="
py_case "holdout-word"      '"gate OFF for holdout arm"'                 caught
py_case "cohort-id"         '"session cohort 7"'                         caught
py_case "variant-id"        '"prompt variant B active"'                  caught
py_case "experiment-id"     '"experiment_id=42"'                         caught
py_case "arm-id"            '"arm id: control"'                          caught
py_case "arm-colon-value"   '"arm: control"'                             caught
py_case "guard-field"       '"fired guard=secrets"'                      caught
py_case "reproduce-field"   '"reproduce_test: true"'                     caught
py_case "via-fstring"       'f"count {1} cohort 7"'                      caught
py_case "via-concat"        '"a " + "variant" + " B"'                    caught
py_case "split-concat"      '"co" + "hort 7"'                            caught

echo
echo "=== B2. non-dict-literal emit forms (RV7) ==="
src_case "subscript-store" 'out = {"hookSpecificOutput": {}}
out["hookSpecificOutput"]["additionalContext"] = "holdout arm B"
print(out)' caught
src_case "keyword-arg"     'print(dict(additionalContext="variant B active"))' caught
src_case "json-string"     'print('"'"'{"hookSpecificOutput": {"additionalContext": "cohort 7"}}'"'"')' caught
src_case "computed-key"    'k = "additionalContext"
print({k: "cohort 7"})' caught

echo
echo "=== B3. text that arrives through a helper (codex) ==="
src_case "helper-arg-label" 'def emit(m):
    print({"additionalContext": m})
emit("cohort 7")' caught
src_case "helper-prefix-fstring" 'def emit(m):
    print({"additionalContext": f"tdd-guard: {m}"})
emit("variant B")' caught
src_case "helper-call-concat" 'def build():
    return "cohort 7"
print({"additionalContext": "x " + build()})' caught
src_case "helper-via-variable" 'def emit(m):
    print({"additionalContext": m})
def run():
    note = "arm: control"
    emit(note)
run()' caught
src_case "helper-arg-clean" 'def emit(m):
    print({"additionalContext": m})
emit("change your approach")' clean
src_case "helper-no-caller-unresolved" 'def emit(m):
    print({"additionalContext": m})' caught

echo
echo "=== C. ordinary guidance text is not a label ==="
py_case "plain-advice"      '"Circuit Breaker: change your approach."'   clean
py_case "guard-prose"       '"the pre-tool guard: blocked the read; fix and retry"' clean
py_case "tdd-prose"         '"tdd-guard: write the failing test first"'  clean
py_case "experiment-prose"  '"experiment with a different approach"'     clean
py_case "experimental-prose" '"this is an experimental flag"'            clean
py_case "variant-prose"     '"variant of the plan"'                      clean
py_case "arm-prose"         '"Note arm: left"'                           clean

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
echo "=== F. mutation probes — each guard property must be load-bearing ==="
gmutate() {  # gmutate <name> <find> <repl> -> mutant guard path or ""
  local out="$WORK/guard-mutant-$1.py"
  if FIND="$2" REPL="$3" SRC="$GUARD" DST="$out" python3 -c '
import os, sys
src = open(os.environ["SRC"], encoding="utf-8").read()
if os.environ["FIND"] not in src:
    sys.exit(1)
open(os.environ["DST"], "w", encoding="utf-8").write(src.replace(os.environ["FIND"], os.environ["REPL"], 1))
'; then echo "$out"; else echo ""; fi
}
# gprobe <name> <find> <repl> <fixture-name> <fixture-src> <want-under-REAL-guard>
gprobe() {
  local name="$1" m root rc
  m=$(gmutate "$name" "$2" "$3")
  if [[ -z "$m" ]]; then bad "mutation/$name-anchor" "anchor not found — probe is inert"; return; fi
  root=$(mkroot "mp-$name"); printf '%s\n' "$5" > "$root/core/hooks/fx.py"
  python3 "$m" --root "$root" >/dev/null 2>&1; rc=$?
  if [[ "$6" == caught && $rc -eq 0 ]] || [[ "$6" == clean && $rc -ne 0 ]]; then
    ok "mutation/$name" "mutant flips fixture $4"
  else
    bad "mutation/$name" "mutant still behaves like the guard on $4 (rc=$rc)"
  fi
}
gprobe keyword-detect 'isinstance(n, ast.keyword) and n.arg in KEYS' 'False' keyword-arg \
  'print(dict(additionalContext="variant B active"))' caught
gprobe json-detect 'return node, "json"          # the key is embedded in a longer string' 'return None, "doc"' json-string \
  'print('"'"'{"additionalContext": "cohort 7"}'"'"')' caught
gprobe caller-trace 'callers = self.calls.get(fn.name, [])' 'callers = []' helper-arg-clean \
  'def emit(m):
    print({"additionalContext": m})
emit("change your approach")' clean
gprobe concat-join 'return _cat([ls, rs]), lo + ro' 'return ls + rs, lo + ro' split-concat \
  'print({"additionalContext": "co" + "hort 7"})' caught

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
