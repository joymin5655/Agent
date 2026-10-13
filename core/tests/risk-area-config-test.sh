#!/usr/bin/env bash
# risk-area-config-test.sh — T-4 (2)(3): `risk_areas.data/deploy/payment` and `resources:` from
# .agent/hook-config.yml|json are READ at runtime by every consumer, EXTENSION-ONLY.
#
# Per consumer (pre-tool-guard / pre-push / auto-ship / r4-mutex-check) four properties:
#   consume  — a pattern placed in the config actually changes the verdict
#   additive — the config can neither remove a built-in pattern nor lower a decision
#   noyaml   — PyYAML absent: built-in behaviour + a warning, never a new refusal
#   badregex — an invalid / over-long / nested-quantifier / universe regex is ignored + warned
# plus the loader's own bounds (backtracking watchdog, count caps) and the doc claims.
#
# Isolation: every case builds a throwaway project under mktemp (own .agent/hook-config.*),
# points the guard at it with AGENT_PROJECT_DIR, sends gate records to a temp sink, and uses a
# stub `gh` on PATH for auto-ship (never the network). PyYAML absence is simulated with a shim
# `yaml.py` that raises ImportError, the same way risk-area-wiring-test.sh does.
#
# Usage: bash core/tests/risk-area-config-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PTG="$REPO_ROOT/core/hooks/pre-tool-guard.sh"
R4="$REPO_ROOT/core/hooks/r4-mutex-check.sh"
PREPUSH="$REPO_ROOT/core/git-hooks/pre-push"
AUTOSHIP="$REPO_ROOT/core/infra/auto-ship.sh"
HC="$REPO_ROOT/core/hooks/hook_config.py"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
export AGENT_GATE_SINK_DIR="$TMP_ROOT/sink"
export AGENT_LOG_ORIGIN=test
unset AGENT_RISK_DATA_PATTERN AGENT_RISK_DEPLOY_PATTERN RISK_DATA_PATTERN RISK_DEPLOY_PATTERN \
      RISK_PAYMENT_PATTERN RISK_SECRETS_PATTERN RISK_DOMAIN_OUTPUT_PATTERN HOOK_CONFIG_PATH

NOYAML="$TMP_ROOT/noyaml"
mkdir -p "$NOYAML"
echo 'raise ImportError("PyYAML absent (test shim)")' > "$NOYAML/yaml.py"

mkproj() { # mkproj <name> -> path with an empty .agent/
  local p="$TMP_ROOT/$1"; mkdir -p "$p/.agent"; echo "$p"
}
decision_of() { # stdout of a PreToolUse hook -> allow|ask|deny
  local out="$1"
  if [[ "$out" == *'"permissionDecision": "deny"'* ]]; then echo deny
  elif [[ "$out" == *'"permissionDecision": "ask"'* ]]; then echo ask
  else echo allow; fi
}

# ---- pre-tool-guard harness: sets PTG_OUT / PTG_ERR / PTG_DEC --------------------------------
ptg() { # ptg <project> <command> [pythonpath]
  local proj="$1" cmd="$2" pp="${3:-}" ev
  ev=$(CMD="$cmd" python3 -c 'import os,json; print(json.dumps({"event":"PreToolUse","tool_name":"Bash","tool_input":{"command":os.environ["CMD"]}}))')
  PTG_OUT=$(cd "$proj" || exit 1; printf '%s' "$ev" | PYTHONPATH="$pp" AGENT_PROJECT_DIR="$proj" timeout "${PTG_TIMEOUT:-60}" bash "$PTG" 2>"$TMP_ROOT/ptg.err" || true)
  PTG_ERR=$(cat "$TMP_ROOT/ptg.err")
  PTG_DEC=$(decision_of "$PTG_OUT")
}
ptg_expect() { # ptg_expect <name> <project> <cmd> <expect> [pythonpath]
  ptg "$2" "$3" "${5:-}"
  [[ "$PTG_DEC" == "$4" ]]; local rc=$?
  [[ $rc -ne 0 ]] && echo "       got=$PTG_DEC out=$PTG_OUT err=$PTG_ERR"
  check "$1 ($4)" $rc
}

