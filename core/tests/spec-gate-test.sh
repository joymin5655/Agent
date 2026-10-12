#!/usr/bin/env bash
# spec-gate-test.sh — verify core/hooks/spec-gate.py planning-discipline gate.
#
# Feeds canonical PreToolUse (Write/Edit/MultiEdit) event JSON on stdin and
# asserts the emitted decision:
#   ask      == permissionDecision "ask"          (block mode, substantive impl, no plan)
#   advisory == hookSpecificOutput additionalContext (dryrun mode, never a stop)
#   allow    == empty stdout                       (flag present / out of scope / skip / off)
#
# The gate's dedup is the plan-approval flag: once it exists EVERY edit passes.
# spec-gate hardcodes the shared /tmp/agent-plan-approved (no env override — the
# reader must stay coupled to plan-gate.py's writer), so the battery toggles that
# REAL path and save/restores any live session's flag on entry/exit so it is never
# clobbered. The dryrun sink is redirected into a work dir so the repo stays clean.
#
# Deny-vs-ask: the gate uses `ask` (not tdd-guard's `deny`) — a planning-discipline
# gate is REVERSIBLE (the edit isn't destructive; the escape is trivial: approve a
# plan or set mode=off), matching the harness escalation principle (pre-tool-guard
# rules 13/14, supervisor). Case (l) asserts the actual value + that the reason
# names /spec and BOTH escapes.
#
# Usage: bash core/tests/spec-gate-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PASS=0
FAIL=0

WORK="$(mktemp -d)"
SINK="$WORK/spec-gate.jsonl"        # absolute sink — keeps the real repo clean
# The hook hardcodes the shared flag path, and the reader must stay coupled to plan-gate.py's
# writer, so run a COPY of core/hooks whose PLAN_FLAG points inside $WORK. The real
# /tmp/agent-plan-approved (another live session may own it) is never touched; the battery
# asserts its state is identical before and after.
REAL_FLAG="/tmp/agent-plan-approved"
real_state() {
  python3 - "$REAL_FLAG" <<'PY'
import hashlib, os, stat, sys
p = sys.argv[1]
try:
    st = os.lstat(p)
except OSError:
    print("absent")
    raise SystemExit
body = ""
if stat.S_ISREG(st.st_mode):
    with open(p, "rb") as fh:
        body = hashlib.sha256(fh.read()).hexdigest()
print(st.st_ino, stat.S_IFMT(st.st_mode), st.st_nlink, st.st_uid, body)
PY
}
REAL_BEFORE="$(real_state)"
FLAG="$WORK/plan-flag"
HOOKS_COPY="$WORK/hooks-copy"
cp -R "$REPO_ROOT/core/hooks" "$HOOKS_COPY"
python3 - "$HOOKS_COPY/spec-gate.py" "$FLAG" <<'PY' || { echo "FAIL: PLAN_FLAG substitution did not match exactly once"; exit 1; }
import sys
path, flag = sys.argv[1:]
src = open(path).read()
old = 'PLAN_FLAG = "/tmp/agent-plan-approved"'
if src.count(old) != 1:
    raise SystemExit(1)
open(path, "w").write(src.replace(old, 'PLAN_FLAG = "%s"' % flag))
PY
HOOK="$HOOKS_COPY/spec-gate.py"
cleanup() {
  [[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# event builders + runner
# ---------------------------------------------------------------------------

evt() { printf '{"event":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"%s"}}' "$1"; }

# set_flag <present|absent|dir|fifo|symlink|hardlink|foreign>: plant the flag slot in a given shape
set_flag() {
  rm -rf "$FLAG"
  case "$1" in
    present)  : > "$FLAG" ;;
    dir)      mkdir "$FLAG" ;;
    fifo)     mkfifo "$FLAG" ;;
    symlink)  : > "$WORK/flag-target"; ln -s "$WORK/flag-target" "$FLAG" ;;
    hardlink) : > "$WORK/flag-hl"; ln "$WORK/flag-hl" "$FLAG" ;;
    foreign)  : > "$FLAG"; chown 65534 "$FLAG" ;;
  esac
}

