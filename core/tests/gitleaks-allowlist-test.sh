#!/usr/bin/env bash
# gitleaks-allowlist-test.sh — B4 follow-up: proves the ALLOW side of gitleaks.toml.
#
# core/infra/gitleaks-fire-test.sh proves DETECTION (a planted secret is caught).
# Nothing proved the other half: that gitleaks.toml's `[allowlist].regexes`
# placeholder patterns (your_*_key, dummy_*, example_*, sk-proj-placeholder,
# {{VAR}}, <your_x>, $USER_*_JWT — see gitleaks.toml lines ~22-34) don't fire
# FALSE positives on ordinary placeholder text in .env.example-style docs/config.
# A gate that never sees its allowlist exercised might be allowlisting nothing
# (dead config) or allowlisting everything (neutered gate) — this proves neither.
#
# Two-sided, non-vacuous by construction:
#   (a) ALLOW:    realistic placeholder fixture -> gitleaks (real config) finds nothing.
#   (a2) CONTROL: the SAME fixture against a stripped config (useDefault, no allowlist)
#                 -> gitleaks DOES flag it. Proves (a)'s clean pass is the allowlist
#                 doing work, not that the fixture was never going to be flagged.
#   (b) MUTATION: a real-shaped secret (reusing gitleaks-fire-test.sh's synthetic
#                 nvapi- probe) still trips the real config. Proves the allowlist
#                 isn't a blanket bypass that would swallow (a) vacuously.
#
# Exit 0: all three legs behave as specified.
# Exit 1: any leg diverged (allowlist over/under-matches).
# SKIP (exit 0, loud "SKIP:" line, no PASS claimed): gitleaks not installed —
# mirrors backends-schema-test.sh's optional-binary convention; verify-all.sh has
# no dedicated SKIP lane for auto-discovered *-test.sh batteries, so a silent
# green here would misreport coverage that never ran (grade.sh lines ~330-336
# apply the same "loud SKIP, not a pass" rule to its own gitleaks GATE leg).
#
# Usage: bash core/tests/gitleaks-allowlist-test.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG="$ROOT/gitleaks.toml"

command -v gitleaks >/dev/null 2>&1 || { echo "SKIP: gitleaks not installed — cannot exercise the allowlist (CI still enforces). Install: brew install gitleaks"; exit 0; }

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

[[ -f "$CONFIG" ]]; check "gitleaks-toml-exists" $?

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# --- fixture: one placeholder shape per allowlist regex, in realistic file
# contexts (config/settings/docs — NOT .env.example, which is already covered
# by the separate PATH allowlist and would make this a test of the wrong
# mechanism). Filenames deliberately avoid the [allowlist].paths patterns.
ALLOW_FX="$TMP_ROOT/allow-fixture"
mkdir -p "$ALLOW_FX"
cat > "$ALLOW_FX/app_config.py" <<'EOF'
API_KEY=your_api_token
SUPABASE_ANON_KEY=your-anon-key
DB_PASSWORD=placeholder
OPENAI_API_KEY=sk-proj-placeholder1234567890123456789012345678901234567890
EOF
cat > "$ALLOW_FX/settings.yaml" <<'EOF'
token = "dummy_token"
secret_key: dummy_secret
api:
  EXAMPLE_SECRET: example_key
EOF
cat > "$ALLOW_FX/README_snippet.md" <<'EOF'
Set the header manually: `Authorization: Bearer <your_api_key>`
Config template: `API_TOKEN={{API_TOKEN_PLACEHOLDER_VALUE_GOES_HERE}}`
EOF
cat > "$ALLOW_FX/curl_examples.sh" <<'EOF'
curl -H "Authorization: Bearer $USER_A_JWT" https://api.example.com/data
curl -H "Authorization: Bearer USER_B_TOKEN" https://api.example.com/data
EOF

echo "=== (a) ALLOW: realistic placeholder fixture -> no findings under the real config ==="
gitleaks detect --no-git --source "$ALLOW_FX" --config "$CONFIG" --no-banner >/dev/null 2>&1
check "placeholder-fixture-no-findings" $?

echo
echo "=== (a2) CONTROL: same fixture, allowlist stripped -> findings (proves (a) is non-vacuous) ==="
NO_ALLOW_CFG="$TMP_ROOT/no-allowlist.toml"
printf '%s\n' '[extend]' 'useDefault = true' > "$NO_ALLOW_CFG"
gitleaks detect --no-git --source "$ALLOW_FX" --config "$NO_ALLOW_CFG" --no-banner >/dev/null 2>&1
[[ $? -ne 0 ]]; check "placeholder-fixture-flagged-without-allowlist" $?

echo
echo "=== (b) MUTATION: real-shaped secret still trips the real config ==="
# Same synthetic nvapi- probe as core/infra/gitleaks-fire-test.sh, assembled at
# runtime so no literal secret lives in this file.
MUT_FX="$TMP_ROOT/mutation-fixture"
mkdir -p "$MUT_FX"
FAKE_KEY="nvapi-$(printf 'A%.0s' $(seq 1 24))"
echo "api_key = \"$FAKE_KEY\"" > "$MUT_FX/planted.env"
gitleaks detect --no-git --source "$MUT_FX" --config "$CONFIG" --no-banner >/dev/null 2>&1
[[ $? -ne 0 ]]; check "real-secret-still-detected" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
