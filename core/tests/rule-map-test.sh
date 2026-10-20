#!/usr/bin/env bash
# rule-map-test.sh — prove core/tests/rule-map.sh is NON-VACUOUS: the shipped map passes, and each
# defect class (dead enforcer path, bad kind, malformed row, duplicate id, unmapped contract
# bullet, bad/expired/unowned exception) is caught, while UNENFORCED only warns.
#
# Each case builds a FRESH tiny repo under mktemp so a mutation never leaks.
#
# Usage: bash core/tests/rule-map-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$REPO_ROOT/core/tests/rule-map.sh"

PASS=0
FAIL=0
check() {
  local name="$1" cond="$2"
  if [[ "$cond" -eq 0 ]]; then echo "  ok   [$name]"; PASS=$((PASS + 1))
  else echo "  FAIL [$name]"; FAIL=$((FAIL + 1)); fi
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# new_fixture <rows...> — a repo with one real enforcer file, a 2-bullet contract, and the
# given map rows between the markers; echoes the repo path.
new_fixture() {
  local fx; fx="$(mktemp -d "$TMP_ROOT/fxXXXXXX")"
  mkdir -p "$fx/docs" "$fx/core/hooks" "$fx/rules/policy" "$fx/hooks"
  printf '{"description":"mentions other.sh only here","hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"\\"${R}/adapter.sh\\" real.sh"}]}]}}\n' > "$fx/hooks/hooks.json"
  : > "$fx/core/hooks/real.sh"
  : > "$fx/AGENTS.md"
  printf '# c\n\n- first rule\n- second rule\n' > "$fx/rules/policy/operating-contract.md"
  {
    echo '# registry'
    echo '<!-- rule-map:begin -->'
    printf '%s\n' "$@"
    echo '<!-- rule-map:end -->'
  } > "$fx/docs/gate-registry.md"
  printf '%s' "$fx"
}

OC='RULE OC-1 | rules/policy/operating-contract.md | a | hook:core/hooks/real.sh
RULE OC-2 | rules/policy/operating-contract.md | b | hook:core/hooks/real.sh'
OUT=""; RC=0
run() { OUT="$(RULE_MAP_TODAY=2026-10-20 bash "$CHECK" --root "$1" 2>&1)"; RC=$?; }
rc_is() { if [[ $RC -eq $1 ]]; then echo 0; else echo 1; fi; }
has() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }

echo "=== (0) the shipped map passes against the real repo ==="
OUT="$(bash "$CHECK" 2>&1)"; RC=$?
check "real-map-passes" "$(rc_is 0)"
has 'UNENFORCED'; check "real-map-reports-unenforced" $?

echo
echo "=== (1) clean fixture -> exit 0; UNENFORCED is a warning, not a failure ==="
FX=$(new_fixture "$OC" 'RULE AG-1 | AGENTS.md | x | UNENFORCED')
run "$FX"
check "unenforced-only-warns" "$(rc_is 0)"
has 'WARN rule-map: 1 UNENFORCED'; check "unenforced-count-reported" $?
has 'AG-1'; check "unenforced-id-listed" $?

echo
echo "=== (2) dead enforcer path -> exit 1 ==="
FX=$(new_fixture "$OC" 'RULE AG-1 | AGENTS.md | x | hook:core/hooks/missing.sh')
run "$FX"
check "dead-path-fails" "$(rc_is 1)"
has 'core/hooks/missing.sh'; check "dead-path-named" $?

echo
echo "=== (3) unknown kind / missing kind / malformed / duplicate ==="
FX=$(new_fixture "$OC" 'RULE AG-1 | AGENTS.md | x | magic:core/hooks/real.sh')
run "$FX"; check "bad-kind-fails" "$(rc_is 1)"
FX=$(new_fixture "$OC" 'RULE AG-1 | AGENTS.md | x | core/hooks/real.sh')
run "$FX"; check "kindless-path-fails" "$(rc_is 1)"
FX=$(new_fixture "$OC" 'RULE AG-1 | AGENTS.md | only three fields')
run "$FX"; check "short-row-fails" "$(rc_is 1)"
FX=$(new_fixture "$OC" 'RULE AG-1 | AGENTS.md | x | UNENFORCED' 'RULE AG-1 | AGENTS.md | y | UNENFORCED')
run "$FX"; check "duplicate-id-fails" "$(rc_is 1)"
has 'duplicate rule id AG-1'; check "duplicate-id-named" $?
FX=$(new_fixture "$OC" 'RULE AG-1 | nope.md | x | UNENFORCED')
run "$FX"; check "missing-source-fails" "$(rc_is 1)"

echo
echo "=== (4) unmapped operating-contract bullet -> exit 1 ==="
FX=$(new_fixture 'RULE OC-1 | rules/policy/operating-contract.md | a | hook:core/hooks/real.sh')
run "$FX"
check "unmapped-bullet-fails" "$(rc_is 1)"
has 'operating-contract.md has 2 bullets'; check "unmapped-bullet-named" $?

