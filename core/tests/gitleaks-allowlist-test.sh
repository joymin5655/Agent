#!/usr/bin/env bash
# gitleaks-allowlist-test.sh — B4 follow-up: proves the ALLOW side of gitleaks.toml.
#
# core/infra/gitleaks-fire-test.sh proves DETECTION (a planted secret is caught).
# Nothing proved the other half: that gitleaks.toml's `[allowlist].regexes`
# placeholder patterns (your_*_key, dummy_*, example_*, sk-proj-placeholder,
# {{VAR}}, <your_x>, $USER_*_JWT — see gitleaks.toml lines ~22-34) don't fire
# FALSE positives on ordinary placeholder text in docs/config.
#
# PER-SHAPE, two-sided, with an HONEST CEILING. Each placeholder shape is probed
# on its own (never as one aggregate directory scan, which passes on a single
# finding anywhere and proves nothing about the other shapes):
#   (a) ALLOW:    shape under the REAL config -> no findings.
#   (a2) CONTROL: the SAME shape under a stripped config (useDefault, no
#                 allowlist) -> classified flagged / not-flagged.
#       * flagged there + clean in (a)  => that allowlist arm is LOAD-BEARING:
#         deleting it would turn the shape into a live finding. Asserted.
#       * not flagged either way        => UNPROVABLE by this method: no rule
#         catches the shape with or WITHOUT the allowlist, so its clean pass is
#         not evidence the allowlist did anything. Reported, never counted as
#         proof. (Measured 2026-08-10: 2 of 10 shapes are load-bearing.)
#   (b) MUTATION: a real-shaped secret (the same synthetic nvapi- probe as
#                 gitleaks-fire-test.sh) still trips the REAL config, asserted by
#                 RULE ID — proves the allowlist is not a blanket bypass.
# A floor assertion requires the load-bearing set to stay non-empty, so a future
# gitleaks/config change cannot silently reduce this battery to proving nothing.
#
# Findings are read from gitleaks' JSON report, not from its exit status: a
# non-zero exit means "leaks found" OR "gitleaks errored" (bad config, unknown
# flag), and conflating the two would let a broken control leg report ok.
#
# Exit 0: every leg behaved as specified.
# Exit 1: a leg diverged (allowlist over- or under-matches).
# Exit 2: gitleaks not installed — INAPPLICABLE, not a pass. verify-all.sh's
#         discovered-check SKIP lane tallies exit 2 as skipped and prints the
#         reason; exiting 0 here would have been reported as PASS with this
#         file's own SKIP text discarded (the runner echoes output on FAIL only),
#         which is a false green precisely where CI cannot see it — the verify
#         runner has no gitleaks installed.
#
# Usage: bash core/tests/gitleaks-allowlist-test.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG="$ROOT/gitleaks.toml"

command -v gitleaks >/dev/null 2>&1 || {
  echo "SKIP: gitleaks not installed — cannot exercise the allowlist (the dedicated CI secret-scan job still enforces it). Install: brew install gitleaks"
  exit 2
}
command -v python3 >/dev/null 2>&1 || {
  echo "SKIP: python3 not installed — needed to read gitleaks' JSON report"
  exit 2
}

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

[[ -f "$CONFIG" ]]; check "gitleaks-toml-exists" $?

TMP_ROOT="$(mktemp -d)" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP_ROOT"' EXIT

NO_ALLOW_CFG="$TMP_ROOT/no-allowlist.toml"
printf '%s\n' '[extend]' 'useDefault = true' > "$NO_ALLOW_CFG"

# scan_rules <source-dir> <config> — prints one RuleID per finding, or the
# sentinel __NOREPORT__ when gitleaks produced no readable report (a fatal
# error). Never conflates "errored" with "found leaks".
scan_rules() {
  local src="$1" cfg="$2" rpt="$TMP_ROOT/report.json"
  rm -f "$rpt"
  gitleaks detect --no-git --source "$src" --config "$cfg" --no-banner \
    --report-format json --report-path "$rpt" >/dev/null 2>&1
  python3 - "$rpt" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        data = json.load(fh)
except Exception:
    print("__NOREPORT__"); raise SystemExit(0)
if not isinstance(data, list):
    print("__NOREPORT__"); raise SystemExit(0)
for f in data:
    print(f.get("RuleID", "__UNKNOWN__"))
PY
}

# --- placeholder shapes, one per allowlist regex arm, in realistic file
# contexts (config/settings/docs — NOT .env.example, which the separate PATH
# allowlist already covers and which would test the wrong mechanism).
# Filenames deliberately avoid the [allowlist].paths patterns. The sk-proj
# value is ASSEMBLED AT RUNTIME so no literal secret-shaped string lives in this
# file: a committed literal would make the repo's own secret-scan depend on the
# allowlist arm it is testing, blocking any future tightening of that arm.
SK_PROJ="sk-proj-placeholder$(printf '1234567890%.0s' 1 2 3 4)"
SHAPES=(
  "app_config.py|API_KEY=your_api_token"
  "app_config.py|SUPABASE_ANON_KEY=your-anon-key"
  "app_config.py|DB_PASSWORD=placeholder"
  "app_config.py|OPENAI_API_KEY=$SK_PROJ"
  "settings.yaml|token = \"dummy_token\""
  "settings.yaml|secret_key: dummy_secret"
  "settings.yaml|EXAMPLE_SECRET: example_key"
  "README_snippet.md|Set the header manually: Authorization: Bearer <your_api_key>"
  "README_snippet.md|API_TOKEN={{API_TOKEN_PLACEHOLDER_VALUE_GOES_HERE}}"
  "curl_examples.sh|curl -H \"Authorization: Bearer USER_B_TOKEN\" https://api.example.com/data"
)