DATA_YML=$'risk_areas:\n  data:\n    pattern: \'^db/migrations/.*\\.sql$\'\n    decision: ask\n'

echo "=== (A) pre-tool-guard: consume ==="
P=$(mkproj ptg-a); printf '%s' "$DATA_YML" > "$P/.agent/hook-config.yml"
Q=$(mkproj ptg-a0)   # no config: same command is allowed
ptg_expect "no-config-migration-add-allowed"  "$Q" 'git add db/migrations/001.sql' allow
ptg_expect "config-data-pattern-git-add"      "$P" 'git add db/migrations/001.sql' ask
ptg_expect "config-data-pattern-touch"        "$P" 'touch db/migrations/002.sql' ask
ptg_expect "config-data-pattern-redirect"     "$P" 'echo x > db/migrations/003.sql' ask
ptg_expect "config-data-pattern-mv"           "$P" 'mv /tmp/x.sql db/migrations/004.sql' ask
ptg_expect "config-data-pattern-sed-i"        "$P" "sed -i 's/a/b/' db/migrations/001.sql" ask
ptg_expect "config-data-pattern-sudo-wrapper" "$P" 'sudo env A=1 git add db/migrations/001.sql' ask
ptg_expect "reading-the-file-is-fine"         "$P" 'cat db/migrations/001.sql' allow
ptg_expect "unrelated-add-allowed"            "$P" 'git add src/app.py' allow
ptg_expect "git-status-allowed"               "$P" 'git status' allow
check_msg() { [[ "$PTG_OUT" == *"WHY:"* && "$PTG_OUT" == *"FIX:"* ]]; check "$1" $?; }
ptg "$P" 'git add db/migrations/001.sql'; check_msg "ask-message-has-WHY-and-FIX (T-1)"
P=$(mkproj ptg-a2)
cat > "$P/.agent/hook-config.yml" <<'YML'
risk_areas:
  deploy:
    pattern: '^workers/.*\.ts$'
  payment:
    pattern: ['(billing/|stripe)', '^pay/']
YML
ptg_expect "deploy-pattern-consumed"          "$P" 'git add workers/api.ts' ask
ptg_expect "payment-pattern-list-1"           "$P" 'git add src/billing/plan.py' ask
ptg_expect "payment-pattern-list-2"           "$P" 'git add pay/x.py' ask
ptg_expect "payment-non-match-allowed"        "$P" 'git add src/app.py' allow
P=$(mkproj ptg-a3); printf '%s' "$DATA_YML" | sed 's/ask/deny/' > "$P/.agent/hook-config.yml"
ptg_expect "explicit-decision-deny-is-deny"   "$P" 'git add db/migrations/001.sql' deny
P=$(mkproj ptg-a4)
printf '{"risk_areas":{"data":{"pattern":"^db/migrations/.*\\\\.sql$"}}}' > "$P/.agent/hook-config.json"
ptg_expect "json-config-consumed"             "$P" 'git add db/migrations/001.sql' ask

echo
echo "=== (B) pre-tool-guard: additive only ==="
P=$(mkproj ptg-b)
cat > "$P/.agent/hook-config.yml" <<'YML'
risk_areas:
  data:
    pattern: '^db/migrations/.*\.sql$'
    decision: advisory
YML
ptg_expect "decision-below-floor-clamped-to-ask" "$P" 'git add db/migrations/001.sql' ask
ptg_expect "builtin-drop-table-still-ask"        "$P" 'psql -c "DROP TABLE users"' ask
ptg_expect "builtin-artifacts-add-still-deny"    "$P" 'git add data/artifacts/model.bin' deny
ptg_expect "builtin-secrets-still-deny"          "$P" 'cat secrets/prod.env' deny
ptg_expect "builtin-force-push-still-deny"       "$P" 'git push --force origin main' deny
P=$(mkproj ptg-b2)
cat > "$P/.agent/hook-config.yml" <<'YML'
risk_areas:
  data:
    pattern: '^nothing-matches-this$'
  deploy:
    pattern: ''
