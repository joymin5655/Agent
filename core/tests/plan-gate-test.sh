#!/usr/bin/env bash
# plan-gate-test.sh — verify core/hooks/plan-gate.py (P1-3 — this hook had no test).
#
# plan-gate.py is a PostToolUse hook: on ExitPlanMode, or a plan-class Agent/Task
# dispatch, it writes the approval flag that spec-gate.py later reads. Every case
# points AGENT_PLAN_FLAG at a throwaway file so the live session flag is untouched.
#
# Covers:
#   ExitPlanMode                         -> flag written
#   Agent subagent_type=Plan             -> flag written
#   Agent description keyword (design)   -> flag written
#   Agent description keyword (Korean)   -> flag written
#   Agent non-plan (subagent_type=code)  -> flag NOT written
#   non-plan tool (Write)                -> flag NOT written
#   malformed stdin                      -> no crash, flag NOT written, exit 0
#   W-8 source-first: ExitPlanMode plan that cites only memory (no file:line /
#   command-output evidence) -> flag withheld + re-verify notice; with evidence,
#   or with no memory citation (incl. "memory leak" prose) -> flag written
#   AG10: per-session withheld markers (<flag>.withheld.d/<sid>) - isolation, unsafe
#   session ids, legacy single-marker compat, stale pruning
#
# Usage: bash core/tests/plan-gate-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/core/hooks/plan-gate.py"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# run_case <name> <event-json> <expect: written|absent>
run_case() {
  local name="$1" event="$2" expect="$3"
  local flag="$TMP_DIR/flag-$name"
  rm -f "$flag"
  printf '%s' "$event" | AGENT_PLAN_FLAG="$flag" python3 "$HOOK" >/dev/null 2>&1
  local rc=$?
  local got="absent"
  [[ -f "$flag" ]] && got="written"
  if [[ $rc -eq 0 && "$got" == "$expect" ]]; then
    echo "  ok   [$name] ($got)"; PASS=$((PASS + 1))
  else
    echo "  FAIL [$name] expected=$expect got=$got rc=$rc"; FAIL=$((FAIL + 1))
  fi
}

echo "=== flag written on plan approval ==="
run_case "exitplanmode-writes" \
  '{"event":"PostToolUse","tool_name":"ExitPlanMode","tool_input":{}}' written
run_case "agent-plan-subtype-writes" \
  '{"event":"PostToolUse","tool_name":"Agent","tool_input":{"subagent_type":"Plan"}}' written
run_case "agent-design-keyword-writes" \
  '{"event":"PostToolUse","tool_name":"Task","tool_input":{"subagent_type":"general-purpose","description":"design the auth architecture"}}' written
run_case "agent-korean-keyword-writes" \
  '{"event":"PostToolUse","tool_name":"Agent","tool_input":{"description":"결제 모듈 설계"}}' written

echo
echo "=== flag NOT written for non-plan events ==="
run_case "agent-nonplan-absent" \
  '{"event":"PostToolUse","tool_name":"Agent","tool_input":{"subagent_type":"code-reviewer","description":"review this diff"}}' absent
run_case "write-tool-absent" \
  '{"event":"PostToolUse","tool_name":"Write","tool_input":{"file_path":"src/x.ts","content":"x"}}' absent

echo
echo "=== W-8 source-first verification (ExitPlanMode plan text) ==="
# plan_event <plan-text> -> ExitPlanMode event JSON carrying tool_input.plan
plan_event() {
  PLAN="$1" python3 -c 'import json,os;print(json.dumps({"event":"PostToolUse","tool_name":"ExitPlanMode","tool_input":{"plan":os.environ["PLAN"]}}))'
}
run_case "w8-memory-only-withheld" \
  "$(plan_event $'Plan\nPer memory, the retry limit is 3 in config.py. Raise it to 5.')" absent
run_case "w8-memory-korean-only-withheld" \
  "$(plan_event $'계획\n메모리에 따르면 훅은 PreToolUse 에서 돈다. 그대로 수정.')" absent
run_case "w8-memory-with-fileline-written" \
  "$(plan_event $'Plan\nPer memory, retry limit is 3 (verified at core/config.py:42). Raise it.')" written
