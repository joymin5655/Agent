#!/usr/bin/env bash
# tdd-guard cache refresh (Phase 1.2).
# Runs vitest with JSON reporter, pipes to cache processor.
# Invoked manually or by tdd-guard-cache-update.py (background spawn).
# Takes ~30s. Silent on failure.
# Plan: ~/.claude/plans/tdd-guard-self-strengthen-frosted-mason.md §1.2

set -e

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
WEB_DIR="$ROOT/apps/web"
PROCESS_PY="$ROOT/scripts/hooks/tdd-guard-cache-process.py"

[[ -d "$WEB_DIR" ]] || exit 0
[[ -f "$PROCESS_PY" ]] || exit 0

TMP="$(mktemp).json"
trap "rm -f '$TMP'" EXIT

cd "$WEB_DIR"
# --outputFile writes pure JSON; stdout/stderr (jsdom warnings, etc.) discarded.
npx vitest run --reporter=json --outputFile="$TMP" --silent >/dev/null 2>&1 || true

[ -s "$TMP" ] && python3 "$PROCESS_PY" < "$TMP" 2>/dev/null || true

exit 0
