#!/usr/bin/env bash
# pre-tool-guard-test.sh — verify core/hooks/pre-tool-guard.sh Bash guards.
#
# Feeds canonical PreToolUse event JSON (a Bash tool_input.command) to the hook
# via stdin and asserts the emitted permissionDecision (deny / ask / allow).
# `allow` == empty stdout (no decision object).
#
# Covers, per rule:
#   Existing (regression — this hook had no test before P3-3):
#     - broad rm -rf / -> deny
#     - force push to main -> deny
#     - git reset --hard -> deny
#     - DROP TABLE -> ask
#     - cat secrets/ -> deny
#     - a benign command -> allow
#   New (P3-3):
#     - git commit --no-verify -> ask         (bypasses the repo's own commit gate)
#     - git commit -n -m "x"   -> ask
#     - git commit -nm "x"     -> ask          (bundled short flag; git reads -n -m)
#     - git commit -vn         -> ask          (bundled, -n not first)
#     - git -c k=v commit --no-verify -> ask   (global opt before subcommand)
#     - git -c core.hooksPath=… commit -> ask  (hooks disabled with no --no-verify)
#     - git push   --no-verify -> ask
#     - git push -n            -> allow        (that's --dry-run, NOT no-verify)
#     - normal git commit -m   -> allow        (no false positive)
#     - commit msg mentions -n -> allow        (message text is stripped before match)
#     - sed -i on .eslintrc    -> ask          (linter-config tamper via Bash)
#     - rm .prettierrc         -> ask
#     - > eslint.config.js      -> ask
#     - cat .eslintrc          -> allow        (reading a config is not tampering)
#     - cat .eslintrc > out     -> allow        (read redirected elsewhere, not the config)
#     - edit tsconfig.json     -> allow        (deliberately out of scope — no FP)
#
# Usage: bash core/tests/pre-tool-guard-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/core/hooks/pre-tool-guard.sh"

PASS=0
FAIL=0

# run_case <name> <command-string> <expect: deny|ask|allow>
run_case() {
  local name="$1" cmd="$2" expect="$3"
  local event out got
  event=$(printf '%s' "$cmd" | python3 -c 'import sys,json; print(json.dumps({"event":"PreToolUse","tool_name":"Bash","tool_input":{"command":sys.stdin.read()}}))')
  out=$(printf '%s' "$event" | bash "$HOOK" 2>/dev/null || true)
  got="allow"
  if [[ "$out" == *'"permissionDecision": "deny"'* || "$out" == *'"permissionDecision":"deny"'* ]]; then
    got="deny"
  elif [[ "$out" == *'"permissionDecision": "ask"'* || "$out" == *'"permissionDecision":"ask"'* ]]; then
    got="ask"
  fi
  if [[ "$got" == "$expect" ]]; then
    echo "  ok   [$name] expected=$expect"
    PASS=$((PASS + 1))
  else
    echo "  FAIL [$name] expected=$expect got=$got :: $out"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== existing rules (regression) ==="
run_case "rm-rf-root-deny"      'rm -rf /'                                deny
run_case "force-push-main-deny" 'git push origin --force main'            deny
run_case "reset-hard-deny"      'git reset --hard HEAD~1'                 deny
run_case "drop-table-ask"       'psql -c "DROP TABLE users"'              ask
run_case "cat-secrets-deny"     'cat secrets/prod.env'                    deny
run_case "benign-allow"         'ls -la && echo hello'                    allow

echo
# no-verify bypasses the repo's own pre-commit/pre-push gate (gitleaks + sanitize).
# ASK (not deny): it is a reversible gate-bypass, not irreversible destruction —
# the repo's escalation principle is ask-for-everything-except-secrets, and ask
# also de-risks a false positive from a commit message that merely mentions -n.
echo "=== P3-3: --no-verify commit/push bypass -> ask ==="
run_case "commit-no-verify-ask"      'git commit --no-verify -m "wip"'    ask
run_case "commit-n-shortflag-ask"    'git commit -n -m "wip"'             ask
run_case "commit-nm-bundled-ask"     'git commit -nm "wip"'               ask
run_case "commit-vn-bundled-ask"     'git commit -vn -m "wip"'            ask
run_case "commit-nv-bundled-ask"     'git commit -nv'                     ask
run_case "commit-c-optprefix-ask"    'git -c foo=bar commit --no-verify'  ask
run_case "commit-hookspath-ask"      'git -c core.hooksPath=/dev/null commit -m x' ask
run_case "push-no-verify-ask"        'git push --no-verify origin feat'   ask
run_case "push-dryrun-n-allow"       'git push -n origin feat'            allow
run_case "normal-commit-allow"       'git commit -m "feat: add thing"'    allow
run_case "commit-am-allow"           'git commit -am "add all files"'     allow
run_case "commit-amend-allow"        'git commit --amend --no-edit'       allow
# message that merely MENTIONS the flag is stripped before matching -> no false ask
run_case "commit-msg-mentions-n-allow"  'git commit -m "fix -n flag parsing"'   allow
run_case "commit-msg-mentions-nv-allow" 'git commit -m "add --no-verify docs"'  allow

echo
echo "=== P3-3: linter/gate config tampering via Bash -> ask ==="
run_case "sed-i-eslintrc-ask"        'sed -i "s/error/off/" .eslintrc.json'  ask
run_case "rm-prettierrc-ask"         'rm .prettierrc'                         ask
run_case "redirect-eslint-config-ask" 'echo "{}" > eslint.config.js'          ask
run_case "truncate-flake8-ask"       'truncate -s 0 .flake8'                  ask
run_case "cat-eslintrc-allow"        'cat .eslintrc.json'                     allow
# a pure READ that redirects its output ELSEWHERE must not trip the mutate guard
run_case "read-redirect-elsewhere-allow" 'cat .eslintrc.json > backup.txt'    allow
run_case "grep-config-redirect-allow"    'grep rules .eslintrc.json > /dev/null' allow
run_case "edit-tsconfig-allow"       'sed -i "s/strict/loose/" tsconfig.json' allow

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