run_case "w8-memory-with-cmd-output-written" \
  "$(plan_event $'Plan\nFrom memory: tests pass. Re-checked live:\n```\n$ pytest -q\n12 passed\n```')" written
run_case "w8-no-memory-claim-written" \
  "$(plan_event $'Plan\nAdd a retry wrapper around the fetch call.')" written
run_case "w8-memory-leak-prose-written" \
  "$(plan_event $'Plan\nFix the memory leak in the cache layer and cut memory usage.')" written
run_case "w8-no-plan-text-written" \
  '{"event":"PostToolUse","tool_name":"ExitPlanMode","tool_input":{}}' written

# plan_event_sid <session_id> <plan-text>
plan_event_sid() {
  SID="$1" PLAN="$2" python3 -c 'import json,os;print(json.dumps({"event":"PostToolUse","session_id":os.environ["SID"],"tool_name":"ExitPlanMode","tool_input":{"plan":os.environ["PLAN"]}}))'
}
MEM_ONLY=$'Plan\nI recall that the limit is 3.'
OK_PLAN=$'Plan\nPer memory, limit is 3 (checked core/config.py:42).'

# negative evidence fixtures: a memory citation + look-alike "evidence" -> withheld
for fx in 'host example.com:443' 'url https://example.com:8080/x' 'ver v1.2:3'; do
  name="w8-badevidence-$(printf '%s' "$fx" | tr -c 'A-Za-z0-9' '-')"
  run_case "$name" "$(plan_event "$(printf 'Plan\nPer memory it works. %s' "$fx")")" absent
done
run_case "w8-bare-dollar-no-fence-withheld" \
  "$(plan_event $'Plan\nPer memory it works.\n$ pytest -q\n12 passed')" absent
run_case "w8-fence-dollar-no-output-withheld" \
  "$(plan_event $'Plan\nPer memory it works.\n```\n$ pytest -q\n```')" absent
run_case "w8-fence-dollar-output-written" \
  "$(plan_event $'Plan\nPer memory it works.\n```\n$ pytest -q\n12 passed\n```')" written
run_case "w8-slash-path-line-written" \
  "$(plan_event 'Plan: per memory X. See docs/a/notes:12')" written

# memory false-positive fixtures -> flag written
for fx in 'Read from memory instead of disk.' 'Tune based on memory pressure.' \
          'Allocate from memory pool.' 'We shall recall the handler later; I remember nothing.'; do
  name="w8-memfp-$(printf '%s' "$fx" | tr -c 'A-Za-z0-9' '-' | cut -c1-30)"
  run_case "$name" "$(plan_event "$(printf 'Plan\n%s' "$fx")")" written
done

# non-dict tool_input / non-dict event -> no crash, exit 0
for ev in '{"tool_name":"ExitPlanMode","tool_input":"oops"}' '{"tool_name":"Agent","tool_input":[1]}' '[1,2]' 'null'; do
  printf '%s' "$ev" | AGENT_PLAN_FLAG="$TMP_DIR/flag-nd" python3 "$HOOK" >/dev/null 2>&1
  check "nondict-no-crash-$(printf '%s' "$ev" | cut -c1-24 | tr -c 'A-Za-z0-9' '-')" $?
done

# session scoping: B's withhold keeps A's flag; same-session withhold clears own
FLAG_S="$TMP_DIR/flag-sess"
rm -rf "$FLAG_S" "$FLAG_S.withheld" "$FLAG_S.withheld.d"
plan_event_sid sessA "$OK_PLAN" | AGENT_PLAN_FLAG="$FLAG_S" python3 "$HOOK" >/dev/null
OUT_B="$(plan_event_sid sessB "$MEM_ONLY" | AGENT_PLAN_FLAG="$FLAG_S" python3 "$HOOK")"
[[ -f "$FLAG_S" && "$OUT_B" == *"another session"* ]]
check "w8-other-session-flag-preserved-and-honest-notice" $?
plan_event_sid sessA "$MEM_ONLY" | AGENT_PLAN_FLAG="$FLAG_S" python3 "$HOOK" >/dev/null
[[ ! -f "$FLAG_S" ]]
check "w8-own-session-flag-cleared" $?

