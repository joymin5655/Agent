#!/usr/bin/env bash
# floor-guard-test.sh — verify core/hooks/floor-guard.py (warn-only quality-floor advisory).
#
# The hook warns (additionalContext, never a permission decision) when a file edit ADDS a
# quality-floor bypass — a test skip or a type/lint suppression, counted as new text minus
# old text — or when a Bash command deletes a test file, adds a skip via `sed -i`/`perl -i`,
# or deselects tests from a pytest run. Covers:
#   - every marker family added            -> warn
#   - marker removed / unchanged / moved   -> silent
#   - Write compared against the file on disk (missing file = empty)
#   - MultiEdit summed over its edits
#   - Bash: rm / unlink / git rm of a test path warn, non-test and non-code paths silent;
#     sed -i / perl -i (replacement side only); pytest --deselect and -k "not ..." (command
#     word only); sh -c / bash -lc; shell comments; conservative shapes (echo, heredoc, bad
#     quoting, oversize command) silent
#   - Write over a missing file (empty), an oversized / unreadable / FIFO / directory path (skipped)
#   - opt-out env AGENT_FLOOR_GUARD=off|0|false
#   - empty / malformed stdin and odd tool_input shapes -> exit 0, no output
#   - no stderr in any run; no output anywhere ever carries a permission decision (never deny / ask / allow)
#   - firing sink record, with no file content or command text in it
#
# All fixtures live in mktemp dirs; the real repo is never touched.
# Usage: bash core/tests/floor-guard-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/core/hooks/floor-guard.py"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/floor-guard-test.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT
SINK="$WORK/sink"
mkdir -p "$WORK/proj/src" "$WORK/proj/tests"

PASS=0
FAIL=0
ALL_OUT="$WORK/all-output.txt"
ALL_ERR="$WORK/all-stderr.txt"
: > "$ALL_OUT"
: > "$ALL_ERR"

