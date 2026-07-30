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

post_event() {  # post_event <command> [tool] — canonical PostToolUse JSON
  CMD="$1" TOOL="${2:-Bash}" SID="${3:-sess-A}" python3 -c '
import os, json
print(json.dumps({
    "ai": "claude-code", "event": "PostToolUse", "session_id": os.environ["SID"],
    "tool_name": os.environ["TOOL"], "tool_input": {"command": os.environ["CMD"]},
    "tool_response": {"stdout": "", "stderr": ""}, "cwd": "/tmp",
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
for cmd in "git checkout main" \
           "cat test.txt" \
           "echo hello world" \
           "ls -la testing/" \
           "grep -rn build src/"; do
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

M2=$(mutate no-code-filter 'if pattern.search(command):' 'if False:' "$OBSERVER")
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