# Agent path stays shut for the withholding session, open for others, reopened by a good plan
agent_ev() { printf '{"event":"PostToolUse","session_id":"%s","tool_name":"Agent","tool_input":{"subagent_type":"Plan"}}' "$1"; }
agent_ev sessA | AGENT_PLAN_FLAG="$FLAG_S" python3 "$HOOK" >/dev/null
[[ ! -f "$FLAG_S" ]]
check "w8-agent-path-blocked-same-session" $?
agent_ev sessC | AGENT_PLAN_FLAG="$FLAG_S" python3 "$HOOK" >/dev/null
[[ -f "$FLAG_S" ]]
check "w8-agent-path-open-other-session" $?
rm -f "$FLAG_S"
plan_event_sid sessA "$OK_PLAN" | AGENT_PLAN_FLAG="$FLAG_S" python3 "$HOOK" >/dev/null
rm -f "$FLAG_S"
agent_ev sessA | AGENT_PLAN_FLAG="$FLAG_S" python3 "$HOOK" >/dev/null
[[ -f "$FLAG_S" ]]
check "w8-agent-path-reopened-after-good-plan" $?

# --- AG10: per-session withheld markers (<flag>.withheld.d/<sid>) ---
FLAG_W="$TMP_DIR/flag-w"
rm -rf "$FLAG_W" "$FLAG_W.withheld" "$FLAG_W.withheld.d"
hook_w() { AGENT_PLAN_FLAG="$FLAG_W" python3 "$HOOK"; }
plan_event_sid wsA "$MEM_ONLY" | hook_w >/dev/null
plan_event_sid wsB "$MEM_ONLY" | hook_w >/dev/null
[[ -f "$FLAG_W.withheld.d/wsA" && -f "$FLAG_W.withheld.d/wsB" && ! -e "$FLAG_W.withheld" ]]
check "ag10-two-sessions-two-markers" $?
agent_ev wsA | hook_w >/dev/null
[[ ! -f "$FLAG_W" ]]
check "ag10-A-agent-path-blocked-after-B-withheld" $?
# B passes a good plan: only B's marker goes; A stays shut
plan_event_sid wsB "$OK_PLAN" | hook_w >/dev/null
[[ ! -e "$FLAG_W.withheld.d/wsB" && -f "$FLAG_W.withheld.d/wsA" ]]
check "ag10-clear-B-keeps-A-marker" $?
rm -f "$FLAG_W"
agent_ev wsA | hook_w >/dev/null
[[ ! -f "$FLAG_W" ]]
check "ag10-A-still-blocked-after-B-cleared" $?
agent_ev wsB | hook_w >/dev/null
[[ -f "$FLAG_W" ]]
check "ag10-B-agent-path-open-after-clear" $?

# unsafe session ids: no path escape, legacy single marker + notice, still blocks
rm -rf "$FLAG_W" "$FLAG_W.withheld" "$FLAG_W.withheld.d" "$TMP_DIR/escape"
for bad in '../escape' 'a/b' '..' '.hidden' 'a b'; do
  OUT_U="$(plan_event_sid "$bad" "$MEM_ONLY" | hook_w)"
  [[ "$OUT_U" == *"not filename-safe"* && "$(cat "$FLAG_W.withheld")" == "$bad" \
     && ! -e "$TMP_DIR/escape" && ! -e "$FLAG_W.withheld.d/$bad" ]]
  check "ag10-unsafe-sid-rejected-$(printf '%s' "$bad" | tr -c 'A-Za-z0-9' '-')" $?
  agent_ev "$bad" | hook_w >/dev/null
  [[ ! -f "$FLAG_W" ]]
  check "ag10-unsafe-sid-still-blocked-$(printf '%s' "$bad" | tr -c 'A-Za-z0-9' '-')" $?
  plan_event_sid "$bad" "$OK_PLAN" | hook_w >/dev/null
  [[ ! -e "$FLAG_W.withheld" ]]
  check "ag10-unsafe-sid-cleared-$(printf '%s' "$bad" | tr -c 'A-Za-z0-9' '-')" $?
  rm -f "$FLAG_W"