ok() { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
no() { echo "  FAIL [$1] ${2:-}"; FAIL=$((FAIL + 1)); }

# mkev <tool> <tool_input-json> -> canonical PreToolUse event
mkev() {
  _T="$1" _I="$2" _C="$WORK/proj" python3 -c '
import json, os
print(json.dumps({"ai": "claude-code", "session_id": "t", "event": "PreToolUse",
                  "tool_name": os.environ["_T"], "tool_input": json.loads(os.environ["_I"]),
                  "cwd": os.environ["_C"]}))'
}
# ti k=v ... -> JSON object of string values (split on the first "=")
ti() { python3 -c 'import json,sys; print(json.dumps(dict(a.split("=", 1) for a in sys.argv[1:])))' "$@"; }

OUT=""
RC=0
# run_hook <event-json> [VAR=value ...]
run_hook() {
  local ev="$1"; shift
  OUT=$(printf '%s' "$ev" | env AGENT_GATE_SINK_DIR="$SINK" AGENT_REPRODUCE_TEST=1 "$@" \
    python3 "$HOOK" 2>"$WORK/stderr")
  RC=$?
  printf '%s\n' "$OUT" >> "$ALL_OUT"
  cat "$WORK/stderr" >> "$ALL_ERR"
}

# expect <name> <silent|warn> <event-json> [needle ...]
expect() {
  local name="$1" want="$2" ev="$3"; shift 3
  run_hook "$ev"
  local got="silent"
  [[ -n "$OUT" ]] && got="warn"
  if [[ "$RC" -ne 0 ]]; then no "$name" "rc=$RC"; return; fi
  if [[ "$got" != "$want" ]]; then no "$name" "want=$want got=$got :: ${OUT:0:200}"; return; fi
  local n
  for n in "$@"; do
    if [[ "$OUT" != *"$n"* ]]; then no "$name" "output lacks '$n' :: ${OUT:0:300}"; return; fi
  done
  ok "$name"
}

edit_ev() { mkev Edit "$(ti file_path="$1" old_string="$2" new_string="$3")"; }

echo "=== Edit: each marker family added -> warn ==="
edit_ev "tests/test_a.py" "def test_a(): pass" $'@pytest.mark.skip\ndef test_a(): pass' > "$WORK/ev"
expect "pytest.mark.skip" warn "$(cat "$WORK/ev")" "tests/test_a.py" "pytest.mark.skip"
expect "pytest.mark.skipif" warn "$(edit_ev tests/t.py "x" '@pytest.mark.skipif(sys.platform == "win32", reason="r")')" "pytest.mark.skipif"
expect "pytest.skip(" warn "$(edit_ev tests/t.py "x" '    pytest.skip("later")')" "pytest.skip("
expect "pytest.mark.xfail" warn "$(edit_ev tests/t.py "x" '@pytest.mark.xfail')" "pytest.mark.xfail"
expect "pytestmark = pytest.mark.skip (no @)" warn "$(edit_ev tests/t.py "x" 'pytestmark = pytest.mark.skip(reason="x")')" "pytest.mark.skip"
expect "pytest.param(marks=pytest.mark.xfail)" warn "$(edit_ev tests/t.py "x" 'pytest.param(1, marks=pytest.mark.xfail)')" "pytest.mark.xfail"
expect "pytest.mark.skipif without @" warn "$(edit_ev tests/t.py "x" 'pytestmark = pytest.mark.skipif(True, reason="r")')" "pytest.mark.skipif"
expect "unittest.skip" warn "$(edit_ev tests/t.py "x" '@unittest.skip("no")')" "@unittest.skip"
expect "it.skip(" warn "$(edit_ev src/a.test.js "x" "it.skip('works', () => {})")" "it.skip("
expect "test.skip(" warn "$(edit_ev src/a.test.js "x" "test.skip('works', () => {})")" "test.skip("
expect "describe.skip(" warn "$(edit_ev src/a.test.js "x" "describe.skip('suite', () => {})")" "describe.skip("
expect "xit(" warn "$(edit_ev src/a.test.js "x" "xit('works', () => {})")" "xit("
expect "xdescribe(" warn "$(edit_ev src/a.test.js "x" "xdescribe('suite', () => {})")" "xdescribe("
expect "xtest(" warn "$(edit_ev src/a.test.js "x" "xtest('works', () => {})")" "xtest("
expect "t.Skip(" warn "$(edit_ev pkg/a_test.go "x" '	t.Skip("flaky")')" "t.Skip("
expect "t.Skipf(" warn "$(edit_ev pkg/a_test.go "x" '	t.Skipf("flaky %d", 1)')" "t.Skip("
expect "rust #[ignore]" warn "$(edit_ev src/lib.rs "x" '#[ignore]')" "#[ignore]"
expect "junit @Disabled" warn "$(edit_ev src/ATest.java "x" '@Disabled("later")')" "@Disabled"
expect "@ts-ignore" warn "$(edit_ev src/a.ts "x" '// @ts-ignore')" "@ts-ignore"
expect "@ts-nocheck" warn "$(edit_ev src/a.ts "x" '// @ts-nocheck')" "@ts-nocheck"
expect "@ts-expect-error" warn "$(edit_ev src/a.ts "x" '// @ts-expect-error')" "@ts-expect-error"
expect "eslint-disable" warn "$(edit_ev src/a.ts "x" '// eslint-disable-next-line no-console')" "eslint-disable"
expect "type: ignore" warn "$(edit_ev src/a.py "x" 'import foo  # type: ignore')" "type: ignore"
expect "noqa" warn "$(edit_ev src/a.py "x" 'import foo  # noqa: F401')" "noqa"
expect "noqa upper-case" warn "$(edit_ev src/a.py "x" 'import foo  # NOQA: F401')" "noqa"
expect "noqa mixed-case" warn "$(edit_ev src/a.py "x" 'import foo  # NoQA')" "noqa"
expect "pyright: ignore" warn "$(edit_ev src/a.py "x" 'import foo  # pyright: ignore')" "pyright: ignore"
expect "count rises 1 -> 2" warn "$(edit_ev src/a.py 'a  # noqa' $'a  # noqa\nb  # noqa')" "noqa"

echo
echo "=== Edit: removed / unchanged / moved / unrelated -> silent ==="
expect "marker removed" silent "$(edit_ev src/a.py 'a  # noqa' 'a')"
expect "marker unchanged" silent "$(edit_ev src/a.py 'a  # noqa' 'b  # noqa')"
expect "marker unchanged across case" silent "$(edit_ev src/a.py 'a  # NOQA' 'b  # noqa')"
expect "skipif is not skip (no phantom)" silent "$(edit_ev tests/t.py '@pytest.mark.skipif(c, reason="r")' '@pytest.mark.skipif(d, reason="r")')"
expect "no markers" silent "$(edit_ev src/a.py 'x = 1' 'x = 2')"
expect "doc file mentions marker" silent "$(edit_ev docs/notes.md 'x' 'use # noqa and @ts-ignore sparingly')"
expect "word boundary: xitem(" silent "$(edit_ev src/a.js 'x' 'xitem(1)')"
expect "word boundary: @Disabled prefix" silent "$(edit_ev src/A.java 'x' '@DisabledOnOs(OS.WINDOWS)')"

echo
echo "=== Write: compared against the file on disk ==="
printf 'import foo  # noqa\n' > "$WORK/proj/src/w.py"
expect "write same marker count" silent "$(mkev Write "$(ti file_path="$WORK/proj/src/w.py" content=$'import foo  # noqa\nx = 1\n')")"
expect "write adds a marker" warn "$(mkev Write "$(ti file_path="$WORK/proj/src/w.py" content=$'import foo  # noqa\nimport bar  # noqa\n')")" "w.py" "noqa"
expect "write removes the marker" silent "$(mkev Write "$(ti file_path="$WORK/proj/src/w.py" content=$'import foo\n')")"
expect "write to a missing file = empty" warn "$(mkev Write "$(ti file_path="$WORK/proj/src/new.py" content=$'import foo  # noqa\n')")" "new.py"
expect "write to a missing file, clean" silent "$(mkev Write "$(ti file_path="$WORK/proj/src/new2.py" content=$'x = 1\n')")"
mkdir -p "$WORK/proj/src/adir"
expect "write to a directory path is skipped" silent "$(mkev Write "$(ti file_path="$WORK/proj/src/adir" content=$'x  # noqa\n')")"
python3 -c 'import sys; sys.stdout.write("# noqa\n" * 400000)' > "$WORK/proj/src/big.py"
expect "write over an existing >2MB file is skipped" silent "$(mkev Write "$(ti file_path="$WORK/proj/src/big.py" content=$'a  # noqa\nb  # noqa\n')")"
printf 'x\n' > "$WORK/proj/src/locked.py"; chmod 000 "$WORK/proj/src/locked.py"
if [[ -r "$WORK/proj/src/locked.py" ]]; then   # running as root: chmod 000 does not lock anything
  echo "  skip [write over an unreadable file] (file still readable)"
else
  expect "write over an existing unreadable file is skipped" silent "$(mkev Write "$(ti file_path="$WORK/proj/src/locked.py" content=$'a  # noqa\n')")"
fi
chmod 600 "$WORK/proj/src/locked.py"
mkfifo "$WORK/proj/src/fifo.py"
FIFO_EV="$(mkev Write "$(ti file_path="$WORK/proj/src/fifo.py" content=$'a  # noqa\n')")"
# bounded run: a hook that blocks on the FIFO must fail the test, not hang it
FIFO_RES="$(HOOK="$HOOK" EV="$FIFO_EV" SINK="$SINK" python3 - <<'PY'
import os, subprocess
try:
    r = subprocess.run(["python3", os.environ["HOOK"]], input=os.environ["EV"].encode(), capture_output=True,
                       timeout=5, env={**os.environ, "AGENT_GATE_SINK_DIR": os.environ["SINK"]})
    print("rc=%d out=%s" % (r.returncode, r.stdout.decode()[:80]))
except subprocess.TimeoutExpired:
    print("TIMEOUT")
PY
)"
if [[ "$FIFO_RES" == "rc=0 out=" ]]; then ok "write to a FIFO path returns promptly and is skipped"; else no "write to a FIFO path" "$FIFO_RES"; fi
printf '@pytest.mark.skip\n@pytest.mark.skip\n' > "$WORK/proj/tests/test_w.py"
expect "write drops 2 skips to 1" silent "$(mkev Write "$(ti file_path="$WORK/proj/tests/test_w.py" content=$'@pytest.mark.skip\n')")"