YML
ptg_expect "other-pattern-leaves-drop-table-ask" "$P" 'psql -c "TRUNCATE TABLE t"' ask
ptg_expect "other-pattern-leaves-artifacts-deny" "$P" 'git add data/artifacts/m.bin' deny

echo
echo "=== (C) pre-tool-guard: PyYAML absent -> built-in + warning, no new refusal ==="
P=$(mkproj ptg-c); printf '%s' "$DATA_YML" > "$P/.agent/hook-config.yml"
ptg "$P" 'touch db/migrations/001.sql' "$NOYAML"
[[ "$PTG_DEC" == allow ]]; check "noyaml-yml-pattern-inactive (allow)" $?
[[ "$PTG_ERR" == *PyYAML* ]]; check "noyaml-warns-PyYAML-on-stderr" $?
ptg "$P" 'ls -la' "$NOYAML"
[[ "$PTG_DEC" == allow && "$PTG_ERR" != *PyYAML* ]]; check "noyaml-non-mutating-command-silent" $?
ptg_expect "noyaml-builtin-drop-still-ask"       "$P" 'psql -c "DROP TABLE t"' ask "$NOYAML"
ptg_expect "noyaml-secrets-failclosed-unchanged" "$P" 'cat config/app.json' deny "$NOYAML"
P=$(mkproj ptg-c2)
printf '{"risk_areas":{"data":{"pattern":"^db/migrations/.*\\\\.sql$"}}}' > "$P/.agent/hook-config.json"
ptg_expect "noyaml-json-config-still-consumed"   "$P" 'git add db/migrations/001.sql' ask "$NOYAML"

echo
echo "=== (D) pre-tool-guard: invalid regex ignored + warned; good sibling kept ==="
P=$(mkproj ptg-d)
LONG=$(python3 -c 'print("a"*250)')
cat > "$P/.agent/hook-config.yml" <<YML
risk_areas:
  data:
    pattern:
      - '(unclosed'
      - '(a+)+\$'
      - '.*'
      - '$LONG'
      - '^db/migrations/.*\.sql\$'
YML
ptg "$P" 'git add db/migrations/001.sql'
[[ "$PTG_DEC" == ask ]]; check "good-sibling-pattern-still-effective" $?
[[ "$PTG_ERR" == *"hook_config:"* && "$PTG_ERR" == *ignored* ]]; check "bad-regex-warned-on-stderr" $?
[[ "$PTG_ERR" == *"invalid regex"* ]]; check "warning names: invalid regex" $?
[[ "$PTG_ERR" == *"nested quantifier"* ]]; check "warning names: nested quantifier" $?
[[ "$PTG_ERR" == *"matches the empty string"* ]]; check "warning names: universe pattern" $?
[[ "$PTG_ERR" == *"longer than 200"* ]]; check "warning names: over-long pattern" $?
ptg "$P" 'git add src/app.py'
[[ "$PTG_DEC" == allow ]]; check "universe-pattern-dropped (unrelated add allowed)" $?
P=$(mkproj ptg-d2)
printf 'risk_areas:\n  data:\n    pattern: "(unclosed"\n' > "$P/.agent/hook-config.yml"
ptg_expect "only-bad-regex-no-effect"            "$P" 'git add db/migrations/001.sql' allow

echo
echo "=== (E) backtracking watchdog: bounded, never hangs ==="
P=$(mkproj ptg-e)
cat > "$P/.agent/hook-config.yml" <<'YML'
risk_areas:
  data:
    pattern: '^(a|aa)+$'
YML
BIGA=$(python3 -c 'print("a"*900+"!")')
t0=$(date +%s)
PTG_TIMEOUT=15 ptg "$P" "git add $BIGA"
t1=$(date +%s)
[[ $((t1 - t0)) -le 8 ]]; check "catastrophic-pattern-time-bounded (<=8s)" $?
[[ "$PTG_DEC" == allow ]]; check "timed-out-pattern-yields-no-match" $?