done

# legacy single marker is honoured, cleared by its own session, and migrated
rm -rf "$FLAG_W" "$FLAG_W.withheld" "$FLAG_W.withheld.d"
printf 'oldA' > "$FLAG_W.withheld"
agent_ev oldA | hook_w >/dev/null
[[ ! -f "$FLAG_W" ]]
check "ag10-legacy-marker-blocks-its-session" $?
agent_ev oldC | hook_w >/dev/null
[[ -f "$FLAG_W" ]]
check "ag10-legacy-marker-ignores-other-session" $?
rm -f "$FLAG_W"
plan_event_sid newB "$MEM_ONLY" | hook_w >/dev/null
[[ -f "$FLAG_W.withheld.d/oldA" && -f "$FLAG_W.withheld.d/newB" && "$(cat "$FLAG_W.withheld")" == "oldA" ]]
check "ag10-legacy-copied-not-deleted-not-overwritten" $?
# an older plugin scope's hook still reads the single slot (old marker_session semantics)
python3 - "$FLAG_W.withheld" <<'PY'
import pathlib, sys
sys.exit(0 if pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").strip() == "oldA" else 1)
PY
check "ag10-old-hook-fixture-still-reads-legacy" $?
agent_ev oldA | hook_w >/dev/null
[[ ! -f "$FLAG_W" ]]
check "ag10-migrated-session-still-blocked" $?
printf 'oldD' > "$FLAG_W.withheld"
plan_event_sid oldD "$OK_PLAN" | hook_w >/dev/null
[[ ! -e "$FLAG_W.withheld" ]]
check "ag10-legacy-cleared-by-good-plan" $?

# --- AG10 review follow-ups: symlinks, unusable dirs, fail-open, TTL, claim ---
# set_age <path> <seconds>: portable mtime backdating (BSD touch has no -d)
set_age() { python3 -c 'import os,sys,time;t=time.time()-float(sys.argv[2]);os.utime(sys.argv[1],(t,t),follow_symlinks=False)' "$1" "$2"; }
# fingerprint <path>: size+mtime_ns, "none" if absent
fingerprint() { python3 -c 'import os,sys
try:
    st=os.stat(sys.argv[1]);print(st.st_size,st.st_mtime_ns)
except OSError:
    print("none")' "$1"; }
reset_w() { chmod -R u+rwx "$FLAG_W.withheld.d" 2>/dev/null; rm -rf "$FLAG_W" "$FLAG_W.withheld" "$FLAG_W.withheld.d" "$FLAG_W".withheld.claim.* "$TMP_DIR/victim" "$TMP_DIR/victim2"; }
DAY=86400

# stale pruning: 7d TTL, an idle-for-25h session keeps its marker
reset_w
mkdir -m 700 "$FLAG_W.withheld.d"
printf 'x' > "$FLAG_W.withheld.d/staleS"; set_age "$FLAG_W.withheld.d/staleS" $((8 * DAY))
printf 'x' > "$FLAG_W.withheld.d/idle25h"; set_age "$FLAG_W.withheld.d/idle25h" $((25 * 3600))
printf 'x' > "$FLAG_W.withheld.d/freshS"
OUT_P="$(plan_event_sid wsN "$MEM_ONLY" | hook_w)"
[[ ! -e "$FLAG_W.withheld.d/staleS" && -f "$FLAG_W.withheld.d/idle25h" \
   && -f "$FLAG_W.withheld.d/freshS" && -f "$FLAG_W.withheld.d/wsN" ]]
check "ag10-ttl-7d-prunes-8d-keeps-25h" $?
[[ "$OUT_P" == *"Pruned 1 withheld marker"* ]]
check "ag10-prune-emits-notice" $?
agent_ev idle25h | hook_w >/dev/null
[[ ! -f "$FLAG_W" ]]
check "ag10-25h-idle-session-still-blocked" $?

# any plan-gate event for the session refreshes its mtime (keep-alive)
set_age "$FLAG_W.withheld.d/idle25h" $((6 * DAY))
agent_ev idle25h | hook_w >/dev/null
python3 -c 'import os,sys,time;sys.exit(0 if time.time()-os.stat(sys.argv[1]).st_mtime<3600 else 1)' "$FLAG_W.withheld.d/idle25h"
check "ag10-agent-event-refreshes-mtime" $?
set_age "$FLAG_W.withheld.d/wsN" $((6 * DAY))
plan_event_sid wsN "$MEM_ONLY" | hook_w >/dev/null
python3 -c 'import os,sys,time;sys.exit(0 if time.time()-os.stat(sys.argv[1]).st_mtime<3600 else 1)' "$FLAG_W.withheld.d/wsN"
check "ag10-withhold-event-refreshes-mtime" $?

# prune never follows symlink entries and leaves non-regular entries alone
reset_w
mkdir -m 700 "$FLAG_W.withheld.d" "$TMP_DIR/victim"
printf 'precious' > "$TMP_DIR/victim/target"; set_age "$TMP_DIR/victim/target" $((30 * DAY))
ln -s "$TMP_DIR/victim/target" "$FLAG_W.withheld.d/linkS"
FP_T="$(fingerprint "$TMP_DIR/victim/target")"
plan_event_sid wsN "$MEM_ONLY" | hook_w >/dev/null
[[ -L "$FLAG_W.withheld.d/linkS" && "$(fingerprint "$TMP_DIR/victim/target")" == "$FP_T" ]]
check "ag10-prune-skips-symlink-entries" $?

# marker dir is a planted symlink -> target untouched, notice, legacy fallback still blocks
reset_w
mkdir -m 700 "$TMP_DIR/victim"
printf 'precious' > "$TMP_DIR/victim/oldfile"; set_age "$TMP_DIR/victim/oldfile" $((30 * DAY))
ln -s "$TMP_DIR/victim" "$FLAG_W.withheld.d"
FP_V="$(fingerprint "$TMP_DIR/victim/oldfile")"
OUT_L="$(plan_event_sid symS "$MEM_ONLY" | hook_w)"
[[ "$(fingerprint "$TMP_DIR/victim/oldfile")" == "$FP_V" && ! -e "$TMP_DIR/victim/symS" \
   && "$(ls "$TMP_DIR/victim" | wc -l | tr -d ' ')" == "1" ]]
check "ag10-symlink-dir-target-untouched" $?
[[ "$OUT_L" == *"marker dir unusable"* && "$OUT_L" == *"fell back"* \
   && "$(cat "$FLAG_W.withheld")" == "symS" ]]
check "ag10-symlink-dir-notice-and-legacy-fallback" $?
agent_ev symS | hook_w >/dev/null
[[ ! -f "$FLAG_W" ]]
check "ag10-symlink-dir-session-still-blocked" $?

# marker dir is a regular file / world-writable / foreign-owned / read-only
for kind in file wwrite foreign ro; do
  reset_w
  case "$kind" in
    file)   printf 'x' > "$FLAG_W.withheld.d" ;;
    wwrite) mkdir "$FLAG_W.withheld.d"; chmod 0777 "$FLAG_W.withheld.d" ;;
    foreign)
      if [[ "$(id -u)" -ne 0 ]]; then echo "  skip [ag10-dir-$kind] (needs root to chown)"; continue; fi
      mkdir -m 700 "$FLAG_W.withheld.d"; chown 65534 "$FLAG_W.withheld.d" ;;
    ro)
      if [[ "$(id -u)" -eq 0 ]]; then echo "  skip [ag10-dir-$kind] (root bypasses mode bits)"; continue; fi
      mkdir -m 500 "$FLAG_W.withheld.d" ;;
  esac
  OUT_K="$(plan_event_sid kindS "$MEM_ONLY" | hook_w)"
  [[ "$OUT_K" == *"fell back"* || "$OUT_K" == *"not recorded"* ]]
  check "ag10-dir-$kind-notice-not-silent-success" $?
  [[ ! -e "$FLAG_W.withheld.d/kindS" ]]
  check "ag10-dir-$kind-no-marker-inside" $?
  agent_ev kindS | hook_w >/dev/null
  [[ ! -f "$FLAG_W" ]]
  check "ag10-dir-$kind-session-still-blocked" $?