echo
echo "=== MultiEdit: summed over the edits ==="
expect "multiedit both add" warn "$(mkev MultiEdit '{"file_path":"src/a.py","edits":[{"old_string":"a","new_string":"a  # noqa"},{"old_string":"b","new_string":"b  # noqa"}]}')" "noqa"
expect "multiedit add + unrelated" warn "$(mkev MultiEdit '{"file_path":"src/a.py","edits":[{"old_string":"a","new_string":"a  # noqa"},{"old_string":"b","new_string":"c"}]}')" "noqa"
expect "multiedit add then remove nets zero" silent "$(mkev MultiEdit '{"file_path":"src/a.py","edits":[{"old_string":"a","new_string":"a  # noqa"},{"old_string":"b  # noqa","new_string":"b"}]}')"
expect "multiedit removes only" silent "$(mkev MultiEdit '{"file_path":"src/a.py","edits":[{"old_string":"a  # noqa","new_string":"a"}]}')"
expect "multiedit with junk edits" silent "$(mkev MultiEdit '{"file_path":"src/a.py","edits":[1,null,"x",{"old_string":5}]}')"

echo
echo "=== Bash: deleting test files ==="
bash_ev() { mkev Bash "$(ti command="$1")"; }
expect "rm tests file" warn "$(bash_ev 'rm tests/test_a.py')" "tests/test_a.py"
expect "rm -rf tests dir" warn "$(bash_ev 'rm -rf tests/')" "tests/"
expect "rm test_*.py" warn "$(bash_ev 'rm src/test_models.py')" "test_models.py"
expect "rm *_test.go" warn "$(bash_ev 'rm pkg/a_test.go')" "a_test.go"
expect "rm *.test.ts" warn "$(bash_ev 'rm -f web/a.test.ts')" "a.test.ts"
expect "rm *.spec.js" warn "$(bash_ev 'rm web/a.spec.js')" "a.spec.js"
expect "git rm test file" warn "$(bash_ev 'git rm tests/test_a.py')" "tests/test_a.py"
expect "git -C dir rm test file" warn "$(bash_ev 'git -C sub rm -q tests/test_a.py')" "tests/test_a.py"
expect "rm after cd &&" warn "$(bash_ev 'cd proj && rm tests/test_a.py')" "tests/test_a.py"
expect "rm after env assignment" warn "$(bash_ev 'FOO=1 rm tests/test_a.py')" "tests/test_a.py"
expect "rm after sudo" warn "$(bash_ev 'sudo rm tests/test_a.py')" "tests/test_a.py"
expect "rm in sh -c" warn "$(bash_ev 'sh -c "rm tests/test_a.py"')" "tests/test_a.py"
expect "unlink test file" warn "$(bash_ev 'unlink tests/test_a.py')" "tests/test_a.py"
expect "rm via ./ and .. that lands in tests" warn "$(bash_ev 'rm src/../tests/test_a.py')" "test_a.py"
expect "rm -r tests (directory operand)" warn "$(bash_ev 'rm -r tests')" "tests"
expect "rm -R spec (directory operand)" warn "$(bash_ev 'rm -R spec')" "spec"
expect "rm helper code inside tests/" warn "$(bash_ev 'rm tests/helpers.py')" "helpers.py"
expect "rm a snapshot inside tests/ (deliberately counts)" warn "$(bash_ev 'rm tests/__snapshots__/a.snap')" "a.snap"
expect "bash -lc rm test" warn "$(bash_ev 'bash -lc "rm tests/test_a.py"')" "tests/test_a.py"
expect "zsh -lc rm test" warn "$(bash_ev "zsh -lc 'rm tests/test_a.py'")" "tests/test_a.py"
expect "bash -c rm test" warn "$(bash_ev 'bash -c "rm tests/test_a.py"')" "tests/test_a.py"
expect "rm before a trailing comment" warn "$(bash_ev 'rm tests/test_a.py # obsolete')" "tests/test_a.py"
expect "quoted # is not a comment" warn "$(bash_ev 'echo "#"; rm tests/test_a.py')" "tests/test_a.py"
expect "rm on the line after a comment" warn "$(bash_ev $'echo ok # note\nrm tests/test_a.py')" "tests/test_a.py"
expect "rm of non-test file" silent "$(bash_ev 'rm src/main.py')"
expect "rm tests/../src/main.py normalizes away" silent "$(bash_ev 'rm tests/../src/main.py')"
expect "rm tests (no -r, a directory)" silent "$(bash_ev 'rm tests')"
expect "rm tests/README.md" silent "$(bash_ev 'rm tests/README.md')"
expect "rm tests/*.pyc" silent "$(bash_ev 'rm tests/*.pyc')"
expect "rm tests/data.json" silent "$(bash_ev 'rm tests/data.json')"
expect "rm docs/spec/old.yaml" silent "$(bash_ev 'rm docs/spec/old.yaml')"
expect "rm src/test_x.pyc" silent "$(bash_ev 'rm src/test_x.pyc')"
expect "rm in a trailing comment" silent "$(bash_ev 'echo ok # later; rm tests/test_a.py')"
expect "rm in a comment line" silent "$(bash_ev $'echo ok\n# rm tests/test_a.py')"
expect "git rm -n dry run" silent "$(bash_ev 'git rm -n tests/test_a.py')"
expect "git rm --dry-run" silent "$(bash_ev 'git rm --dry-run tests/test_a.py')"
expect "git rm -rn dry run" silent "$(bash_ev 'git rm -rn tests')"
expect "oversize command is not scanned" silent "$(bash_ev "rm tests/test_a.py; echo $(python3 -c 'print("x" * 20100)')")"
expect "rm of scratch dir" silent "$(bash_ev 'rm -rf /tmp/build-out')"
expect "rm test path under /tmp" silent "$(bash_ev 'rm -rf /tmp/x/tests/')"
expect "rm test path under node_modules" silent "$(bash_ev 'rm -rf node_modules/pkg/test/')"
# shellcheck disable=SC2016  # the literal $TMPDIR is the fixture: the hook must not resolve it
expect "rm via unresolved variable" silent "$(bash_ev 'rm -rf "$TMPDIR/tests"')"
expect "git rm --cached keeps the file" silent "$(bash_ev 'git rm --cached tests/test_a.py')"
expect "echo mentioning rm" silent "$(bash_ev 'echo "rm tests/test_a.py"')"
expect "ls tests" silent "$(bash_ev 'ls tests/')"
expect "git commit message mentioning rm" silent "$(bash_ev 'git commit -m "rm tests/test_a.py is wrong"')"
expect "heredoc body is not a command" silent "$(bash_ev $'cat <<EOF\nrm tests/test_a.py\nEOF')"
expect "unbalanced quote does not crash" silent "$(bash_ev 'rm "tests/test_a.py')"