echo
echo "=== (F) loader unit: bounds and clamps ==="
lc() { python3 - "$@" <<'PY'
import sys, json, os, tempfile
sys.path.insert(0, os.path.dirname(sys.argv[1]))
import hook_config as hc
root = tempfile.mkdtemp()
os.makedirs(os.path.join(root, ".agent"))
open(os.path.join(root, ".agent", "hook-config.json"), "w").write(sys.argv[2])
r = hc.load_risk_area_patterns(root)
print(json.dumps(r, sort_keys=True))
PY
}
OUT=$(lc "$HC" '{"risk_areas":{"data":{"pattern":["^a/","^b/"],"decision":"deny"},"deploy":{"pattern":"^d/","decision":"bogus"},"secrets":{"pattern":"^s/"}}}')
echo "$OUT" | python3 -c '
import sys, json
r = json.load(sys.stdin)
a = r["areas"]
ok = (a["data"]["patterns"] == ["^a/", "^b/"] and a["data"]["decision"] == "deny"
      and a["deploy"]["decision"] is None and "secrets" not in a)
sys.exit(0 if ok else 1)'
check "loader: union of list patterns, declared decision, invalid decision dropped, secrets not exposed" $?
OUT=$(lc "$HC" "{\"risk_areas\":{\"data\":{\"pattern\":[$(python3 -c 'print(",".join("\"^p%d/\"" % i for i in range(60)))')]}}}")
echo "$OUT" | python3 -c 'import sys,json; r=json.load(sys.stdin); sys.exit(0 if len(r["areas"]["data"]["patterns"]) <= 20 else 1)'
check "loader: pattern count capped (<=20)" $?
python3 - "$HC" <<'PY'
import sys, os
sys.path.insert(0, os.path.dirname(sys.argv[1]))
import hook_config as hc
ok = (hc.effective_decision("pre-push", None) == "advisory"
      and hc.effective_decision("pre-push", "ask") == "ask"
      and hc.effective_decision("pre-push", "deny") == "deny"
      and hc.effective_decision("pre-push", "advisory") == "advisory"
      and hc.effective_decision("pre-tool-guard", "advisory") == "ask"
      and hc.effective_decision("pre-tool-guard", None) == "ask"
      and hc.effective_decision("pre-tool-guard", "deny") == "deny"
      and hc.effective_decision("auto-ship", "advisory") == "deny")
sys.exit(0 if ok else 1)
PY
check "loader: effective_decision is max(consumer floor, declared) — never lower" $?

echo
echo "=== (G) pre-push: real git push against a bare remote ==="
mkrepo() { # mkrepo <name> -> $TMP_ROOT/<name>/work (main pushed; origin/main exists)
  local d="$TMP_ROOT/$1"; mkdir -p "$d"
  git init -q --bare -b main "$d/remote.git"
  git init -q -b main "$d/work"
  (cd "$d/work" && git config user.email t@t && git config user.name t \
    && git config commit.gpgsign false && mkdir -p .agent && echo base > README.md \
    && git add README.md && git commit -q -m base \
    && git remote add origin "$d/remote.git" \
    && git -c core.hooksPath=/dev/null push -q origin main 2>/dev/null)
  echo "$d/work"
}
commit_files() { # commit_files <work> <file...> (on branch feat)
  local w="$1"; shift
  (cd "$w" && git checkout -q -B feat origin/main
   for f in "$@"; do mkdir -p "$(dirname "$f")"; echo "$f" > "$f"; done
   git add -A -- . ':!.agent' 2>/dev/null; git commit -q -m change)
}
pp() { # pp <work> [pythonpath]  -> PP_RC / PP_ERR (direct invoke with git's stdin shape)
  local w="$1" pyp="${2:-}" sha
  sha=$(git -C "$w" rev-parse HEAD)
  PP_ERR=$(cd "$w" && printf 'refs/heads/feat %s refs/heads/feat 0000000000000000000000000000000000000000\n' "$sha" \
    | PYTHONPATH="$pyp" bash "$PREPUSH" origin 2>&1 >/dev/null); PP_RC=$?
}
W=$(mkrepo pp1); commit_files "$W" app/migrations/001.sql src/a.py
pp "$W"
[[ $PP_RC -eq 0 && "$PP_ERR" == *"[ADVISORY data]"* ]]; check "default data pattern advisory (baseline)" $?
W=$(mkrepo pp2); commit_files "$W" db/schema/x.sql
pp "$W"
[[ "$PP_ERR" != *"[ADVISORY data]"* ]]; check "no-config: db/schema/x.sql not flagged" $?
printf '%s' $'risk_areas:\n  data:\n    pattern: \'^db/.*\\.sql$\'\n' > "$W/.agent/hook-config.yml"
pp "$W"
[[ $PP_RC -eq 0 && "$PP_ERR" == *"[ADVISORY data]"* && "$PP_ERR" == *db/schema/x.sql* ]]
check "consume: config data pattern flags db/schema/x.sql, push not blocked" $?
W=$(mkrepo pp3); commit_files "$W" app/migrations/001.sql
printf '%s' $'risk_areas:\n  data:\n    pattern: \'^other/\'\n    decision: advisory\n' > "$W/.agent/hook-config.yml"
pp "$W"
[[ $PP_RC -eq 0 && "$PP_ERR" == *"[ADVISORY data]"* && "$PP_ERR" == *app/migrations/001.sql* ]]
check "additive: built-in data pattern still flagged under a different config pattern" $?
W=$(mkrepo pp4); commit_files "$W" billing/plan.py workers/api.ts
cat > "$W/.agent/hook-config.yml" <<'YML'
risk_areas:
  payment:
    pattern: '^billing/'
  deploy:
    pattern: '^workers/'
