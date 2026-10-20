#!/usr/bin/env bash
# plan-converge.sh — turn a REFUTED completion verdict into the next plan wave.
#
# Usage: plan-converge.sh <slug|dir> --from <verdict.json> [--spec-change]
#   <slug|dir>  resolved exactly like plan-lint.sh (a `/` or `.` means directory,
#               otherwise .agent/plans/<slug>/ relative to the CWD)
#   --from      verdict-schema JSON (docs/scoring-convention.md); the gaps are its
#               `refutations` plus `advisories` of the form "decision D<n> not
#               covered ..."
#   --spec-change  the supervisor judged the gaps need a spec change, not code
#
# Appends one `## Wave <N+1>: converge <k>` section to plan.md (N = highest wave
# number, k = converge waves so far + 1): one `- fix:` step per gap, flattened to a
# single line (newlines collapsed, backticks turned into '), each verified by
# `bash core/infra/completion-gate.sh <slug> <N+1>`. plan.md is then linted; on a
# lint failure the original bytes are restored. spec.md is never written.
#
# Exit codes:
#   0  Converged: CONFIRMED and no uncovered-decision advisory; nothing appended
#   2  usage, missing plan.md, or unreadable / malformed verdict JSON; plan unchanged
#   3  a converge wave was appended (the supervisor then runs `supervisor-goal.sh add-wave`)
#   4  the appended wave failed plan-lint; plan.md restored byte-for-byte
#   5  stop, round cap: 3 converge waves already exist
#   6  stop, no progress: every gap repeats the previous converge wave's fix lines
#   7  stop, --spec-change given
# Stops are checked in the order 0, 7, 5, 6; none of them modifies the plan.
set -euo pipefail
export LC_ALL=C

usage() {
  echo "usage: plan-converge.sh <slug|dir> --from <verdict.json> [--spec-change]" >&2
  exit 2
}

target="" verdict="" spec_change=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) [[ $# -ge 2 ]] || usage; verdict="$2"; shift 2 ;;
    --spec-change) spec_change=1; shift ;;
    -*) usage ;;
    *) [[ -z "$target" ]] || usage; target="$1"; shift ;;
  esac
done
[[ -n "$target" && -n "$verdict" ]] || usage

if [[ "$target" == */* || "$target" == "." ]]; then
  dir="$target"
elif [[ "$target" =~ ^[A-Za-z0-9._-]+$ && "$target" != ".." ]]; then
  dir=".agent/plans/$target"
else
  echo "plan-converge: invalid slug '$target'" >&2
  usage
fi
plan="$dir/plan.md"
if [[ ! -f "$plan" ]]; then
  echo "plan-converge: no plan.md at $dir" >&2
  exit 2
fi
slug="$(basename "$(cd "$dir" && pwd)")"
lint="$(dirname "${BASH_SOURCE[0]}")/plan-lint.sh"

backup="$(mktemp)"
trap 'rm -f "$backup"' EXIT
cp -p "$plan" "$backup"

rc=0
python3 -I - "$plan" "$verdict" "$slug" "$spec_change" <<'PY' || rc=$?
import json
import os
import re
import sys
import tempfile

plan_path, verdict_path, slug, spec_change = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
ROUND_CAP = 3


def die(code, msg):
    print("plan-converge: " + msg, file=sys.stderr)
    sys.exit(code)


def flat(text):
    return re.sub(r"\s+", " ", text.replace("`", "'")).strip()


def norm(text):
    return flat(text).lower()


try:
    with open(verdict_path, encoding="utf-8") as f:
        v = json.load(f)
except (OSError, ValueError) as e:
    die(2, "cannot read verdict JSON %s: %s" % (verdict_path, e))
if not isinstance(v, dict) or v.get("verdict") not in ("CONFIRMED", "REFUTED", "MIXED"):
    die(2, "verdict JSON lacks a CONFIRMED/REFUTED/MIXED `verdict`")
lists = {}
for key in ("refutations", "advisories"):
    val = v.get(key, [])
    if not isinstance(val, list) or not all(isinstance(x, str) for x in val):
        die(2, "verdict `%s` must be a list of strings" % key)
    lists[key] = val

uncovered = re.compile(r"\bdecision\s+D\d+\b.*\bnot covered\b", re.IGNORECASE)
gaps = []
for text in lists["refutations"] + [a for a in lists["advisories"] if uncovered.search(a)]:
    g = flat(text)
    if g and g not in gaps:
        gaps.append(g)

if not gaps:
    if v["verdict"] == "CONFIRMED":
        print("Converged: verdict CONFIRMED, nothing to append")
        sys.exit(0)
    die(2, "verdict %s carries no refutations to turn into steps" % v["verdict"])

try:
    with open(plan_path, "rb") as f:
        text = f.read().decode("utf-8")
except (OSError, ValueError) as e:
    die(2, "cannot read %s: %s" % (plan_path, e))

wave_re = re.compile(r"^## Wave (\d+): (.+)$")
fix_re = re.compile(r"^- fix: (.*?)(?: → verify: `bash core/infra/completion-gate\.sh [^`]*`)?\s*$")
highest = 0
converge_waves = 0
prev_fixes = set()
fence = None
in_converge = False
for line in text.split("\n"):
    m = re.match(r"^\s*(`{3,}|~{3,})", line)
    if m:
        if fence is None:
            fence = m.group(1)
        elif m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence) and line.strip() == m.group(1):
            fence = None
        continue
    if fence is not None:
        continue
    if line.startswith("## "):
        w = wave_re.match(line)
        in_converge = False
        if w:
            highest = max(highest, int(w.group(1)))
            if re.fullmatch(r"converge [0-9]+", w.group(2).strip()):
                converge_waves += 1
                in_converge = True
                prev_fixes = set()
        continue
    if in_converge:
        f = fix_re.match(line)
        if f:
            prev_fixes.add(norm(f.group(1)))
if highest == 0:
    die(2, "no `## Wave <N>:` header in %s" % plan_path)

if spec_change:
    die(7, "stop: --spec-change, the remaining gaps need a spec change")
if converge_waves >= ROUND_CAP:
    die(5, "stop: round cap, %d converge waves already exist" % converge_waves)
if prev_fixes and prev_fixes <= {norm(g) for g in gaps}:
    die(6, "stop: no progress, the gaps repeat the previous converge wave")

new_wave = highest + 1
block = "## Wave %d: converge %d\n" % (new_wave, converge_waves + 1)
for g in gaps:
    block += "- fix: %s → verify: `bash core/infra/completion-gate.sh %s %d`\n" % (g, slug, new_wave)
sep = "" if text.endswith("\n\n") else ("\n" if text.endswith("\n") else "\n\n")

directory = os.path.dirname(os.path.abspath(plan_path))
fd, tmp = tempfile.mkstemp(dir=directory, prefix=".plan.md.")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text + sep + block)
    os.chmod(tmp, os.stat(plan_path).st_mode & 0o7777)
    os.replace(tmp, plan_path)
except BaseException:
    if os.path.exists(tmp):
        os.unlink(tmp)
    raise
print("appended Wave %d: converge %d (%d steps)" % (new_wave, converge_waves + 1, len(gaps)))
sys.exit(3)
PY

if [[ "$rc" -eq 3 ]] && ! bash "$lint" "$dir" >&2; then
  cp -p "$backup" "$plan.restore.$$"
  mv "$plan.restore.$$" "$plan"
  echo "plan-converge: appended wave failed plan-lint; plan.md restored" >&2
  exit 4
fi
exit "$rc"
