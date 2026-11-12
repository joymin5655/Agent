#!/usr/bin/env bash
# plugin-eval-compare-test.sh — model-free tests for evals/plugin/compare.py and regress.py.
# Synthetic result JSON only; the eval CLI is replaced by a fake script. No network.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPARE="$ROOT/evals/plugin/compare.py"
REGRESS="$ROOT/evals/plugin/regress.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export PYTHONDONTWRITEBYTECODE=1
export TMPDIR="$TMP/tmpdir"
mkdir -p "$TMPDIR"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { # check <label> <expected-exit> <actual-exit>
  if [ "$2" = "$3" ]; then ok "$1 (exit $3)"; else bad "$1 (exit $3, want $2)"; fi
}
has() { # has <label> <needle> <file>
  if grep -qF -- "$2" "$3"; then ok "$1"; else bad "$1 (missing: $2)"; fi
}
hasnt() { # hasnt <label> <needle> <file>
  if grep -qF -- "$2" "$3"; then bad "$1 (found: $2)"; else ok "$1"; fi
}
hasline() { # hasline <label> <whole line> <file>
  if grep -qxF -- "$2" "$3"; then ok "$1"; else bad "$1 (no line: $2)"; fi
}

# mk.py <out> <spec...>; spec = name:kind:passes:total[:errors]
# kind = fires | quiet | quietsame (quiet grader named like the fires one) | behavior
# MK_PARTIAL=1 marks the file partial. Fires graders carry only tool + input_match; quiet ones
# add min/max 0 (see evals/plugin/wrap-fires/graders/skill-fired.md).
cat > "$TMP/mk.py" <<'PY'
import json
import os
import sys

out, specs = sys.argv[1], sys.argv[2:]
cases = []
for spec in specs:
    name, kind, passes, total, *rest = spec.split(":")
    passes, total = int(passes), int(total)
    errors = int(rest[0]) if rest else 0
    if kind == "fires":
        gname = "skill-fired"
        gdef = {"name": gname, "type": "tool_used", "weight": 1,
                "config": {"tool": "Skill", "input_match": "x"}}
    elif kind in ("quiet", "quietsame"):
        gname = "skill-fired" if kind == "quietsame" else "skill-not-fired"
        gdef = {"name": gname, "type": "tool_used", "weight": 1,
                "config": {"tool": "Skill", "input_match": "x", "min": 0, "max": 0,
                           "arm": "both"}}
    else:
        gname = "behavior"
        gdef = {"name": gname, "type": "llm", "weight": 1, "config": {"criteria": "c"}}
    runs = []
    for i in range(total):
        runs.append({"passed": True, "score": 1, "error": "boom" if i < errors else None,
                     "graders": [{"name": gname, "passed": i < passes, "withOnly": False}]})
    cases.append({"name": name, "graders": [gdef], "arms": {"with": runs, "without": []}})
json.dump({"schemaVersion": 1, "claudeVersion": "0", "partial": os.environ.get("MK_PARTIAL") == "1",
           "suite": {}, "cases": cases, "aggregates": {}}, open(out, "w"))
PY
mk() { python3 "$TMP/mk.py" "$@"; }

# run <name> <compare args...>: stdout -> $TMP/<name>.out, exit code in $RC
run() {
  local name="$1"
  shift
  RC=0
  python3 "$COMPARE" "$@" > "$TMP/$name.out" 2> "$TMP/$name.err" || RC=$?
}

echo "== compare.py =="
mk "$TMP/a1.json" a-fires:fires:0:3
mk "$TMP/h1.json" a-fires:fires:3:3
run improved --base "$TMP/a1.json" --head "$TMP/h1.json"
check "fires 0/3 -> 3/3" 0 "$RC"
has "  labelled IMPROVED" "| a-fires | skill-fired | 0/3 | 3/3 | IMPROVED |" "$TMP/improved.out"

mk "$TMP/a2.json" a-fires:fires:3:3
mk "$TMP/h2.json" a-fires:fires:1:3
run regression --base "$TMP/a2.json" --head "$TMP/h2.json"
check "fires 3/3 -> 1/3" 1 "$RC"
has "  labelled REGRESSION" "| a-fires | skill-fired | 3/3 | 1/3 | REGRESSION |" \
  "$TMP/regression.out"

