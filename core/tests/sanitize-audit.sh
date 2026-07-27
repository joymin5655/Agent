#!/usr/bin/env bash
# Sanitize audit — verify no AirLens / prior-project taint outside legacy/
#
# Usage:
#   bash core/tests/sanitize-audit.sh               # scan working tree (default)
#   bash core/tests/sanitize-audit.sh --range A..B  # scan added lines of every commit in A..B
#
# Exit 0: clean. Exit 1: taint found (prints offending files / lines).
#
# Working-tree scope (default): tracked files (working-tree state) plus
# untracked-but-not-ignored files (anything that could reach a commit).
# Gitignored runtime state (.claude/locks/, .omc/, /CLAUDE.md, *.jsonl, ...)
# is never scanned: it never ships.
#
# --range scope: `git log -p A..B` — the added lines of EVERY commit in the range,
# not the net A..B diff. A token added in one commit and removed in a later one
# (leaving HEAD clean) is therefore still caught. This closes the add-then-remove
# gap that the working-tree scan and the CI HEAD scan both miss; CI runs it over
# the pull-request / push commit range.
#
# The token list below is intentionally split into separate array elements so the
# audit script itself does not trigger its own pattern when committed.

set -u

# --- forbidden prior-project token set (single source for both modes) ---
# The regex is constructed at runtime from these tokens, not stored as a literal.
TOKENS=(
  "AirLens"
  "airlens"
  "PM2\\.5"
  "AOD"
  "DQSS"
  "Obsidian-airlens"
  "Glass-box"
  "/Volumes/WD_BLACK"
  "ML Uncertainty"
  "Edge Fn"
)

# --- machine-identity PII token set (rules/public-repo.md § Machine-identity PII) ---
# Personal machine identifiers must never enter the repo: real macOS home paths
# and Apple mDNS device hostnames. Patterns are deliberately narrow, and this
# group is scanned CASE-SENSITIVELY (unlike TOKENS above) — macOS generates the
# capitalized spellings, and a case-insensitive match would false-positive on
# REST-route text like api.github.com/users/octocat or "imacros-….local":
#   - "/Users/" followed by an alphanumeric = a REAL home path; the placeholder
#     spellings docs use ("/Users/<name>") stay legal because '<' breaks the match.
#   - Only .local hostnames that embed an Apple model name are matched — a bare
#     ".local" token would false-positive on .env.local / settings.local.json.
#     "Mac-?" covers both joined and macOS's hyphenated ComputerName forms
#     (Mac-mini / Mac-Pro / Mac-Studio / MacBook).
TOKENS_CS=(
  "/Users/[A-Za-z0-9]"
  "[A-Za-z0-9-]*(Mac-?(Book|mini|Pro|Studio)|iMac)[A-Za-z0-9-]*\\.local"
)
# Join with |  (multi-word tokens are fine: the joined pattern is passed as a
# single quoted ERE argument, where a space is a literal).
JOINED="$(IFS='|'; echo "${TOKENS[*]}")"
JOINED_CS="$(IFS='|'; echo "${TOKENS_CS[*]}")"

# Pathspec excludes (shared by both modes; mirror the CI sanitize job):
# legacy/ is the intentional archive; this script and ci.yml hold the forbidden
# tokens as literals (runtime-joined here, grep pattern there).
EXCLUDES=(
  ':!legacy'
  ':!core/tests/sanitize-audit.sh'
  ':!.github/workflows/ci.yml'
)