done

# planted <dir>/<sid> symlink is not followed
reset_w
mkdir -m 700 "$FLAG_W.withheld.d" "$TMP_DIR/victim"
printf 'precious' > "$TMP_DIR/victim/target"; set_age "$TMP_DIR/victim/target" $((30 * DAY))
ln -s "$TMP_DIR/victim/target" "$FLAG_W.withheld.d/linkSid"
FP_T="$(fingerprint "$TMP_DIR/victim/target")"
OUT_S="$(plan_event_sid linkSid "$MEM_ONLY" | hook_w)"
[[ "$(fingerprint "$TMP_DIR/victim/target")" == "$FP_T" && "$OUT_S" == *"write failed"* ]]
check "ag10-planted-sid-symlink-not-followed-notice" $?
agent_ev linkSid | hook_w >/dev/null
[[ ! -f "$FLAG_W" ]]
check "ag10-planted-sid-symlink-session-blocked-via-legacy" $?

# write failure everywhere: reported as not recorded, never as success
reset_w
mkdir -m 700 "$FLAG_W.withheld.d" "$FLAG_W.withheld.d/failS" "$FLAG_W.withheld"
OUT_N="$(plan_event_sid failS "$MEM_ONLY" | hook_w)"; RC_N=$?
[[ $RC_N -eq 0 && "$OUT_N" == *"Withheld marker not recorded"* && "$OUT_N" != *"fell back"* ]]
check "ag10-write-failure-everywhere-says-not-recorded" $?
rmdir "$FLAG_W.withheld" "$FLAG_W.withheld.d/failS"

