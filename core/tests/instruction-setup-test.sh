#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# Isolate every default target: nothing in this test may touch the real home.
export HOME="$WORK/home"
mkdir -p "$HOME" "$WORK/project"
cd "$WORK/project"
unset CODEX_HOME GEMINI_GLOBAL_AGENTS DO_ANTIGRAVITY DO_LAUNCHERS
# setup.sh's install-location and auto-yes overrides: inherited, a regressed --dry-run
# refusal would install outside the temporary HOME before any check below could see it.
unset AGENT_ANTIGRAVITY_PLUGIN_DIR AGENT_BRAIN_DIR AGENT_CLAUDE_USER_CONFIG \
    AGENT_CODEX_TIERS_FILE AGENT_COMMANDS_DIR AGENT_GATE_SINK_DIR AGENT_GLOBAL_SETTINGS \
    AGENT_HOOK_MANIFEST AGENT_PLUGIN_CACHE_ROOT AGENT_PROFILE_FILE AGENT_SETUP_YES \
    AGENT_BOOTSTRAP_STDIN_IS_TTY CLAUDE_CONFIG_DIR CLAUDE_SETTINGS CODEX_CONFIG \
    CODEX_SKILLS_DIR GEMINI_SETTINGS
export AGENT_SKIP_CLAUDE_MCP=1
export CLAUDE_GLOBAL_INSTRUCTIONS="$WORK/CLAUDE.md"
export CODEX_GLOBAL_AGENTS="$WORK/AGENTS.md"
printf 'personal Claude\n' > "$CLAUDE_GLOBAL_INSTRUCTIONS"
printf 'personal Codex\n' > "$CODEX_GLOBAL_AGENTS"
if bash "$ROOT/setup.sh" --instructions-only --dry-run > "$WORK/check.log" </dev/null; then
    echo 'FAIL: missing managed block must report drift'; exit 1
fi
[[ "$(cat "$CLAUDE_GLOBAL_INSTRUCTIONS")" == 'personal Claude' ]]
bash "$ROOT/setup.sh" --instructions-only > "$WORK/apply.log" </dev/null
bash "$ROOT/setup.sh" --instructions-only --dry-run > "$WORK/current.log" </dev/null
grep -q 'personal Claude' "$CLAUDE_GLOBAL_INSTRUCTIONS"
grep -q 'personal Codex' "$CODEX_GLOBAL_AGENTS"

# agy target: skipped (and ~/.gemini not created) unless ~/.gemini already exists.
if [[ -e "$HOME/.gemini" ]] || grep -q '\.gemini' "$WORK/apply.log"; then
    echo 'FAIL: --instructions-only must not target or create ~/.gemini when it is absent'; exit 1
fi
mkdir "$HOME/.gemini"
bash "$ROOT/setup.sh" --instructions-only > "$WORK/gemini-apply.log" </dev/null
grep -q 'agent-harness:operating-contract:start' "$HOME/.gemini/AGENTS.md" || {
    echo 'FAIL: --instructions-only must sync ~/.gemini/AGENTS.md when ~/.gemini exists'; exit 1
}
bash "$ROOT/setup.sh" --instructions-only --dry-run > "$WORK/gemini-current.log" </dev/null
grep -q "OK $HOME/.gemini/AGENTS.md" "$WORK/gemini-current.log" || {
    echo 'FAIL: repeat check must report the agy target as current'; exit 1
}

if bash "$ROOT/setup.sh" --instructions-only --codex > "$WORK/reject.log" 2>&1 </dev/null; then
    echo 'FAIL: mixed installation mode must be rejected'; exit 1
fi
grep -q 'cannot be combined with other install modes' "$WORK/reject.log" || {
    echo 'FAIL: mixed mode must be rejected by the mode-isolation guard, not by arg parsing'; exit 1
}
# --gemini retired 2026-10-09 (legacy/lanes-2026-10/gemini/): now an unknown arg, exit 2 before any install
if bash "$ROOT/setup.sh" --gemini > "$WORK/gemini.log" 2>&1 </dev/null; then
    echo 'FAIL: retired --gemini flag must be rejected'; exit 1
fi
grep -q 'unknown arg: --gemini' "$WORK/gemini.log" || {
    echo 'FAIL: retired --gemini flag must report an unknown arg'; exit 1
}

# --dry-run outside --bootstrap / --instructions-only: exit 2, nothing written.
# A fresh empty HOME with no target overrides, so any real install would show up there.
DRY_HOME="$WORK/dry-home"
mkdir -p "$DRY_HOME"
dry_case=0
for args in "--claude --dry-run" "--codex --dry-run" "--all --dry-run" \
            "--doctor --dry-run" "--dry-run"; do
    dry_case=$((dry_case + 1))
    log="$WORK/dry-$dry_case.log"
    rc=0
    # shellcheck disable=SC2086  # $args is a deliberate word-split flag list
    env -u CLAUDE_GLOBAL_INSTRUCTIONS -u CODEX_GLOBAL_AGENTS HOME="$DRY_HOME" \
        bash "$ROOT/setup.sh" $args > "$log" 2>&1 </dev/null || rc=$?
    if [[ $rc -ne 2 ]]; then
        echo "FAIL: setup.sh $args must exit 2 (got $rc)"; exit 1
    fi
    grep -q -- '--dry-run applies only to --bootstrap and --instructions-only' "$log" || {
        echo "FAIL: setup.sh $args must explain the --dry-run restriction"; exit 1
    }
    if [[ -n "$(find "$DRY_HOME" -mindepth 1 -print -quit)" ]]; then
        echo "FAIL: setup.sh $args wrote into HOME"; exit 1
    fi
done

# The two supported --dry-run pairings keep working (not rejected with exit 2).
rc=0
env -u CLAUDE_GLOBAL_INSTRUCTIONS -u CODEX_GLOBAL_AGENTS HOME="$DRY_HOME" \
    bash "$ROOT/setup.sh" --bootstrap --dry-run > "$WORK/bootstrap.log" 2>&1 </dev/null || rc=$?
if [[ $rc -eq 2 ]] || grep -q -- '--dry-run applies only' "$WORK/bootstrap.log"; then
    echo 'FAIL: --bootstrap --dry-run must still run'; exit 1
fi
rc=0
bash "$ROOT/setup.sh" --instructions-only --dry-run > "$WORK/instr-dry.log" 2>&1 </dev/null || rc=$?
if [[ $rc -ne 0 ]]; then
    echo "FAIL: --instructions-only --dry-run on synced targets must exit 0 (got $rc)"; exit 1
fi
echo 'PASS: read-only drift, claude/codex/agy targets, personal text, repeat check,' \
     'mode isolation, retired --gemini, --dry-run restriction'