echo
echo "=== Bash: skip markers via sed -i / perl -i ==="
expect "sed -i skip into test file" warn "$(bash_ev "sed -i '1i @pytest.mark.skip' tests/test_a.py")" "tests/test_a.py"
expect "sed -i '' (BSD) skip into test file" warn "$(bash_ev "sed -i '' 's/^def test_a/@pytest.mark.skip\\ndef test_a/' tests/test_a.py")" "tests/test_a.py"
expect "perl -pi skip into spec file" warn "$(bash_ev "perl -pi -e 's/^it\\(/it.skip(/' web/a.spec.js")" "a.spec.js"
expect "sed -i skip into non-test file" silent "$(bash_ev "sed -i '1i @pytest.mark.skip' src/main.py")"
expect "sed -i on test file, no skip" silent "$(bash_ev "sed -i 's/a/b/' tests/test_a.py")"
expect "sed without -i" silent "$(bash_ev "sed 's/^/@pytest.mark.skip /' tests/test_a.py")"
expect "sed -i delete of a skip line is not an add" silent "$(bash_ev "sed -i '/@pytest.mark.skip/d' tests/test_a.py")"
expect "sed -i xit( -> it( removes a skip" silent "$(bash_ev "sed -i 's/xit(/it(/' a.test.js")"
expect "sed -i it.skip( -> it( removes a skip" silent "$(bash_ev "sed -i 's/it.skip(/it(/' web/a.test.js")"
expect "sed -i delete with BSD empty suffix" silent "$(bash_ev "sed -i '' '/xit(/d' a.test.js")"
expect "perl -pi xit( -> it( removes a skip" silent "$(bash_ev "perl -pi -e 's/xit\\(/it(/' web/a.spec.js")"
expect "sed -i s/// replacement adds skip + newline" warn "$(bash_ev "sed -i 's/^def test_x/@pytest.mark.skip\\ndef test_x/' tests/test_a.py")" "tests/test_a.py"
expect "sed -i \\n directly before the marker" warn "$(bash_ev "sed -i 's/^a/b\\nxit(1)/' tests/test_a.js")" "tests/test_a.js"
expect "sed -i address + i command adds skip" warn "$(bash_ev "sed -i '/def test_x/i @pytest.mark.skip' tests/test_a.py")" "tests/test_a.py"
expect "sed -i c command adds skip" warn "$(bash_ev "sed -i '2c\\xit(1)' tests/test_a.js")" "tests/test_a.js"
expect "sed -i block with address adds skip" warn "$(bash_ev "sed -i -e '/foo/{s/a/it.skip(/;p}' web/a.test.js")" "a.test.js"
expect "sed --in-place=.bak adds skip" warn "$(bash_ev "sed --in-place=.bak 's/a/xit(/' web/a.test.js")" "a.test.js"
expect "sed -i -e replacement adds skip" warn "$(bash_ev "sed -i -e 's/^it(/it.skip(/' web/a.spec.js")" "a.spec.js"
expect "sed -i with unparseable s///" silent "$(bash_ev "sed -i 's/it(/it.skip(' web/a.spec.js")"
expect "sed -f script file stays silent" silent "$(bash_ev "sed -i -f fix.sed web/a.spec.js")"