YML
pp "$W"
[[ $PP_RC -eq 0 && "$PP_ERR" == *"[ADVISORY payment]"* && "$PP_ERR" == *"[ADVISORY deploy]"* ]]
check "consume: payment + deploy config patterns advisory" $?
cat > "$W/.agent/hook-config.yml" <<'YML'
risk_areas:
  payment:
    pattern: '^billing/'
    decision: deny
YML
pp "$W"
[[ $PP_RC -eq 14 && "$PP_ERR" == *"[BLOCK payment]"* ]]
check "explicit decision: deny blocks the push (exit 14)" $?
# a real git push is rejected by that same hook
(cd "$W" && git -c core.hooksPath="$REPO_ROOT/core/git-hooks" push -q origin feat >/dev/null 2>"$TMP_ROOT/push.err"); PUSH_RC=$?
[[ $PUSH_RC -ne 0 ]] && grep -q '\[BLOCK payment\]' "$TMP_ROOT/push.err"
check "real git push is rejected by explicit deny" $?
printf '%s' $'risk_areas:\n  payment:\n    pattern: \'^billing/\'\n' > "$W/.agent/hook-config.yml"
(cd "$W" && git -c core.hooksPath="$REPO_ROOT/core/git-hooks" push -q origin feat >/dev/null 2>"$TMP_ROOT/push.err"); PUSH_RC=$?
[[ $PUSH_RC -eq 0 ]] && grep -q '\[ADVISORY payment\]' "$TMP_ROOT/push.err"
check "real git push passes with advisory output when no decision declared" $?
W=$(mkrepo pp5); commit_files "$W" db/schema/x.sql
printf '%s' $'risk_areas:\n  data:\n    pattern: \'^db/.*\\.sql$\'\n' > "$W/.agent/hook-config.yml"
pp "$W" "$NOYAML"
[[ $PP_RC -eq 0 && "$PP_ERR" == *PyYAML* && "$PP_ERR" != *"[ADVISORY data]"* ]]
check "noyaml: defaults only + PyYAML warning, push not blocked" $?
rm "$W/.agent/hook-config.yml"
printf '{"risk_areas":{"data":{"pattern":"^db/.*\\\\.sql$"}}}' > "$W/.agent/hook-config.json"
pp "$W" "$NOYAML"
[[ $PP_RC -eq 0 && "$PP_ERR" == *"[ADVISORY data]"* ]]; check "noyaml: json config still consumed" $?
W=$(mkrepo pp6); commit_files "$W" db/schema/x.sql app/migrations/9.sql
printf '%s' $'risk_areas:\n  data:\n    pattern:\n      - \'(unclosed\'\n      - \'^db/.*\\.sql$\'\n' > "$W/.agent/hook-config.yml"
pp "$W"
[[ $PP_RC -eq 0 && "$PP_ERR" == *ignored* && "$PP_ERR" == *db/schema/x.sql* && "$PP_ERR" == *app/migrations/9.sql* ]]
check "bad regex ignored + warned, good sibling and default both still flagged" $?
W=$(mkrepo pp7); commit_files "$W" app/migrations/1.sql
printf '%s' $'risk_areas:\n  data:\n    pattern: \'^zzz/\'\n    decision: deny\n' > "$W/.agent/hook-config.yml"
pp "$W"
[[ $PP_RC -eq 12 ]]; check "deny declared on a pattern also upgrades default-pattern hits (exit 12)" $?
W=$(mkrepo pp8); commit_files "$W" app/migrations/1.sql
printf '%s' $'risk_areas:\n  data:\n    pattern: \'^zzz/\'\n' > "$W/.agent/hook-config.yml"
PP_ERR=$(cd "$W" && printf 'refs/heads/feat %s refs/heads/feat 0000000000000000000000000000000000000000\n' "$(git rev-parse HEAD)" \
  | AGENT_RISK_DATA_PATTERN='^only-env/' bash "$PREPUSH" origin 2>&1 >/dev/null)
