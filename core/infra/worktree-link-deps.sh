#!/usr/bin/env bash
# Symlink heavy install dirs (node_modules, .venv) from main checkout into a worktree.
# OPT-IN: only run if you are sure main and the worktree's branch share the same
# package.json / pyproject.toml lockfile state. Otherwise install in the worktree directly.
# Risks: branch divergence in deps masks bugs; building in main while WT runs may corrupt state.

set -euo pipefail

# Resolve the main checkout (first entry in `git worktree list --porcelain`)
# rather than `--show-toplevel`, which returns the *current* worktree's path
# and would make MAIN_CHECKOUT == TARGET when invoked from inside a worktree.
MAIN_CHECKOUT="$(git worktree list --porcelain | awk '/^worktree /{sub(/^worktree /, ""); print; exit}')"
if [[ -z "$MAIN_CHECKOUT" || ! -d "$MAIN_CHECKOUT" ]]; then
  echo "✗ refuse: could not resolve main checkout from 'git worktree list'" >&2
  exit 1
fi
MAIN_CHECKOUT="$(cd "$MAIN_CHECKOUT" && pwd)"
REPO_ROOT="$MAIN_CHECKOUT"  # link sources read from main checkout
TARGET="${1:-$PWD}"

if [[ ! -d "$TARGET" ]]; then
  echo "usage: worktree-link-deps.sh [<worktree-path>]" >&2
  exit 2
fi
TARGET="$(cd "$TARGET" && pwd)"

if [[ "$TARGET" == "$MAIN_CHECKOUT" ]]; then
  echo "✗ refuse: target is the main checkout" >&2
  exit 1
fi

if [[ "$TARGET" != *"/.worktrees/"* ]]; then
  echo "⚠ warning: target is not under .worktrees/ — proceeding anyway" >&2
fi

link_dir() {
  local rel="$1"
  local src="$REPO_ROOT/$rel"
  local dst="$TARGET/$rel"
  if [[ -L "$dst" ]]; then
    echo "  $rel → already linked"
    return
  fi
  if [[ -e "$dst" ]]; then
    echo "  $rel → exists in worktree (skipped; rm first to relink)"
    return
  fi
  if [[ ! -e "$src" ]]; then
    echo "  $rel → missing in main (run install in main first)"
    return
  fi
  mkdir -p "$(dirname "$dst")"
  # T1-D: realpath ensures the symlink target is canonical absolute, never relative.
  ln -s "$(cd "$src" 2>/dev/null && pwd -P || echo "$src")" "$dst"
  echo "  $rel → linked"
}

# Rewrite scoped workspace symlinks inside a linked node_modules so they point
# at MAIN's packages/ via absolute path. npm install creates these as relative
# (../../packages/<pkg>); from inside a linked node_modules they would resolve
# against the WORKTREE's packages/, which causes silent drift when the worktree
# branch has different packages/<pkg>/src state.
fix_workspace_symlinks() {
  local nm="$1"
  local scope="${AGENT_WORKSPACE_SCOPE:-}"
  [[ -n "$scope" && -d "$nm/$scope" ]] || return 0
  local link target abs
  for link in "$nm/$scope"/*; do
    [[ -L "$link" ]] || continue
    target="$(readlink "$link")"
    case "$target" in
      /*) continue ;;  # already absolute
    esac
    abs="$(cd "$nm/$scope" 2>/dev/null && cd "$(dirname "$target")" 2>/dev/null && pwd -P)/$(basename "$target")"
    if [[ -d "$abs" ]]; then
      rm "$link"
      ln -s "$abs" "$link"
      echo "    $(basename "$link") → $abs"
    fi
  done
}

echo "Linking heavy deps from main → $TARGET"
IFS=':' read -r -a DEP_PATHS <<< "${AGENT_DEP_PATHS:-node_modules:.venv}"
for rel in "${DEP_PATHS[@]}"; do
  [[ -n "$rel" ]] && link_dir "$rel"
done

echo
if [[ -n "${AGENT_WORKSPACE_SCOPE:-}" ]]; then
  echo "Fixing ${AGENT_WORKSPACE_SCOPE}/* workspace symlinks (point to main's packages/ absolute)…"
  for rel in "${DEP_PATHS[@]}"; do
    nm="$TARGET/$rel"
    [[ "$(basename "$nm")" == "node_modules" && -d "$nm" ]] || continue
    fix_workspace_symlinks "$nm"
  done
fi

echo
echo "⚠ Linked deps share install state with main."
echo "  • If branches differ in package.json / pyproject.toml, run install in worktree."
echo "  • Avoid running install in main and worktree simultaneously."
echo "  • If you change packages/<pkg>/src, re-run this script to refresh scoped symlinks."