# --- --range mode: scan the added lines of every commit in the range ---
if [[ "${1:-}" == "--range" ]]; then
  RANGE="${2:-}"
  if [[ -z "$RANGE" ]]; then
    echo "usage: sanitize-audit.sh --range <A>..<B>" >&2
    exit 2
  fi
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "FAIL — not a git work tree (--range scans git history)"
    exit 1
  }
  # Resolve the range first: an unresolvable range (missing endpoint — e.g. a
  # shallow checkout without fetch-depth: 0) must FAIL LOUD, never silently pass.
  if ! git rev-list "$RANGE" >/dev/null 2>&1; then
    echo "FAIL — cannot resolve range '$RANGE' (missing endpoint? CI needs fetch-depth: 0)" >&2
    exit 2
  fi
  # Every commit's patch (not the net diff). NB: this covers ordinary commits;
  # content introduced solely via a merge's conflict resolution is not shown by
  # `git log -p` and is out of scope (the workflow here is squash/linear anyway).
  # Capture git-log's OWN exit status: a range that resolves but whose objects
  # can't be read (partial clone / corruption) must FAIL LOUD, not pass on the
  # resulting empty output — the earlier rev-list guard does not cover this.
  if ! RAW="$(git log -p --no-merges "$RANGE" -- "${EXCLUDES[@]}")"; then
    echo "FAIL — 'git log' could not read range '$RANGE' (partial clone / object error?)" >&2
    exit 2
  fi
  # `+` = added line; drop the `+++ ` diff file-header — it always has a trailing
  # space, so an added CONTENT line beginning with `++` (e.g. `++i;`) is NOT
  # mistaken for a header and dropped; then strip the leading marker.
  ADDED="$(printf '%s\n' "$RAW" | grep -E '^\+' | grep -vE '^\+\+\+ ' | sed 's/^+//' || true)"
  HITS="$(printf '%s\n' "$ADDED" | grep -iE "$JOINED" || true)"
  HITS_CS="$(printf '%s\n' "$ADDED" | grep -E "$JOINED_CS" || true)"
  # Commit METADATA of the range too (author name/email, subject, body): the
  # historical PII leak class was a hostname-bearing author field, which diff
  # lines never show. Same fail-loud contract as the log -p read above.
  if ! META="$(git log --format='%an %ae %cn %ce%n%s%n%b' --no-merges "$RANGE")"; then
    echo "FAIL — 'git log' could not read metadata for range '$RANGE'" >&2
    exit 2
  fi
  META_HITS="$({ printf '%s\n' "$META" | grep -iE "$JOINED"; printf '%s\n' "$META" | grep -E "$JOINED_CS"; } | sort -u || true)"
  if [[ -n "$HITS" || -n "$HITS_CS" || -n "$META_HITS" ]]; then
    echo "FAIL — forbidden token added by a commit in range $RANGE:"
    printf '%s\n' "$HITS" "$HITS_CS" | sed '/^$/d;s/^/  /'
    if [[ -n "$META_HITS" ]]; then
      echo "  -- in commit metadata (author/subject/body):"
      printf '%s\n' "$META_HITS" | sed 's/^/  /'
    fi
    echo ""
    echo "A commit in this range adds a forbidden token even though HEAD may be clean."
    echo "Find it with: git log -p -S'<token>' $RANGE  — then sanitize that commit."
    echo "See AGENTS.md § 2 (sanitize discipline)."
    exit 1
  fi
  echo "PASS — no taint in range $RANGE (added lines + commit metadata of every commit scanned)"
  exit 0
fi

# --- default mode: scan the working tree ---
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "FAIL — not a git work tree (audit scans git-tracked scope)"
  exit 1
}

TAINT=$( { git grep -I -l -i -E --untracked -e "$JOINED" -- "${EXCLUDES[@]}"; git grep -I -l -E --untracked -e "$JOINED_CS" -- "${EXCLUDES[@]}"; } | sort -u || true)

if [[ -n "$TAINT" ]]; then
  echo "FAIL — taint detected in files outside legacy/:"
  echo "$TAINT" | sed 's/^/  /'
  echo ""
  echo "Sanitize before commit. See AGENTS.md § 2 (sanitize discipline)."
  exit 1
fi

echo "PASS — no taint detected (scope: tracked + untracked-unignored; excluded legacy/, self, ci.yml)"
exit 0