# planted legacy symlink / FIFO is not followed or blocked on
reset_w
printf 'precious' > "$TMP_DIR/victim-file"; FP_F="$(fingerprint "$TMP_DIR/victim-file")"
ln -s "$TMP_DIR/victim-file" "$FLAG_W.withheld"
plan_event_sid ../bad "$MEM_ONLY" | hook_w >/dev/null
[[ "$(fingerprint "$TMP_DIR/victim-file")" == "$FP_F" ]]
check "ag10-legacy-symlink-not-followed" $?
rm -f "$FLAG_W.withheld" "$FLAG_W"; mkfifo "$FLAG_W.withheld"
# portable timeout (macOS has no GNU timeout): subprocess.run(timeout=) fails on a hang
agent_ev fifoS | AGENT_PLAN_FLAG="$FLAG_W" python3 -c '
import subprocess, sys
try:
    subprocess.run([sys.executable, sys.argv[1]], stdin=sys.stdin, stdout=subprocess.DEVNULL, timeout=10)
except subprocess.TimeoutExpired:
    sys.exit(1)
' "$HOOK"
check "ag10-legacy-fifo-does-not-hang" $?
rm -f "$FLAG_W.withheld"

# legacy claim: a non-matching session never removes someone else's slot
reset_w
printf 'ownerX' > "$FLAG_W.withheld"
plan_event_sid otherY "$OK_PLAN" | hook_w >/dev/null
[[ "$(cat "$FLAG_W.withheld")" == "ownerX" ]] && ! compgen -G "$FLAG_W.withheld.claim.*" >/dev/null
check "ag10-legacy-claim-restores-foreign-slot-no-leftover" $?
plan_event_sid ownerX "$OK_PLAN" | hook_w >/dev/null
[[ ! -e "$FLAG_W.withheld" ]] && ! compgen -G "$FLAG_W.withheld.claim.*" >/dev/null
check "ag10-legacy-claim-deletes-own-slot" $?

# D1: a hard link planted at the legacy slot must not get a victim-owned file truncated
reset_w
printf 'precious' > "$TMP_DIR/victim2"; ln "$TMP_DIR/victim2" "$FLAG_W.withheld"
OUT_H="$(plan_event_sid ../x "$MEM_ONLY" | hook_w)"
[[ "$(cat "$TMP_DIR/victim2")" == "precious" && "$OUT_H" == *"not recorded"* ]]
check "ag10-legacy-hardlink-victim-not-truncated" $?
agent_ev ../x | hook_w >/dev/null
check "ag10-legacy-hardlink-agent-event-no-crash" $?