[[ "$PP_ERR" != *"[ADVISORY data]"* ]]; check "env AGENT_RISK_DATA_PATTERN still replaces the built-in default (operator knob unchanged)" $?

echo
echo "=== (H) auto-ship: stub gh, never the network ==="
STUB="$TMP_ROOT/stub"; mkdir -p "$STUB"
cat > "$STUB/gh" <<'STUBGH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view") echo '{"state":"OPEN","mergeable":"MERGEABLE","headRefName":"feat","headRefOid":"abc","baseRefName":"main"}' ;;
  "pr checks") echo "all checks passed"; exit 0 ;;
  "pr diff") if [[ " $* " == *" --name-only "* ]]; then cat "$STUB_DIFF_FILES"; fi ;;
  "pr merge") echo "stub: merge refused" >&2; exit 1 ;;
  *) exit 0 ;;
esac
STUBGH
chmod +x "$STUB/gh"
as() { # as <project> <pythonpath> <files...>  -> AS_RC / AS_OUT
  local proj="$1" pyp="$2"; shift 2
  printf '%s\n' "$@" > "$TMP_ROOT/diff-files"
  AS_OUT=$(cd "$proj" && STUB_DIFF_FILES="$TMP_ROOT/diff-files" PATH="$STUB:$PATH" PYTHONPATH="$pyp" \
    bash "$AUTOSHIP" 7 2>&1); AS_RC=$?
}
mkgit() { local p; p=$(mkproj "$1"); git -C "$p" init -q -b main; echo "$p"; }
P=$(mkgit as0)
as "$P" "" src/app.py
[[ $AS_RC -eq 17 ]]; check "baseline: clean diff reaches merge step (stub refuses -> exit 17)" $?
as "$P" "" x/migrations/a.sql
[[ $AS_RC -eq 12 ]]; check "baseline: built-in data pattern aborts (exit 12)" $?
as "$P" "" db/schema/a.sql
[[ $AS_RC -eq 17 ]]; check "no-config: db/schema/a.sql not a risk file" $?
printf '%s' $'risk_areas:\n  data:\n    pattern: \'^db/.*\\.sql$\'\n' > "$P/.agent/hook-config.yml"
as "$P" "" db/schema/a.sql
[[ $AS_RC -eq 12 ]]; check "consume: config data pattern aborts (exit 12)" $?
as "$P" "" x/migrations/a.sql
[[ $AS_RC -eq 12 ]]; check "additive: built-in data pattern still aborts alongside config" $?
cat > "$P/.agent/hook-config.yml" <<'YML'
risk_areas:
  deploy:
    pattern: '^workers/'
  payment:
    pattern: '^pay/'
    decision: advisory
