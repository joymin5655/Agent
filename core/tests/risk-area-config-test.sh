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
  ev=$(CMD="$cmd" python3 -c 'import os,json; e={"event":"PreToolUse","tool_name":"Bash","tool_input":{"command":os.environ["CMD"]}}
if os.environ.get("EVCWD"): e["cwd"]=os.environ["EVCWD"]
print(json.dumps(e))')
  PTG_OUT=$(cd "$proj" || exit 1; printf '%s' "$ev" | PYTHONPATH="$pp" AGENT_PROJECT_DIR="$proj" timeout "${PTG_TIMEOUT:-60}" bash "${PTG_SCRIPT:-$PTG}" 2>"$TMP_ROOT/ptg.err" || true)
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
  R4_OUT=$(cd "$proj" || exit 1; printf '%s' "$ev" | PYTHONPATH="$pyp" AGENT_SESSION_ID=mine AGENT_PROJECT_DIR="$proj" timeout 12 bash "$R4" 2>"$TMP_ROOT/r4.err" || true)
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
echo "=== (K) r1: catastrophic regex in the SCREENING stage is bounded and ignored ==="
PATHO=('(?:|){40}(?!)' "$(python3 -c 'print("(|)"*40+"(?!)")')" '(?:(|)|(|)){16}')
now_ms() { echo $(( $(date +%s%N) / 1000000 )); }
timed_ptg() { # timed_ptg <project> <cmd>  -> PTG_* and ELAPSED_MS
  local t0; t0=$(now_ms); PTG_TIMEOUT=12 ptg "$1" "$2"; ELAPSED_MS=$(( $(now_ms) - t0 ))
}
for area in data deploy payment; do
  for pi in 0 1 2; do
    P=$(mkproj "ptg-k-$area-$pi")
    cat > "$P/.agent/hook-config.yml" <<YML
risk_areas:
  secrets:
    paths:
      - 'vault/**'
  $area:
    pattern:
      - '${PATHO[$pi]}'
      - '^db/migrations/.*\.sql\$'
YML
    timed_ptg "$P" 'cp a src/x.txt'
    [[ "$PTG_DEC" == allow && $ELAPSED_MS -le 3000 ]]; check "$area/P$pi: cp a src/x.txt allow within 3s (${ELAPSED_MS}ms)" $?
    if [[ $pi -eq 2 ]]; then   # P2 matches "" at once: dropped by the universe screen, no budget involved
      [[ "$PTG_ERR" == *ignored* ]]; check "$area/P2: pattern ignored + warned" $?
    else
      [[ "$PTG_ERR" == *ignored* && "$PTG_ERR" == *budget* ]]; check "$area/P$pi: pattern ignored + warned (budget)" $?
    fi
    timed_ptg "$P" 'cp vault/k src/x.txt'
    [[ "$PTG_DEC" == deny && $ELAPSED_MS -le 3000 ]]; check "$area/P$pi: cp vault/k deny, 11b not delayed or suppressed (${ELAPSED_MS}ms)" $?
    if [[ $pi -eq 0 ]]; then
      timed_ptg "$P" 'echo hi > src/x.txt'
      [[ "$PTG_DEC" == allow && $ELAPSED_MS -le 3000 ]]; check "$area/P0: redirect write allow within 3s" $?
      timed_ptg "$P" 'git add src/x.txt'
      [[ "$PTG_DEC" == allow && $ELAPSED_MS -le 3000 ]]; check "$area/P0: git add allow within 3s" $?
      timed_ptg "$P" 'touch db/migrations/a.sql'
      [[ "$PTG_DEC" == ask ]]; check "$area/P0: good sibling pattern still effective" $?
    fi
  done
done
for pi in 0 1 2; do
  P=$(mkgit "r4-k-$pi"); r4lock "$P" ship-it "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  cat > "$P/.agent/hook-config.yml" <<YML
resources:
  ship-it:
    triggers:
      - '${PATHO[$pi]}'
      - 'make ship'
YML
  t0=$(now_ms); r4 "$P" Bash 'make ship'; el=$(( $(now_ms) - t0 ))
  [[ $R4_DEC == ask && $el -le 3000 ]]; check "r4/P$pi: good sibling trigger effective within 3s (${el}ms)" $?
  if [[ $pi -eq 2 ]]; then [[ "$R4_ERR" == *ignored* ]]; else [[ "$R4_ERR" == *ignored* && "$R4_ERR" == *budget* ]]; fi
  check "r4/P$pi: pattern ignored + warned" $?
  t0=$(now_ms); r4 "$P" Bash 'cp a b'; el=$(( $(now_ms) - t0 ))
  [[ $R4_DEC == allow && $el -le 3000 ]]; check "r4/P$pi: unrelated command allow within 3s (${el}ms)" $?
done
for pi in 0 1 2; do
  P=$(mkproj "cli-k-$pi")
  cat > "$P/.agent/hook-config.yml" <<YML
risk_areas:
  payment:
    pattern:
      - '${PATHO[$pi]}'
      - '^pay/'
YML
  t0=$(now_ms); CLI_OUT=$(printf 'a\npay/x\n' | timeout 10 python3 "$HC" risk-paths "$P" auto-ship 2>/dev/null); el=$(( $(now_ms) - t0 ))
  [[ "$CLI_OUT" == *$'HIT\tpayment\tpay/x'* && $el -le 3000 ]]; check "risk-paths/P$pi (pre-push, auto-ship loader): bounded, good sibling HIT (${el}ms)" $?
done

echo
echo "=== (L) r1: worst-case config volume finishes inside ONE process-wide deadline ==="
P=$(mkproj ptg-l)
python3 - "$P" <<'PY'
import json, sys
root = sys.argv[1]
cfg = {"risk_areas": dict((a, {"pattern": ["^(a|aa|%d)+$" % i for i in range(20)]}) for a in ("data", "deploy", "payment"))}
json.dump(cfg, open(root + "/.agent/hook-config.json", "w"))
PY
LONGA=$(python3 -c 'print("a"*900+"!")')
t0=$(now_ms); PTG_TIMEOUT=12 ptg "$P" "git add $LONGA"; el=$(( $(now_ms) - t0 ))
[[ "$PTG_DEC" == allow && $el -le 4500 ]]; check "pre-tool-guard: 3 areas x 20 slow patterns x long path <= 4.5s (${el}ms)" $?
[[ "$PTG_ERR" == *budget* ]]; check "pre-tool-guard: exhausted budget is warned" $?
P=$(mkgit r4-l); r4lock "$P" res0 "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
python3 - "$P" <<'PY'
import json, sys
root = sys.argv[1]
cfg = {"resources": dict(("res%d" % i, {"triggers": ["^(a|aa|%d)+$" % (i * 20 + j) for j in range(20)]}) for i in range(20))}
json.dump(cfg, open(root + "/.agent/hook-config.json", "w"))
PY
t0=$(now_ms); r4 "$P" Bash "$LONGA"; el=$(( $(now_ms) - t0 ))
[[ $R4_DEC == allow && $el -le 4500 ]]; check "r4: 20 resources x 20 slow triggers x long command <= 4.5s (${el}ms)" $?
[[ "$R4_ERR" == *budget* ]]; check "r4: exhausted budget is warned" $?

echo
echo "=== (M) r1: write-target extraction (full hook, event cwd) ==="
P=$(mkproj ptg-m); mkdir -p "$P/db/migrations" "$P/src"
printf '%s' $'risk_areas:\n  data:\n    pattern: \'^.*/migrations/.*\\.sql$\'\n' > "$P/.agent/hook-config.yml"
ptg_cwd() { # ptg_cwd <name> <event-cwd> <command> <expect>
  EVCWD="$2" ptg "$P" "$3"
  [[ "$PTG_DEC" == "$4" ]]; local rc=$?
  [[ $rc -ne 0 ]] && echo "       got=$PTG_DEC cmd=$3 err=$PTG_ERR"
  check "$1 ($4)" $rc
}
ptg_cwd "cwd=db/migrations: touch a.sql"            "$P/db/migrations" 'touch a.sql' ask
ptg_cwd "cwd=db/migrations: redirect > a.sql"       "$P/db/migrations" 'echo x > a.sql' ask
ptg_cwd "cwd=db: git add migrations/a.sql"          "$P/db" 'git add migrations/a.sql' ask
ptg_cwd "cwd=src: ../db/migrations/a.sql"           "$P/src" 'touch ../db/migrations/a.sql' ask
ptg_cwd "cwd outside repo: touch a.sql is not ours" "/tmp" 'touch a.sql' allow
ptg_cwd "cwd outside repo: absolute path inside"    "/tmp" "touch $P/db/migrations/a.sql" ask
ptg_cwd "git -C db add migrations/a.sql"            "$P" 'git -C db add migrations/a.sql' ask
ptg_cwd "git -C db/migrations add a.sql"           "$P" 'git -C db/migrations add a.sql' ask
ptg_cwd "bash -c with a trailing ; true"            "$P" "bash -c 'touch db/migrations/a.sql; true'" ask
ptg_cwd "bash -c control (no trailing command)"     "$P" "bash -c 'touch db/migrations/a.sql'" ask
ptg_cwd "sh -c nested quotes"                       "$P" "sh -c \"cp x.sql db/migrations/b.sql && true\"" ask
ptg_cwd "command substitution body"                 "$P" 'echo $(touch db/migrations/a.sql)' ask
ptg_cwd "redirect >|"                               "$P" 'printf x >| db/migrations/a.sql' ask
ptg_cwd "redirect &>"                               "$P" 'make &> db/migrations/a.sql' ask
ptg_cwd "redirect &>>"                              "$P" 'make &>> db/migrations/a.sql' ask
ptg_cwd "redirect 2>"                               "$P" 'make 2> db/migrations/a.sql' ask
ptg_cwd "redirect 1>>"                              "$P" 'make 1>>db/migrations/a.sql' ask
ptg_cwd "sed --in-place=.bak"                       "$P" "sed --in-place=.bak 's/a/b/' db/migrations/a.sql" ask
ptg_cwd "sed --in-place"                            "$P" "sed --in-place 's/a/b/' db/migrations/a.sql" ask
ptg_cwd "sed -i -e script"                          "$P" "sed -i -e 's/a/b/' db/migrations/a.sql" ask
ptg_cwd "perl -pi -e"                               "$P" "perl -pi -e 's/a/b/' db/migrations/a.sql" ask
ptg_cwd "git checkout -- path"                      "$P" 'git checkout -- db/migrations/a.sql' ask
ptg_cwd "git restore path"                          "$P" 'git restore db/migrations/a.sql' ask
ptg_cwd "cp into a directory"                       "$P" 'cp x.sql db/migrations/' ask
ptg_cwd "cp -t DIR"                                 "$P" 'cp -t db/migrations x.sql' ask
ptg_cwd "mv: the SOURCE disappears"                 "$P" 'mv db/migrations/a.sql /tmp/gone.sql' ask
ptg_cwd "ln -s into the directory"                  "$P" 'ln -s ../x db/migrations/l.sql' ask
ptg_cwd "dd of="                                    "$P" 'dd if=/dev/zero of=db/migrations/a.sql' ask
echo "  -- over-asks that must stay allowed --"
ptg_cwd "quoted '> path' is data"                   "$P" "printf '%s\n' '> db/migrations/a.sql x'" allow
ptg_cwd "quoted '; touch path' is data"             "$P" "printf '%s\n' '; touch db/migrations/a.sql x'" allow
ptg_cwd "heredoc body is data"                      "$P" $'cat <<\'EOF\'\ntouch db/migrations/a.sql\nEOF' allow
ptg_cwd "quoted echo with >"                        "$P" "echo 'a > db/migrations/x.sql y'" allow
ptg_cwd "../ is normalised (db/a.sql)"              "$P" 'touch db/migrations/../a.sql' allow
ptg_cwd "cp SOURCE is only read"                    "$P" 'cp db/migrations/a.sql /tmp/copy.sql' allow
ptg_cwd "sed -i script operand is not a path"      "$P" "sed -i 'db/migrations/x.sql' f" allow
ptg_cwd "sed -n without -i only reads"              "$P" "sed -n -e p db/migrations/a.sql" allow
ptg_cwd "< input redirect is not a target (tee)"    "$P" 'tee out.txt < db/migrations/a.sql' allow
ptg_cwd "< input redirect is not a target (xargs)"  "$P" 'xargs rm < db/migrations/list.sql' allow
ptg_cwd "git checkout <ref> (no --) is no path"     "$P" 'git checkout db/migrations/a.sql' allow
ptg_cwd "perl script file operand is not a target"  "$P" 'perl -i db/migrations/s.pl f.txt' allow

echo
echo "=== (N) r1: truncation is never silent ==="
P=$(mkproj cli-n)
printf 'risk_areas:\n  payment:\n    pattern: "^pay/"\n' > "$P/.agent/hook-config.yml"
python3 -c 'print("\n".join("src/f%d" % i for i in range(2100)) + "\npay/secret.py")' > "$TMP_ROOT/files-2100"
CLI_OUT=$(timeout 10 python3 "$HC" risk-paths "$P" auto-ship < "$TMP_ROOT/files-2100" 2>/dev/null)
[[ "$CLI_OUT" == *$'HIT\tpayment\tpay/secret.py'* ]]; check "2100 paths, match LAST: still a HIT (processed in full)" $?
python3 -c 'print("\n".join("src/f%d" % i for i in range(20001)))' > "$TMP_ROOT/files-20001"
CLI_OUT=$(timeout 10 python3 "$HC" risk-paths "$P" auto-ship < "$TMP_ROOT/files-20001" 2>"$TMP_ROOT/cli.err")
[[ "$CLI_OUT" == *$'HIT\tpayment\t(file list too large'* && "$(cat "$TMP_ROOT/cli.err")" == *truncat* ]]
check "20001 paths: warned + fail-closed HIT on every area with a pattern" $?
[[ "$CLI_OUT" != *$'HIT\tdata'* ]]; check "areas without a pattern are not marked" $?
P=$(mkgit as-n)
printf 'risk_areas:\n  payment:\n    pattern: "^pay/"\n' > "$P/.agent/hook-config.yml"
as "$P" "" $(python3 -c 'print(" ".join("src/f%d" % i for i in range(20001)))')
[[ $AS_RC -eq 14 ]]; check "auto-ship: truncated list aborts (exit 14, fail-closed)" $?
rm "$P/.agent/hook-config.yml"
as "$P" "" $(python3 -c 'print(" ".join("src/f%d" % i for i in range(20001)))')
[[ $AS_RC -eq 17 ]]; check "auto-ship: same big list without config is unaffected" $?
W=$(mkrepo pp-n)
(cd "$W" && git checkout -q -B feat origin/main && python3 - <<'PY'
import os
os.makedirs("big", exist_ok=True)
for i in range(20001):
    open("big/f%d" % i, "w").write("x")
PY
git add big && git commit -q -m big)
printf 'risk_areas:\n  payment:\n    pattern: "^pay/"\n    decision: deny\n' > "$W/.agent/hook-config.yml"
pp "$W"
[[ $PP_RC -eq 14 && "$PP_ERR" == *"[BLOCK payment]"* ]]; check "pre-push: truncation + declared deny blocks (exit 14)" $?
printf 'risk_areas:\n  payment:\n    pattern: "^pay/"\n' > "$W/.agent/hook-config.yml"
pp "$W"
[[ $PP_RC -eq 0 && "$PP_ERR" == *"[ADVISORY payment]"* ]]; check "pre-push: truncation without deny is an advisory, not a block" $?
P=$(mkproj ptg-n)
printf '%s' $'risk_areas:\n  data:\n    pattern: \'^db/migrations/.*\\.sql$\'\n' > "$P/.agent/hook-config.yml"
FILLER=$(python3 -c 'print("true; " * 700)')
ptg "$P" "${FILLER}touch src/x"
[[ "$PTG_DEC" == ask && "$PTG_ERR" == *truncat* ]]; check "pre-tool-guard: oversized command asks (and warns) when an area is declared" $?
FILLER=$(python3 -c 'print("true; " * 50)')
ptg "$P" "${FILLER}touch src/x"
[[ "$PTG_DEC" == allow ]]; check "pre-tool-guard: moderate command is fully analysed (allow)" $?
ptg "$P" "${FILLER}touch db/migrations/a.sql"
[[ "$PTG_DEC" == ask ]]; check "pre-tool-guard: match at the END of a moderate command is found" $?
ptg "$P" ": $(python3 -c 'print("x" * 70000)'); touch src/x"
[[ "$PTG_DEC" == ask && "$PTG_ERR" == *truncat* ]]; check "pre-tool-guard: command over 64 KiB asks (and warns), never silently cut" $?
Q=$(mkproj ptg-n0)
ptg "$Q" "$(python3 -c 'print("true; " * 700)')touch src/x"
[[ "$PTG_DEC" == allow ]]; check "pre-tool-guard: oversized command without declared areas is unaffected" $?

echo
echo "=== (O) r1: decision keyword is case-insensitive ==="
P=$(mkproj ptg-o)
printf '%s' $'risk_areas:\n  data:\n    pattern: \'^db/migrations/.*\\.sql$\'\n    decision: DENY\n' > "$P/.agent/hook-config.yml"
ptg_expect "decision: DENY -> deny"   "$P" 'git add db/migrations/001.sql' deny
printf '%s' $'risk_areas:\n  data:\n    pattern: \'^db/migrations/.*\\.sql$\'\n    decision: Deny\n' > "$P/.agent/hook-config.yml"
ptg_expect "decision: Deny -> deny"   "$P" 'git add db/migrations/001.sql' deny
printf '%s' $'risk_areas:\n  data:\n    pattern: \'^db/migrations/.*\\.sql$\'\n    decision: ASK\n' > "$P/.agent/hook-config.yml"
ptg_expect "decision: ASK -> ask"     "$P" 'git add db/migrations/001.sql' ask
W=$(mkrepo pp-o); commit_files "$W" app/migrations/1.sql
printf '%s' $'risk_areas:\n  data:\n    pattern: \'^zzz/\'\n    decision: DENY\n' > "$W/.agent/hook-config.yml"
pp "$W"
[[ $PP_RC -eq 12 ]]; check "pre-push: decision: DENY blocks (exit 12)" $?


echo
echo "=== (P) r1: the secrets verdict (11b) is settled BEFORE any config evaluation ==="
HANG="$TMP_ROOT/hooks-hang"
cp -r "$REPO_ROOT/core/hooks" "$HANG"
cat >> "$HANG/hook_config.py" <<'PY'


def risk_command_report(repo_root, command, cwd=""):  # test double: config evaluation that never returns
    import time
    time.sleep(120)
PY
P=$(mkproj ptg-p)
cat > "$P/.agent/hook-config.yml" <<'YML'
risk_areas:
  secrets:
    paths:
      - 'vault/**'
  data:
    pattern: '^db/.*'
YML
t0=$(now_ms); PTG_SCRIPT="$HANG/pre-tool-guard.sh" PTG_TIMEOUT=20 ptg "$P" 'cp vault/k src/x.txt'; el=$(( $(now_ms) - t0 ))
[[ "$PTG_DEC" == deny && $el -le 3000 ]]; check "hung config evaluation: cp vault/k is still denied at once (${el}ms)" $?
t0=$(now_ms); PTG_SCRIPT="$HANG/pre-tool-guard.sh" PTG_TIMEOUT=20 ptg "$P" 'cp a src/x.txt'; el=$(( $(now_ms) - t0 ))
[[ "$PTG_DEC" == allow && $el -le 8000 ]]; check "hung config evaluation: outer timeout lets other commands through (${el}ms)" $?

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
