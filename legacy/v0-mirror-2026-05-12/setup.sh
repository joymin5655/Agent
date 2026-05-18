#!/usr/bin/env bash
# Agent repo bootstrap — install global Karpathy setup + optional project scaffold.
#
# Usage:
#   gh repo clone joymin5655/Agent ~/agent
#   bash ~/agent/setup.sh              # global only (~/.claude/)
#   bash ~/agent/setup.sh --project    # global + current project .claude/ scaffold
#
# Idempotent — existing files are not overwritten unless --force.

set -euo pipefail

AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_INIT=0
FORCE=0

for arg in "$@"; do
  case "$arg" in
    --project) PROJECT_INIT=1 ;;
    --force)   FORCE=1 ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $arg" >&2
      exit 2
      ;;
  esac
done

copy_safe() {
  local src="$1" dst="$2"
  if [[ -e "$dst" && $FORCE -eq 0 ]]; then
    echo "  skip (exists): $dst"
    return 0
  fi
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
  echo "  wrote: $dst"
}

echo "[1/3] global ~/.claude/ Karpathy + RTK setup"
copy_safe "$AGENT_DIR/claude/global/CLAUDE.md"  "$HOME/.claude/CLAUDE.md"
copy_safe "$AGENT_DIR/claude/global/karpathy.md" "$HOME/.claude/karpathy.md"
copy_safe "$AGENT_DIR/claude/global/RTK.md"      "$HOME/.claude/RTK.md"

echo "[2/3] project init"
if [[ $PROJECT_INIT -eq 0 ]]; then
  echo "  skip (no --project flag)"
else
  if [[ ! -d .git ]]; then
    echo "  error: current dir is not a git repo. cd into the project root and re-run." >&2
    exit 3
  fi

  PROJECT_ROOT="$(pwd)"
  echo "  target: $PROJECT_ROOT"

  # CLAUDE.md template (only if absent — never overwrite project CLAUDE.md)
  if [[ ! -f "$PROJECT_ROOT/CLAUDE.md" ]]; then
    cp "$AGENT_DIR/claude/templates/CLAUDE.md.airlens-root" "$PROJECT_ROOT/CLAUDE.md"
    echo "  wrote: CLAUDE.md (AirLens template — edit for this project)"
  else
    echo "  skip (exists): CLAUDE.md"
  fi

  # gitleaks.toml (if absent)
  if [[ ! -f "$PROJECT_ROOT/gitleaks.toml" ]]; then
    cp "$AGENT_DIR/gitleaks.toml" "$PROJECT_ROOT/gitleaks.toml"
    echo "  wrote: gitleaks.toml"
  fi

  # .claude/ scaffold (rules + agents only — no hooks, no settings.local.json)
  mkdir -p "$PROJECT_ROOT/.claude/rules/policy" "$PROJECT_ROOT/.claude/agents"
  for f in "$AGENT_DIR"/claude/rules/root/*.md; do
    name="$(basename "$f")"
    [[ -e "$PROJECT_ROOT/.claude/rules/$name" ]] || cp "$f" "$PROJECT_ROOT/.claude/rules/$name"
  done
  for f in "$AGENT_DIR"/claude/rules/root/policy/*.md; do
    name="$(basename "$f")"
    [[ -e "$PROJECT_ROOT/.claude/rules/policy/$name" ]] || cp "$f" "$PROJECT_ROOT/.claude/rules/policy/$name"
  done
  echo "  wrote: .claude/rules/ (review and adapt — AirLens-specific paths inside)"

  # .gitignore additions (claude runtime)
  GITIGNORE="$PROJECT_ROOT/.gitignore"
  touch "$GITIGNORE"
  for line in ".claude/locks/" ".claude/logs/" ".claude/settings.local.json" ".claude/state.local/" "secrets/" ".env" ".env.*"; do
    grep -qxF "$line" "$GITIGNORE" || echo "$line" >> "$GITIGNORE"
  done
  echo "  wrote: .gitignore additions"
fi

echo "[3/3] done"
echo ""
echo "next steps:"
echo "  - verify globals: cat ~/.claude/CLAUDE.md"
if [[ $PROJECT_INIT -eq 1 ]]; then
  echo "  - review CLAUDE.md and replace AirLens-specific paths"
  echo "  - review .claude/rules/ — many reference Obsidian-airlens/ etc."
  echo "  - run: gitleaks detect --config=gitleaks.toml"
fi
