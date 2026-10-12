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

# shell_rx_case <name> <caught|clean> <regex the guard output must match> <script on stdin>
shell_rx_case() {
  local name="$1" want="$2" rx="$3" root got
  root=$(mkroot "$name"); cat > "$root/core/hooks/fx.sh"
  got=$(verdict "$GUARD" "$root")
  if [[ "$got" == "$want" ]] && python3 "$GUARD" --root "$root" 2>&1 | grep -qE "$rx"; then
    ok "$name" "want=$want /$rx/"
  else
    bad "$name" "want=$want /$rx/ got=$got"
  fi
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
echo "=== B19. a << that is not a heredoc must not hide later definitions (r7) ==="
# shell_lt_case <name> <line placed before the real definition>
shell_lt_case() {
  local pre="$2"
  shell_case "$1" caught <<SH
#!/usr/bin/env bash
$pre
build() { echo "holdout arm"; }
CTX="\$(build)"
jq -nc --arg ctx "\$CTX" '{hookSpecificOutput: {additionalContext: \$ctx}}'
SH
}
shell_lt_case "shell-arith-shift-spaced"  'n=$((1 << 2))'
shell_lt_case "shell-arith-shift-tight"   'n=$((1<<2))'
shell_lt_case "shell-let-shift"           "let 'n = 1 << 3'"
shell_lt_case "shell-quoted-heredoc-text" 'echo "usage: cat <<EOF"'
shell_lt_case "shell-single-quoted-marker" "msg='see <<END marker'"
shell_lt_case "shell-unterminated-heredoc" 'cat <<EOF'
shell_case "shell-real-heredoc-then-def" caught <<'SH'
#!/usr/bin/env bash
cat <<EOF >/dev/null
just text
EOF
build() { echo "holdout arm"; }
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH

echo
echo "=== B20. label noun + runtime value stays UNRESOLVED in prose, paths and URLs (AG18 r1) ==="
# Accepted false positives: the guard is a fail-closed CI tripwire. A label can ride in a
# sentence, a path, a file name or a URL ("cohort_{x}.csv" -> cohort_treatment.csv), so none
# of these is proven clean. Remedy: reword so the noun and the value are apart
# (f"{x} is full"); never ALLOW (it blinds the whole function).
i=0
while IFS= read -r expr; do
  i=$((i + 1)); form_case "prose-caught-$i" "$expr" caught '^UNRESOLVED .*runtime value'
done <<'FORMS'
f'bucket {x} is full'
f'left arm {x}'
f'Experiment {x} finished'
f'use variant {x}'
f'the bucket {x}'
f'cohort {x} ready'
f'session cohort {x}'
f'user variant {x}'
f'assigned arm {x}'
f'your bucket {x}'
f'this experiment {x}'
f'cohort {x} selected'
f'variant "{x}" selected'
f'variant ({x}) active'
f'arm=/{x}'
f'arm=={x}'
f'arm=[ {x}]'
f'done.arm={x}'
f'arm_{x}.v2'
f'arm.{x}'
f'(bucket {x})'
FORMS
i=0
while IFS= read -r expr; do
  i=$((i + 1)); form_case "label-still-caught-$i" "$expr" caught '^UNRESOLVED .*runtime value'
done <<'FORMS'
f'cohort {x}'
f'arm {x}.'
f'note: arm {x}'
f'done. Variant {x}'
f'arm id {x}'
f'bucket name {x} is set'
f'cohort_{x}'
f'variant-{x}'
f'?variant={x}'
f'--arm={x}'
f'experiment: {x} is next'
f'cohort {x}, ok'
FORMS

echo
echo "=== B21. paths, URLs and markdown around a label word (AG18 r1: accepted false positives) ==="
i=0
while IFS= read -r expr; do
  i=$((i + 1)); form_case "path-caught-$i" "$expr" caught '^UNRESOLVED .*runtime value'
done <<'FORMS'
f'docs/arm/{x}'
f'see docs/variant/{x}.md'
f'[variant]({x})'
f'/arm/{x}/file'
f'https://x.test/variant/{x}'
f'cohort_{x}.csv'
f'arm/{x}/file'
f'/tmp/arm/{x}'
FORMS

echo
echo "=== B22. shell: a call line inside a heredoc is not a function definition (AG18 A3) ==="
shell_case "shell-heredoc-call-lines-clean" clean <<'SH'
#!/usr/bin/env bash
python3 - <<'PY'
def run():
    pass
flush()
end()
self.end()
note_mention()
PY
MSG="please end the session and flush the cache, then note_mention"
jq -nc --arg ctx "$MSG" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shell_case "shell-heredoc-call-then-real-def" caught <<'SH'
#!/usr/bin/env bash
python3 - <<'PY'
flush()
PY
flush() { echo "holdout arm"; }
CTX="$(flush)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shell_case "shell-for-body-still-unfollowable" caught <<'SH'
#!/usr/bin/env bash
build()
for x in a; do echo "holdout arm"; done
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shell_case "shell-while-body-still-unfollowable" caught <<'SH'
#!/usr/bin/env bash
build() while true; do echo "holdout arm"; break; done
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shell_case "shell-test-body-still-unfollowable" caught <<'SH'
#!/usr/bin/env bash
build()
[[ -n "$HOME" ]]
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH

echo
echo "=== B23. shell: names with :: and . are definitions too (AG18 A4) ==="
shell_case "shell-ns-colon-def" caught <<'SH'
#!/usr/bin/env bash
lib::build() { echo "holdout arm"; }
CTX="$(lib::build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shell_case "shell-dotted-def" caught <<'SH'
#!/usr/bin/env bash
pkg.build() {
  echo "holdout arm"
}
CTX="$(pkg.build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shell_case "shell-ns-keyword-def" caught <<'SH'
#!/usr/bin/env bash
function lib::build {
  echo "holdout arm"
}
CTX="$(lib::build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shell_case "shell-ns-subshell-def-unresolved" caught <<'SH'
#!/usr/bin/env bash
lib::build() (
  echo "holdout arm"
)
CTX="$(lib::build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shell_case "shell-ns-def-clean" clean <<'SH'
#!/usr/bin/env bash
lib::build() { echo "change your approach"; }
CTX="$(lib::build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH

echo
echo "=== B24. shell: a trailing comment after name() does not hide the { body (AG18 A5) ==="
shell_case "shell-comment-tail-clean" clean <<'SH'
#!/usr/bin/env bash
build() # builds the text
{
  echo "change your approach"
}
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shell_rx_case "shell-comment-tail-label" caught '^LABEL ' <<'SH'
#!/usr/bin/env bash
build() # builds the text
{
  echo "holdout arm"
}
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shell_rx_case "shell-comment-tail-same-line-label" caught '^LABEL ' <<'SH'
#!/usr/bin/env bash
build() { # builds the text
  echo "holdout arm # not a comment"
}
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH

echo
echo "=== B25. cost: a combinatorial shape stops at a global budget (AG18 A6, r1: message-based) ==="
# cost_case <name> <expected UNRESOLVED message regex> <python snippet that prints the hook source>
# The verdict is the message, not the clock: a slow machine cannot fake or hide it. The 5 s
# ceiling only catches a runaway.
cost_case() {
  local name="$1" rx="$2" root out rc t0 t1
  root=$(mkroot "$name")
  python3 -c "
def alt(i, n):
    e = \"'z'\"
    for j in range(n - 1):
        e = \"('v%d_%d' if s else %s)\" % (i, j, e)
    return e
$3" > "$root/core/hooks/fx.py"
  t0=$(python3 -c 'import time; print(time.time())')
  out=$(python3 "$GUARD" --root "$root" 2>&1); rc=$?
  t1=$(python3 -c 'import time; print(time.time())')
  if [[ $rc -ne 0 ]] && printf '%s' "$out" | grep -qE "^UNRESOLVED .*($rx)" && ! printf '%s' "$out" | grep -q Traceback \
     && python3 -c "import sys; sys.exit(0 if $t1 - $t0 < 5.0 else 1)"; then
    ok "$name" "/$rx/ in $(python3 -c "print(round($t1 - $t0, 2))")s"
  else
    bad "$name" "rc=$rc $(python3 -c "print(round($t1 - $t0, 2))")s (want /$rx/, <5s): $(printf '%s' "$out" | tail -1 | cut -c1-120)"
  fi
}
cost_case "cost-binop-40" 'distinct tails' "print('import sys\ns = sys.argv\nprint({\"additionalContext\": %s})' % ' + '.join(alt(i, 3) for i in range(40)))"
cost_case "cost-binop-300" 'distinct tails' "print('import sys\ns = sys.argv\nprint({\"additionalContext\": %s})' % ' + '.join(alt(i, 2) for i in range(300)))"
cost_case "cost-dict-60x8" 'distinct tails' "print('import sys, json\ns = sys.argv\nd = {%s}\nprint({\"additionalContext\": json.dumps(d)})' % ', '.join('\"k%d\": %s' % (i, alt(i, 8)) for i in range(60)))"
cost_case "cost-names-50x8" 'work budget exceeded' "print('import sys\ns = sys.argv\n%s\nprint({\"additionalContext\": %s})' % ('\n'.join('n%d = %s' % (i, alt(i, 8)) for i in range(50)), ' + '.join('n%d' % i for i in range(50))))"
cost_case "cost-name-doubling" 'work budget exceeded' "print('n0 = \"a\"\n%s\nprint({\"additionalContext\": n21})' % '\n'.join('n%d = n%d + n%d' % (i, i - 1, i - 1) for i in range(1, 22)))"

echo
echo "=== B26. shell: a backslash-continued definition is still a definition (AG18 r1) ==="
# main reported all of these UNRESOLVED; dropping the definition made them clean (fail-open).
shell_case "shell-cont-parens" caught <<'SH'
#!/usr/bin/env bash
build() \
{
  echo "holdout arm"
}
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shell_case "shell-cont-keyword" caught <<'SH'
#!/usr/bin/env bash
function build \
{
  echo "holdout arm"
}
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shell_case "shell-cont-keyword-parens" caught <<'SH'
#!/usr/bin/env bash
function build() \
{
  echo "holdout arm"
}
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
printf '%s\n' '#!/usr/bin/env bash' 'build()'$'\t''\' '{' '  echo "holdout arm"' '}' 'CTX="$(build)"' \
  "jq -nc --arg ctx \"\$CTX\" '{hookSpecificOutput: {additionalContext: \$ctx}}'" | shell_case "shell-cont-tab" caught
shell_case "shell-cont-twice" caught <<'SH'
#!/usr/bin/env bash
build() \
\
{
  echo "holdout arm"
}
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shell_case "shell-cont-comment-line" caught <<'SH'
#!/usr/bin/env bash
build() \
# c
{
  echo "holdout arm"
}
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shell_case "shell-cont-subshell" caught <<'SH'
#!/usr/bin/env bash
build() \
(
  echo "holdout arm"
)
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shell_case "shell-cont-clean" clean <<'SH'
#!/usr/bin/env bash
build() \
{
  echo "change your approach"
}
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shell_case "shell-cont-even-backslashes-not-joined" caught <<'SH'
#!/usr/bin/env bash
echo a \\
build() { echo "holdout arm"; }
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
printf '%s\n' '#!/usr/bin/env bash' 'CTX="$(build)"' \
  "jq -nc --arg ctx \"\$CTX\" '{hookSpecificOutput: {additionalContext: \$ctx}}'" 'build() \' | shell_case "shell-cont-dangling-eof" caught
shell_case "shell-paren-space-def" caught <<'SH'
#!/usr/bin/env bash
build ( ) {
  echo "holdout arm"
}
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH

echo
echo "=== B27. computed keys: giving up on one must not blind the next (AG18 r1) ==="
# gen_case <name> <want> <regex> <python snippet printing the source>
gen_case() {
  local name="$1" want="$2" rx="$3" root got
  root=$(mkroot "$name")
  python3 -c "
def alt(i, n):
    e = \"'z'\"
    for j in range(n - 1):
        e = \"('v%d_%d' if s else %s)\" % (i, j, e)
    return e
$4" > "$root/core/hooks/fx.py"
  got=$(verdict "$GUARD" "$root")
  if [[ "$got" == "$want" ]] && python3 "$GUARD" --root "$root" 2>&1 | grep -qE "$rx"; then
    ok "$name" "want=$want /$rx/"
  else
    bad "$name" "want=$want got=$got (needs /$rx/)"
  fi
}
JUNK="' + '.join(alt(i, 3) for i in range(40))"
gen_case "key-dict-after-junk-finds-site" caught '^UNRESOLVED .*runtime value' \
  "print('import sys\ns = sys.argv\njunk = {%s: 1}\nprint({\"additional\" + \"Context\": f\"arm={sys.argv[1]}\"})' % ($JUNK))"
gen_case "key-dict-junk-is-unresolved" caught '^UNRESOLVED .*computed key' \
  "print('import sys\ns = sys.argv\njunk = {%s: 1}\nprint({\"additional\" + \"Context\": \"all good\"})' % ($JUNK))"
gen_case "key-subscript-after-junk-finds-site" caught '^UNRESOLVED .*runtime value' \
  "print('import sys\ns = sys.argv\nd = {}\nd[%s] = 1\nd[\"additional\" + \"Context\"] = f\"arm={sys.argv[1]}\"' % ($JUNK))"
gen_case "key-subscript-junk-is-unresolved" caught '^UNRESOLVED .*computed key' \
  "print('import sys\ns = sys.argv\nd = {}\nd[%s] = 1\nd[\"additional\" + \"Context\"] = \"all good\"' % ($JUNK))"
src_case "key-runtime-stays-exempt" 'import os
d = {}
d[os.environ["K"]] = 1
print({"additionalContext": "all good"})' clean

echo
echo "=== B29. shell: a backslash-newline inside single quotes stays literal (AG18 r2) ==="
# Bash keeps `\`+newline inside '...' and inside a quoted heredoc; joining it would glue
# `holdout\` + `arm` into `holdoutarm` and hide the label. The physical lines are checked too.
shell_rx_case "shell-sq-continuation-label" caught '^LABEL ' <<'SH'
#!/usr/bin/env bash
CTX='holdout\
arm'
jq -n --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shell_rx_case "shell-quoted-heredoc-continuation-label" caught '^LABEL ' <<'SH'
#!/usr/bin/env bash
build() {
  cat <<'EOF'
holdout\
arm
EOF
}
CTX="$(build)"
jq -n --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shell_rx_case "shell-def-line-continuation-physical-label" caught '^LABEL ' <<'SH'
#!/usr/bin/env bash
build() \
{ echo 'holdout\
arm'; }
CTX="$(build)"
jq -n --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shell_rx_case "shell-dq-continuation-label" caught '^LABEL ' <<'SH'
#!/usr/bin/env bash
CTX="hold\
out"
jq -n --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shell_case "shell-sq-continuation-clean" clean <<'SH'
#!/usr/bin/env bash
CTX='change your\
approach'
jq -n --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH

echo
echo "=== B30. computed keys: setdefault, dict(pairs), and keys with an unfollowable piece (AG18 r2) ==="
src_case "key-setdefault-computed" 'd = {}
d.setdefault("additional" + "Context", "holdout arm")
print(d)' caught "" '^LABEL '
src_case "key-setdefault-computed-runtime" 'import sys
d = {}
d.setdefault("additional" + "Context", f"arm={sys.argv[1]}")
print(d)' caught "" '^UNRESOLVED .*runtime value'
src_case "key-dict-pairs-list" 'd = dict([("additional" + "Context", "holdout arm")])
print(d)' caught "" '^LABEL '
src_case "key-dict-pairs-tuple" 'd = dict((("additional" + "Context", "holdout arm"),))
print(d)' caught "" '^LABEL '
src_case "key-setdefault-runtime-clean" 'import os
d = {}
d.setdefault(os.environ["K"], "all good")
print({"additionalContext": "all good"})' clean
src_case "key-dict-pairs-runtime-clean" 'import os
d = dict([(os.environ["K"], "all good")])
print({"additionalContext": "all good"})' clean
CHAIN=$(python3 -c '
print("a0 = \"additional\"")
for i in range(1, 46):
    print("a%d = a%d" % (i, i - 1))
print("print({f\"{a45}Context\": \"all good\"})")')
src_case "key-fstring-alias-chain" "$CHAIN" caught "" '^UNRESOLVED .*computed key'
src_case "key-fstring-prefix-runtime" 'import os
print({f"additional{os.environ[chr(75)]}": "all good"})' caught "" '^UNRESOLVED .*computed key'
src_case "key-fstring-suffix-runtime" 'import os
print({f"{os.environ[chr(75)]}Context": "all good"})' caught "" '^UNRESOLVED .*computed key'
src_case "key-fstring-unrelated-clean" 'import os
print({f"k{os.environ[chr(75)]}": "all good", "additionalContext": "all good"})' clean
src_case "key-fstring-pure-runtime-clean" 'import os
print({f"{os.environ[chr(75)]}": "all good"})' clean

echo
echo "=== B31. one file cannot cost keys x WORK_CAP: a file-wide budget (AG18 r2) ==="
gen_case "file-budget-many-keys" caught 'work budget exceeded for the whole file' \
  "print('import sys\ns = sys.argv\n' + '\n'.join('junk%d = {%s: 1}' % (k, ' + '.join(alt(i, 3) for i in range(40))) for k in range(60)) + '\nprint({\"additionalContext\": \"all good\"})')"

echo
echo "=== B28. the test file itself stays portable (BSD sed has no bare in-place flag) (AG18 r1) ==="
if grep -nE 'se[d] -i' "$0" >/dev/null; then bad "no-gnu-sed-i" "$(grep -nE 'se[d] -i' "$0" | head -3 | tr '\n' ' ')"; else ok "no-gnu-sed-i" "no in-place sed in this file"; fi

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
root=$(mkroot mp-huge); printf '%s\n' "$BIGSRC" > "$root/core/hooks/fx.py"
# gcap <file> <value> — set WORK_CAP in a mutant (python: BSD sed has no bare in-place flag)
gcap() {
  python3 - "$1" "$2" <<'PY'
import re, sys
p, v = sys.argv[1], sys.argv[2]
t = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(re.sub(r"(?m)^WORK_CAP = .*$", "WORK_CAP = " + v, t, count=1))
PY
}
# tprobe <name> <find> <repl> <fixture-root> <message regex> [cap] [extra-find extra-repl]
# A mutant that stops enforcing a cost limit either runs past 5 s or no longer says what the
# real guard says. The message is the deterministic signal; the clock only catches a runaway.
tprobe() {
  local name="$1" m root flipped
  m=$(gmutate "$name" "$2" "$3")
  if [[ -z "$m" ]]; then bad "mutation/$name-anchor" "anchor not found — probe is inert"; return; fi
  [[ -n "${6:-}" ]] && gcap "$m" "$6"
  if [[ -n "${7:-}" ]]; then
    python3 - "$m" "$7" "${8:-}" <<'PY' || { bad "mutation/$name-anchor" "extra anchor not found — probe is inert"; return; }
import sys
p, a, b = sys.argv[1:4]
t = open(p, encoding="utf-8").read()
if a not in t:
    sys.exit(1)
open(p, "w", encoding="utf-8").write(t.replace(a, b, 1))
PY
  fi
  root="$4"
  python3 "$GUARD" --root "$root" 2>&1 | grep -qE "^UNRESOLVED .*($5)" || { bad "mutation/$name-fixture" "real guard does not say /$5/"; return; }
  flipped=$(python3 - "$m" "$root" "$5" <<'PY'
import re, subprocess, sys
m, root, rx = sys.argv[1:4]
try:
    r = subprocess.run([sys.executable, m, "--root", root], capture_output=True, text=True, timeout=5)
except subprocess.TimeoutExpired:
    print("timeout"); sys.exit(0)
print("silent" if not re.search("(?m)^UNRESOLVED .*(" + rx + ")", r.stdout + r.stderr) else "same")
PY
)
  if [[ "$flipped" == timeout || "$flipped" == silent ]]; then ok "mutation/$name" "mutant: $flipped"; else bad "mutation/$name" "mutant still says /$5/ within 5s"; fi
}
# cost: without the early exit (and without the budget masking it) the huge template runs for many seconds
tprobe cat-early-exit 'return list(itertools.islice(nxt, HARD_CAP))     # stop at the first overflow' 'pass' "$WORK/mp-huge" 'distinct tails' '10**12'
# r5 probes
gprobe separator-class '# separator class' '# separator class
_SEP = r"[\s=:]*"' sep-form-1 \
  'from exp import g
x = g()
print({"additionalContext": f"arm=[{x}]"})' caught '^UNRESOLVED .*runtime value'
shprobe shell-brace-next-line 'def _next_line(code, i):' 'def _next_line(code, i):
    return None' caught <<'SH'
#!/usr/bin/env bash
build()
{
  echo "holdout arm"
}
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
# r6 probes
# restoring a heredoc skip at definition level swallows everything after `$((1<<2))`
shprobe shell-outer-heredoc-skip '        m = _SH_FUNC.match(ln)' '        if globals().get("_T") is not None:
            if ln.strip() == globals()["_T"]:
                globals()["_T"] = None
            continue
        _hd = _HEREDOC.search(ln)
        if _hd:
            globals()["_T"] = _hd.group(2)
        m = _SH_FUNC.match(ln)' caught <<'SH'
#!/usr/bin/env bash
n=$((1<<2))
build() { echo "holdout arm"; }
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
# replacing (instead of merging) lets a heredoc look-alike hide the real definition
shprobe shell-replace-redefinition 'funcs[name] = (old_body + body + head_phys, old_ok and ok)' 'funcs[name] = (body, ok)' caught <<'SH'
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
shprobe shell-merge-redefinition 'funcs[name] = (old_body + body + head_phys, old_ok and ok)' 'funcs[name] = (body, ok)' caught <<'SH'
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
# AG18 probes — each condition of the r8 fixes must be load-bearing
# r1: the r0 narrowing of _RUNTIME must not come back — each piece alone flips a fixture
gprobe r0-trailing-end '    + SENT + r"|(?<![\w-])(?:guard' '    + SENT + r"(?![ \t]+\w)|(?<![\w-])(?:guard' prose-selected \
  'from exp import g
x = g()
print({"additionalContext": f"cohort {x} selected"})' caught '^UNRESOLVED .*runtime value'
gprobe r0-path-neighbour 'r"(?i)\b(?:experiment|cohort|variant|arm|bucket)[ _-]?(?:id|name|label|group)?" + _SEP' 'r"(?i)(?<![\w/.])\b(?:experiment|cohort|variant|arm|bucket)[ _-]?(?:id|name|label|group)?" + _SEP' path-neighbour \
  'from exp import g
x = g()
print({"additionalContext": f"done.arm={x}"})' caught '^UNRESOLVED .*runtime value'
gprobe r0-clause-start 'r"(?i)\b(?:experiment|cohort|variant|arm|bucket)[ _-]?(?:id|name|label|group)?" + _SEP' 'r"(?i)(?<![A-Za-z] )\b(?:experiment|cohort|variant|arm|bucket)[ _-]?(?:id|name|label|group)?" + _SEP' prose-session \
  'from exp import g
x = g()
print({"additionalContext": f"session cohort {x}"})' caught '^UNRESOLVED .*runtime value'
shprobe shell-call-line-not-def 'if nl is None or not _SH_BODY.match(code[nl][1].strip()):' 'if nl is None:' clean <<'SH'
#!/usr/bin/env bash
python3 - <<'PY'
flush()
end()
PY
MSG="please end the session and flush the cache"
jq -nc --arg ctx "$MSG" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shprobe shell-same-line-not-def 'elif not _SH_BODY.match(tail) and not unsure:' 'elif False:' clean <<'SH'
#!/usr/bin/env bash
python3 - <<'PY'
flush() : pass
PY
MSG="please flush the cache"
jq -nc --arg ctx "$MSG" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shprobe shell-name-class '_SH_NAME = r"[A-Za-z_][\w:.-]*"' '_SH_NAME = r"[A-Za-z_][\w-]*"' caught <<'SH'
#!/usr/bin/env bash
lib::build() { echo "holdout arm"; }
CTX="$(lib::build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shprobe shell-name-dot '_SH_NAME = r"[A-Za-z_][\w:.-]*"' '_SH_NAME = r"[A-Za-z_][\w:-]*"' caught <<'SH'
#!/usr/bin/env bash
pkg.build() { echo "holdout arm"; }
CTX="$(pkg.build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shprobe shell-comment-tail 'if tail.startswith("#"):' 'if False:' caught <<'SH'
#!/usr/bin/env bash
build() # builds the text
{
  echo "holdout arm"
}
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
# the global budget: the node-visit check and the join check each bound a different shape
tprobe work-budget-visit 'if self.spend(1):' 'if False:' "$WORK/cost-name-doubling" 'work budget exceeded'
# the join and the compress charge are one mechanism (either alone is backed up by the other)
tprobe work-budget-cat 'if self.spend(len(cur) * len(part)):' 'if False:' "$WORK/cost-names-50x8" 'work budget exceeded' "" 'if self.spend(4 * len(nxt)):' 'if False:'
tprobe work-budget-message 'work budget exceeded (%d steps)' 'gave up (%d steps)' "$WORK/cost-name-doubling" 'work budget exceeded'
# r1: computed keys — a fresh budget per probe, and "gave up" becomes a site
gprobe key-probe-reset '        rs.work = 0
        strs, opq = rs.resolve(node' '        strs, opq = rs.resolve(node' key-dict-after-junk \
  "$(python3 -c "
def alt(i, n):
    e = \"'z'\"
    for j in range(n - 1):
        e = \"('v%d_%d' if s else %s)\" % (i, j, e)
    return e
print('import sys\ns = sys.argv\njunk = {%s: 1}\nprint({\"additional\" + \"Context\": f\"arm={sys.argv[1]}\"})' % ' + '.join(alt(i, 3) for i in range(40)))")" caught '^UNRESOLVED .*runtime value'
gprobe key-gave-up-site '        elif gave_up:
            sites.append((lineno, "key"' '        elif False:
            sites.append((lineno, "key"' key-dict-junk \
  "$(python3 -c "
def alt(i, n):
    e = \"'z'\"
    for j in range(n - 1):
        e = \"('v%d_%d' if s else %s)\" % (i, j, e)
    return e
print('import sys\ns = sys.argv\njunk = {%s: 1}\nprint({\"additional\" + \"Context\": \"all good\"})' % ' + '.join(alt(i, 3) for i in range(40)))")" caught '^UNRESOLVED .*computed key'
gprobe key-gave-up-subscript '        elif gave_up:
            sites.append((lineno, "key"' '        elif False:
            sites.append((lineno, "key"' key-subscript-junk \
  "$(python3 -c "
def alt(i, n):
    e = \"'z'\"
    for j in range(n - 1):
        e = \"('v%d_%d' if s else %s)\" % (i, j, e)
    return e
print('import sys\ns = sys.argv\nd = {}\nd[%s] = 1\nd[\"additional\" + \"Context\"] = \"all good\"' % ' + '.join(alt(i, 3) for i in range(40)))")" caught '^UNRESOLVED .*computed key'
# r1: backslash continuation and definitions that look like `build ( )`
shprobe shell-cont-join 'def _logical_lines(lines):' 'def _logical_lines(lines):
    return [(i + 1, ln) for i, ln in enumerate(lines)]' clean <<'SH'
#!/usr/bin/env bash
build() \
{
  echo "change your approach"
}
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shprobe shell-cont-parity 'len(m.group(1)) % 2 == 0' 'len(m.group(1)) % 2 == 2' caught <<'SH'
#!/usr/bin/env bash
echo a \\
build() { echo "holdout arm"; }
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shprobe shell-cont-comment 'commentish = text.lstrip().startswith("#") or re.search(r"\s#", text)' 'commentish = False' clean <<'SH'
#!/usr/bin/env bash
build() \
# c \
{
  echo "change your approach"
}
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shprobe shell-cont-unsure 'unsure = isinstance(ln, _Joined) or tail == "\\"' 'unsure = False' caught <<'SH'
#!/usr/bin/env bash
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
build() \
SH
shprobe shell-paren-space 'r")\s*\(\s*\))\s*(.*)$")' 'r")\s*\(\))\s*(.*)$")' caught <<'SH'
#!/usr/bin/env bash
build ( ) {
  echo "holdout arm"
}
CTX="$(build)"
jq -nc --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
# r2 probes: the lines as written, more computed-key forms, the file-wide budget
shprobe shell-physical-sq 'strs = [x for t in strs for x in [t] + _phys(t)]    # and the lines as written' 'pass' caught <<'SH'
#!/usr/bin/env bash
CTX='holdout\
arm'
jq -n --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shprobe shell-physical-heredoc 'strs = [x for t in strs for x in [t] + _phys(t)]    # and the lines as written' 'pass' caught <<'SH'
#!/usr/bin/env bash
build() {
  cat <<'EOF'
holdout\
arm
EOF
}
CTX="$(build)"
jq -n --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
shprobe shell-physical-def-line '(old_body + body + head_phys, old_ok and ok)' '(old_body + body, old_ok and ok)' caught <<'SH'
#!/usr/bin/env bash
build() \
{ echo 'holdout\
arm'; }
CTX="$(build)"
jq -n --arg ctx "$CTX" '{hookSpecificOutput: {additionalContext: $ctx}}'
SH
gprobe key-setdefault 'f.attr == "setdefault" and len(n.args) >= 2 \' 'f.attr == "setdefault_" and len(n.args) >= 2 \' key-setdefault-computed \
  'd = {}
d.setdefault("additional" + "Context", "holdout arm")
print(d)' caught '^LABEL '
gprobe key-dict-pairs 'elif isinstance(f, ast.Name) and f.id == "dict" and n.args \' 'elif isinstance(f, ast.Name) and f.id == "dict_" and n.args \' key-dict-pairs-list \
  'd = dict([("additional" + "Context", "holdout arm")])
print(d)' caught '^LABEL '
gprobe key-may-spell 'elif any(_may_spell(c) for c in texts):' 'elif False:' key-fstring-prefix-runtime \
  'import os
print({f"additional{os.environ[chr(75)]}": "all good"})' caught '^UNRESOLVED .*computed key'
gprobe key-may-spell-suffix 'elif any(_may_spell(c) for c in texts):' 'elif False:' key-fstring-suffix-runtime \
  'import os
print({f"{os.environ[chr(75)]}Context": "all good"})' caught '^UNRESOLVED .*computed key'
tprobe file-budget 'return self.work > WORK_CAP or self.total > FILE_CAP' 'return self.work > WORK_CAP' "$WORK/file-budget-many-keys" 'whole file'
# timing: the guard must stay cheap (it runs in every battery)
T0=$(python3 -c 'import time; print(time.time())')
python3 "$GUARD" --root "$REPO_ROOT" >/dev/null 2>&1
T1=$(python3 -c 'import time; print(time.time())')
if python3 -c "import sys; sys.exit(0 if $T1 - $T0 < 3.0 else 1)"; then ok "guard-under-3s" "$(python3 -c "print(round($T1 - $T0, 2))")s"; else bad "guard-under-3s" "slow"; fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