echo
echo "=== Bash: test-runner deselect flags ==="
expect "pytest --deselect" warn "$(bash_ev 'pytest tests/ --deselect tests/test_a.py::test_x')" "--deselect"
expect "pytest --deselect=" warn "$(bash_ev 'python3 -m pytest --deselect=tests/test_a.py::test_x')" "--deselect"
expect "pytest -k not" warn "$(bash_ev 'pytest -k "not slow and not db"')" "-k"
expect "uv run pytest -k not" warn "$(bash_ev 'uv run pytest tests -k "not flaky"')" "-k"
expect "pytest -k plain selection" silent "$(bash_ev 'pytest -k slow')"
expect "pytest plain" silent "$(bash_ev 'pytest tests/ -x -q')"
expect "py.test --deselect" warn "$(bash_ev 'py.test tests/ --deselect tests/test_a.py::test_x')" "--deselect"
expect "poetry run pytest -k not" warn "$(bash_ev 'poetry run pytest -k "not flaky"')" "-k"
expect "echo mentioning pytest --deselect" silent "$(bash_ev 'echo pytest --deselect x')"
expect "grep pytest -k not" silent "$(bash_ev 'grep pytest -k "not x" f')"
expect "python script named pytest-notes" silent "$(bash_ev 'python3 notes.py pytest --deselect x')"
expect "sort -k is not a deselect" silent "$(bash_ev 'sort -k 2 file.txt')"
expect "grep mentioning --deselect" silent "$(bash_ev 'grep -r -- "--deselect" docs')"

