#!/usr/bin/env bash
# verify-observer-test.sh — verify the two halves of the unverified-session gate:
#   WRITER: core/hooks/verify-observer.py     (PostToolUse Bash, records that a
#                                              verification command was invoked)
#   READER: core/hooks/session-quality-gate.py layer 3 (Stop advisory)
#
# Contract covered:
#   A. family matching — real verification commands record, look-alikes do NOT
#      (`git checkout` must not match "check", `cat test.txt` must not match
#      "test"; a false positive here would mark an unverified session verified)
#   B. observer protocol — zero bytes on stdout always, exit 0 always, no raw
#      command text in the sink (no secret-leak surface), sink override confined
#   C. Stop advisory — fires on code-changes-with-no-verification, silent when a
#      verification was invoked / only docs changed / nothing changed
#   D. observe-by-default — NEVER `decision: block` unless
#      AGENT_VERIFY_OBSERVER_BLOCK=1; anti-loop second Stop still passes
#   E. session scoping — another session's record does not satisfy this session
#   F. mutation probes — the advisory condition is load-bearing, not decorative
#
# Fixtures are throwaway git repos in mktemp passed as the event `cwd`; the real
# repo .agent/ is never written to.
#
# Usage: bash core/tests/verify-observer-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OBSERVER="$REPO_ROOT/core/hooks/verify-observer.py"
GATE="$REPO_ROOT/core/hooks/session-quality-gate.py"
# Empty splice: the secret-shaped fixtures below are assembled at RUNTIME so no
# literal secret pattern appears in this source and the repo's own gitleaks gate
# stays green (same technique as core/tests/check-hardcoding-test.sh).
Z=""

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/verify-observer-test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
ok()  { echo "  ok   [$1]${2:+ $2}"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL [$1]${2:+ $2}"; FAIL=$((FAIL + 1)); }

# bash 3.2 + set -u: never self-reference a variable inside the same `local`.
mkproj() {  # mkproj <name> [ext] — throwaway git repo with one untracked file
  local name="$1"
  local ext="${2:-py}"
  local d="$TMP_ROOT/$name"
  mkdir -p "$d"
  git -C "$d" init --quiet >/dev/null 2>&1
  printf 'x = 1\n' > "$d/changed.$ext"
  echo "$d"
}

post_event() {  # post_event <command> [tool] [session] [cwd]
  # `cwd` is what the hook resolves the project root (and so the DEFAULT sink)
  # from, so it must be a parameter — hardcoding it made the default-path checks
  # in section G test /tmp instead of the fixture.
  CMD="$1" TOOL="${2:-Bash}" SID="${3:-sess-A}" CWD="${4:-$TMP_ROOT}" python3 -c '
import os, json
print(json.dumps({
    "ai": "claude-code", "event": "PostToolUse", "session_id": os.environ["SID"],
    "tool_name": os.environ["TOOL"], "tool_input": {"command": os.environ["CMD"]},
    "tool_response": {"stdout": "", "stderr": ""}, "cwd": os.environ["CWD"],
}))'
}

stop_event() {  # stop_event <root> <active> [session_id]
  ROOT="$1" ACTIVE="$2" SID="${3:-sess-A}" python3 -c '
import os, json
print(json.dumps({
    "ai": "claude-code", "event": "Stop", "hook_event_name": "Stop",
    "session_id": os.environ["SID"], "cwd": os.environ["ROOT"],
    "stop_hook_active": os.environ["ACTIVE"] == "true",
}))'
}

# observe <command> <sink> [tool] [session] -> echoes observer stdout
observe() {
  printf '%s' "$(post_event "$1" "${3:-Bash}" "${4:-sess-A}")" \
    | AGENT_VERIFY_OBSERVED_SINK="$2" AGENT_REPRODUCE_TEST=1 python3 "$OBSERVER" 2>/dev/null
}

sink_families() {  # sink_families <sink> -> space-separated families recorded
  [[ -f "$1" ]] || { echo ""; return; }
  S="$1" python3 -c '
import json, os
out = []
for line in open(os.environ["S"], encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    try:
        r = json.loads(line)
    except ValueError:
        continue
    if r.get("event") == "verification_invoked":
        out.append(r.get("family", "?"))
print(" ".join(out))'
}

echo "=== A. family matching — real verification commands record ==="
for spec in "pytest -q tests/:tests" \
            "python3 -m pytest:tests" \
            "npm test --silent:tests" \
            "go test ./...:tests" \
            "bash core/tests/verify-all.sh:battery" \
            "npx tsc --noEmit:typecheck" \
            "ruff check core/:lint" \
            "npm run build:build"; do
  CMD="${spec%:*}"; WANT="${spec##*:}"
  SINK="$TMP_ROOT/fam-$WANT-$RANDOM.jsonl"
  observe "$CMD" "$SINK" >/dev/null
  GOT="$(sink_families "$SINK")"
  if [[ "$GOT" == "$WANT" ]]; then
    ok "family/$CMD" "-> $WANT"
  else
    bad "family/$CMD" "want=$WANT got='$GOT'"
  fi
done

echo
echo "=== A2. look-alikes must NOT record (a false positive hides a real gap) ==="
# The second block is the eight cases a review reproduced against the first cut
# of this hook, when the family patterns were `search`-based instead of anchored
# at invocation position. Each one marked an unverified session "verified".
for cmd in "git checkout main" \
           "cat test.txt" \
           "echo hello world" \
           "ls -la testing/" \
           "grep -rn build src/" \
           "pip install pytest-mock" \
           "which eslint" \
           "grep -rn mypy setup.cfg" \
           "git commit -m 'add pytest fixtures'" \
           "cat core/tests/verify-all.sh" \
           "wc -l core/tests/verify-all.sh" \
           "npm i -D vitest" \
           "apt-get install shellcheck" \
           "git log --oneline -- core/tests/verify-all.sh" \
           "echo 'run pytest later' >> TODO.md" \
           "./pytest.md" \
           "./eslint.txt" \
           "less core/tests/verify-all.sh" \
           "vim core/tests/x-test.sh" \
           "cd pytest && ls" \
           "VAR=pytest echo hi" \
           "echo pytest" \
           "sudo sudo sudo sudo sudo sudo sudo sudo sudo pytest" \
           "X=1 Y=2 Z=3 A=4 B=5 C=6 D=7 E=8 F=9 pytest"; do
  SINK="$TMP_ROOT/neg-$RANDOM.jsonl"
  observe "$cmd" "$SINK" >/dev/null
  GOT="$(sink_families "$SINK")"
  if [[ -z "$GOT" ]]; then
    ok "no-match/$cmd"
  else
    bad "no-match/$cmd" "recorded '$GOT'"
  fi
done

echo
echo "=== A3. invocation-position normalisation (real runs behind wrappers) ==="
# Anchoring at invocation position is only correct if the normaliser actually
# reaches the program: absolute/relative paths, env assignments, wrapper
# prefixes, and runners after a shell separator.
# `echo $(pytest)` is a TRUE positive, not a leak in the anchoring: command
# substitution executes pytest, so the session really did run it. `npm run
# test:unit` is why the npm-script alternatives keep \b instead of (?=\s|$) —
# colon-suffixed script names are the common form.
for spec in "/usr/local/bin/pytest -q:tests" \
            "./node_modules/.bin/jest --ci:tests" \
            "CI=1 pytest -q:tests" \
            "sudo make build:build" \
            "uv run pytest:tests" \
            "pnpm exec tsc --noEmit:typecheck" \
            "git add -A && pytest -q:tests" \
            "cd /tmp; ruff check .:lint" \
            "bash /abs/path/core/tests/x-test.sh:battery" \
            "./core/tests/verify-all.sh:battery" \
            "echo \$(pytest):tests" \
            "npm run test:unit:tests"; do
  CMD="${spec%:*}"; WANT="${spec##*:}"
  SINK="$TMP_ROOT/norm-$WANT-$RANDOM.jsonl"
  observe "$CMD" "$SINK" >/dev/null
  GOT="$(sink_families "$SINK")"
  if [[ "$GOT" == "$WANT" ]]; then
    ok "normalise/$CMD" "-> $WANT"
  else
    bad "normalise/$CMD" "want=$WANT got='$GOT'"
  fi
done

echo
echo "=== A4. shell syntax the parser must model (data vs. executed commands) ==="
# Found by probing the seams a review flagged as unexamined. Each negative here
# is the SAME defect class as the substring bug: text that merely LOOKS like a
# verification run, marking an unverified session verified.
#   - a here-doc body is data (writing docs that SHOW `pytest -q` is realistic)
#   - `pip install \` + newline + `pytest` is ONE `pip install pytest`
#   - NBSP is whitespace to Python's str.split()/strip() but not to a shell, so
#     `\xa0pytest` (a command that cannot run) must not read as an invocation
check_cmd() {  # check_cmd <label> <command> <expected family or "">
  local label="$1"
  local cmd="$2"
  local want="$3"
  local sink="$TMP_ROOT/syn-$RANDOM.jsonl"
  observe "$cmd" "$sink" >/dev/null
  local got
  got="$(sink_families "$sink")"
  if [[ "$got" == "$want" ]]; then
    ok "syntax/$label" "${want:-no match}"
  else
    bad "syntax/$label" "want='${want}' got='$got'"
  fi
}
check_cmd "heredoc-body-is-data"    "$(printf 'cat <<EOF\npytest -q\nEOF')" ""
check_cmd "heredoc-quoted-delim"    "$(printf "cat > R.md <<'EOF'\nruff check .\nEOF")" ""
check_cmd "heredoc-dash-delim"      "$(printf 'cat <<-END\nnpm test\nEND')" ""
check_cmd "line-continuation"       "$(printf 'pip install \\\n  pytest')" ""
check_cmd "nbsp-is-not-a-separator" "$(printf '\xc2\xa0pytest -q')" ""
# ...while the real invocations around that syntax still record.
check_cmd "heredoc-then-real-run"   "$(printf 'cat <<EOF\ndata\nEOF\npytest -q')" "tests"
check_cmd "continuation-then-run"   "$(printf 'echo a \\\n b && pytest')" "tests"
check_cmd "subshell-runs"           '(pytest -q)' "tests"
check_cmd "newline-two-commands"    "$(printf 'echo hi\npytest -q')" "tests"
# A security lane found these two. Case first: `PYTEST -q` is "command not
# found" on a case-sensitive filesystem — it runs nothing — yet an IGNORECASE
# match banked it as verification, across every family.
check_cmd "case-sensitive-pytest"   'PYTEST -q'      ""
check_cmd "case-sensitive-make"     'Make build'     ""
check_cmd "case-sensitive-tsc"      'TSC --noEmit'   ""
check_cmd "case-lowercase-still-ok" 'make build'     "build"
# ...and `<<<` is a here-STRING, not a here-doc. The heredoc regex used to match
# the last two of the three angle brackets, opening a fake here-doc whose
# delimiter swallowed every following line — including a real run.
check_cmd "herestring-not-heredoc"  "$(printf 'grep x <<<word\npytest -q')" "tests"

echo
echo "=== B. observer protocol: zero bytes, exit 0, no command text, confinement ==="
SINK="$TMP_ROOT/proto.jsonl"
OUT=$(observe "pytest -q" "$SINK"); RC=$?
if [[ $RC -eq 0 && -z "$OUT" ]]; then
  ok "observer-zero-bytes" "rc=0, empty stdout while recording"
else
  bad "observer-zero-bytes" "rc=$RC out='$OUT'"
fi

SINK="$TMP_ROOT/secret.jsonl"
# Assembled at runtime (see the ${Z} note at the top): these two fixtures carry
# the shapes a real command line leaks — a bearer-style token and a URL with
# inline credentials. The assertion is that NEITHER reaches the sink.
PROBE_A="sk-${Z}live-ABC${Z}DEF123456"
PROBE_B="https://user:${Z}pw@example.com"
observe "pytest -q --arg=$PROBE_A $PROBE_B" "$SINK" >/dev/null
if [[ -f "$SINK" ]] && ! grep -q "$PROBE_A\|user:${Z}pw" "$SINK"; then
  ok "no-command-text-stored" "family label only, no redaction surface"
else
  bad "no-command-text-stored" "sink contains command text: $(cat "$SINK" 2>/dev/null)"
fi

OUT=$(printf '' | AGENT_VERIFY_OBSERVED_SINK="$TMP_ROOT/e.jsonl" python3 "$OBSERVER" 2>/dev/null); RC=$?
if [[ $RC -eq 0 && -z "$OUT" ]]; then ok "empty-stdin-failsafe"; else bad "empty-stdin-failsafe" "rc=$RC"; fi
OUT=$(printf 'not json' | AGENT_VERIFY_OBSERVED_SINK="$TMP_ROOT/m.jsonl" python3 "$OBSERVER" 2>/dev/null); RC=$?
if [[ $RC -eq 0 && -z "$OUT" ]]; then ok "malformed-stdin-failsafe"; else bad "malformed-stdin-failsafe" "rc=$RC"; fi

SINK="$TMP_ROOT/tool.jsonl"
observe "pytest -q" "$SINK" Write >/dev/null
if [[ -z "$(sink_families "$SINK")" ]]; then
  ok "non-bash-tool-ignored"
else
  bad "non-bash-tool-ignored" "recorded on a Write event"
fi

ESCAPE="$HOME/.verify-observer-escape-$$.jsonl"
rm -f "$ESCAPE"
printf '%s' "$(post_event 'pytest -q')" | AGENT_VERIFY_OBSERVED_SINK="$ESCAPE" \
  python3 "$OBSERVER" >/dev/null 2>&1 || true
if [[ ! -e "$ESCAPE" ]]; then
  ok "sink-escape-refused" "override outside .agent/logs and tempdir ignored"
else
  bad "sink-escape-refused" "wrote outside confinement: $ESCAPE"; rm -f "$ESCAPE"
fi

SINK="$TMP_ROOT/shape.jsonl"
observe "pytest -q" "$SINK" >/dev/null
SHAPE=$(S="$SINK" python3 -c '
import json, os
r = json.loads(open(os.environ["S"], encoding="utf-8").readline())
need = ("ts", "guard", "hook", "schema_version", "session_id", "event", "family")
print("ok" if all(k in r for k in need)
      and r["guard"] == "verify-observed"
      and r["hook"] == "verify-observer.py"
      and r.get("reproduce_test") is True else "bad " + json.dumps(r))')
if [[ "$SHAPE" == "ok" ]]; then
  ok "record-shape" "telemetry-digest fields + reproduce_test"
else
  bad "record-shape" "$SHAPE"
fi

echo
echo "=== C. Stop advisory fires only when code changed AND nothing was run ==="
run_stop() {  # run_stop <root> <active> <sink> [session] [env...] -> stdout in $STOPOUT
  local root="$1" active="$2" sink="$3" sid="${4:-sess-A}"
  shift 4 || shift 3
  STOPOUT=$(printf '%s' "$(stop_event "$root" "$active" "$sid")" \
    | env AGENT_VERIFY_OBSERVED_SINK="$sink" AGENT_REPRODUCE_TEST=1 "$@" \
      python3 "$GATE" 2>/dev/null)
  STOPRC=$?
}
has_advisory() { [[ "$STOPOUT" == *"verify-observer"* ]]; }
is_block()     { [[ "$STOPOUT" == *'"decision": "block"'* || "$STOPOUT" == *'"decision":"block"'* ]]; }

P=$(mkproj adv py); SINK="$TMP_ROOT/adv.jsonl"
run_stop "$P" false "$SINK"
if has_advisory && ! is_block; then
  ok "code-changed-no-verification" "advisory, not a block"
else
  bad "code-changed-no-verification" "out=$STOPOUT"
fi
[[ $STOPRC -eq 0 ]] && ok "advisory-exit-0" || bad "advisory-exit-0" "rc=$STOPRC"

FIRED=$(S="$SINK" python3 -c '
import json, os
n = 0
for line in open(os.environ["S"], encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    r = json.loads(line)
    if (r.get("event") == "unverified_session" and r.get("guard") == "verify-observed"
            and r.get("hook") == "session-quality-gate.py" and r.get("decision") == "advisory"):
        n += 1
print(n)')
if [[ "$FIRED" == "1" ]]; then
  ok "advisory-firing-recorded" "one registry-countable record"
else
  bad "advisory-firing-recorded" "count=$FIRED"
fi

P=$(mkproj verified py); SINK="$TMP_ROOT/verified.jsonl"
observe "pytest -q" "$SINK" Bash sess-A >/dev/null
run_stop "$P" false "$SINK" sess-A
if ! has_advisory; then
  ok "verification-observed-silent"
else
  bad "verification-observed-silent" "out=$STOPOUT"
fi

P=$(mkproj docsonly md); SINK="$TMP_ROOT/docs.jsonl"
run_stop "$P" false "$SINK"
if ! has_advisory; then
  ok "docs-only-change-silent"
else
  bad "docs-only-change-silent" "out=$STOPOUT"
fi

P="$TMP_ROOT/nochange"; mkdir -p "$P"; git -C "$P" init --quiet >/dev/null 2>&1
SINK="$TMP_ROOT/nochange.jsonl"
run_stop "$P" false "$SINK"
if ! has_advisory; then
  ok "no-change-silent"
else
  bad "no-change-silent" "out=$STOPOUT"
fi

echo
echo "=== D. observe-by-default: block ONLY under explicit opt-in ==="
P=$(mkproj noblock py); SINK="$TMP_ROOT/noblock.jsonl"
run_stop "$P" false "$SINK" sess-A
if ! is_block; then
  ok "default-never-blocks" "no decision field without the opt-in"
else
  bad "default-never-blocks" "out=$STOPOUT"
fi

P=$(mkproj optin py); SINK="$TMP_ROOT/optin.jsonl"
run_stop "$P" false "$SINK" sess-A AGENT_VERIFY_OBSERVER_BLOCK=1
if is_block && [[ "$STOPOUT" == *"WHY:"* && "$STOPOUT" == *"FIX:"* ]]; then
  ok "optin-blocks-with-teaching-tags"
else
  bad "optin-blocks-with-teaching-tags" "out=$STOPOUT"
fi
[[ $STOPRC -eq 0 ]] && ok "optin-block-exit-0" || bad "optin-block-exit-0" "rc=$STOPRC"

BLOCKED=$(S="$TMP_ROOT/optin.jsonl" python3 -c '
import json, os
n = 0
for line in open(os.environ["S"], encoding="utf-8"):
    line = line.strip()
    if line and json.loads(line).get("decision") == "blocked":
        n += 1
print(n)')
if [[ "$BLOCKED" == "1" ]]; then
  ok "block-firing-recorded" "decision=blocked"
else
  bad "block-firing-recorded" "count=$BLOCKED"
fi

P=$(mkproj antiloop py); SINK="$TMP_ROOT/antiloop.jsonl"
run_stop "$P" true "$SINK" sess-A AGENT_VERIFY_OBSERVER_BLOCK=1
if ! is_block; then
  ok "second-stop-passes" "anti-loop honored even with the opt-in"
else
  bad "second-stop-passes" "out=$STOPOUT"
fi

echo
echo "=== E. session scoping — another session's record does not count ==="
P=$(mkproj scoped py); SINK="$TMP_ROOT/scoped.jsonl"
observe "pytest -q" "$SINK" Bash sess-OTHER >/dev/null
run_stop "$P" false "$SINK" sess-A
if has_advisory; then
  ok "other-session-record-ignored"
else
  bad "other-session-record-ignored" "out=$STOPOUT"
fi

echo
echo "=== F. mutation probes — the advisory condition must be load-bearing ==="
mutate() {  # mutate <name> <find> <replace> <src> -> mutant path, or "" on miss
  local name="$1" find="$2" repl="$3" src="$4"
  local out="$TMP_ROOT/mutant-$name.py"
  if FIND="$find" REPL="$repl" SRC="$src" DST="$out" python3 -c '
import os, sys
src = open(os.environ["SRC"], encoding="utf-8").read()
if os.environ["FIND"] not in src:
    sys.exit(1)
open(os.environ["DST"], "w", encoding="utf-8").write(
    src.replace(os.environ["FIND"], os.environ["REPL"], 1))
'; then echo "$out"; else echo ""; fi
}

M1=$(mutate always-verified 'if session_ran_verification(root, session_id):' 'if True:' "$GATE")
if [[ -z "$M1" ]]; then
  bad "mutation/anchor-session-check" "anchor missing — probe is inert"
else
  ok "mutation/anchor-session-check"
  P=$(mkproj mut1 py)
  STOPOUT=$(printf '%s' "$(stop_event "$P" false sess-A)" \
    | AGENT_VERIFY_OBSERVED_SINK="$TMP_ROOT/mut1.jsonl" python3 "$M1" 2>/dev/null)
  if ! has_advisory; then
    ok "mutation/session-check-detected" "forcing 'already verified' removes the advisory"
  else
    bad "mutation/session-check-detected" "advisory survived the mutation"
  fi
fi

echo
echo "=== G. writer/reader convergence — the DEFAULT sink path, no override ==="
# Every other check passes AGENT_VERIFY_OBSERVED_SINK, so the default path
# construction (observer SINK_NAME vs gate VERIFY_SINK_NAME) was never exercised
# end to end: renaming either constant would silently degrade the feature to
# "always advisory" in real sessions while the battery stayed green.
CONV="$(mkproj conv)"
printf '%s' "$(post_event 'pytest -q' Bash sess-conv "$CONV")" \
  | (cd "$CONV" && AGENT_REPRODUCE_TEST=1 python3 "$OBSERVER" >/dev/null 2>&1)
DEFAULT_SINK="$CONV/.agent/logs/verify-observed.jsonl"
if [[ -f "$DEFAULT_SINK" ]]; then
  ok "default-sink/writer-lands-in-project" ".agent/logs under the event cwd"
else
  bad "default-sink/writer-lands-in-project" "no sink at $DEFAULT_SINK"
fi
# ...and the reader must find THAT file with no override either: the advisory
# must be absent because the writer's record satisfied it.
OUT=$(printf '%s' "$(stop_event "$CONV" false sess-conv)" \
  | (cd "$CONV" && python3 "$GATE" 2>&1))
if ! printf '%s' "$OUT" | grep -q "no verification"; then
  ok "default-sink/reader-reads-same-file" "record suppresses the advisory"
else
  bad "default-sink/reader-reads-same-file" "reader missed the writer's record"
fi
# Control: without the record the same fixture DOES advise — proves the check
# above is not passing merely because the advisory never fires here.
CONV2="$(mkproj conv2)"
OUT=$(printf '%s' "$(stop_event "$CONV2" false sess-conv2)" \
  | (cd "$CONV2" && python3 "$GATE" 2>&1))
if printf '%s' "$OUT" | grep -q "no verification"; then
  ok "default-sink/control-advises" "same path, no record -> advisory fires"
else
  bad "default-sink/control-advises" "advisory silent even with no record"
fi

echo
echo "=== G2. a non-regular sink must never hang a hook (no env var needed) ==="
# Measured 2026-07-30: `open(sink, "a")` blocks forever on a reader-less FIFO,
# and the DEFAULT sink path reaches it with no environment variable — a project
# shipping a FIFO at .agent/logs/verify-observed.jsonl hung every Bash call
# (writer) and the Stop hook itself (reader), so the session could not end.
# `timeout` is the assertion: rc=124 means the hang is back.
FIFO_ROOT="$(mkproj fifo)"
mkdir -p "$FIFO_ROOT/.agent/logs"
mkfifo "$FIFO_ROOT/.agent/logs/verify-observed.jsonl"
printf '%s' "$(post_event 'pytest -q' Bash sess-fifo "$FIFO_ROOT")" \
  | timeout 10 python3 "$OBSERVER" >/dev/null 2>&1
RC=$?
if [[ $RC -ne 124 ]]; then
  ok "fifo/writer-does-not-hang" "rc=$RC"
else
  bad "fifo/writer-does-not-hang" "TIMED OUT — blocking open regressed"
fi
printf '%s' "$(stop_event "$FIFO_ROOT" false sess-fifo)" \
  | timeout 10 python3 "$GATE" >/dev/null 2>&1
RC=$?
if [[ $RC -ne 124 ]]; then
  ok "fifo/reader-does-not-hang" "rc=$RC"
else
  bad "fifo/reader-does-not-hang" "TIMED OUT — Stop hook cannot end the session"
fi
# A character device must not be read forever either.
printf '%s' "$(post_event 'pytest -q' Bash sess-dev)" \
  | AGENT_VERIFY_OBSERVED_SINK=/dev/zero timeout 10 python3 "$OBSERVER" >/dev/null 2>&1
RC=$?
if [[ $RC -ne 124 ]]; then
  ok "chardev/writer-does-not-hang" "rc=$RC"
else
  bad "chardev/writer-does-not-hang" "TIMED OUT"
fi
# ...and the FIFO must not be silently treated as a valid record store: the
# advisory must still fire, because nothing was actually recorded.
OUT=$(printf '%s' "$(stop_event "$FIFO_ROOT" false sess-fifo)" \
  | timeout 10 python3 "$GATE" 2>&1)
if printf '%s' "$OUT" | grep -q "no verification"; then
  ok "fifo/fails-closed-to-advisory" "unwritable sink != verified"
else
  bad "fifo/fails-closed-to-advisory" "silently treated as verified"
fi

echo
echo "=== G3. confinement returns the RESOLVED path; tail read respects the boundary ==="
# Both found by a security lane.
# F3: confinement was decided on the realpath but the UNRESOLVED override string
#     was returned, so the symlink was re-opened later — a swap between check and
#     open could redirect the write (S_ISREG rejects device nodes, not locations).
# F5: the partial-line drop fired whenever the file exceeded the tail window,
#     even when the window happened to start exactly on a line boundary, throwing
#     away a whole valid record.
SEC=$(SRC="$OBSERVER" GT="$GATE" python3 -c '
import importlib.util, json, os, tempfile
def load(n, p):
    spec = importlib.util.spec_from_file_location(n, p)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod
obs = load("obs", os.environ["SRC"])
gate = load("gate", os.environ["GT"])
root = tempfile.mkdtemp()
logs = os.path.join(root, ".agent", "logs")
os.makedirs(logs)
real = os.path.join(logs, "real.jsonl")
open(real, "w").close()
link = os.path.join(logs, "link.jsonl")
os.symlink(real, link)
os.environ["AGENT_VERIFY_OBSERVED_SINK"] = link
w_resolved = os.path.basename(obs.resolve_sink(root)) == "real.jsonl"
r_resolved = os.path.basename(gate.verify_sink_path(root)) == "real.jsonl"
del os.environ["AGENT_VERIFY_OBSERVED_SINK"]
# Build a sink whose tail window starts exactly on a line boundary, with the
# only session record as the final line.
sink = os.path.join(logs, gate.VERIFY_SINK_NAME)
rec = json.dumps({"event": "verification_invoked", "session_id": "S"})
pad = json.dumps({"event": "pad", "x": "y" * 80})
with open(sink, "w") as fh:
    n = 0
    while n < gate._SINK_TAIL_BYTES - len(rec) - 1:
        fh.write(pad + "\n")
        n += len(pad) + 1
    fh.write(rec + "\n")
oversized = os.path.getsize(sink) > gate._SINK_TAIL_BYTES
found = gate.session_ran_verification(root, "S")
print(f"{int(w_resolved)}{int(r_resolved)}{int(oversized)}{int(found)}")
')
[[ "${SEC:0:1}" == "1" ]] && ok "resolved-path/writer" "symlink resolved before return" \
                          || bad "resolved-path/writer" "returned the unresolved override"
[[ "${SEC:1:1}" == "1" ]] && ok "resolved-path/reader" "symlink resolved before return" \
                          || bad "resolved-path/reader" "returned the unresolved override"
[[ "${SEC:2:1}" == "1" ]] && ok "tail-boundary/fixture-oversized" "sink exceeds the tail window" \
                          || bad "tail-boundary/fixture-oversized" "fixture too small — check is vacuous"
[[ "${SEC:3:1}" == "1" ]] && ok "tail-boundary/record-survives" "boundary-aligned record not dropped" \
                          || bad "tail-boundary/record-survives" "valid record discarded as partial"

echo
echo "=== H. confinement parity — writer and reader must agree on every path ==="
# resolve_sink() (writer) and verify_sink_path() (reader) are byte-identical
# confinement logic in two files, kept in sync by comment discipline. If they
# ever disagree, records land somewhere the reader will not look. Assert the
# accept/reject decision matches for adversarial paths.
PARITY_ROOT="$(mkproj parity)"
mkdir -p "$PARITY_ROOT/.agent/logs"
for cand in "$PARITY_ROOT/.agent/logs/ok.jsonl" \
            "$PARITY_ROOT/.agent/logs/../../escape.jsonl" \
            "$PARITY_ROOT/.agent/logs/sub/deep.jsonl" \
            "${TMPDIR:-/tmp}/tmp-ok.jsonl" \
            "/etc/passwd" \
            "$HOME/.claude/settings.json" \
            "$PARITY_ROOT/notlogs.jsonl"; do
  RES=$(OBS="$OBSERVER" GT="$GATE" R="$PARITY_ROOT" C="$cand" python3 -c '
import importlib.util, os, sys
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod
os.environ["AGENT_VERIFY_OBSERVED_SINK"] = os.environ["C"]
w = load("obs", os.environ["OBS"])
g = load("gate", os.environ["GT"])
root = os.environ["R"]
# accepted == the resolver returned the override rather than the default
wa = w.resolve_sink(root) == os.environ["C"]
ga = g.verify_sink_path(root) == os.environ["C"]
print("MATCH" if wa == ga else "DIVERGE", "accepted" if wa else "rejected")
' 2>&1)
  case "$RES" in
    MATCH*) ok "confinement-parity" "$(basename "$cand") -> ${RES#MATCH }" ;;
    *)      bad "confinement-parity" "$cand -> $RES" ;;
  esac
done

echo
M2=$(mutate no-code-filter 'if pattern.match(invocation):' 'if False:' "$OBSERVER")
if [[ -z "$M2" ]]; then
  bad "mutation/anchor-family-match" "anchor missing — probe is inert"
else
  ok "mutation/anchor-family-match"
  SINK="$TMP_ROOT/mut2.jsonl"
  printf '%s' "$(post_event 'pytest -q')" | AGENT_VERIFY_OBSERVED_SINK="$SINK" \
    python3 "$M2" >/dev/null 2>&1 || true
  if [[ -z "$(sink_families "$SINK")" ]]; then
    ok "mutation/family-match-detected" "disabling the matcher stops all recording"
  else
    bad "mutation/family-match-detected" "still recorded after mutation"
  fi
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
