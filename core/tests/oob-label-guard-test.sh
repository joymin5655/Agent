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
# kind_case <name> <python source> <regex the guard output must match>
# Asserts WHICH branch caught it (LABEL line with the site kind), so removing a
# branch cannot be masked by the generic UNRESOLVED failure.
kind_case() {
  local name="$1" src="$2" rx="$3" root out
  root=$(mkroot "$name")
  printf '%s\n' "$src" > "$root/core/hooks/fx.py"
  out=$(python3 "$GUARD" --root "$root" 2>&1)
  if printf '%s' "$out" | grep -qE "$rx"; then ok "$name" "matched $rx"; else bad "$name" "out=$out"; fi
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
echo "=== B4. which branch caught it (RV7 G) ==="
kind_case "subscript-store-kind" 'out = {"hookSpecificOutput": {}}
out["hookSpecificOutput"]["additionalContext"] = "holdout arm B"' '^LABEL .*\(subscript\)'
kind_case "json-string-kind" 'print('"'"'{"hookSpecificOutput": {"additionalContext": "cohort 7"}}'"'"')' '^LABEL .*\(json\)'
kind_case "keyword-kind" 'print(dict(additionalContext="variant B active"))' '^LABEL .*\(keyword\)'
src_case "annassign-store" 'out = {}
out["additionalContext"]: str = "cohort 7"' caught

echo
echo "=== B5. templates and serialised records are checked as the text they produce ==="
src_case "format-const" 'print({"additionalContext": "cohort {}".format("B")})' caught
src_case "format-via-name" 'C = "B"
print({"additionalContext": "cohort {}".format(C)})' caught
src_case "format-kwarg" 'print({"additionalContext": "arm {x}".format(x="B")})' caught
src_case "percent-format" 'print({"additionalContext": "variant %s" % "B"})' caught
src_case "percent-named" 'print({"additionalContext": "arm %(x)s" % {"x": "B"}})' caught
src_case "json-dumps-dict" 'import json
print({"additionalContext": json.dumps({"guard": "x"})})' caught
src_case "json-dumps-in-fstring" 'import json
print({"additionalContext": f"note {json.dumps({'"'"'gate_id'"'"': '"'"'g1'"'"'})}"})' caught
src_case "join-const-list" 'print({"additionalContext": "".join(["cohort ", "7"])})' caught
src_case "unparseable-hook-fails" 'def broken(:' caught
src_case "format-clean" 'print({"additionalContext": "advice {}".format("x")})' clean
src_case "dumps-clean" 'import json
print({"additionalContext": json.dumps({"hint": "retry"})})' clean

echo
echo "=== B6. caller tracing cannot be bypassed ==="
src_case "param-default" 'def emit(m="cohort 7"):
    print({"additionalContext": m})
emit()' caught
src_case "param-default-clean" 'def emit(m="try again"):
    print({"additionalContext": m})
emit()' clean
src_case "star-star-call" 'def emit(text):
    print({"additionalContext": text})
emit(**{"text": "cohort B"})' caught
src_case "star-args-call" 'def emit(text):
    print({"additionalContext": text})
args = ["cohort B"]
emit(*args)' caught
src_case "same-name-methods" 'class A:
    def build(self):
        return "clean"
class B:
    def build(self):
        return "cohort 7"
print({"additionalContext": B().build()})' caught
src_case "other-object-emit-ignored" 'import logging
def emit(m):
    print({"additionalContext": m})
emit("change your approach")
logging.getLogger().emit("cohort 7")' clean
src_case "method-ambiguous-receiver" 'class A:
    def emit(self, m):
        print({"additionalContext": m})
def go(obj):
    obj.emit("cohort 7")' caught

echo
echo "=== B7. forms the docstring claims to cover ==="
src_case "computed-concat-key" 'print({"additional" + "Context": "cohort 7"})' caught
src_case "computed-concat-key-subscript" 'o = {}
o["additional" + "Context"] = "cohort 7"' caught
src_case "imported-const-interpolated" 'from labels import LBL
print({"additionalContext": f"advice: {LBL}"})' caught
src_case "runtime-local-interpolated-clean" 'import sys
n = len(sys.argv)
print({"additionalContext": f"advice: {n} items"})' clean
src_case "combo-truncation" 'import sys
a = "x" if sys.argv else "cohort 7"
b = "1" if sys.argv else "2"
msg = a + b + b + b + b + b + b + b
print({"additionalContext": msg})' caught
src_case "min-max-text" 'print({"additionalContext": min("cohort 7", "zzz")})' caught

echo
echo "=== C2. vocabulary regressions (word boundary) ==="
py_case "identity-prose"    '"experiment identity check failed"'        clean
py_case "bucket-names-prose" '"bucket names must be lowercase"'          clean

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

root=$(mkroot shfn)
cat > "$root/core/hooks/fx.sh" <<'SH'
#!/usr/bin/env bash
build() { echo "session cohort 7"; }
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
python3 "$GUARD" --root "$root" >/dev/null 2>&1 && bad "shell-function-followed" "not caught" || ok "shell-function-followed" "rc!=0"

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
gprobe caller-trace 'for c in self.calls.get(fn.name, []):' 'for c in []:' helper-arg-clean \
  'def emit(m):
    print({"additionalContext": m})
emit("change your approach")' clean
gprobe concat-join 'return self.cat([ls, rs], op), op' 'return ls + rs, op' split-concat \
  'print({"additionalContext": "co" + "hort 7"})' caught
gprobe percent-template 'if isinstance(node.op, ast.Mod) and ls:' 'if False:' percent-format \
  'print({"additionalContext": "variant %s" % "B"})' caught
gprobe dumps-render 'if name == "dumps" and node.args:' 'if False:' dumps-clean \
  'import json
print({"additionalContext": json.dumps({"hint": "retry"})})' clean
gprobe param-default 'arg = self.default_of(fn, name)' 'arg = None' param-default \
  'def emit(m="cohort 7"):
    print({"additionalContext": m})
emit()' caught
gprobe star-unpack 'opq.append("%s() called with */** unpacking" % fn.name)' 'pass' star-star-call \
  'def emit(text):
    print({"additionalContext": text})
emit(**{"text": "cohort B"})' caught
gprobe imported-interp 'op.append("imported name %s interpolated" % base.id)' 'pass' imported-const \
  'from labels import LBL
print({"additionalContext": f"advice: {LBL}"})' caught
gprobe computed-key 'elif isinstance(n, ast.Dict):' 'elif False:' computed-concat-key \
  'print({"additional" + "Context": "cohort 7"})' caught
gprobe annassign 'ast.Assign, ast.AugAssign, ast.AnnAssign)):
        asg = parents.get(id(asg))' 'ast.Assign, ast.AugAssign)):
        asg = parents.get(id(asg))' annassign-store \
  'out = {}
