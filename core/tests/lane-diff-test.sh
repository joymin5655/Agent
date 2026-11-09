#!/usr/bin/env bash
# lane-diff-test.sh — core/infra/lane-diff.py: function context for code files, default diff
# for everything else, blow-up guard, total cap, context_mode report. Temp repo, no network.
#
# Usage: bash core/tests/lane-diff-test.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LD="$REPO_ROOT/core/infra/lane-diff.py"
PASS=0
FAIL=0
ok()  { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL [$1]${2:+ — $2}"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/repo"
cd "$TMP/repo"
git init -q .
git config user.email t@example.invalid
git config user.name t
git config commit.gpgsign false

python3 - <<'PY'
body = "".join(f"        x{i} = {i}\n" for i in range(30))
open("svc.py", "w").write(
    "class Svc:\n    def first(self):\n" + body + "        return 1\n\n"
    "    def second(self):\n        try:\n            a = 1\n            b = 2\n"
    "            c = 3\n            return a + b + c\n        except ValueError:\n"
    "            return 0\n")
PY
printf 'greet() {\n  echo one\n  echo two\n  echo three\n}\n' > run.sh
printf '{\n  "a": 1,\n  "b": 2\n}\n' > conf.json
printf 'lock1\nlock2\n' > deps.lock
printf '# title\n\ntext\n' > notes.md
git add -A
git commit -qm base

sed -i.bak 's/b = 2/b = 22/' svc.py && rm svc.py.bak
sed -i.bak 's/echo two/echo TWO/' run.sh && rm run.sh.bak
sed -i.bak 's/"b": 2/"b": 3/' conf.json && rm conf.json.bak
printf 'lock1\nlock3\n' > deps.lock
printf '# title\n\ntext changed\n' > notes.md
git add -A

run() { python3 "$LD" "$@" > "$TMP/out" 2> "$TMP/err"; }
mode() { tail -n 1 "$TMP/err"; }
field() { mode | tr ' ' '\n' | grep "^$1=" | cut -d= -f2; }
file_hunk() { awk -v f="$1" '/^diff --git/{p=($0 ~ (" b/" f "$"))} p' "$2"; }

echo "=== staged: per-file behaviour ==="
if run --staged; then ok "exit 0"; else bad "exit 0"; fi
git diff --staged > "$TMP/plain"
for f in conf.json deps.lock notes.md; do
  if [[ "$(file_hunk "$f" "$TMP/out")" == "$(file_hunk "$f" "$TMP/plain")" \
        && -n "$(file_hunk "$f" "$TMP/out")" ]]; then
    ok "$f hunk equals default diff"
  else bad "$f hunk equals default diff"; fi
done
PYH="$(file_hunk svc.py "$TMP/out")"
if grep -q 'def second(self):' <<<"$PYH" && grep -q 'return 0' <<<"$PYH"; then
  ok "python hunk holds the whole enclosing method"
else bad "python hunk holds the whole enclosing method"; fi
if grep -q 'echo three' <<<"$(file_hunk run.sh "$TMP/out")"; then ok "shell hunk present"
else bad "shell hunk present"; fi
if [[ "$(field context_mode)" == "w" ]]; then ok "context_mode=w"
else bad "context_mode=w" "$(mode)"; fi
if [[ "$(field files)" == 5 && "$(field w_files)" == 2 ]]; then ok "files=5 w_files=2"
else bad "counts" "$(mode)"; fi
if [[ "$(field bytes)" == "$(wc -c < "$TMP/out" | tr -d ' ')" ]]; then ok "bytes matches stdout"
else bad "bytes matches stdout"; fi

echo "=== total cap ==="
run --staged --max-bytes "$(wc -c < "$TMP/plain" | tr -d ' ')"
if cmp -s "$TMP/out" "$TMP/plain"; then ok "over total cap -> whole default diff"
else bad "over total cap -> whole default diff"; fi
if [[ "$(field context_mode)" == "default" && "$(field w_files)" == 0 ]]; then
  ok "cap fallback reports default"
else bad "cap fallback reports default" "$(mode)"; fi
run --staged --max-bytes 10
if cmp -s "$TMP/out" "$TMP/plain"; then ok "default over cap still printed"
else bad "default over cap still printed"; fi
if [[ "$(field context_mode)" == "over_cap" ]]; then ok "context_mode=over_cap"
else bad "context_mode=over_cap" "$(mode)"; fi

echo "=== mixed mode: guard falls back for one file ==="
git commit -qm change
python3 - <<'PY'
# one huge function: -W prints the whole file, the default diff only the changed line
open("big.sh", "w").write("big() {\n" + "".join(f"  echo {i}\n" for i in range(3000)) + "}\n")
PY
git add big.sh
git commit -qm big
sed -i.bak 's/echo 1500$/echo changed/' big.sh && rm big.sh.bak
sed -i.bak 's/a = 1/a = 11/' svc.py && rm svc.py.bak
git add -A
run --staged
git diff --staged > "$TMP/plain"
if [[ "$(file_hunk big.sh "$TMP/out")" == "$(file_hunk big.sh "$TMP/plain")" ]]; then
  ok "blow-up guard keeps default diff for the huge function"
else bad "blow-up guard"; fi
if [[ "$(field context_mode)" == "mixed" && "$(field w_files)" == 1 && "$(field files)" == 2 ]]; then
  ok "context_mode=mixed"
else bad "context_mode=mixed" "$(mode)"; fi

echo "=== default mode: only non-code files ==="
git commit -qm more
printf '# title\n\ntext changed twice\n' > notes.md
git add notes.md
run --staged
if [[ "$(field context_mode)" == "default" && "$(field w_files)" == 0 ]]; then
  ok "context_mode=default"
else bad "context_mode=default" "$(mode)"; fi
if git diff --staged | cmp -s - "$TMP/out"; then ok "default output equals git diff"
else bad "default output equals git diff"; fi
git commit -qm notes

echo "=== selectors ==="
run --head
if git diff HEAD~1..HEAD | cmp -s - "$TMP/out"; then ok "--head = HEAD~1..HEAD"
else bad "--head = HEAD~1..HEAD"; fi
run HEAD~2..HEAD~1
if [[ "$(field files)" == 2 ]]; then ok "range passes through"
else bad "range passes through" "$(mode)"; fi
run --staged
if [[ ! -s "$TMP/out" && "$(mode)" == "context_mode=default bytes=0 files=0 w_files=0" ]]; then
  ok "empty diff"
else bad "empty diff" "$(mode)"; fi

echo "=== rename and deletion ==="
git mv run.sh run2.sh
git rm -q deps.lock
if run --staged; then ok "rename + delete exit 0"; else bad "rename + delete exit 0"; fi
if grep -q 'rename from run.sh' "$TMP/out"; then ok "rename kept as rename"
else bad "rename kept as rename"; fi
if [[ "$(field files)" == 2 ]]; then ok "two files"; else bad "two files" "$(mode)"; fi

echo "=== usage: option-looking target ==="
# after `--` argparse hands the value to the script as the target; without the check it
# reaches git, and `git diff --output=<file>` writes that file
if python3 "$LD" -- "--output=$TMP/pwned" > "$TMP/out" 2> "$TMP/err"; then rc=0; else rc=$?; fi
if [[ "$rc" == 2 ]]; then ok "dash target exits 2"; else bad "dash target exits 2" "rc=$rc"; fi
if [[ ! -e "$TMP/pwned" ]]; then ok "dash target created no file"
else bad "dash target created no file"; fi

echo "=== subdirectory and literal pathspecs ==="
git commit -qm renames 2>/dev/null || true
mkdir -p "app/[id]" app/i sub
printf 'one\n' > "app/[id]/page.tsx"
printf 'one\n' > app/i/page.tsx
git add -A
git commit -qm pages
printf 'two\n' > "app/[id]/page.tsx"
printf 'two\n' > app/i/page.tsx
git add -A
run --staged
n1="$(grep -c '^diff --git a/app/\[id\]/page.tsx' "$TMP/out" || true)"
n2="$(grep -c '^diff --git a/app/i/page.tsx' "$TMP/out" || true)"
if [[ "$n1" == 1 && "$n2" == 1 ]]; then ok "glob-named file: each hunk once"
else bad "glob-named file: each hunk once" "[id]=$n1 i=$n2"; fi
cp "$TMP/out" "$TMP/top.out"
( cd sub && python3 "$LD" --staged > "$TMP/sub.out" 2> "$TMP/sub.err" )
if cmp -s "$TMP/top.out" "$TMP/sub.out" && [[ -s "$TMP/sub.out" ]]; then
  ok "subdirectory output equals top-level output, nonempty"
else bad "subdirectory output equals top-level output" "$(tail -n 1 "$TMP/sub.err")"; fi

echo "=== repository-configured commands do not run ==="
printf 'stored\n' > tc.txt
git add tc.txt
git commit -qm tc
printf 'stored2\n' > tc.txt
git add tc.txt
printf '%s\n' '#!/bin/sh' "touch \"$TMP/marker-ext\"" 'exit 0' > "$TMP/ext.sh"
printf '%s\n' '#!/bin/sh' "touch \"$TMP/marker-fsm\"" 'exit 0' > "$TMP/fsm.sh"
printf '%s\n' '#!/bin/sh' 'tr a-z A-Z < "$1"' > "$TMP/tc.sh"
chmod +x "$TMP/ext.sh" "$TMP/fsm.sh" "$TMP/tc.sh"
printf 'tc.txt diff=evil\n*.tsx diff=extdiff\n' > .gitattributes
git config diff.evil.textconv "$TMP/tc.sh"
git config diff.extdiff.command "$TMP/ext.sh"
git add .gitattributes
printf 'three\n' > app/i/page.tsx
git add app/i/page.tsx
# set after the last `git add` of the test so only lane-diff.py can trigger the markers
git config core.fsmonitor "$TMP/fsm.sh"
git config diff.external "$TMP/ext.sh"
rm -f "$TMP/marker-ext" "$TMP/marker-fsm"
run --staged
if grep -q '^+stored2' "$TMP/out" && ! grep -q 'STORED' "$TMP/out"; then
  ok "textconv driver not applied: stored text printed"
else bad "textconv driver not applied"; fi
if [[ ! -e "$TMP/marker-ext" ]]; then ok "external diff command not run"
else bad "external diff command not run"; fi
if [[ ! -e "$TMP/marker-fsm" ]]; then ok "core.fsmonitor command not run"
else bad "core.fsmonitor command not run"; fi
git config --unset diff.external
git config --unset core.fsmonitor

echo "=== code files as text; pathspec environment ==="
mkdir "$TMP/repo2"
(
  cd "$TMP/repo2"
  git init -q .
  git config user.email t@example.invalid
  git config user.name t
  git config commit.gpgsign false
  printf 'def f():\n    return 1\n' > evil.py
  git add -A
  git commit -qm base
  printf 'evil.py -diff\n' > .gitattributes
  printf 'def f():\n    return 2\n' > evil.py
  git add -A
  git commit -qm attrs
  printf 'def f():\n    return 3\n' > evil.py
  git add -A
  git commit -qm change
)
cd "$TMP/repo2"
run HEAD~1..HEAD
if grep -q '^+    return 3' "$TMP/out" && ! grep -q '^Binary files' "$TMP/out"; then
  ok "in-tree -diff attribute does not hide a code file"
else bad "in-tree -diff attribute does not hide a code file" "$(head -n 5 "$TMP/out")"; fi
printf 'def f():\n    return 4\n' > evil.py
git add evil.py
GIT_LITERAL_PATHSPECS=1 python3 "$LD" --staged > "$TMP/out" 2> "$TMP/err" || true
if grep -q '^+    return 4' "$TMP/out"; then ok "GIT_LITERAL_PATHSPECS in the environment is ignored"
else bad "GIT_LITERAL_PATHSPECS in the environment is ignored" "$(mode)"; fi
cd "$TMP/repo"

echo "=== git error ==="
if python3 "$LD" no-such-rev..other > "$TMP/out" 2> "$TMP/err"; then bad "bad range exits non-zero"
else ok "bad range exits non-zero"; fi
if grep -q '^lane-diff:' "$TMP/err"; then ok "one-line reason"; else bad "one-line reason"; fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