mk "$TMP/h3.json" a-fires:fires:2:3
run noise --base "$TMP/a2.json" --head "$TMP/h3.json"
check "fires 3/3 -> 2/3" 0 "$RC"
has "  labelled NOISE" "| a-fires | skill-fired | 3/3 | 2/3 | NOISE |" "$TMP/noise.out"
has "  note explains NOISE" "re-run to confirm" "$TMP/noise.out"

mk "$TMP/a4.json" a-quiet:quiet:3:3
mk "$TMP/h4.json" a-quiet:quiet:2:3
run quiet --base "$TMP/a4.json" --head "$TMP/h4.json"
check "quiet 0 -> 1 false fire" 1 "$RC"
has "  labelled REGRESSION" "| a-quiet | skill-not-fired | 3/3 | 2/3 | REGRESSION |" \
  "$TMP/quiet.out"

mk "$TMP/qa.json" a-quiet:quiet:2:3
mk "$TMP/qh.json" a-quiet:quiet:3:3
run quietbetter --base "$TMP/qa.json" --head "$TMP/qh.json"
check "quiet 1 false fire -> 0" 0 "$RC"
has "  labelled IMPROVED" "| a-quiet | skill-not-fired | 2/3 | 3/3 | IMPROVED |" \
  "$TMP/quietbetter.out"

run quietsame --base "$TMP/a4.json" --head "$TMP/a4.json"
check "quiet unchanged" 0 "$RC"
has "  labelled UNCHANGED" "| a-quiet | skill-not-fired | 3/3 | 3/3 | UNCHANGED |" \
  "$TMP/quietsame.out"

mk "$TMP/h5.json" a-fires:fires:3:3 new-fires:fires:3:3
run onlyhead --base "$TMP/a2.json" --head "$TMP/h5.json"
check "case only in head" 0 "$RC"
has "  labelled ONLY-IN-HEAD" "| new-fires | * | - | - | ONLY-IN-HEAD |" "$TMP/onlyhead.out"

mk "$TMP/b5.json" a-fires:fires:3:3 gone-fires:fires:3:3
run onlybase --base "$TMP/b5.json" --head "$TMP/a2.json"
check "case only in base" 0 "$RC"
has "  labelled ONLY-IN-BASE" "| gone-fires | * | - | - | ONLY-IN-BASE |" "$TMP/onlybase.out"

mk "$TMP/h6.json" a-fires:fires:3:3:1
run errored --base "$TMP/a2.json" --head "$TMP/h6.json"
check "errored run" 0 "$RC"
has "  labelled UNDETERMINED" "| a-fires | skill-fired | 3/3 | 3/3 (1 err) | UNDETERMINED |" \
  "$TMP/errored.out"

mk "$TMP/h7.json" a-fires:fires:2:2
run unequal --base "$TMP/a2.json" --head "$TMP/h7.json"
check "unequal run totals" 0 "$RC"
has "  labelled UNDETERMINED" "| a-fires | skill-fired | 3/3 | 2/2 | UNDETERMINED |" \
  "$TMP/unequal.out"

mk "$TMP/z.json" a-fires:fires:0:0
run zerobase --base "$TMP/z.json" --head "$TMP/h1.json"
check "zero runs on base" 0 "$RC"
has "  labelled UNDETERMINED" "| a-fires | skill-fired | 0/0 | 3/3 | UNDETERMINED |" \
  "$TMP/zerobase.out"
run zerohead --base "$TMP/a1.json" --head "$TMP/z.json"
check "zero runs on head" 0 "$RC"
has "  labelled UNDETERMINED" "| a-fires | skill-fired | 0/3 | 0/0 | UNDETERMINED |" \
  "$TMP/zerohead.out"

mk "$TMP/k1.json" a-x:fires:3:3
mk "$TMP/k2.json" a-x:quietsame:3:3
run kinddiff --base "$TMP/k1.json" --head "$TMP/k2.json"
check "grader kind differs" 0 "$RC"
has "  labelled UNDETERMINED" "| a-x | skill-fired | 3/3 | 3/3 | UNDETERMINED |" \
  "$TMP/kinddiff.out"

