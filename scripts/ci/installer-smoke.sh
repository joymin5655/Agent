#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

make_repo() {
  local name="$1"
  local repo="$TMPDIR/$name"
  mkdir -p "$repo"
  git init -q "$repo"
  printf '%s\n' "$repo"
}

run_setup() {
  local repo="$1"
  local home="$2"
  shift 2
  mkdir -p "$home"
  (
    cd "$repo"
    HOME="$home" bash "$ROOT/setup.sh" "$@"
  )
}

assert_file() {
  [[ -f "$1" ]] || fail "expected file: $1"
}

assert_dir() {
  [[ -d "$1" ]] || fail "expected directory: $1"
}

assert_missing() {
  [[ ! -e "$1" ]] || fail "expected missing: $1"
}

assert_contains() {
  local file="$1"
  local needle="$2"
  grep -qF "$needle" "$file" || fail "expected $file to contain $needle"
}

assert_no_forbidden_markers() {
  local root="$1"
  local pattern='WD_BLACK|AirLens-platform|Obsidian-airlens|/Users/joymin|AIRLENS_'
  local found=0
  while IFS= read -r -d '' file; do
    if grep -nE "$pattern" "$file" >/dev/null 2>&1; then
      echo "forbidden marker in $file" >&2
      grep -nE "$pattern" "$file" >&2 || true
      found=1
    fi
  done < <(find "$root" -path '*/.git' -prune -o -type f -print0)
  [[ $found -eq 0 ]] || fail "default install leaked project-specific markers"
}

minimal_repo="$(make_repo minimal)"
minimal_home="$TMPDIR/home-minimal"
run_setup "$minimal_repo" "$minimal_home" --profile minimal
assert_file "$minimal_repo/.agent-harness/config.json"
assert_file "$minimal_repo/.agent-harness/agent-registry.json"
assert_dir "$minimal_repo/.claude/rules"
assert_file "$minimal_repo/gitleaks.toml"
assert_file "$minimal_repo/CLAUDE.md"
assert_file "$minimal_repo/scripts/hooks/pre-tool-guard.sh"
assert_missing "$minimal_repo/.claude/settings.local.json"
assert_missing "$minimal_home/.claude"

dry_repo="$(make_repo dry-run)"
dry_home="$TMPDIR/home-dry"
run_setup "$dry_repo" "$dry_home" --dry-run --profile claude --project
assert_missing "$dry_repo/.agent-harness"
assert_missing "$dry_repo/.claude"
assert_missing "$dry_home/.claude"

claude_repo="$(make_repo claude)"
claude_home="$TMPDIR/home-claude"
run_setup "$claude_repo" "$claude_home" --profile claude --project --no-hooks
assert_file "$claude_repo/.claude/settings.local.template.json"
assert_file "$claude_repo/.claude/agents/supervisor.md"
assert_file "$claude_repo/.claude/commands/project-init.md"
assert_missing "$claude_repo/scripts/hooks/supervisor.py"
assert_missing "$claude_home/.claude"

multi_repo="$(make_repo multi-agent)"
multi_home="$TMPDIR/home-multi"
run_setup "$multi_repo" "$multi_home" --profile multi-agent --project --no-hooks
assert_file "$multi_repo/scripts/infra/agent-session.sh"
assert_missing "$multi_repo/scripts/hooks/r4-mutex-check.sh"
assert_missing "$multi_home/.claude"

full_repo="$(make_repo full)"
full_home="$TMPDIR/home-full"
run_setup "$full_repo" "$full_home" --profile full --project --no-global
assert_file "$full_repo/.claude/settings.local.template.json"
assert_file "$full_repo/.codex/skills/code-explorer/SKILL.md"
assert_file "$full_repo/scripts/infra/agent-session.sh"
assert_file "$full_repo/scripts/hooks/supervisor.py"
assert_missing "$full_home/.claude"
assert_no_forbidden_markers "$full_repo"

skip_repo="$(make_repo skip-existing)"
skip_home="$TMPDIR/home-skip"
run_setup "$skip_repo" "$skip_home" --profile minimal
printf 'custom local instructions\n' > "$skip_repo/CLAUDE.md"
printf '{"sentinel":true}\n' > "$skip_repo/.agent-harness/config.json"
run_setup "$skip_repo" "$skip_home" --profile minimal
assert_contains "$skip_repo/CLAUDE.md" "custom local instructions"
assert_contains "$skip_repo/.agent-harness/config.json" '"sentinel":true'

backup_repo="$(make_repo backup)"
backup_home="$TMPDIR/home-backup"
run_setup "$backup_repo" "$backup_home" --profile minimal
printf '{"sentinel":true}\n' > "$backup_repo/.agent-harness/config.json"
run_setup "$backup_repo" "$backup_home" --profile minimal --force --backup
assert_contains "$backup_repo/.agent-harness/config.json" '"schema_version"'
backup_count="$(find "$backup_repo/.agent-harness" -name 'config.json.bak.*' -type f | wc -l | tr -d ' ')"
[[ "$backup_count" -ge 1 ]] || fail "expected config backup file"

global_repo="$(make_repo global-opt-in)"
global_home="$TMPDIR/home-global"
run_setup "$global_repo" "$global_home" --profile claude --project --global --no-hooks
assert_file "$global_home/.claude/CLAUDE.md"
assert_file "$global_home/.claude/commands/project-init.md"

airlens_repo="$(make_repo airlens-example)"
airlens_home="$TMPDIR/home-airlens"
run_setup "$airlens_repo" "$airlens_home" --profile airlens-example --project
assert_file "$airlens_repo/examples/airlens/README.md"
assert_missing "$airlens_repo/.agent-harness"
assert_missing "$airlens_home/.claude"

echo "[ok] installer smoke tests passed"
