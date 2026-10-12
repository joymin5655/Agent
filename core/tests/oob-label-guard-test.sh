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
  rm -rf "${WORK:?}/$1"; mkdir -p "$WORK/$1/core/hooks"
  echo "$WORK/$1"
}

# verdict <guard> <root> -> caught | clean | crash. "caught" needs a non-zero exit AND
# a LABEL/UNRESOLVED line: a guard that dies with a Traceback is never counted.
verdict() {
  local out rc
  out=$(python3 "$1" --root "$2" 2>&1); rc=$?
  if printf '%s' "$out" | grep -q Traceback; then echo crash
  elif [[ $rc -ne 0 ]] && printf '%s' "$out" | grep -qE '^(LABEL|UNRESOLVED) '; then echo caught
  elif [[ $rc -eq 0 ]]; then echo clean
  else echo crash; fi
}
# shell_case <name> <caught|clean> <script text on stdin>
shell_case() {
  local name="$1" want="$2" root got
  root=$(mkroot "$name"); cat > "$root/core/hooks/fx.sh"
  got=$(verdict "$GUARD" "$root")
  if [[ "$got" == "$want" ]]; then ok "$name" "want=$want"; else bad "$name" "want=$want got=$got"; fi
}

# src_case <name> <python source> <caught|clean> [guard-path] [output regex]
src_case() {
  local name="$1" src="$2" want="$3" g="${4:-$GUARD}" rx="${5:-}" root got
  root=$(mkroot "$name")
  printf '%s\n' "$src" > "$root/core/hooks/fx.py"
  got=$(verdict "$g" "$root")
  if [[ "$got" == "$want" ]] && { [[ -z "$rx" ]] || python3 "$g" --root "$root" 2>&1 | grep -qE "$rx"; }; then
    ok "$name" "want=$want${rx:+ /$rx/}"
  else
    bad "$name" "want=$want got=$got${rx:+ (needs /$rx/)}"
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
echo "=== B8. numeric constants and format specs (r3) ==="
src_case "int-format"      'print({"additionalContext": "cohort {}".format(7)})' caught "" '^LABEL'
src_case "int-fstring"     'print({"additionalContext": f"cohort {7}"})' caught "" '^LABEL'
src_case "int-percent"     'print({"additionalContext": "variant %d" % 3})' caught "" '^LABEL'
src_case "int-via-name"    'N = 7
print({"additionalContext": "cohort {}".format(N)})' caught "" '^LABEL'
src_case "int-spec"        'print({"additionalContext": "cohort {:02}".format(7)})' caught "" '^LABEL'
src_case "spec-truncation" 'print({"additionalContext": "arm {:.1}".format("Bclean")})' caught
src_case "percent-precision" 'print({"additionalContext": "arm %.1s" % "Bclean"})' caught
src_case "int-count-clean" 'print({"additionalContext": "found {} files".format(7)})' clean
src_case "int-fstring-clean" 'print({"additionalContext": f"retry {3} times"})' clean

echo
echo "=== B9. record fields reaching the context by other routes (r3) ==="
src_case "dict-subscript-dumps" 'import json
rec = {}
rec["guard"] = "x"
print({"additionalContext": json.dumps(rec)})' caught
src_case "dict-str" 'rec = {}
rec["guard"] = "x"
print({"additionalContext": str(rec)})' caught
src_case "dict-repr-literal" 'print({"additionalContext": repr({"guard": "x"})})' caught
src_case "dict-fstring" 'rec = {"gate_id": "g1"}
print({"additionalContext": f"state {rec}"})' caught
src_case "dumps-twice" 'import json
print({"additionalContext": json.dumps(json.dumps({"guard": "x"}))})' caught
src_case "percent-dict-var" 'ctx = {"v": "B"}
print({"additionalContext": "variant %(v)s" % ctx})' caught
src_case "format-star-star" 'ctx = {"v": "B"}
print({"additionalContext": "variant {v}".format(**ctx)})' caught
src_case "dumps-unresolved-value" 'import json
print({"additionalContext": json.dumps({"x": get()})})' caught
src_case "dumps-numeric-clean" 'import json, sys
print({"additionalContext": json.dumps({"n": len(sys.argv)})})' clean
src_case "circular-dict" 'import json
d = {"a": 1}
d["a"] = d
print({"additionalContext": json.dumps(d)})' caught

echo
echo "=== B10. no silent truncation, no silent aliasing (r3) ==="
src_case "template-expansion" 'import sys
a = "x" if sys.argv else ("y" if sys.argv else "cohort 7")
b = "1" if sys.argv else ("2" if sys.argv else ("3" if sys.argv else ("4" if sys.argv else ("5" if sys.argv else ("6" if sys.argv else ("7" if sys.argv else "8"))))))
print({"additionalContext": "{} {} {}".format(a, b, b)})' caught
src_case "compress-keeps-early-hit" 'import sys
a = "cohort 7 ................................................................"
b = "1" if sys.argv else "2"
msg = a + b + b + b + b + b + b + b
print({"additionalContext": msg})' caught
src_case "state-explosion" 'import sys
b = "a" if sys.argv else "b"
msg = b + b + b + b + b + b + b + b + b + b + b + b + b
print({"additionalContext": msg})' caught
src_case "alias-shadows-safe-module" 'from labels import LBL as os
print({"additionalContext": f"advice: {os.x}"})' caught
src_case "stdlib-interp-clean" 'import os
print({"additionalContext": f"advice: {os.getcwd()}"})' clean

echo
echo "=== B11. label word followed by a runtime value (r4) ==="
src_case "runtime-arm-assign" 'from exp import compute_arm
arm = compute_arm("s")
print({"additionalContext": f"arm={arm}"})' caught "" '^UNRESOLVED .*runtime value'
src_case "runtime-variant-local-fn" 'def pick():
    return input()
v = pick()
print({"additionalContext": f"variant: {v}"})' caught "" '^UNRESOLVED .*runtime value'
src_case "runtime-bucket-format" 'from exp import arm_of
print({"additionalContext": "bucket: {}".format(arm_of(1))})' caught "" '^UNRESOLVED .*runtime value'
src_case "runtime-arm-environ" 'import os
print({"additionalContext": "arm: {}".format(os.environ["ARM"])})' caught "" '^UNRESOLVED .*runtime value'
src_case "runtime-cohort-call" 'from exp import assign_cohort
print({"additionalContext": f"cohort {assign_cohort(1)}"})' caught "" '^UNRESOLVED .*runtime value'
src_case "runtime-cohort-percent" 'from exp import g
print({"additionalContext": "cohort %s" % g()})' caught "" '^UNRESOLVED .*runtime value'
src_case "runtime-guard-field" 'from exp import g
print({"additionalContext": f"guard={g()}"})' caught "" '^UNRESOLVED .*runtime value'
src_case "runtime-count-clean" 'import sys
n = len(sys.argv)
print({"additionalContext": f"{n} files changed; run tests"})' clean
src_case "runtime-cwd-clean" 'import os
p = os.getcwd()
print({"additionalContext": f"cwd: {p}"})' clean
src_case "runtime-after-prose-clean" 'import os
p = os.getcwd()
print({"additionalContext": f"retry the command in {p}"})' clean

echo
echo "=== B12. shell function bodies (r4) ==="
shell_case "shell-function-keyword" caught <<'SH'
#!/usr/bin/env bash
function build {
  echo "session cohort 7"
}
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shell_case "shell-function-keyword-parens" caught <<'SH'
#!/usr/bin/env bash
function build() {
  echo "session cohort 7"
}
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shell_case "shell-heredoc-brace" caught <<'SH'
#!/usr/bin/env bash
build() {
  cat <<EOF
}
EOF
  echo "holdout arm B"
}
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shell_case "shell-escaped-brace" caught <<'SH'
#!/usr/bin/env bash
build() {
  echo \}
  echo "session cohort 7"
}
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shell_case "shell-quoted-brace" caught <<'SH'
#!/usr/bin/env bash
build() {
  echo "}"
  echo "session cohort 7"
}
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shell_case "shell-heredoc-clean" clean <<'SH'
#!/usr/bin/env bash
build() {
  cat <<'EOF'
}
change your approach
EOF
}
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH

