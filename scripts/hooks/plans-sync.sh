#!/usr/bin/env bash
# SessionStart Hook: ~/.claude/plans/*.md → Obsidian-airlens/raw/plans/<slug>.md
# one-way sync (mtime 비교 incremental).
#
# 정책:
# - one-way: ~/.claude/plans/ 가 SOT. 역방향 sync 없음
# - 충돌 = source 우선 (Obsidian 쪽 수정은 overwrite)
# - 삭제 sync 없음 (사용자 수동 정리)
# - frontmatter 자동 부여 (source / synced_at / auto_synced: true)
# - silent + best-effort + idempotent
#
# Refs:
# - Plan: ~/.claude/plans/inherited-wobbling-frog.md (Phase 2.E)

set -uo pipefail

# stdin drain (SessionStart hook contract)
cat >/dev/null 2>&1 || true

SOURCE_DIR="$HOME/.claude/plans"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# worktree fallback: resolve to main worktree root
if [ ! -d "$PROJECT_ROOT/Obsidian-airlens" ]; then
    if [ -f "$PROJECT_ROOT/.git" ]; then
        gitdir=""
        while IFS= read -r line; do
            case "$line" in
                gitdir:*)
                    gitdir="${line#gitdir: }"
                    break
                    ;;
            esac
        done < "$PROJECT_ROOT/.git"
        if [ -n "$gitdir" ]; then
            # gitdir = <main>/.git/worktrees/<wt> → ../../.. = <main>
            candidate=$(cd "$gitdir/../../.." 2>/dev/null && pwd) || candidate=""
            if [ -n "$candidate" ] && [ -d "$candidate/Obsidian-airlens" ]; then
                PROJECT_ROOT="$candidate"
            fi
        fi
    fi
fi

DEST_DIR="$PROJECT_ROOT/Obsidian-airlens/raw/plans"

[ -d "$SOURCE_DIR" ] || exit 0
[ -d "$DEST_DIR" ] || exit 0

# Sync newer or missing .md files (top-level only, _archive/ 등 제외)
synced=0
for src in "$SOURCE_DIR"/*.md; do
    [ -f "$src" ] || continue
    name=$(basename "$src")
    dest="$DEST_DIR/$name"

    # skip if dest is newer or equal
    if [ -f "$dest" ] && [ ! "$src" -nt "$dest" ]; then
        continue
    fi

    synced_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    {
        printf -- '---\n'
        printf 'source: ~/.claude/plans/%s\n' "$name"
        printf 'synced_at: %s\n' "$synced_at"
        printf 'auto_synced: true\n'
        printf -- '---\n\n'
        cat "$src"
    } > "$dest" 2>/dev/null || continue
    synced=$((synced + 1))
done

# silent on no-op; advisory on first session of day
if [ "$synced" -gt 0 ]; then
    printf 'plans-sync: %d file(s) synced → raw/plans/\n' "$synced" >&2
fi

exit 0