out["additionalContext"]: str = "cohort 7"' caught
gprobe tail-compress 'nxt = dict.fromkeys(_compress(x) for x in nxt)' 'nxt = dict(itertools.islice(nxt.items(), MAX_COMBOS))' combo-truncation \
  'import sys
a = "x" if sys.argv else "cohort 7"
b = "1" if sys.argv else "2"
msg = a + b + b + b + b + b + b + b
print({"additionalContext": msg})' caught
# shell function following
m=$(gmutate shell-fn 'strs += funcs[f]' 'pass')
if [[ -z "$m" ]]; then bad "mutation/shell-fn-anchor" "anchor not found — probe is inert"; else
  root=$(mkroot mp-shell-fn)
  printf '%s\n' '#!/usr/bin/env bash' 'build() { echo "session cohort 7"; }' 'CTX="$(build)"' \
    "jq -nc --arg ctx \"\$CTX\" '{hookSpecificOutput: {additionalContext: \$ctx}}'" > "$root/core/hooks/fx.sh"
  python3 "$m" --root "$root" >/dev/null 2>&1 && ok "mutation/shell-fn" "mutant misses the function body" || bad "mutation/shell-fn" "mutant still caught it"
fi
# timing: the guard must stay cheap (it runs in every battery)
T0=$(python3 -c 'import time; print(time.time())')
python3 "$GUARD" --root "$REPO_ROOT" >/dev/null 2>&1
T1=$(python3 -c 'import time; print(time.time())')
if python3 -c "import sys; sys.exit(0 if $T1 - $T0 < 1.0 else 1)"; then ok "guard-under-1s" "$(python3 -c "print(round($T1 - $T0, 2))")s"; else bad "guard-under-1s" "slow"; fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