# D4: an unencodable (lone surrogate) session id: notice, no traceback, slot not wiped
reset_w
printf 'ownerX' > "$FLAG_W.withheld"
OUT_U8="$(printf '%s' '{"event":"PostToolUse","session_id":"x\ud800y","tool_name":"ExitPlanMode","tool_input":{"plan":"Plan\nI recall that the limit is 3."}}' | hook_w 2>"$TMP_DIR/u8.err")"; RC_U8=$?
[[ $RC_U8 -eq 0 && "$OUT_U8" == *"not recorded"* && "$(cat "$FLAG_W.withheld")" == "ownerX" \
   && ! -s "$TMP_DIR/u8.err" ]]
check "ag10-unencodable-sid-notice-and-slot-intact" $?

# direct unit tests of the claim/restore paths and the owner / mode checks
cat > "$TMP_DIR/unit.py" <<'PY'
import glob, importlib.util, os, pathlib, stat, sys

hook, tmp = sys.argv[1], pathlib.Path(sys.argv[2])
n = 0


def load(name):
    global n
    n += 1
    flag = tmp / f"unit-{name}"
    os.environ["AGENT_PLAN_FLAG"] = str(flag)
    spec = importlib.util.spec_from_file_location(f"plan_gate_u{n}", hook)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod, flag


def slot(flag):
    return pathlib.Path(str(flag) + ".withheld")


def claims(flag):
    return glob.glob(str(flag) + ".withheld.claim.*")


def report(name, ok):
    print(("PASS " if ok else "FAIL ") + name)


def patched(attr_owner, attr, fake):
    real = getattr(attr_owner, attr)
    setattr(attr_owner, attr, fake)
    return lambda: setattr(attr_owner, attr, real)


# sanity: the leftover glob really matches a claim-shaped name
mod, flag = load("glob")
probe = pathlib.Path(str(flag) + ".withheld.claim.1.ab")
probe.write_text("x")
report("claim-glob-matches-real-claim-names", claims(flag) == [str(probe)])
probe.unlink()

# claim of a slot that is not ours is restored: same inode, content, no leftover
mod, flag = load("restore")
slot(flag).write_text("ownerX")
ino = slot(flag).stat().st_ino
mod._claim_remove_legacy("other")
report("claim-restore-same-inode-no-leftover",
       slot(flag).exists() and slot(flag).stat().st_ino == ino
       and slot(flag).read_text() == "ownerX" and not claims(flag))

# our own slot is deleted
mod, flag = load("own")
slot(flag).write_text("me")
mod._claim_remove_legacy("me")
report("claim-deletes-own-slot", not slot(flag).exists() and not claims(flag))

# another session writes a new slot between rename and link: EEXIST, never overwritten
mod, flag = load("eexist")
slot(flag).write_text("ownerX")
real_rename = os.rename


def racing_rename(a, b, *args, **kw):
    real_rename(a, b, *args, **kw)
    if a == str(slot(flag)) and ".claim." in str(b):
        slot(flag).write_text("newZ")


undo = patched(os, "rename", racing_rename)
try:
    mod._claim_remove_legacy("other")
finally:
    undo()
kept = pathlib.Path(str(flag) + ".withheld.d") / "ownerX"
report("claim-eexist-newer-slot-not-overwritten-old-session-kept",
       slot(flag).read_text() == "newZ" and kept.is_file() and kept.read_text() == "ownerX"
       and not claims(flag))


def no_link(*a, **kw):
    raise PermissionError(1, "Operation not permitted")


# FS without hard links (EPERM): slot is renamed back, not lost
mod, flag = load("eperm")
slot(flag).write_text("ownerX")
undo = patched(os, "link", no_link)
try:
    mod._claim_remove_legacy("other")
finally:
    undo()
report("claim-link-eperm-restored-by-rename",
       slot(flag).exists() and slot(flag).read_text() == "ownerX" and not claims(flag))

# EPERM + a newer slot appeared: old session preserved per-session, newer slot intact
mod, flag = load("eperm2")
slot(flag).write_text("ownerX")
undo1 = patched(os, "link", no_link)
undo2 = patched(os, "rename", racing_rename)
try:
    mod._claim_remove_legacy("other")