MK_PARTIAL=1 mk "$TMP/p1.json" a-fires:fires:3:3
run partialin --base "$TMP/a2.json" --head "$TMP/p1.json"
check "partial input" 0 "$RC"
has "  PARTIAL line" "PARTIAL: at least one input run hit its cost ceiling" "$TMP/partialin.out"
hasnt "  clean input has no PARTIAL" "PARTIAL:" "$TMP/improved.out"

printf '{"schemaVersion": 2, "cases": []}' > "$TMP/bad.json"
run malformed --base "$TMP/bad.json" --head "$TMP/h1.json"
check "malformed file" 2 "$RC"
has "  names the file" "unrecognized result shape: $TMP/bad.json" "$TMP/malformed.err"

python3 - "$TMP/noarm.json" <<'PY'
import json
import sys

gdef = {"name": "skill-fired", "type": "tool_used", "config": {"tool": "Skill"}}
case = {"name": "a-fires", "graders": [gdef], "arms": {"without": []}}
json.dump({"schemaVersion": 1, "cases": [case]}, open(sys.argv[1], "w"))
PY
run noarm --base "$TMP/noarm.json" --head "$TMP/h1.json"
check "missing arms.with" 2 "$RC"
has "  names the file" "unrecognized result shape: $TMP/noarm.json" "$TMP/noarm.err"

mk "$TMP/dup.json" a-fires:fires:3:3
run dup --base "$TMP/dup.json" "$TMP/dup.json" --head "$TMP/h1.json"
check "duplicate name on one side" 2 "$RC"

mk "$TMP/m1.json" x-fires:fires:3:3
mk "$TMP/m2.json" y-fires:fires:3:3
mk "$TMP/mh1.json" x-fires:fires:0:3
mk "$TMP/mh2.json" y-fires:fires:3:3
run merge --base "$TMP/m1.json" "$TMP/m2.json" --head "$TMP/mh1.json" "$TMP/mh2.json" \
  --json-out "$TMP/merge.json" --md-out "$TMP/merge.md"
check "two files per side merge" 1 "$RC"
has "  md-out written" "| x-fires | skill-fired | 3/3 | 0/3 | REGRESSION |" "$TMP/merge.md"
has "  other case unchanged" "| y-fires | skill-fired | 3/3 | 3/3 | UNCHANGED |" "$TMP/merge.md"
if python3 - "$TMP/merge.json" <<'PY'
import json
import sys

d = json.load(open(sys.argv[1]))
assert d["regression"] is True
assert d["summary"]["REGRESSION"] == 1 and d["summary"]["UNCHANGED"] == 1
assert {r["case"] for r in d["rows"]} == {"x-fires", "y-fires"}
PY
then ok "  --json-out content"; else bad "  --json-out content"; fi

mk "$TMP/i1.json" b:behavior:3:3 r-fires:fires:3:3
mk "$TMP/i2.json" b:behavior:1:3 r-fires:fires:3:3
run info --base "$TMP/i1.json" --head "$TMP/i2.json"
check "non-routing grader is information only" 0 "$RC"
has "  shows counts" "| b | behavior | 3/3 | 1/3 | info |" "$TMP/info.out"

mk "$TMP/n1.json" b:behavior:3:3
run norouting --base "$TMP/n1.json" --head "$TMP/n1.json"
check "no routing grader at all" 2 "$RC"
has "  says so" "no routing graders found" "$TMP/norouting.err"

echo "== regress.py =="
# mkrepo <dir>: skills foo bar baz (baz has no cases) + extras/skills/ext; cases for foo bar ext
mkrepo() {
  local d="$1" s
  mkdir -p "$d/skills/foo" "$d/skills/bar" "$d/skills/baz" "$d/extras/skills/ext"
  for s in foo bar ext; do
    mkdir -p "$d/evals/plugin/$s-fires/graders" "$d/evals/plugin/$s-quiet/graders"
    printf 'prompt-v1\n' > "$d/evals/plugin/$s-fires/prompt.md"
    printf 'prompt-v1\n' > "$d/evals/plugin/$s-quiet/prompt.md"
    printf -- '---\ntype: tool_used\ntool: Skill\ninput_match: x\n---\n' \
      > "$d/evals/plugin/$s-fires/graders/skill-fired.md"
    printf -- '---\ntype: tool_used\ntool: Skill\ninput_match: x\nmin: 0\nmax: 0\n---\n' \
      > "$d/evals/plugin/$s-quiet/graders/skill-not-fired.md"
  done
  for s in foo bar baz; do printf 'old\n' > "$d/skills/$s/SKILL.md"; done
  printf 'old\n' > "$d/extras/skills/ext/SKILL.md"
}
gitr() { # gitr <dir> <git args...>
  local d="$1"
  shift
  git -C "$d" -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false "$@"
}