echo
echo "=== (5) exceptions need reason + expiry + approver, and must be live ==="
BASE=("$OC" 'RULE AG-1 | AGENTS.md | x | UNENFORCED')
FX=$(new_fixture "${BASE[@]}" 'EXCEPT AG-1 | no checker exists yet | 2026-12-31 | maintainer')
run "$FX"; check "valid-exception-ok" "$(rc_is 0)"
FX=$(new_fixture "${BASE[@]}" 'EXCEPT AG-1 | no checker exists yet | 2026-12-31 |')
run "$FX"; check "no-approver-fails" "$(rc_is 1)"
FX=$(new_fixture "${BASE[@]}" 'EXCEPT AG-1 | | 2026-12-31 | maintainer')
run "$FX"; check "no-reason-fails" "$(rc_is 1)"
FX=$(new_fixture "${BASE[@]}" 'EXCEPT AG-1 | why | someday | maintainer')
run "$FX"; check "bad-date-fails" "$(rc_is 1)"
FX=$(new_fixture "${BASE[@]}" 'EXCEPT AG-1 | why | 2026-10-19 | maintainer')
run "$FX"; check "expired-fails" "$(rc_is 1)"
has 'expired 2026-10-19'; check "expired-named" $?
FX=$(new_fixture "${BASE[@]}" 'EXCEPT AG-9 | why | 2026-12-31 | maintainer')
run "$FX"; check "unknown-rule-exception-fails" "$(rc_is 1)"
FX=$(new_fixture "$OC" 'RULE AG-1 | AGENTS.md | x | hook:core/hooks/real.sh' 'EXCEPT AG-1 | why | 2026-12-31 | maintainer')
run "$FX"; check "exception-on-enforced-rule-fails" "$(rc_is 1)"

echo
echo "=== (5b) real dates only; PARTIAL rows can be excepted ==="
FX=$(new_fixture "${BASE[@]}" 'EXCEPT AG-1 | why | 2026-02-30 | maintainer')
run "$FX"; check "impossible-date-fails" "$(rc_is 1)"
FX=$(new_fixture "$OC" 'RULE AG-1 | AGENTS.md | x | PARTIAL hook:core/hooks/real.sh ~ half' 'EXCEPT AG-1 | why | 2026-12-31 | maintainer')
run "$FX"; check "partial-exception-ok" "$(rc_is 0)"

echo
echo "=== (5c) PARTIAL needs a gap; counts are reported ==="
FX=$(new_fixture "$OC" 'RULE AG-1 | AGENTS.md | x | PARTIAL hook:core/hooks/real.sh')
run "$FX"; check "partial-no-gap-fails" "$(rc_is 1)"
FX=$(new_fixture "$OC" 'RULE AG-1 | AGENTS.md | x | PARTIAL hook:core/hooks/real.sh ~ ')
run "$FX"; check "partial-empty-gap-fails" "$(rc_is 1)"
FX=$(new_fixture "$OC" 'RULE AG-1 | AGENTS.md | x | PARTIAL hook:core/hooks/real.sh ~ only half')
run "$FX"; check "partial-with-gap-passes" "$(rc_is 0)"
has 'WARN rule-map: 1 PARTIAL'; check "partial-warned" $?
has '1 PARTIAL, 0 UNENFORCED'; check "partial-counted" $?
FX=$(new_fixture "$OC" 'RULE AG-1 | AGENTS.md | x | PARTIAL hook:core/hooks/gone.sh ~ half')
run "$FX"; check "partial-dead-path-fails" "$(rc_is 1)"

echo
echo "=== (5d) hook enforcers must be registered; stray block lines fail ==="
FX=$(new_fixture "$OC" 'RULE AG-1 | AGENTS.md | x | hook:core/hooks/real.sh')
: > "$FX/core/hooks/other.sh"
printf 'RULE AG-2 | AGENTS.md | y | hook:core/hooks/other.sh\n' >> "$FX/docs/gate-registry.md"
python3 -I - "$FX/docs/gate-registry.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
row = "RULE AG-2 | AGENTS.md | y | hook:core/hooks/other.sh\n"
s = s.replace(row, "", 1).replace("<!-- rule-map:end -->", row + "<!-- rule-map:end -->")
open(p, "w").write(s)
PY
run "$FX"
check "unregistered-hook-fails" "$(rc_is 1)"
has 'not registered in hooks/hooks.json'; check "unregistered-hook-named" $?
# a name that appears only in a description, not in any command, is not registered
FX=$(new_fixture "$OC" 'RULE AG-1 | AGENTS.md | x | hook:core/hooks/other.sh')
: > "$FX/core/hooks/other.sh"
run "$FX"; check "description-only-mention-not-registered" "$(rc_is 1)"
FX=$(new_fixture "$OC" 'this line is prose, not a row')
run "$FX"; check "stray-line-fails" "$(rc_is 1)"
has 'unrecognized line'; check "stray-line-named" $?
FX=$(new_fixture "$OC" '# a comment' '')
run "$FX"; check "comment-and-blank-allowed" "$(rc_is 0)"

echo
echo "=== (6) no map block -> exit 2 ==="
FX=$(new_fixture "$OC")
printf '# nothing here\n' > "$FX/docs/gate-registry.md"
run "$FX"; check "missing-block-exit2" "$(rc_is 2)"

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