echo "=== (a)+(a2) PER-SHAPE: allowed under the real config; classified against a stripped config ==="
LOAD_BEARING=0
UNPROVABLE=0
LOAD_BEARING_NAMES=""
i=0
for entry in "${SHAPES[@]}"; do
  i=$((i + 1))
  fname="${entry%%|*}"
  line="${entry#*|}"
  d="$TMP_ROOT/shape-$i"
  mkdir -p "$d"
  printf '%s\n' "$line" > "$d/$fname"

  real="$(scan_rules "$d" "$CONFIG")"
  bare="$(scan_rules "$d" "$NO_ALLOW_CFG")"

  # (a): the real config must find nothing for this shape.
  [[ -z "$real" ]]; check "allowed-under-real-config[$i:$fname]" $?
  # a fatal gitleaks error must never read as "allowed"
  [[ "$real" != *__NOREPORT__* ]]; check "real-config-report-readable[$i]" $?

  if [[ "$bare" == *__NOREPORT__* ]]; then
    # the control itself is broken — fail loudly rather than silently
    # downgrading this shape to "unprovable".
    check "control-config-report-readable[$i]" 1
  elif [[ -n "$bare" && -z "$real" ]]; then
    # BOTH halves are required for load-bearing: flagged without the allowlist
    # AND clean with it. A shape flagged under both configs means that arm is
    # broken, and counting it toward the floor would let the floor be satisfied
    # by the very failure it exists to catch (the `allowed-under-real-config`
    # check above already goes red, but the floor must not disagree with it).
    LOAD_BEARING=$((LOAD_BEARING + 1))
    LOAD_BEARING_NAMES="$LOAD_BEARING_NAMES $i:$fname"
    echo "  ok   [load-bearing[$i:$fname] — flagged without the allowlist as: $(printf '%s' "$bare" | tr '\n' ',' | sed 's/,$//')]"
    PASS=$((PASS + 1))
  elif [[ -n "$bare" ]]; then
    echo "  --   [arm-broken[$i:$fname] — flagged under BOTH configs; not counted load-bearing (see the failed allow check above)]"
  else
    UNPROVABLE=$((UNPROVABLE + 1))
    echo "  --   [unprovable[$i:$fname] — no rule catches this shape with OR without the allowlist; its clean pass proves nothing about the allowlist]"
  fi
done

echo
echo "=== (a3) FLOOR: the measured load-bearing set must not shrink or drift ==="
# Without this, a gitleaks version bump or a rule change could silently make
# every shape unprovable and leave the battery green while proving nothing.
# The floor pins the MEASURED SET, not just its size (a size floor has zero
# headroom at 2 and would accept a different pair while the two known-catchable
# shapes silently stopped being caught).
echo "  load-bearing:$LOAD_BEARING [${LOAD_BEARING_NAMES# }] · unprovable-by-this-method: $UNPROVABLE (of ${#SHAPES[@]} shapes)"
[[ "$LOAD_BEARING" -ge 2 ]]; check "load-bearing-floor-at-least-2" $?
# measured 2026-08-10: shape 4 (sk-proj-… → the sk-(proj-)?(your|placeholder|…)
# arm) and shape 10 (Bearer USER_B_TOKEN → the USER_*(JWT|TOKEN) arm).
for expect in "4:app_config.py" "10:curl_examples.sh"; do
  case " $LOAD_BEARING_NAMES " in
    *" $expect "*) check "load-bearing-includes[$expect]" 0 ;;
    *) echo "    expected shape $expect to be catchable without the allowlist — gitleaks' ruleset may have changed"
       check "load-bearing-includes[$expect]" 1 ;;
  esac
done
# HONEST CEILING, stated so it cannot be mistaken for coverage: gitleaks.toml
# declares 9 allowlist regex arms; the two load-bearing shapes exercise 2 of
# them. The other 7 arms — including the unanchored bare `placeholder` arm —
# are asserted by nothing in either direction here, because no rule catches
# their shapes with OR without the allowlist. Proving those needs either a
# rule that matches them or a different method; this battery does not claim to.
echo "  ceiling: 2 of gitleaks.toml's 9 allowlist arms are exercised; the other 7 are unproven by this method"

echo
echo "=== (a4) AGGREGATE: the whole fixture tree is clean under the real config ==="
ALL_FX="$TMP_ROOT/all-fixture"
mkdir -p "$ALL_FX"
i=0
for entry in "${SHAPES[@]}"; do
  i=$((i + 1))
  fname="${entry%%|*}"
  printf '%s\n' "${entry#*|}" >> "$ALL_FX/${i}_$fname"
done
agg="$(scan_rules "$ALL_FX" "$CONFIG")"
[[ -z "$agg" ]]; check "aggregate-fixture-no-findings" $?

echo
echo "=== (b) MUTATION: a real-shaped secret still trips the real config, by RULE ID ==="
# Same synthetic nvapi- probe as core/infra/gitleaks-fire-test.sh, assembled at
# runtime so no literal secret lives in this file.
MUT_FX="$TMP_ROOT/mutation-fixture"
mkdir -p "$MUT_FX"
FAKE_KEY="nvapi-$(printf 'A%.0s' $(seq 1 24))"
echo "api_key = \"$FAKE_KEY\"" > "$MUT_FX/planted.env"
mut="$(scan_rules "$MUT_FX" "$CONFIG")"
printf '%s\n' "$mut" | grep -qx 'nvidia-nim-api-key'; check "real-secret-detected-by-expected-rule" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