echo
echo "=== Output shape: additionalContext only, never a decision ==="
run_hook "$(edit_ev tests/t.py "x" '@pytest.mark.skip')"
if python3 - "$OUT" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
h = d["hookSpecificOutput"]
assert h["hookEventName"] == "PreToolUse", h
assert "permissionDecision" not in h and "permissionDecisionReason" not in h, h
assert set(d) == {"hookSpecificOutput"}, d
ctx = h["additionalContext"]
assert "explicitly asked" in ctx and "root cause" in ctx, ctx
assert "tests/t.py" in ctx and "pytest.mark.skip" in ctx, ctx
PY
then ok "shape: additionalContext, names file+marker, says ask-or-fix"; else no "shape" "$OUT"; fi
many=$'@pytest.mark.skip\n@pytest.mark.xfail\n@unittest.skip\nxit(\nxdescribe(\n# noqa\n# type: ignore\n@ts-ignore\n'
run_hook "$(edit_ev src/many.py "x" "$many")"
if python3 - "$OUT" <<'PY'
import json, sys
ctx = json.loads(sys.argv[1])["hookSpecificOutput"]["additionalContext"]
assert "more" in ctx, ctx
assert len(ctx) < 1500, len(ctx)
PY
then ok "long marker list is capped"; else no "cap" "$OUT"; fi

