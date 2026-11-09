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

echo "=== git error ==="
if python3 "$LD" no-such-rev..other > "$TMP/out" 2> "$TMP/err"; then bad "bad range exits non-zero"
else ok "bad range exits non-zero"; fi
if grep -q '^lane-diff:' "$TMP/err"; then ok "one-line reason"; else bad "one-line reason"; fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