echo
echo "=== B13. remaining artificial forms (r4) ==="
src_case "nested-format-spec" 'print({"additionalContext": "cohort {:{}} x".format(7, 5)})' caught
src_case "format-index-field" 'print({"additionalContext": "cohort {0[1]}".format(("x", 7))})' caught
src_case "format-attr-field" 'print({"additionalContext": "cohort {0.real}".format(7)})' caught
src_case "string-multiply-template" 'print({"additionalContext": ("{} " * 2).format("a", "cohort 7")})' caught
src_case "dict-update-kwarg" 'import json
rec = {}
rec.update(guard="x")
print({"additionalContext": json.dumps(rec)})' caught
src_case "dict-update-dict" 'import json
rec = {}
rec.update({"guard": "x"})
print({"additionalContext": json.dumps(rec)})' caught
src_case "dict-setdefault" 'import json
rec = {}
rec.setdefault("guard", "x")
print({"additionalContext": json.dumps(rec)})' caught

echo
echo "=== B14. cost: a huge template stops at the first state explosion (r4) ==="
FIELDS=$(python3 -c 'print(", ".join(["a"] * 60))')
BIGSRC="import sys
a = \"p\" if sys.argv else (\"q\" if sys.argv else (\"r\" if sys.argv else (\"s\" if sys.argv else (\"t\" if sys.argv else (\"u\" if sys.argv else (\"v\" if sys.argv else \"w\"))))))
print({\"additionalContext\": (\"{}.\" * 60).format($FIELDS)})"
T0=$(python3 -c 'import time; print(time.time())')
src_case "huge-template-unresolved" "$BIGSRC" caught "" '^UNRESOLVED .*distinct tails'
T1=$(python3 -c 'import time; print(time.time())')
if python3 -c "import sys; sys.exit(0 if $T1 - $T0 < 3.0 else 1)"; then ok "huge-template-fast" "$(python3 -c "print(round($T1 - $T0, 2))")s"; else bad "huge-template-fast" "$(python3 -c "print(round($T1 - $T0, 2))")s (>=3s)"; fi

echo
echo "=== B15. separators between a label word and a runtime value (r5) ==="
# form_case <name> <python expression using {x}> <caught|clean>
form_case() {
  src_case "$1" "from exp import g
x = g()
print({\"additionalContext\": $2})" "$3" "" "${4:-}"
}
i=0
while IFS= read -r expr; do
  i=$((i + 1)); form_case "sep-form-$i" "$expr" caught '^UNRESOLVED .*runtime value'
done <<'FORMS'
f'arm=[{x}]'
f"arm='{x}'"
f'arm="{x}"'
f'cohort #{x}'
f'variant ({x})'
f'arm=<{x}>'
f'arm=`{x}`'
f'cohort.{x}'
f'variant/{x}'
f'arm=-{x}'
f'variant "{x}"'
FORMS
i=0
while IFS= read -r expr; do
  i=$((i + 1)); form_case "sep-clean-$i" "$expr" clean
done <<'FORMS'
f'alarm={x}'
f'farm: {x}'
f'charm {x}'
f'armed={x}'
f'variant of {x}'
f'cohort of {x}'
f'arm64 build: {x}'
f'experiment with {x}'
f'variants: {x}'
f'buckets {x}'
FORMS

echo
echo "=== B16. shell function whose opening brace is on the next line (r5) ==="
shell_case "shell-brace-next-line-parens" caught <<'SH'
#!/usr/bin/env bash
build()
{
  echo "holdout arm"
}
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shell_case "shell-brace-next-line-keyword" caught <<'SH'
#!/usr/bin/env bash
function build

{
  echo "holdout arm"
}
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shell_case "shell-brace-next-line-clean" clean <<'SH'
#!/usr/bin/env bash
build()
{
  echo "change your approach"
}
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH

echo
echo "=== B17. shell: a later look-alike must not hide a real definition (r6) ==="
shell_case "shell-heredoc-def-same-line" caught <<'SH'
#!/usr/bin/env bash
build() {
  echo "holdout arm"
}
cat <<EOF >/dev/null
build() {}
EOF
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shell_case "shell-heredoc-def-next-line" caught <<'SH'
#!/usr/bin/env bash
build() {
  echo "holdout arm"
}
cat <<EOF >/dev/null
build()
{}
EOF
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shell_case "shell-heredoc-def-json" caught <<'SH'
#!/usr/bin/env bash
build() {
  echo "holdout arm"
}
cat <<EOF >/dev/null
build()
{ "a": 1 }
EOF
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shell_case "shell-redefined-function" caught <<'SH'
#!/usr/bin/env bash
build() {
  echo "holdout arm"
}
build() {
  echo "all good"
}
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH

echo
echo "=== B18. shell: function bodies that are not a { } group (r6) ==="
shell_case "shell-subshell-body-same-line" caught <<'SH'
#!/usr/bin/env bash
build() (
  echo "holdout arm"
)
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shell_case "shell-subshell-body-next-line" caught <<'SH'
#!/usr/bin/env bash
build()
(
  echo "holdout arm"
)
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shell_case "shell-if-body" caught <<'SH'
#!/usr/bin/env bash
build()
if true; then echo "holdout arm"; fi
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shell_case "shell-unused-subshell-function-clean" clean <<'SH'
#!/usr/bin/env bash
unrelated() (
  echo "holdout arm"
)
CTX="all good"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH

echo
echo "=== C2. vocabulary regressions (word boundary) ==="
py_case "identity-prose"    '"experiment identity check failed"'        clean
py_case "bucket-names-prose" '"bucket names must be lowercase"'          clean

echo
echo "=== D. systemMessage key + shell hook ==="
root=$(mkroot sysmsg)
printf 'import json\nprint(json.dumps({"systemMessage": "holdout arm B"}))\n' > "$root/core/hooks/fx.py"
[[ $(verdict "$GUARD" "$root") == caught ]] && ok "systemMessage-caught" "LABEL line" || bad "systemMessage-caught" "not caught"

root=$(mkroot shbad)
cat > "$root/core/hooks/fx.sh" <<'SH'
#!/usr/bin/env bash
CTX_PARTS+=("session cohort 3")
CTX="$(printf '%s\n' "${CTX_PARTS[@]}")"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
[[ $(verdict "$GUARD" "$root") == caught ]] && ok "shell-hook-caught" "LABEL line" || bad "shell-hook-caught" "not caught"

root=$(mkroot shgood)
cat > "$root/core/hooks/fx.sh" <<'SH'
#!/usr/bin/env bash
CTX_PARTS+=("2 active sessions in this repo")
CTX="$(printf '%s\n' "${CTX_PARTS[@]}")"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
[[ $(verdict "$GUARD" "$root") == clean ]] && ok "shell-hook-clean" "rc=0" || bad "shell-hook-clean" "false positive"

root=$(mkroot shfn)
cat > "$root/core/hooks/fx.sh" <<'SH'
#!/usr/bin/env bash
build() { echo "session cohort 7"; }
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
[[ $(verdict "$GUARD" "$root") == caught ]] && ok "shell-function-followed" "LABEL line" || bad "shell-function-followed" "not caught"

root=$(mkroot shfn2)
cat > "$root/core/hooks/fx.sh" <<'SH'
#!/usr/bin/env bash
build() { local h="${HOME}"
  echo "session cohort 7"
}
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
[[ $(verdict "$GUARD" "$root") == caught ]] && ok "shell-multiline-function" "LABEL line" || bad "shell-multiline-function" "not caught"
root=$(mkroot shfn3)
cat > "$root/core/hooks/fx.sh" <<'SH'
#!/usr/bin/env bash
build() {
  echo "all good"
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
[[ $(verdict "$GUARD" "$root") == caught ]] && ok "shell-unterminated-function" "UNRESOLVED line" || bad "shell-unterminated-function" "passed"

echo
echo "=== E. a site with unresolvable text fails (no silent blindness) ==="
root=$(mkroot blind)
printf 'import json, sys\nprint(json.dumps({"additionalContext": sys.argv[1]}))\n' > "$root/core/hooks/fx.py"
[[ $(verdict "$GUARD" "$root") == caught ]] && ok "unresolved-fails" "UNRESOLVED line" || bad "unresolved-fails" "passed blind"

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
  local name="$1" m root got
  m=$(gmutate "$name" "$2" "$3")
  if [[ -z "$m" ]]; then bad "mutation/$name-anchor" "anchor not found — probe is inert"; return; fi
  root=$(mkroot "mp-$name"); printf '%s\n' "$5" > "$root/core/hooks/fx.py"
  got=$(verdict "$m" "$root")
  # 7th arg: output the REAL guard gives; the mutant must stop giving it
  if [[ -n "${7:-}" ]] && ! python3 "$m" --root "$root" 2>&1 | grep -qE "$7"; then got=flipped; fi
  if [[ "$got" == flipped ]] || [[ "$6" == caught && "$got" == clean ]] || [[ "$6" == clean && "$got" == caught ]]; then
    ok "mutation/$name" "mutant flips fixture $4"
  else
    bad "mutation/$name" "mutant still behaves like the guard on $4 (got=$got)"
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
gprobe compress-hits 'return ("\n".join(hits) + "\n" if hits else "") + text[-TAIL:]' 'return text[-TAIL:]' compress-keeps-early-hit \
  'import sys
a = "cohort 7 ................................................................"
b = "1" if sys.argv else "2"
msg = a + b + b + b + b + b + b + b
print({"additionalContext": msg})' caught
gprobe hard-cap 'opq.append("combinatorial expansion beyond %d distinct tails" % HARD_CAP)' 'pass' state-explosion \
  'import sys
b = "a" if sys.argv else "b"
msg = b + b + b + b + b + b + b + b + b + b + b + b + b
print({"additionalContext": msg})' caught
gprobe number-const 'if isinstance(node.value, (int, float)) and not isinstance(node.value, bool):' 'if False:' int-fstring \
  'print({"additionalContext": f"cohort {7}"})' caught '^LABEL'
gprobe format-spec '_apply_spec(val, spec) for val in vals' 'val for val in vals' spec-truncation \
  'print({"additionalContext": "arm {:.1}".format("Bclean")})' caught
gprobe dict-subscript-sets 'pairs += self.dict_sets.get((name, id(fn)), []) + self.dict_sets.get((name, id(None)), [])' 'pass' dict-subscript-dumps \
  'import json
rec = {}
rec["guard"] = "x"
print({"additionalContext": json.dumps(rec)})' caught
gprobe quoted-key-field '_Q = r"""(?:\\?["'"'"'])"""' '_Q = r"""(?:")"""' dumps-twice \
  'import json
print({"additionalContext": json.dumps(json.dumps({"guard": "x"}))})' caught
gprobe render-opaque 'return [quote(x) for x in s] or ["0"], op' 'return [quote(x) for x in s] or ["0"], []' dumps-unresolved-value \
  'import json
print({"additionalContext": json.dumps({"x": get()})})' caught
gprobe import-origin 'and self.imported[base.id] not in SAFE_MODULES' 'and base.id not in SAFE_MODULES' alias-shadows-safe-module \
  'from labels import LBL as os
print({"additionalContext": f"advice: {os.x}"})' caught
# --- r4 probes
shprobe() {  # shprobe <name> <find> <repl> <caught|clean>  (fixture script on stdin)
  local name="$1" m root got
  m=$(gmutate "$name" "$2" "$3")
  if [[ -z "$m" ]]; then bad "mutation/$name-anchor" "anchor not found — probe is inert"; cat >/dev/null; return; fi
  root=$(mkroot "mp-$name"); cat > "$root/core/hooks/fx.sh"
  [[ $(verdict "$GUARD" "$root") == "$4" ]] || bad "mutation/$name-fixture" "fixture is not '$4' under the real guard"
  got=$(verdict "$m" "$root")
  if [[ "$4" == caught && "$got" == clean ]] || [[ "$4" == clean && "$got" == caught ]]; then
    ok "mutation/$name" "mutant flips the shell fixture"
  else
    bad "mutation/$name" "mutant behaves like the guard (got=$got)"
  fi
}
gprobe sentinel-fstring 's = s + [SENT]        # a value the guard cannot see' 'pass' runtime-arm-assign \
  'from exp import compute_arm
arm = compute_arm("s")
print({"additionalContext": f"arm={arm}"})' caught '^UNRESOLVED .*runtime value'
gprobe sentinel-template 'return s + [SENT] if (not s or o) else s' 'return s or [""]' runtime-bucket-format \
  'from exp import arm_of
print({"additionalContext": "bucket: {}".format(arm_of(1))})' caught '^UNRESOLVED .*runtime value'
gprobe runtime-hit-report 'if rt:' 'if False:' runtime-cohort-call \
  'from exp import assign_cohort
print({"additionalContext": f"cohort {assign_cohort(1)}"})' caught '^UNRESOLVED .*runtime value'
gprobe string-multiply 'if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Mult):' 'if False:' string-multiply-template \
  'print({"additionalContext": ("{} " * 2).format("a", "cohort 7")})' caught
gprobe dict-update 'if f.attr == "update":' 'if False:' dict-update-kwarg \
  'import json
rec = {}
rec.update(guard="x")
print({"additionalContext": json.dumps(rec)})' caught
gprobe dict-setdefault 'elif f.attr == "setdefault" and len(n.args) >= 2:' 'elif False:' dict-setdefault \
  'import json
rec = {}
rec.setdefault("guard", "x")
print({"additionalContext": json.dumps(rec)})' caught
gprobe format-nested-spec '(?::((?:[^{}]|\{[^{}]*\})*))?' '(?::([^{}]*))?' nested-format-spec \
  'print({"additionalContext": "cohort {:{}} x".format(7, 5)})' caught
gprobe format-accessors '((?:\.\w+|\[[^\]]*\])*)' '()' format-index-field \
  'print({"additionalContext": "cohort {0[1]}".format(("x", 7))})' caught
shprobe shell-function-keyword 'name = m.group(1) or m.group(2)' 'name = m.group(2) or "-"' caught <<'SH'
#!/usr/bin/env bash
function build {
  echo "session cohort 7"
}
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shprobe shell-heredoc 'if tag is not None:' 'if False:' caught <<'SH'
#!/usr/bin/env bash
build() {
  cat <<EOF
}
EOF
  echo "holdout arm B"
}
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shprobe shell-escaped-brace '# \{ \} are literal' '# \{ \} are literal
    t = line' caught <<'SH'
#!/usr/bin/env bash
build() {
  echo \}
  echo "session cohort 7"
}
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shprobe shell-quoted-brace '# quoted text' '# quoted text
    t = line' caught <<'SH'
#!/usr/bin/env bash
build() {
  echo "}"
  echo "session cohort 7"
}
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
# cost: without the early exit the huge template runs for many seconds
m=$(gmutate cat-early-exit 'return list(itertools.islice(nxt, HARD_CAP))     # stop at the first overflow' 'pass')
if [[ -z "$m" ]]; then bad "mutation/cat-early-exit-anchor" "anchor not found — probe is inert"; else
  root=$(mkroot mp-cat-early-exit); printf '%s\n' "$BIGSRC" > "$root/core/hooks/fx.py"
  if python3 -c "
import subprocess, sys
try:
    subprocess.run([sys.executable, '$m', '--root', '$root'], capture_output=True, timeout=3)
except subprocess.TimeoutExpired:
    sys.exit(0)
sys.exit(1)"; then ok "mutation/cat-early-exit" "mutant exceeds 3s on the huge template"; else bad "mutation/cat-early-exit" "mutant is still fast"; fi
fi
# r5 probes
gprobe separator-class '# separator class' '# separator class
_SEP = r"[\s=:]*"' sep-form-1 \
  'from exp import g
x = g()
print({"additionalContext": f"arm=[{x}]"})' caught '^UNRESOLVED .*runtime value'
shprobe shell-brace-next-line 'def _next_line(code, i):' 'def _next_line(code, i):
    return None' clean <<'SH'
#!/usr/bin/env bash
build()
{
  echo "change your approach"
}
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
# r6 probes
shprobe shell-heredoc-skip-outer 'if outer_tag is not None:' 'if False:' clean <<'SH'
#!/usr/bin/env bash
build() {
  echo "change your approach"
}
cat <<EOF >/dev/null
build()
echo look-alike text
EOF
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shprobe shell-merge-redefinition 'funcs[name] = (old_body + body, old_ok and ok)' 'funcs[name] = (body, ok)' caught <<'SH'
#!/usr/bin/env bash
build() {
  echo "holdout arm"
}
build() {
  echo "all good"
}
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shprobe shell-unfollowable-body 'body, ok = [], False' 'body, ok = [], True' caught <<'SH'
#!/usr/bin/env bash
build() (
  echo "holdout arm"
)
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
# shell function following
m=$(gmutate shell-fn 'strs += funcs[f][0]' 'pass')
if [[ -z "$m" ]]; then bad "mutation/shell-fn-anchor" "anchor not found — probe is inert"; else
  root=$(mkroot mp-shell-fn)
  printf '%s\n' '#!/usr/bin/env bash' 'build() { echo "session cohort 7"; }' 'CTX="$(build)"' \
    "jq -nc --arg ctx \"\$CTX\" '{hookSpecificOutput: {additionalContext: \$ctx}}'" > "$root/core/hooks/fx.sh"
  [[ $(verdict "$m" "$root") == clean ]] && ok "mutation/shell-fn" "mutant misses the function body" || bad "mutation/shell-fn" "mutant still caught it"
fi
# brace counting: a clean multi-line function with an unquoted ${...} must stay clean
m=$(gmutate shell-brace 'depth += _braces(nxt)' 'depth += 0')
if [[ -z "$m" ]]; then bad "mutation/shell-brace-anchor" "anchor not found — probe is inert"; else
  root=$(mkroot mp-shell-brace)
  printf '%s\n' '#!/usr/bin/env bash' 'build() { h=${HOME}' '  echo "all good"' '}' 'CTX="$(build)"' \
    "jq -nc --arg ctx \"\$CTX\" '{hookSpecificOutput: {additionalContext: \$ctx}}'" > "$root/core/hooks/fx.sh"
  [[ $(verdict "$GUARD" "$root") == clean ]] || bad "mutation/shell-brace-fixture" "clean fixture not clean under the real guard"
  [[ $(verdict "$m" "$root") == caught ]] && ok "mutation/shell-brace" "mutant leaves the function unterminated" || bad "mutation/shell-brace" "mutant still clean"
fi
# timing: the guard must stay cheap (it runs in every battery)
T0=$(python3 -c 'import time; print(time.time())')
python3 "$GUARD" --root "$REPO_ROOT" >/dev/null 2>&1
T1=$(python3 -c 'import time; print(time.time())')
if python3 -c "import sys; sys.exit(0 if $T1 - $T0 < 1.0 else 1)"; then ok "guard-under-1s" "$(python3 -c "print(round($T1 - $T0, 2))")s"; else bad "guard-under-1s" "slow"; fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
