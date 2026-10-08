#!/usr/bin/env bash
# session-indexer-test.sh — verify core/infra/session-indexer.py (FTS5 session search).
#
# Uses AGENT_SESSIONS_DIR / AGENT_SESSIONS_DB pointing at a temp dir, run from a temp cwd
# so the real wiki/sessions and .agent/state db are never touched.
#
# Covers: (a) --reindex counts files, (b) --query returns JSON with fields, (c) title from
# first '# ' heading / filename fallback, (d) date extraction / "unknown", (e) --top limit,
# (f) no-match -> [], (g) no args -> exit 1, (h) archive/ subdir indexed, (i) new file
# auto-indexed on next query, (j) modified file reindexed, (k) --output writes file,
# (l) missing sessions dir -> reindex 0, (m) snippet markers.
#
# Skips (exit 2 + single SKIP line) when python sqlite3 lacks FTS5.
#
# Usage: bash core/tests/session-indexer-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/core/infra/session-indexer.py"

if ! python3 -c 'import sqlite3; c=sqlite3.connect(":memory:"); c.execute("create virtual table t using fts5(a)")' 2>/dev/null; then
  echo "SKIP python sqlite3 has no FTS5"
  exit 2
fi

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then
    echo "  ok   [$name]"
    PASS=$((PASS + 1))
  else
    echo "  FAIL [$name]"
    FAIL=$((FAIL + 1))
  fi
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
export HOME="$TMP_DIR/home"; mkdir -p "$HOME"
S="$TMP_DIR/sessions"
export AGENT_SESSIONS_DIR="$S"
export AGENT_SESSIONS_DB="$TMP_DIR/state/idx.db"
mkdir -p "$S/archive/old"
WORK="$TMP_DIR/cwd"; mkdir -p "$WORK"

printf '# Auth Refactor\n\nWe rewrote the authentication middleware today.\n' > "$S/2026-01-02-auth.md"
printf '# Globe Page\n\nRendering globe with zebra texture.\n' > "$S/2026-02-03-globe.md"
printf 'no heading here, just pelican notes\n' > "$S/notes.md"
printf '# Archived\n\nancient walrus discussion\n' > "$S/archive/old/2025-12-01-walrus.md"

idx() { (cd "$WORK" && python3 "$SCRIPT" "$@"); }
jq_py() { python3 -c "import json,sys; d=json.load(sys.stdin); $1"; }

# (a)
out="$(idx --reindex)"; rc=$?
[[ $rc -eq 0 && "$(echo "$out" | jq_py 'print(d["indexed"])')" == "4" ]]; check "reindex counts all 4 files (incl. archive)" $?
[[ -f "$AGENT_SESSIONS_DB" ]]; check "db created at AGENT_SESSIONS_DB" $?

# (b)(c)(d)(m)
out="$(idx --query authentication)"; rc=$?
echo "$out" | jq_py '
r=d[0]
assert r["session_id"]=="2026-01-02-auth", r
assert r["date"]=="2026-01-02", r
assert r["title"]=="Auth Refactor", r
assert ">>>" in r["snippet"] and "<<<" in r["snippet"], r
assert r["relevance_score"]>0, r'
check "query returns session_id/date/title/snippet/score" $?

out="$(idx --query pelican)"
echo "$out" | jq_py 'r=d[0]; assert r["title"]=="notes" and r["date"]=="unknown", r'
check "no heading -> filename stem title, date unknown" $?

# (h)
out="$(idx --query walrus)"
echo "$out" | jq_py 'assert len(d)==1 and d[0]["session_id"]=="2025-12-01-walrus", d'
check "archive/ subdir sessions searchable" $?

# (f)
out="$(idx --query nonexistentterm)"
[[ "$(echo "$out" | jq_py 'print(len(d))')" == "0" ]]; check "no match -> empty array" $?

# (e)
out="$(idx --query "the OR we OR with OR just OR discussion OR texture OR notes" --top 2)"
[[ "$(echo "$out" | jq_py 'print(len(d))')" == "2" ]]; check "--top limits result count" $?

# (g)
idx >/dev/null 2>&1; rc=$?
[[ $rc -eq 1 ]]; check "no args -> help + exit 1" $?

# (i)
printf '# New One\n\nfresh platypus entry\n' > "$S/2026-03-04-new.md"
out="$(idx --query platypus)"
echo "$out" | jq_py 'assert d[0]["session_id"]=="2026-03-04-new", d'
check "new file auto-indexed on query" $?

# (j)
printf '# Auth Refactor\n\nnow mentions quokka only\n' > "$S/2026-01-02-auth.md"
touch -d '+1 minute' "$S/2026-01-02-auth.md"
out="$(idx --query quokka)"
echo "$out" | jq_py 'assert d and d[0]["session_id"]=="2026-01-02-auth", d'
check "modified file reindexed" $?
out="$(idx --query authentication)"
[[ "$(echo "$out" | jq_py 'print(len(d))')" == "0" ]]; check "stale content dropped after reindex" $?

# (k)
idx --query globe --output "$TMP_DIR/out.json" >"$TMP_DIR/stdout"
[[ ! -s "$TMP_DIR/stdout" ]] && python3 -c "import json; json.load(open('$TMP_DIR/out.json'))"; check "--output writes JSON file, stdout empty" $?

# (l)
out="$(AGENT_SESSIONS_DIR="$TMP_DIR/missing" AGENT_SESSIONS_DB="$TMP_DIR/state/other.db" idx --reindex)"; rc=$?
[[ $rc -eq 0 && "$(echo "$out" | jq_py 'print(d["indexed"])')" == "0" ]]; check "missing sessions dir -> indexed 0" $?

echo "session-indexer-test: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