finally:
    undo2()
    undo1()
kept = pathlib.Path(str(flag) + ".withheld.d") / "ownerX"
report("claim-link-eperm-newer-slot-old-session-preserved",
       slot(flag).read_text() == "newZ" and kept.is_file() and not claims(flag))

# owner checks with a patched euid (works for non-root too)
mod, flag = load("owner")
d = pathlib.Path(str(flag) + ".withheld.d")
d.mkdir(mode=0o700)
f = d / "aged"
f.write_text("x")
os.utime(f, (1, 1))
real_euid = os.geteuid()
undo = patched(os, "geteuid", lambda: real_euid + 1)
try:
    fd, why = mod.open_marker_dir(False)
    rejected_dir = fd is None and "another user" in why
    if fd is not None:
        os.close(fd)
    rejected_file = mod._read(str(f)) is None
finally:
    undo()
dfd = os.open(d, os.O_RDONLY | os.O_DIRECTORY)
undo = patched(os, "geteuid", lambda: real_euid + 1)
try:
    pruned = mod.prune_stale(dfd, "none")
finally:
    undo()
    os.close(dfd)
report("owner-check-rejects-foreign-dir", rejected_dir)
report("owner-check-rejects-foreign-file", rejected_file)
report("owner-check-prune-skips-foreign-file", not pruned and f.exists())

# marker dir is created 0700 whatever the umask
mod, flag = load("mode")
old = os.umask(0)
try:
    fd, why = mod.open_marker_dir(True)
finally:
    os.umask(old)
mode = stat.S_IMODE(os.stat(str(flag) + ".withheld.d").st_mode)
if fd is not None:
    os.close(fd)
report("mkdir-mode-0700", fd is not None and mode == 0o700)

# hard-linked file: writes refused and untouched; reads still fine
mod, flag = load("nlink")
victim = tmp / "unit-nlink-victim"
victim.write_text("precious")
os.link(victim, slot(flag))
wrote = mod._write_verified(str(slot(flag)), "sidZ")
report("nlink-write-refused-victim-intact",
       wrote is False and victim.read_text() == "precious")
report("nlink-read-allowed", mod._read(str(slot(flag))) == "precious")

# unencodable content never opens (so never truncates) the target
mod, flag = load("enc")
slot(flag).write_text("ownerX")
wrote = mod._write_verified(str(slot(flag)), "x\ud800y")
report("unencodable-write-false-slot-intact",
       wrote is False and slot(flag).read_text() == "ownerX")
PY
while read -r verdict name; do
  [[ -z "${verdict:-}" ]] && continue
  if [[ "$verdict" == "PASS" ]]; then echo "  ok   [ag10-unit-$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [ag10-unit-$name]"; FAIL=$((FAIL + 1)); fi
done < <(python3 "$TMP_DIR/unit.py" "$HOOK" "$TMP_DIR" 2>&1 || echo "FAIL unit-script-crashed")

# optional: event without session_id says no marker was recorded
reset_w
OUT_E="$(printf '%s' '{"event":"PostToolUse","tool_name":"ExitPlanMode","tool_input":{"plan":"Plan\nI recall that the limit is 3."}}' | hook_w)"
[[ "$OUT_E" == *"no session_id"* ]]
check "ag10-empty-sid-notice" $?
reset_w

# flag content carries session id; consumers only test existence
plan_event_sid sessZ "$OK_PLAN" | AGENT_PLAN_FLAG="$FLAG_S" python3 "$HOOK" >/dev/null
grep -q "session=sessZ" "$FLAG_S"
check "w8-flag-records-session" $?

echo
echo "=== malformed stdin -> no crash, no flag, exit 0 ==="
FLAG_M="$TMP_DIR/flag-malformed"
rm -f "$FLAG_M"
printf 'not json{' | AGENT_PLAN_FLAG="$FLAG_M" python3 "$HOOK" >/dev/null 2>&1
RC_M=$?
[[ $RC_M -eq 0 && ! -f "$FLAG_M" ]]
check "malformed-no-crash-no-flag" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
