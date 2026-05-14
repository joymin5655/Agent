#!/usr/bin/env bash
# Agent Harness starter-kit installer.
#
# Examples:
#   bash setup.sh --profile minimal
#   bash setup.sh --profile claude --project
#   bash setup.sh --profile multi-agent --project
#   bash setup.sh --profile full --project
#   bash setup.sh --profile full --project --global
#   bash setup.sh --profile airlens-example --project
#   bash setup.sh --dry-run --profile claude --project

set -euo pipefail

AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="minimal"
PROJECT_INIT=1
FORCE=0
BACKUP=0
DRY_RUN=0
NO_HOOKS=0
GLOBAL=0
TARGET_DIR="$(pwd)"

usage() {
  cat <<'EOF'
Agent Harness starter-kit installer.

Examples:
  bash setup.sh --profile minimal
  bash setup.sh --profile claude --project
  bash setup.sh --profile multi-agent --project
  bash setup.sh --profile full --project
  bash setup.sh --profile full --project --global
  bash setup.sh --profile airlens-example --project
  bash setup.sh --dry-run --profile claude --project

Options:
  --profile <name>   minimal | claude | codex | multi-agent | full | airlens-example
  --project          install project-scoped files into the current directory (default)
  --target <dir>     install project-scoped files into a specific repository
  --global           also install Claude baseline files into ~/.claude
  --dry-run          print actions without writing
  --backup           when used with --force, back up existing files before overwrite
  --force            overwrite existing files
  --no-hooks         skip hook runtime/template installation
  --no-global        compatibility alias for the default project-only behavior
  -h, --help         show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      PROFILE="${2:-}"
      [[ -n "$PROFILE" ]] || { echo "--profile requires a value" >&2; exit 2; }
      shift 2
      ;;
    --project) PROJECT_INIT=1; shift ;;
    --target)
      TARGET_DIR="${2:-}"
      [[ -n "$TARGET_DIR" ]] || { echo "--target requires a directory" >&2; exit 2; }
      PROJECT_INIT=1
      shift 2
      ;;
    --global) GLOBAL=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --backup) BACKUP=1; shift ;;
    --force) FORCE=1; shift ;;
    --no-hooks) NO_HOOKS=1; shift ;;
    --no-global) GLOBAL=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$PROFILE" in
  minimal|claude|codex|multi-agent|full|airlens-example) ;;
  *) echo "unknown profile: $PROFILE" >&2; exit 2 ;;
esac