REPO="$TMP/repo"
mkrepo "$REPO"
gitr "$REPO" init -q -b main
gitr "$REPO" add -A
gitr "$REPO" commit -q -m base
BASE_REV="$(gitr "$REPO" rev-parse HEAD)"
gitr "$REPO" commit -q --allow-empty -m nochange
NOCHANGE_REV="$(gitr "$REPO" rev-parse HEAD)"
printf 'MARKER\n' > "$REPO/skills/foo/SKILL.md"
printf 'prompt-v2\n' > "$REPO/evals/plugin/foo-fires/prompt.md"
gitr "$REPO" add -A
gitr "$REPO" commit -q -m "change foo"
HEAD_REV="$(gitr "$REPO" rev-parse HEAD)"
printf 'MARKER\n' > "$REPO/extras/skills/ext/SKILL.md"
gitr "$REPO" add -A
gitr "$REPO" commit -q -m "change ext"
EXT_REV="$(gitr "$REPO" rev-parse HEAD)"

# fake eval CLI: logs the skill, records which prompt each tree saw, writes a result JSON.
# MARKER in the tree's skill file = fires. FAKE_MODE: normal | exit1 | partial | nojson | zero
cat > "$TMP/fake-claude.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=""
glob=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) out="$2" ;;
    --case) glob="$2" ;;
  esac
  shift
done
skill="${glob%-\*}"
echo "$skill" >> "$FAKE_LOG"
echo "$(basename "$PWD") $(cat evals/plugin/foo-fires/prompt.md)" >> "$FAKE_SEEN"
mode="${FAKE_MODE:-normal}"
fires=0
if grep -qs MARKER "skills/$skill/SKILL.md" "extras/skills/$skill/SKILL.md"; then fires=3; fi
case "$mode" in
  nojson) exit 0 ;;
  zero) python3 "$FAKE_MK" "$out"; exit 0 ;;
  partial) MK_PARTIAL=1 python3 "$FAKE_MK" "$out" "$skill-fires:fires:$fires:3" \
    "$skill-quiet:quiet:3:3"; exit 2 ;;
  exit1) python3 "$FAKE_MK" "$out" "$skill-fires:fires:$fires:3" "$skill-quiet:quiet:3:3"; exit 1 ;;
  *) python3 "$FAKE_MK" "$out" "$skill-fires:fires:$fires:3" "$skill-quiet:quiet:3:3" ;;
esac
SH
chmod +x "$TMP/fake-claude.sh"
cat > "$TMP/fake-fail.sh" <<'SH'
#!/usr/bin/env bash
exit 3
SH
chmod +x "$TMP/fake-fail.sh"
export FAKE_LOG="$TMP/fake.log" FAKE_SEEN="$TMP/fake.seen" FAKE_MK="$TMP/mk.py"
: > "$FAKE_LOG"
: > "$FAKE_SEEN"
FAKE="$TMP/fake-claude.sh"

run_regress() { # run_regress <name> <args...>: run regress.py with cwd = the throwaway repo
  local name="$1"
  shift
  RC=0
  (cd "${WHERE:-$REPO}" && python3 "$REGRESS" "$@") > "$TMP/$name.out" 2> "$TMP/$name.err" \
    || RC=$?
}
trees_left() { find "$TMPDIR" -maxdepth 1 -name 'regress-trees-*' | wc -l | tr -d ' '; }
outs_left() { find "$TMPDIR" -maxdepth 1 -name 'regress-out-*' | wc -l | tr -d ' '; }
reset_logs() { : > "$FAKE_LOG"; : > "$FAKE_SEEN"; }

REGRESS_CLAUDE_BIN="$FAKE" run_regress notarget --base "$BASE_REV" --head "$NOCHANGE_REV"
check "no skill change" 0 "$RC"
has "  prints no target" "no target: no skill changed between" "$TMP/notarget.out"

