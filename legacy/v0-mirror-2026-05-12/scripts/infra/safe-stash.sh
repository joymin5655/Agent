#!/usr/bin/env bash
# T1-C: safe stash for blocking-untracked files during rebase / worktree ops.
#
# Memory: feedback_untracked_hook_tmp_backup_loss.md (PR #217 incident)
#   rebase blocking untracked file → /tmp 이동 시 시스템 정리로 소실.
#   영속 path 사용해야 함.
#
# Usage:
#   safe-stash.sh save <branch-slug>           # snapshot all untracked files into ~/.claude/backup/<date>-<slug>/
#   safe-stash.sh save <branch-slug> <path>... # snapshot specific paths only
#   safe-stash.sh restore <branch-slug>        # restore the most recent snapshot for slug
#   safe-stash.sh list                         # list snapshots, ordered by date
#   safe-stash.sh prune <days>                 # delete snapshots older than N days
#
# Storage location:
#   ~/.claude/backup/YYYY-MM-DD-<slug>/...
#   Persistent across reboot. Manual cleanup via `safe-stash.sh prune`.

set -euo pipefail

BACKUP_ROOT="${SAFE_STASH_ROOT:-$HOME/.claude/backup}"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

mkdir -p "$BACKUP_ROOT"

usage() {
  cat <<'USAGE' >&2
safe-stash.sh — persistent backup for blocking-untracked files

USAGE:
  safe-stash.sh save <branch-slug> [<path>...]
  safe-stash.sh restore <branch-slug>
  safe-stash.sh list
  safe-stash.sh prune <days>

ENV:
  SAFE_STASH_ROOT   override backup root (default ~/.claude/backup)
USAGE
  exit 2
}

cmd_save() {
  local slug="${1:-}"
  [[ -z "$slug" ]] && usage
  shift || true

  local stamp; stamp="$(date +%Y-%m-%d-%H%M%S)"
  local dest="$BACKUP_ROOT/${stamp}-${slug}"
  mkdir -p "$dest"

  if [[ $# -eq 0 ]]; then
    # Snapshot ALL untracked files reported by git
    local files
    files="$(git -C "$REPO_ROOT" ls-files --others --exclude-standard)"
    if [[ -z "$files" ]]; then
      echo "safe-stash: no untracked files to save" >&2
      rmdir "$dest"
      return 0
    fi
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      mkdir -p "$dest/$(dirname "$f")"
      cp -p "$REPO_ROOT/$f" "$dest/$f"
    done <<< "$files"
  else
    # Snapshot specific paths
    for p in "$@"; do
      local abs="$REPO_ROOT/$p"
      [[ ! -e "$abs" ]] && { echo "safe-stash: skip missing $p" >&2; continue; }
      mkdir -p "$dest/$(dirname "$p")"
      cp -rp "$abs" "$dest/$p"
    done
  fi

  echo "✓ snapshot → $dest"
  echo "  restore: scripts/infra/safe-stash.sh restore $slug"
}

cmd_restore() {
  local slug="${1:-}"
  [[ -z "$slug" ]] && usage

  local latest
  latest="$(find "$BACKUP_ROOT" -maxdepth 1 -type d -name "*-${slug}" 2>/dev/null \
    | sort | tail -1)"
  if [[ -z "$latest" ]]; then
    echo "✗ no snapshot found for slug: $slug" >&2
    return 1
  fi

  echo "Restoring from $latest → $REPO_ROOT"
  (cd "$latest" && find . -type f -print0) | while IFS= read -r -d '' rel; do
    rel="${rel#./}"
    local target="$REPO_ROOT/$rel"
    if [[ -e "$target" ]]; then
      echo "  $rel → already exists in repo (skipped)"
      continue
    fi
    mkdir -p "$(dirname "$target")"
    cp -p "$latest/$rel" "$target"
    echo "  $rel → restored"
  done
  echo "✓ restore complete (existing files preserved)"
}

cmd_list() {
  if [[ ! -d "$BACKUP_ROOT" ]] || [[ -z "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]]; then
    echo "(no snapshots)"
    return 0
  fi
  ls -1t "$BACKUP_ROOT" | while read -r dir; do
    local count size
    count="$(find "$BACKUP_ROOT/$dir" -type f 2>/dev/null | wc -l | tr -d ' ')"
    size="$(du -sh "$BACKUP_ROOT/$dir" 2>/dev/null | awk '{print $1}')"
    echo "  $dir  ($count files, $size)"
  done
}

cmd_prune() {
  local days="${1:-}"
  [[ -z "$days" ]] && usage
  if ! [[ "$days" =~ ^[0-9]+$ ]]; then
    echo "✗ days must be a positive integer" >&2
    return 1
  fi
  local removed=0
  while IFS= read -r dir; do
    [[ -z "$dir" ]] && continue
    rm -rf "$dir"
    echo "  removed $dir"
    removed=$((removed + 1))
  done < <(find "$BACKUP_ROOT" -maxdepth 1 -type d -mtime +"$days" -not -path "$BACKUP_ROOT" 2>/dev/null)
  echo "✓ pruned $removed snapshot(s) older than $days day(s)"
}

case "${1:-}" in
  save)    shift; cmd_save "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  list)    shift; cmd_list ;;
  prune)   shift; cmd_prune "$@" ;;
  -h|--help|help|"") usage ;;
  *) echo "unknown: $1" >&2; usage ;;
esac