YML
as "$P" "" workers/a.ts; [[ $AS_RC -eq 13 ]]; check "consume: config deploy pattern aborts (exit 13)" $?
as "$P" "" pay/a.py;     [[ $AS_RC -eq 14 ]]; check "decision below floor cannot soften payment (still exit 14)" $?
as "$P" "" src/billing/x.py; [[ $AS_RC -eq 14 ]]; check "built-in payment pattern intact (exit 14)" $?
printf '%s' $'risk_areas:\n  data:\n    pattern: \'^db/.*\\.sql$\'\n' > "$P/.agent/hook-config.yml"
as "$P" "$NOYAML" db/schema/a.sql
[[ $AS_RC -eq 17 && "$AS_OUT" == *PyYAML* ]]; check "noyaml: defaults only + PyYAML warning" $?
as "$P" "$NOYAML" x/migrations/a.sql
[[ $AS_RC -eq 12 ]]; check "noyaml: built-in pattern still aborts" $?
rm "$P/.agent/hook-config.yml"
printf '{"risk_areas":{"data":{"pattern":"^db/.*\\\\.sql$"}}}' > "$P/.agent/hook-config.json"
as "$P" "$NOYAML" db/schema/a.sql
[[ $AS_RC -eq 12 ]]; check "noyaml: json config still consumed" $?
rm "$P/.agent/hook-config.json"
printf '%s' $'risk_areas:\n  data:\n    pattern:\n      - \'(unclosed\'\n      - \'^db/.*\\.sql$\'\n' > "$P/.agent/hook-config.yml"
as "$P" "" db/schema/a.sql
[[ $AS_RC -eq 12 && "$AS_OUT" == *ignored* ]]; check "bad regex ignored + warned, good sibling effective" $?
rm "$P/.agent/hook-config.yml"
printf '%s' $'risk_areas:\n  data:\n    pattern: \'^db/.*\\.sql$\'\n' > "$P/hook-config.yml"
as "$P" "" db/schema/a.sql
[[ $AS_RC -eq 17 && "$AS_OUT" == *".agent/hook-config"* ]]
check "legacy root hook-config.yml is not read; one line says where to put it" $?
rm "$P/hook-config.yml"
! grep -q 'HOOK_CONFIG=' "$AUTOSHIP"; check "dead HOOK_CONFIG variable removed from auto-ship.sh" $?
! grep -q 'HOOK_CONFIG_PATH' "$AUTOSHIP"; check "no HOOK_CONFIG_PATH env claim left in auto-ship.sh" $?

echo
echo "=== (I) r4-mutex-check: resources: triggers ==="
r4lock() { # r4lock <project> <resource> <claimed_at>  -> lock file owned by another session
  mkdir -p "$1/.agent/locks"
  jq -n --arg r "$2" --arg t "$3" \
    '{sessions:[{session_id:"other-s",agent:"codex",branch:"b"}],shared_resource_locks:{($r):{session_id:"other-s",claimed_at:$t}}}' \
    > "$1/.agent/locks/active-sessions.json"
}
r4() { # r4 <project> <tool> <command> [pythonpath]  -> R4_DEC / R4_ERR / R4_OUT
  local proj="$1" tool="$2" cmd="$3" pyp="${4:-}" ev
  ev=$(T="$tool" CMD="$cmd" python3 -c 'import os,json; print(json.dumps({"event":"PreToolUse","tool_name":os.environ["T"],"tool_input":{"command":os.environ["CMD"]}}))')
  R4_OUT=$(cd "$proj" || exit 1; printf '%s' "$ev" | PYTHONPATH="$pyp" AGENT_SESSION_ID=mine AGENT_PROJECT_DIR="$proj" bash "$R4" 2>"$TMP_ROOT/r4.err" || true)
  R4_ERR=$(cat "$TMP_ROOT/r4.err")
  R4_DEC=$(decision_of "$R4_OUT")
}
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
P=$(mkgit r4a); r4lock "$P" ship-it "$NOW"
r4 "$P" Bash 'make ship'
[[ $R4_DEC == allow ]]; check "no-config: custom trigger not a resource (allow)" $?
cat > "$P/.agent/hook-config.yml" <<'YML'
resources:
  ship-it:
    triggers:
      - 'make ship'
      - '^release\.sh'
    auto_expire_minutes: 1