REGRESS_CLAUDE_BIN="$FAKE" run_regress plan --base "$BASE_REV" --head "$HEAD_REV" --plan
check "--plan" 0 "$RC"
has "  lists foo" "skills: foo" "$TMP/plan.out"
has "  prints the eval command" "--case 'foo-*'" "$TMP/plan.out"
has "  plan names a new temp dir" "out dir: <new temp dir>" "$TMP/plan.out"
if [ ! -s "$FAKE_LOG" ]; then ok "  --plan called nothing"; else bad "  --plan called the eval CLI"; fi
if [ "$(outs_left)$(trees_left)" = "00" ]; then
  ok "  --plan created no directory"
else
  bad "  --plan created a directory"
fi

REGRESS_CLAUDE_BIN="$FAKE" run_regress noeval --base "$BASE_REV" --head "$HEAD_REV" --skill baz
check "skill without eval cases" 0 "$RC"
has "  reports the skip" "skipped: no eval cases for baz" "$TMP/noeval.out"

REGRESS_CLAUDE_BIN="$FAKE" run_regress nosuch --base "$BASE_REV" --head "$HEAD_REV" \
  --skill nosuch
check "skill that does not exist" 0 "$RC"
has "  reports the skip" "skipped: no skill named nosuch" "$TMP/nosuch.out"

REGRESS_CLAUDE_BIN="$FAKE" run_regress badrev --base nonexistent-rev --head "$HEAD_REV"
check "bad revision" 2 "$RC"

REGRESS_CLAUDE_BIN="$FAKE" run_regress fewruns --base "$BASE_REV" --head "$HEAD_REV" --runs 2
check "--runs below 3" 2 "$RC"
has "  says why" "--runs must be at least 3" "$TMP/fewruns.err"

OUT="$TMP/out"
reset_logs
REGRESS_CLAUDE_BIN="$FAKE" run_regress full --base "$BASE_REV" --head "$HEAD_REV" \
  --out-dir "$OUT"
check "full run" 0 "$RC"
has "  IMPROVED" "| foo-fires | skill-fired | 0/3 | 3/3 | IMPROVED |" "$TMP/full.out"
has "  quiet unchanged" "| foo-quiet | skill-not-fired | 3/3 | 3/3 | UNCHANGED |" "$TMP/full.out"
has "  cost note" "cost note: 2 eval calls" "$TMP/full.out"
has "  prints the merge-base" "→ merge-base ${BASE_REV:0:10}" "$TMP/full.out"
if [ -s "$OUT/compare.md" ] && [ -s "$OUT/compare.json" ]; then
  ok "  compare.md / compare.json written"
else
  bad "  compare.md / compare.json missing"
fi
if [ "$(trees_left)" = "0" ]; then ok "  temp trees removed"; else bad "  temp trees left"; fi
calls=$(wc -l < "$FAKE_LOG" | tr -d ' ')
if [ "$calls" = "2" ]; then ok "  two eval calls (base, head)"; else bad "  eval calls: $calls"; fi
if [ -z "$(gitr "$REPO" status --porcelain)" ]; then
  ok "  working tree untouched"
else
  bad "  working tree changed"
fi
hasline "  default cases come from head (base tree)" "base prompt-v2" "$TMP/fake.seen"
hasline "  default cases come from head (head tree)" "head prompt-v2" "$TMP/fake.seen"

reset_logs
REGRESS_CLAUDE_BIN="$FAKE" run_regress pinned --base "$BASE_REV" --head "$HEAD_REV" \
  --cases-from "$BASE_REV" --out-dir "$TMP/out-pinned"
check "--cases-from pins the cases" 0 "$RC"
hasline "  base tree sees the pinned cases" "base prompt-v1" "$TMP/fake.seen"
hasline "  head tree sees the pinned cases" "head prompt-v1" "$TMP/fake.seen"
hasnt "  no tree sees the head-only cases" "prompt-v2" "$TMP/fake.seen"

reset_logs
REGRESS_CLAUDE_BIN="$FAKE" run_regress extras --base "$HEAD_REV" --head "$EXT_REV" \
  --out-dir "$TMP/out-extras"