echo
echo "=== Opt-out env AGENT_FLOOR_GUARD ==="
EV="$(edit_ev tests/t.py "x" '@pytest.mark.skip')"
BEV="$(bash_ev 'rm tests/test_a.py')"
for v in off 0 false OFF False; do
  run_hook "$EV" AGENT_FLOOR_GUARD="$v"
  if [[ -z "$OUT" && "$RC" -eq 0 ]]; then ok "opt-out Edit AGENT_FLOOR_GUARD=$v"; else no "opt-out Edit $v" "$OUT"; fi
done
run_hook "$BEV" AGENT_FLOOR_GUARD=off
if [[ -z "$OUT" && "$RC" -eq 0 ]]; then ok "opt-out Bash"; else no "opt-out Bash" "$OUT"; fi
run_hook "$EV" AGENT_FLOOR_GUARD=on
if [[ -n "$OUT" ]]; then ok "AGENT_FLOOR_GUARD=on still warns"; else no "on still warns"; fi

echo
echo "=== Malformed input: fail-open, exit 0, no output ==="
for bad in '' 'not json' '[]' '"str"' '{}' '{"tool_name":"Edit"}' '{"tool_name":"Edit","tool_input":"s"}' \
  '{"tool_name":"Edit","tool_input":{"file_path":5,"old_string":null,"new_string":7}}' \
  '{"tool_name":"Write","tool_input":{"file_path":"a.py","content":["x"]}}' \
  '{"tool_name":"MultiEdit","tool_input":{"file_path":"a.py","edits":"nope"}}' \
  '{"tool_name":"Bash","tool_input":{"command":5}}' \
  '{"tool_name":["Edit"],"tool_input":{}}' \
  '{"tool_name":"Read","tool_input":{"file_path":"a.py","content":"# noqa @ts-ignore"}}'; do
  run_hook "$bad"
  if [[ -z "$OUT" && "$RC" -eq 0 ]]; then ok "malformed: ${bad:0:50}"; else no "malformed: ${bad:0:50}" "rc=$RC out=${OUT:0:100}"; fi
done

echo
echo "=== Never denies ==="
if grep -Eq 'permissionDecision|"deny"|"ask"' "$ALL_OUT"; then
  no "no permission decision anywhere" "$(grep -E 'permissionDecision|"deny"|"ask"' "$ALL_OUT" | head -2)"
else ok "no permission decision in any output of this run"; fi

echo
echo "=== Firing record ==="
rm -rf "$SINK"
SECRET_BODY='zz_content_probe_zz'
run_hook "$(edit_ev tests/t.py "x" "@pytest.mark.skip  $SECRET_BODY")"
if [[ -s "$SINK/floor-guard.jsonl" ]] && python3 - "$SINK/floor-guard.jsonl" "$SECRET_BODY" <<'PY'
import json, sys
rec = json.loads(open(sys.argv[1]).read().splitlines()[-1])
assert rec["hook"] == "floor-guard.py" and rec["decision"] == "warn", rec
assert rec["reproduce_test"] is True and rec["file_path"] == "tests/t.py", rec
assert "pytest.mark.skip" in rec["markers"], rec
assert sys.argv[2] not in json.dumps(rec), "content leaked into the sink"
PY
then ok "warn writes a content-free record to AGENT_GATE_SINK_DIR"; else no "firing record" "$(cat "$SINK/floor-guard.jsonl" 2>/dev/null)"; fi
rm -rf "$SINK"
run_hook "$(edit_ev src/a.py 'x' 'y')"
if [[ ! -e "$SINK/floor-guard.jsonl" ]]; then ok "silent run writes no record"; else no "silent writes no record"; fi
if [[ ! -e "$REPO_ROOT/.agent/logs/floor-guard.jsonl" ]]; then ok "real repo sink untouched"; else no "real repo sink touched"; fi

echo
echo "=== stderr across every run above ==="
if [[ ! -s "$ALL_ERR" ]]; then ok "no stderr output in any run"; else no "stderr output" "$(head -n 3 "$ALL_ERR")"; fi

echo
echo "=== floor-guard: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