YML
r4 "$P" Bash 'make ship'
[[ $R4_DEC == ask && "$R4_OUT" == *"ship-it"* ]]; check "consume: config trigger maps command to resource -> ask" $?
r4 "$P" Bash 'release.sh --prod'
[[ $R4_DEC == ask ]]; check "consume: second trigger (python re) -> ask" $?
r4 "$P" Bash 'make test'
[[ $R4_DEC == allow ]]; check "non-matching command stays allow" $?
r4lock "$P" ship-it "2020-01-01T00:00:00Z"
r4 "$P" Bash 'make ship'
[[ $R4_DEC == ask ]]; check "auto_expire_minutes is not honoured: an old claim still blocks (expiry would weaken)" $?
r4lock "$P" production-deploy "$NOW"
r4 "$P" Bash 'fly deploy'
[[ $R4_DEC == ask && "$R4_OUT" == *production-deploy* ]]; check "additive: built-in trigger still resolves with a config present" $?
cat > "$P/.agent/hook-config.yml" <<'YML'
resources:
  elsewhere:
    triggers: ['fly deploy']
YML
r4 "$P" Bash 'fly deploy'
[[ $R4_DEC == ask && "$R4_OUT" == *production-deploy* ]]; check "additive: config cannot re-route a built-in trigger to another resource" $?
r4lock "$P" ship-it "$NOW"
cat > "$P/.agent/hook-config.yml" <<'YML'
resources:
  ship-it:
    triggers: ['make ship']
YML
r4 "$P" Bash 'make ship' "$NOYAML"
[[ $R4_DEC == allow && "$R4_ERR" == *PyYAML* ]]; check "noyaml: yml trigger inactive + PyYAML warning, no new refusal" $?
rm "$P/.agent/hook-config.yml"
printf '{"resources":{"ship-it":{"triggers":["make ship"]}}}' > "$P/.agent/hook-config.json"
r4 "$P" Bash 'make ship' "$NOYAML"
[[ $R4_DEC == ask ]]; check "noyaml: json trigger still consumed" $?
cat > "$P/.agent/hook-config.json" <<'JSON'
{"resources":{"ship-it":{"triggers":["(unclosed","make ship"]},"Bad Name!":{"triggers":["make ship"]}}}
JSON
r4 "$P" Bash 'make ship'
[[ $R4_DEC == ask && "$R4_ERR" == *ignored* ]]; check "bad regex ignored + warned, good sibling effective" $?
cat > "$P/.agent/hook-config.json" <<'JSON'
{"resources":{"Bad Name!":{"triggers":["make ship"]}}}
JSON
r4 "$P" Bash 'make ship'
[[ $R4_DEC == allow && "$R4_ERR" == *ignored* ]]; check "invalid resource name ignored + warned" $?
cat > "$P/.agent/hook-config.json" <<'JSON'
{"resources":{"mcp-thing":{"triggers":["^mcp__vendor__push$"]}}}
JSON
r4lock "$P" mcp-thing "$NOW"
r4 "$P" mcp__vendor__push ''
[[ $R4_DEC == ask && "$R4_OUT" == *mcp-thing* ]]; check "consume: trigger matches an MCP tool name" $?
rm -f "$P/.agent/hook-config.json"

echo
echo "=== (J) docs and schema claims match the wiring ==="
! grep -q 'no hook reads this block' "$REPO_ROOT/docs/customization.md"; check "customization.md no longer claims no hook reads the block" $?
! grep -q 'auto_expire_minutes' "$REPO_ROOT/templates/hook-config.yml.template" \
  || grep -qi 'not wired\|not honoured\|not honored' "$REPO_ROOT/templates/hook-config.yml.template"
check "template: auto_expire_minutes removed or marked not wired" $?
grep -q 'risk_areas.data' "$REPO_ROOT/docs/hook-config.md"; check "hook-config.md documents the wired fields" $?

echo
echo "risk-area-config-test: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