check "skill under extras/skills" 0 "$RC"
has "  checks ext" "skills: ext" "$TMP/extras.out"
has "  IMPROVED" "| ext-fires | skill-fired | 0/3 | 3/3 | IMPROVED |" "$TMP/extras.out"

FAKE_MODE=partial REGRESS_CLAUDE_BIN="$FAKE" run_regress partial --base "$BASE_REV" \
  --head "$HEAD_REV" --out-dir "$TMP/out-partial"
check "eval exits 2 with a partial JSON" 0 "$RC"
has "  PARTIAL line" "PARTIAL:" "$TMP/partial.out"
has "  results still compared" "| foo-fires | skill-fired | 0/3 | 3/3 | IMPROVED |" \
  "$TMP/partial.out"

FAKE_MODE=exit1 REGRESS_CLAUDE_BIN="$FAKE" run_regress exit1 --base "$BASE_REV" \
  --head "$HEAD_REV" --out-dir "$TMP/out-exit1"
check "eval exits 1 (a failing case is a normal result)" 0 "$RC"
has "  results compared" "| foo-fires | skill-fired | 0/3 | 3/3 | IMPROVED |" "$TMP/exit1.out"

REGRESS_CLAUDE_BIN="$TMP/fake-fail.sh" run_regress infra --base "$BASE_REV" \
  --head "$HEAD_REV" --out-dir "$TMP/out2"
check "eval CLI exits 3" 2 "$RC"
if [ "$(trees_left)" = "0" ]; then ok "  temp trees removed after failure"; else bad "  trees left"; fi

REGRESS_CLAUDE_BIN=/nonexistent/claude run_regress nobin --base "$BASE_REV" \
  --head "$HEAD_REV" --out-dir "$TMP/out3"
check "eval binary missing" 2 "$RC"
hasnt "  no traceback" "Traceback" "$TMP/nobin.err"
has "  reports an infrastructure failure" "infrastructure failure" "$TMP/nobin.err"
if [ "$(trees_left)" = "0" ]; then ok "  temp trees removed after OSError"; else bad "  trees left"; fi

mkdir -p "$TMP/out-stale"
printf 'stale\n' > "$TMP/out-stale/base-foo.json"
FAKE_MODE=nojson REGRESS_CLAUDE_BIN="$FAKE" run_regress nojson --base "$BASE_REV" \
  --head "$HEAD_REV" --out-dir "$TMP/out-stale"
check "eval writes no JSON (a stale file is not reused)" 2 "$RC"
has "  says so" "wrote no result JSON" "$TMP/nojson.err"

FAKE_MODE=zero REGRESS_CLAUDE_BIN="$FAKE" run_regress zero --base "$BASE_REV" \
  --head "$HEAD_REV" --out-dir "$TMP/out-zero"
check "eval result with zero cases" 2 "$RC"
has "  says so" "produced no cases" "$TMP/zero.err"
if [ "$(trees_left)" = "0" ]; then ok "  temp trees removed after zero cases"; else bad "  trees left"; fi

# branch behind main: main edits bar after the branch point, the branch edits foo
REPO2="$TMP/repo2"
mkrepo "$REPO2"
gitr "$REPO2" init -q -b main
gitr "$REPO2" add -A
gitr "$REPO2" commit -q -m base
gitr "$REPO2" checkout -q -b feat
printf 'MARKER\n' > "$REPO2/skills/foo/SKILL.md"
gitr "$REPO2" commit -q -am "feat edits foo"
gitr "$REPO2" checkout -q main
printf 'MARKER\n' > "$REPO2/skills/bar/SKILL.md"
gitr "$REPO2" commit -q -am "main edits bar"
gitr "$REPO2" checkout -q feat
MAIN_BASE="$(gitr "$REPO2" rev-parse main~1)"
WHERE="$REPO2" REGRESS_CLAUDE_BIN="$FAKE" run_regress behind --base main --plan
check "branch behind main" 0 "$RC"
hasline "  only foo is checked" "skills: foo" "$TMP/behind.out"
has "  base is the merge-base" "base main → merge-base ${MAIN_BASE:0:10}" "$TMP/behind.out"

echo
echo "$PASS passed / $FAIL failed"
[ "$FAIL" -eq 0 ]