is_git_repo() {
  git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

say() { printf '%s\n' "$*"; }

run_cmd() {
  if [[ $DRY_RUN -eq 1 ]]; then
    say "  dry-run: $*"
  else
    "$@"
  fi
}

backup_existing() {
  local dst="$1"
  [[ -e "$dst" && $BACKUP -eq 1 && $FORCE -eq 1 ]] || return 0
  local bak="${dst}.bak.${STAMP}"
  say "  backup: $dst -> $bak"
  run_cmd mv "$dst" "$bak"
}

copy_file() {
  local src="$1" dst="$2"
  if [[ -e "$dst" && $FORCE -eq 0 ]]; then
    say "  skip (exists): $dst"
    return 0
  fi
  backup_existing "$dst"
  say "  write: $dst"
  run_cmd mkdir -p "$(dirname "$dst")"
  run_cmd cp "$src" "$dst"
}

copy_dir_contents() {
  local src="$1" dst="$2"
  [[ -d "$src" ]] || return 0
  say "  sync dir: $src -> $dst"
  run_cmd mkdir -p "$dst"
  local file rel
  while IFS= read -r -d '' file; do
    rel="${file#"$src"/}"
    copy_file "$file" "$dst/$rel"
  done < <(find "$src" -type f -print0)
}

append_gitignore() {
  local dst="$TARGET_DIR/.gitignore"
  local lines=(
    ".claude/locks/"
    ".claude/logs/"
    ".claude/settings.local.json"
    ".claude/state.local/"
    ".agent-harness/state/"
    "secrets/"
    ".env"
    ".env.*"
  )
  say "  update: $dst"
  run_cmd touch "$dst"
  if [[ $DRY_RUN -eq 0 ]]; then
    for line in "${lines[@]}"; do
      grep -qxF "$line" "$dst" || printf '%s\n' "$line" >> "$dst"
    done
  fi
}

install_global_claude() {
  [[ $GLOBAL -eq 1 ]] || return 0
  [[ -d "$AGENT_DIR/adapters/claude/global" ]] || return 0
  say "[global] ~/.claude baseline"
  copy_dir_contents "$AGENT_DIR/adapters/claude/global" "$HOME/.claude"
  copy_file "$AGENT_DIR/adapters/claude/commands/project-init.md" "$HOME/.claude/commands/project-init.md"
}

install_minimal() {
  say "[project:minimal] config, rules, gitleaks, secret guard"
  copy_dir_contents "$AGENT_DIR/core/config" "$TARGET_DIR/.agent-harness"
  copy_dir_contents "$AGENT_DIR/core/rules" "$TARGET_DIR/.claude/rules"
  copy_file "$AGENT_DIR/gitleaks.toml" "$TARGET_DIR/gitleaks.toml"
  if [[ ! -f "$TARGET_DIR/CLAUDE.md" || $FORCE -eq 1 ]]; then
    copy_file "$AGENT_DIR/templates/project/CLAUDE.md.template" "$TARGET_DIR/CLAUDE.md"
  else
    say "  skip (exists): $TARGET_DIR/CLAUDE.md"
  fi
  append_gitignore

  if [[ $NO_HOOKS -eq 0 ]]; then
    copy_file "$AGENT_DIR/core/hooks/pre-tool-guard.sh" "$TARGET_DIR/scripts/hooks/pre-tool-guard.sh"
    copy_file "$AGENT_DIR/core/hooks/context-mode-guard.sh" "$TARGET_DIR/scripts/hooks/context-mode-guard.sh"
  fi
}

install_claude() {
  say "[project:claude] Claude agents, command, settings template, supervisor hooks"
  copy_dir_contents "$AGENT_DIR/adapters/claude/agents" "$TARGET_DIR/.claude/agents"
  copy_file "$AGENT_DIR/adapters/claude/commands/project-init.md" "$TARGET_DIR/.claude/commands/project-init.md"
  copy_file "$AGENT_DIR/templates/claude/settings.local.template.json" "$TARGET_DIR/.claude/settings.local.template.json"
  if [[ $NO_HOOKS -eq 0 ]]; then
    copy_file "$AGENT_DIR/core/hooks/supervisor.py" "$TARGET_DIR/scripts/hooks/supervisor.py"
    copy_file "$AGENT_DIR/core/hooks/plan-gate.py" "$TARGET_DIR/scripts/hooks/plan-gate.py"
    copy_file "$AGENT_DIR/core/hooks/tdd-guard.py" "$TARGET_DIR/scripts/hooks/tdd-guard.py"
    copy_file "$AGENT_DIR/core/hooks/admin-merge-track.py" "$TARGET_DIR/scripts/hooks/admin-merge-track.py"
  fi
}

install_codex() {
  say "[project:codex] Codex skills"
  copy_dir_contents "$AGENT_DIR/adapters/codex/skills" "$TARGET_DIR/.codex/skills"
}

install_multi_agent() {
  say "[project:multi-agent] session infra and mutex hooks"
  copy_dir_contents "$AGENT_DIR/core/infra" "$TARGET_DIR/scripts/infra"
  if [[ $NO_HOOKS -eq 0 ]]; then
    copy_file "$AGENT_DIR/core/hooks/agent-session-start.sh" "$TARGET_DIR/scripts/hooks/agent-session-start.sh"
    copy_file "$AGENT_DIR/core/hooks/agent-session-heartbeat.sh" "$TARGET_DIR/scripts/hooks/agent-session-heartbeat.sh"
    copy_file "$AGENT_DIR/core/hooks/r4-mutex-check.sh" "$TARGET_DIR/scripts/hooks/r4-mutex-check.sh"
    copy_file "$AGENT_DIR/core/hooks/r4-file-mutex-check.sh" "$TARGET_DIR/scripts/hooks/r4-file-mutex-check.sh"
  fi
}

install_airlens_example() {
  say "[project:airlens-example] example assets"
  copy_dir_contents "$AGENT_DIR/examples/airlens" "$TARGET_DIR/examples/airlens"
}

install_project() {
  [[ $PROJECT_INIT -eq 1 ]] || return 0
  if ! is_git_repo "$TARGET_DIR"; then
    echo "target is not a git repo: $TARGET_DIR" >&2
    exit 3
  fi

  case "$PROFILE" in
    minimal)
      install_minimal
      ;;
    claude)
      install_minimal
      install_claude
      ;;
    codex)
      install_minimal
      install_codex
      ;;
    multi-agent)
      install_minimal
      install_multi_agent
      ;;
    full)
      install_minimal
      install_claude
      install_codex
      install_multi_agent
      ;;
    airlens-example)
      install_airlens_example
      ;;
  esac
}

say "Agent Harness setup"
say "  profile: $PROFILE"
say "  target:  $TARGET_DIR"
say "  global:  $GLOBAL"
say "  dry-run: $DRY_RUN"

if [[ "$PROFILE" == "claude" || "$PROFILE" == "full" ]]; then
  install_global_claude
fi

install_project

say "done"
if [[ $PROJECT_INIT -eq 1 ]]; then
  say "next:"
  if [[ "$PROFILE" == "airlens-example" ]]; then
    say "  - review examples/airlens/README.md"
  else
    say "  - review .agent-harness/*.json"
    if [[ "$PROFILE" == "claude" || "$PROFILE" == "full" ]]; then
      say "  - copy .claude/settings.local.template.json to .claude/settings.local.json only when you want local hooks enabled"
    fi
    say "  - run: gitleaks detect --no-git --source . --config gitleaks.toml"
  fi
fi