# run <mode> <flag: present|absent> <json>  -> sets OUT, RC
run() {
  local mode="$1" flagstate="$2" json="$3"
  set_flag "$flagstate"
  OUT="$(printf '%s' "$json" | ( cd "$WORK" && env \
    AGENT_SPEC_GATE_MODE="$mode" \
    AGENT_SPEC_GATE_SINK="$SINK" \
    AGENT_SESSION_ID=test \
    python3 "$HOOK" ) 2>/dev/null)"
  RC=$?
}

# classify OUT -> GOT in {ask, deny, advisory, allow, other}
classify() {
  if [[ "$OUT" == *'"permissionDecision": "ask"'* || "$OUT" == *'"permissionDecision":"ask"'* ]]; then
    GOT=ask
  elif [[ "$OUT" == *'"permissionDecision": "deny"'* || "$OUT" == *'"permissionDecision":"deny"'* ]]; then
    GOT=deny
  elif [[ "$OUT" == *'additionalContext'* ]]; then
    GOT=advisory
  elif [[ -z "$OUT" ]]; then
    GOT=allow
  else
    GOT=other
  fi
}

# ---------------------------------------------------------------------------
# assertions
# ---------------------------------------------------------------------------

ok()  { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL [$1] $2"; FAIL=$((FAIL + 1)); }

# expect <name> <mode> <flagstate> <file_path> <ask|advisory|allow>
expect() {
  local name="$1" mode="$2" flagstate="$3" fp="$4" want="$5"
  run "$mode" "$flagstate" "$(evt "$fp")"
  classify
  if [[ "$GOT" == "$want" && "$RC" -eq 0 ]]; then
    ok "$name (expected=$want)"
  else
    bad "$name" "expected=$want got=$GOT rc=$RC :: $OUT"
  fi
}

assert_contains()     { if [[ "$OUT" == *"$2"* ]]; then ok "$1"; else bad "$1" "OUT missing '$2': $OUT"; fi; }
assert_not_contains() { if [[ "$OUT" != *"$2"* ]]; then ok "$1"; else bad "$1" "OUT unexpectedly has '$2': $OUT"; fi; }
assert_rc_zero()      { if [[ "$RC" -eq 0 ]]; then ok "$1"; else bad "$1" "expected exit 0, got $RC"; fi; }
assert_empty()        { if [[ -z "$OUT" ]]; then ok "$1"; else bad "$1" "expected empty stdout, got: $OUT"; fi; }

# ---------------------------------------------------------------------------
# scenarios
# ---------------------------------------------------------------------------

echo "=== core gate matrix ==="
expect "a-block-impl-noflag-asks"      block  absent  'src/x.ts'          ask
expect "b-block-impl-flag-allows"      block  present 'src/x.ts'          allow
expect "c-dryrun-impl-noflag-advises"  dryrun absent  'src/x.ts'          advisory
expect "d-off-mode-noop"               off    absent  'src/x.ts'          allow
expect "e-block-testfile-allows"       block  absent  'src/x.test.ts'     allow
expect "f1-block-doc-allows"           block  absent  'README.md'         allow
expect "f2-block-config-allows"        block  absent  'tsconfig.json'     allow
expect "g-block-meta-allows"           block  absent  '.agent/state/x.py' allow
expect "j1-block-migration-allows"     block  absent  'migrations/x.sql'  allow
expect "j2-block-secret-allows"        block  absent  'secrets/.env'      allow
expect "k-block-outscope-lang-allows"  block  absent  'src/x.go'          allow

echo
echo "=== anchored skip: only a REAL segment skips (review MAJOR — was unanchored) ==="
expect "t1-subtypes-dir-not-skipped"   block absent 'src/subtypes/billing.ts' ask    # 'subtypes' != 'types'
expect "t2-myconfig-dir-not-skipped"   block absent 'src/myconfig/pay.ts'      ask    # 'myconfig' != 'config'
expect "t3-real-types-dir-skips"       block absent 'src/types/schema.ts'      allow  # real types/ segment still exempt
expect "t4-real-config-dir-skips"      block absent 'src/config/env.ts'        allow  # real config/ segment still exempt

echo
echo "=== production-representative ABSOLUTE file_path (review MINOR) ==="
expect "u1-abs-impl-noflag-asks"       block absent '/opt/proj/src/pay.ts'    ask
expect "u2-abs-impl-flag-allows"       block present '/opt/proj/src/pay.ts'    allow

echo
echo "=== broadened default scope: app/ pages/ lib/ server/ components/ (review MINOR) ==="
expect "v1-app-router-asks"            block absent 'app/api/charge/route.ts'  ask
expect "v2-lib-service-asks"           block absent 'lib/payment.ts'           ask
expect "v3-server-asks"                block absent 'server/auth.ts'           ask
expect "v4-components-asks"            block absent 'components/Pay.tsx'        ask
expect "v5-core-harness-not-gated"     block absent 'core/hooks/x.py'          allow  # harness self-dev stays ungated

echo
echo "=== case-insensitive extension: uppercase spelling can't evade (review NIT) ==="
expect "w1-uppercase-ext-asks"         block absent 'src/Pay.TS'  ask
expect "w2-uppercase-py-asks"          block absent 'src/Pay.PY'  ask

echo
echo "=== fail-open ==="
run block absent 'this is not json {['
assert_rc_zero "h-malformed-stdin-rc0"
assert_empty   "h-malformed-stdin-empty"
run block absent "$(evt '')"
assert_rc_zero "i-empty-filepath-rc0"
assert_empty   "i-empty-filepath-empty"
run block absent '{"event":"PreToolUse","tool_name":"Write"}'
assert_rc_zero "i2-missing-toolinput-rc0"
assert_empty   "i2-missing-toolinput-empty"

echo
echo "=== flag dominates every branch (the flag is the dedup) ==="
expect "o-dryrun-impl-flag-allows"     dryrun present 'src/x.ts'  allow
expect "n-block-py-flag-allows"        block  present 'src/x.py'  allow

echo
echo "=== scope coverage ==="
expect "p-block-jsx-noflag-asks"       block absent 'src/x.jsx'                 ask
expect "q-block-nested-tsx-noflag-asks" block absent 'src/deep/nest/widget.tsx' ask
expect "r-block-py-noflag-asks"        block absent 'src/pkg/svc.py'            ask

echo
echo "=== (l) deny-vs-ask decision + reason names /spec and BOTH escapes ==="
run block absent "$(evt 'src/pay.ts')"
assert_contains     "l-decision-is-ask"      '"permissionDecision": "ask"'
assert_not_contains "l-decision-not-deny"    'deny'
assert_contains     "l-reason-names-spec"    '/spec'
assert_contains     "l-reason-escape-exitplan" 'ExitPlanMode'
assert_contains     "l-reason-escape-modeoff"  'AGENT_SPEC_GATE_MODE=off'

echo
echo "=== dryrun never emits a stop decision ==="
run dryrun absent "$(evt 'src/pay.ts')"
assert_not_contains "s-dryrun-no-permissiondecision" 'permissionDecision'
assert_contains     "s-dryrun-has-advisory"          'additionalContext'

echo
echo "=== AG16: only a regular, own, single-link file counts as approval ==="
expect "ag16-dir-flag-not-approval"      block dir      'src/x.ts' ask
expect "ag16-fifo-flag-not-approval"     block fifo     'src/x.ts' ask
expect "ag16-symlink-flag-not-approval"  block symlink  'src/x.ts' ask
expect "ag16-hardlink-flag-not-approval" block hardlink 'src/x.ts' ask
expect "ag16-regular-flag-approves"      block present  'src/x.ts' allow
if [[ "$(id -u)" -eq 0 ]]; then
  expect "ag16-foreign-uid-flag-not-approval" block foreign 'src/x.ts' ask
fi

echo
echo "=== real shared flag untouched ==="
if [[ "$(real_state)" == "$REAL_BEFORE" ]]; then ok "real-flag-state-unchanged"; else bad "real-flag-state-unchanged" "$REAL_BEFORE -> $(real_state)"; fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
