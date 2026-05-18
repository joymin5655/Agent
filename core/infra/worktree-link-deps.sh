#!/usr/bin/env bash
# Symlink heavy install dirs (node_modules, .venv) from the main checkout into a worktree.
#
# OPT-IN: only run if you are sure main and the worktree's branch share the same
# package.json / pyproject.toml lockfile state. Otherwise install in the worktree directly.
#
# Risks:
#   - Branch divergence in deps masks bugs
#   - Building in main while a worktree runs may corrupt state
#   - Workspace symlinks (e.g., npm workspaces) need a fix-up step (see fix_workspace_symlinks)
#
# Configure for your monorepo via env var:
#   AGENT_LINK_DIRS="node_modules apps/web/node_modules apps/app/node_modules backend/.venv"
#   AGENT_WORKSPACE_SCOPE="@myorg"

set -euo pipefail

MAIN_CHECKOUT="$(git worktree list --porcelain | awk '/^worktree /{sub(/^worktree /, ""); print; exit}')"
if [[ -z "$MAIN_CHECKOUT" || ! -d "$MAIN_CHECKOUT" ]]; then
  echo "refuse: could not resolve main checkout from 'git worktree list'" >&2
  exit 1
fi
MAIN_CHECKOUT="$(cd "$MAIN_CHECKOUT" && pwd)"
REPO_ROOT="$MAIN_CHECKOUT"
TARGET="${1:-$PWD}"

if [[ ! -d "$TARGET" ]]; then
  echo "usage: worktree-link-deps.sh [<worktree-path>]" >&2
  exit 2
fi
TARGET="$(cd "$TARGET" && pwd)"

if [[ "$TARGET" == "$MAIN_CHECKOUT" ]]; then
  echo "refuse: target is the main checkout" >&2
  exit 1
fi

if [[ "$TARGET" != *"/.worktrees/"* ]]; then
  echo "warning: target is not under .worktrees/ — proceeding anyway" >&2
fi

# Default list — override via env var for monorepo layouts
LINK_DIRS=( ${AGENT_LINK_DIRS:-node_modules .venv} )

link_dir() {
  local rel="$1"
  local src="$REPO_ROOT/$rel"
  local dst="$TARGET/$rel"
  if [[ -L "$dst" ]]; then
    echo "  $rel -> already linked"
    return
  fi
  if [[ -e "$dst" ]]; then
    echo "  $rel -> exists in worktree (skipped; rm first to relink)"
    return
  fi
  if [[ ! -e "$src" ]]; then
    echo "  $rel -> missing in main (run install in main first)"
    return
  fi
  mkdir -p "$(dirname "$dst")"
  ln -s "$(cd "$src" 2>/dev/null && pwd -P || echo "$src")" "$dst"
  echo "  $rel -> linked"
}

# Workspace symlink fix-up (npm workspaces / pnpm / yarn workspaces):
# When node_modules is linked from main, any @<scope>/<package> entries pointing
# at packages/<pkg> via relative paths (../../packages/<pkg>) would resolve against
# the worktree's packages/, causing silent drift. Rewrite to absolute paths.
fix_workspace_symlinks() {
  local nm="$1"
  local scope="${AGENT_WORKSPACE_SCOPE:-}"
  [[ -z "$scope" ]] && return 0
  local scope_dir="$nm/$scope"
  [[ -d "$scope_dir" ]] || return 0
  local link target abs
  for link in "$scope_dir"/*; do
    [[ -L "$link" ]] || continue
    target="$(readlink "$link")"
    case "$target" in
      /*) continue ;;
    esac
    abs="$(cd "$scope_dir" 2>/dev/null && cd "$(dirname "$target")" 2>/dev/null && pwd -P)/$(basename "$target")"
    if [[ -d "$abs" ]]; then
      rm "$link"
      ln -s "$abs" "$link"
      echo "    $(basename "$link") -> $abs"
    fi
  done
}

echo "Linking heavy deps from main -> $TARGET"
for d in "${LINK_DIRS[@]}"; do
  link_dir "$d"
done

if [[ -n "${AGENT_WORKSPACE_SCOPE:-}" ]]; then
  echo
  echo "Fixing $AGENT_WORKSPACE_SCOPE/* workspace symlinks (point to main's packages/ absolute)..."
  for d in "${LINK_DIRS[@]}"; do
    if [[ -d "$TARGET/$d" ]]; then
      fix_workspace_symlinks "$TARGET/$d"
    fi
  done
fi

echo
echo "WARNING — Linked deps share install state with main:"
echo "  - If branches differ in package.json / pyproject.toml, run install in worktree."
echo "  - Avoid running install in main and worktree simultaneously."
echo "  - If you change shared workspace package source, re-run this script."
