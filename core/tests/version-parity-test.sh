#!/usr/bin/env bash
# version-parity-test.sh — battery for version-parity.sh
#
# Covers: a consistent fixture passes; each lagging source (README badge,
# marketplace.json, CHANGELOG latest heading) fails naming itself; the
# [Unreleased] heading is skipped when reading the CHANGELOG's latest release;
# a missing file fails loud (never a silent skip); and the REAL repo passes
# (proves the release landed consistently). Fixtures are mktemp trees.
#
# Usage: bash core/tests/version-parity-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

GATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/version-parity.sh"

PASS=0; FAIL=0
ok() { echo "  ok   [$1]"; PASS=$((PASS + 1)); }
no() { echo "  FAIL [$1] $2"; FAIL=$((FAIL + 1)); }

DIR="$(mktemp -d)"
cleanup() { rm -rf "$DIR"; }
trap cleanup EXIT

# fixture <badge_en> <status_en> <badge_ko> <status_ko> <plugin> <market> <changelog>
fixture() {
  mkdir -p "$DIR/.claude-plugin"
  printf '![Version](https://img.shields.io/badge/version-%s-blue.svg)\n\n> Status: v%s\n' "$1" "$2" > "$DIR/README.md"
  printf '![Version](https://img.shields.io/badge/version-%s-blue.svg)\n\n> 상태: v%s\n' "$3" "$4" > "$DIR/README.ko.md"
  printf '{"name":"agent-harness","version":"%s"}\n' "$5" > "$DIR/.claude-plugin/plugin.json"
  # metadata-nested shape — the branch the REAL marketplace.json exercises
  # (no top-level "version" key there)
  printf '{"plugins":[{"name":"agent-harness"}],"metadata":{"version":"%s"}}\n' "$6" > "$DIR/.claude-plugin/marketplace.json"
  printf '# Changelog\n\n## [Unreleased]\n\n## [%s] — 2026-07-21\n' "$7" > "$DIR/CHANGELOG.md"
}

# --- (a) consistent fixture -> PASS ---
fixture 1.2.3 1.2.3 1.2.3 1.2.3 1.2.3 1.2.3 1.2.3
if OUT="$(bash "$GATE" "$DIR")"; then
  ok "a: consistent fixture passes"
else
  no "a: consistent fixture passes" "expected exit 0, got: $OUT"
fi

# --- (b) README badge lags -> FAIL naming it ---
fixture 1.2.2 1.2.3 1.2.3 1.2.3 1.2.3 1.2.3 1.2.3
if OUT="$(bash "$GATE" "$DIR")"; then
  no "b: lagging badge fails" "expected exit 1, got pass"
else
  if grep -q "README badge: 1.2.2" <<<"$OUT"; then
    ok "b: lagging badge fails naming source"
  else
    no "b: lagging badge fails naming source" "not named in: $OUT"
  fi
fi

# --- (c) marketplace lags -> FAIL ---
fixture 1.2.3 1.2.3 1.2.3 1.2.3 1.2.3 1.2.2 1.2.3
if bash "$GATE" "$DIR" >/dev/null; then
  no "c: lagging marketplace fails" "expected exit 1, got pass"
else
  ok "c: lagging marketplace fails"
fi

# --- (d) CHANGELOG latest release != plugin.json -> FAIL ---
fixture 1.2.3 1.2.3 1.2.3 1.2.3 1.2.3 1.2.3 1.2.2
if bash "$GATE" "$DIR" >/dev/null; then
  no "d: lagging changelog fails" "expected exit 1, got pass"
else
  ok "d: lagging changelog fails"
fi

# --- (e) [Unreleased] above the release heading is skipped, not misread ---
fixture 1.2.3 1.2.3 1.2.3 1.2.3 1.2.3 1.2.3 1.2.3
printf '# Changelog\n\n## [Unreleased]\n\n### Added\n- pending thing\n\n## [1.2.3] — 2026-07-21\n' > "$DIR/CHANGELOG.md"
if bash "$GATE" "$DIR" >/dev/null; then
  ok "e: Unreleased heading skipped"
else
  no "e: Unreleased heading skipped" "expected exit 0"
fi

# --- (f) missing file -> FAIL loud, never a silent skip ---
rm "$DIR/.claude-plugin/marketplace.json"
if OUT="$(bash "$GATE" "$DIR")"; then
  no "f: missing file fails loud" "expected exit 1, got pass"
else
  if grep -q "marketplace.json: file missing" <<<"$OUT"; then
    ok "f: missing file fails loud"
  else
    no "f: missing file fails loud" "not named in: $OUT"
  fi
fi

# --- (g) the REAL repo -> PASS (release landed consistently) ---
if OUT="$(bash "$GATE")"; then
  ok "g: real repo consistent"
else
  no "g: real repo consistent" "$OUT"
fi

echo ""
echo "=== version-parity-test: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
