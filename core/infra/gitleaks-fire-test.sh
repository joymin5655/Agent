#!/usr/bin/env bash
# gitleaks-fire-test.sh — W-3 secret-gate fire drill.
#
# A gate you never see fire might be dead wiring. This plants a SYNTHETIC secret
# in a throwaway file, runs gitleaks against it, and asserts gitleaks DETECTS it —
# proving the secret gate is actually live (config valid, binary working) before
# /wrap relies on it. The synthetic key is generated at runtime and never touches
# the repo tree, so this file itself carries no secret.
#
# This is a DRILL, not a gate on the repo: it validates the tool, then cleans up.
#
# Exit 0: gitleaks is present AND detected the planted secret (gate is live).
# Exit 2: gitleaks not installed — SKIP (loud, not silent; CI still enforces).
# Exit 1: gitleaks ran but did NOT detect the planted secret — the gate is
#         MISCONFIGURED (e.g. gitleaks.toml allowlists too much). This is the
#         failure the drill exists to surface.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG="$ROOT/gitleaks.toml"

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "SKIP — gitleaks not installed; cannot run the fire drill (CI still enforces). Install: brew install gitleaks" >&2
  exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Synthetic secret matching the repo's OWN shipped custom rule (nvidia-nim-api-key,
# `nvapi-[A-Za-z0-9_-]{20,}`), assembled at runtime so no literal secret lives in
# this file. Using the config's own rule means the drill validates THIS gitleaks
# config end-to-end — not a generic key that the broad placeholder allowlist (or a
# default stopword like "EXAMPLE") would swallow, which would make the drill lie.
FAKE_KEY="nvapi-$(printf 'A%.0s' $(seq 1 24))"              # nvapi- + 24 chars
echo "api_key = \"$FAKE_KEY\"" > "$WORK/planted.env"

CONFIG_ARG=()
[ -f "$CONFIG" ] && CONFIG_ARG=(--config="$CONFIG")

# gitleaks exits non-zero when it FINDS secrets — that is the SUCCESS case here.
if gitleaks detect --source "$WORK" --no-git "${CONFIG_ARG[@]}" --no-banner >/dev/null 2>&1; then
  # exit 0 from gitleaks == no leaks found == the planted secret was NOT detected.
  echo "FAIL — gitleaks did NOT detect the planted synthetic secret. The secret gate is misconfigured (check gitleaks.toml allowlist/rules)." >&2
  exit 1
fi

echo "PASS — gitleaks detected the planted synthetic secret; the secret gate is live." >&2
exit 0
