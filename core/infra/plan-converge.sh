#!/usr/bin/env bash
# plan-converge.sh — turn a REFUTED completion verdict into plan work.
#
# Usage: plan-converge.sh <slug|dir> --from <verdict.json> --wave <i> [--spec-change]
#   <slug|dir>  resolved exactly like plan-lint.sh (a `/` or `.` means directory,
#               otherwise .agent/plans/<slug>/ relative to the CWD); a directory's
#               base name must be a valid slug (^[A-Za-z0-9._-]+$)
#   --from      verdict-schema JSON (docs/scoring-convention.md); the gaps are its
#               `refutations` plus `advisories` of the form "decision D<n> not
#               covered ..."
#   --wave      number of the wave whose completion gate returned the verdict
#   --spec-change  the supervisor judged the gaps need a spec change, not code
#
# Gaps become one `- fix:` step each, flattened to a single line (whitespace
# collapsed, backticks turned into ', `$(` into `$ (`), each verified by
# `bash core/infra/completion-gate.sh <slug> <wave>`.
#   - Wave <i> is a planned wave and no later converge wave exists: append
#     `## Wave <N+1>: converge <k>` (N = highest wave number, k = converge waves
#     so far + 1).
#   - Wave <i> is a planned wave and a converge wave numbered > i already exists
#     (pending): merge the new gaps into the last such wave, skipping duplicates.
#   - Wave <i> is a converge wave: append a new converge wave, unless no progress.
# plan.md is linted before and after the write; spec.md is never written.
#
# Exit codes:
#   0  Converged: CONFIRMED and no uncovered-decision advisory; plan unchanged
#   2  usage, missing plan.md / wave, unreadable or malformed verdict JSON, or an
#      internal error; plan unchanged
#   3  a converge wave was appended (the supervisor then runs `supervisor-goal.sh
#      add-wave`)
#   4  the written plan failed plan-lint; plan.md restored byte-for-byte
#   5  stop, round cap: 3 converge waves already exist
#   6  stop, no progress: wave <i> is a converge wave and the new gaps are a
#      superset of (or equal to) its own fix lines
#   7  stop, --spec-change given
#   8  merged into a pending converge wave; do NOT run add-wave (no new wave)
#   9  plan/spec already fails plan-lint before any change; plan.md untouched
# Checks run in the order 0, 7, 5, 6; only 3, 4 and 8 modify the plan.
set -euo pipefail
export LC_ALL=C

usage() {
  echo "usage: plan-converge.sh <slug|dir> --from <verdict.json> --wave <i> [--spec-change]" >&2
  exit 2
}

target="" verdict="" wave="" spec_change=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --from) [[ $# -ge 2 ]] || usage; verdict="$2"; shift 2 ;;
    --wave) [[ $# -ge 2 ]] || usage; wave="$2"; shift 2 ;;
    --spec-change) spec_change=1; shift ;;
    -*) usage ;;
    *) [[ -z "$target" ]] || usage; target="$1"; shift ;;
  esac
done
[[ -n "$target" && -n "$verdict" && "$wave" =~ ^[0-9]+$ && "$wave" -ge 1 ]] || usage

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
if [[ ! "$slug" =~ ^[A-Za-z0-9._-]+$ || "$slug" == ".." ]]; then
  echo "plan-converge: directory name '$slug' is not a valid slug" >&2
  exit 2
fi
lint="$(dirname "${BASH_SOURCE[0]}")/plan-lint.sh"

backup="$(mktemp)"
newplan="$(mktemp "$dir/.plan.md.XXXXXX")"
trap 'rm -f "$backup" "$newplan"' EXIT
cp -p "$plan" "$backup"
cp -p "$plan" "$newplan"

rc=0
python3 -I - "$plan" "$verdict" "$slug" "$wave" "$spec_change" "$newplan" <<'PY' || rc=$?
import json
import re
import sys

plan_path, verdict_path, slug, wave_arg, spec_change, out_path = sys.argv[1:7]
wave_arg = int(wave_arg)
spec_change = spec_change == "1"
ROUND_CAP = 3


def die(code, msg):
    print("plan-converge: " + msg, file=sys.stderr)
    sys.exit(code)


def flat(text):
    return re.sub(r"\s+", " ", text.replace("`", "'").replace("$(", "$ (")).strip()


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
lines = text.split("\n")
waves = []
cur = None
fence = None
for idx, line in enumerate(lines):
    s = line.lstrip(" \t")
    c = s[:1]
    if c in ("`", "~"):
        n = len(s) - len(s.lstrip(c))
        if n >= 3:
            rest = s[n:]
            if fence is None:
                if not (c == "`" and "`" in rest):  # mirrors plan-lint.sh fence_line
                    fence = (c, n)
                    continue
            else:
                if c == fence[0] and n >= fence[1] and rest.strip(" \t\r") == "":
                    fence = None
                continue
    if fence is not None:
        continue
    if line.startswith("# ") or line.startswith("## "):
        if cur is not None:
            cur["end"] = idx
            cur = None
        w = wave_re.match(line)
        if w:
            cur = {"num": int(w.group(1)), "head": idx, "end": len(lines),
                   "converge": re.fullmatch(r"converge [0-9]+", w.group(2).strip()) is not None,
                   "fixes": set()}
            waves.append(cur)
        continue
    if cur is not None and cur["converge"]:
        f = fix_re.match(line)
        if f:
            cur["fixes"].add(norm(f.group(1)))
if not waves:
    die(2, "no `## Wave <N>:` header in %s" % plan_path)
by_num = {w["num"]: w for w in waves}
if wave_arg not in by_num:
    die(2, "wave %d is not in %s" % (wave_arg, plan_path))
refuted = by_num[wave_arg]
converge_waves = [w for w in waves if w["converge"]]
highest = max(w["num"] for w in waves)
gap_norms = {norm(g) for g in gaps}

if spec_change:
    die(7, "stop: --spec-change, the remaining gaps need a spec change")

pending = [w for w in converge_waves if w["num"] > wave_arg] if not refuted["converge"] else []
if pending:
    target = max(pending, key=lambda w: w["num"])
    new = [g for g in gaps if norm(g) not in target["fixes"]]
    if not new:
        print("merged: Wave %d already lists every gap" % target["num"])
        sys.exit(8)
    steps = ["- fix: %s → verify: `bash core/infra/completion-gate.sh %s %d`" % (g, slug, target["num"])
             for g in new]
    at = target["head"]
    for i in range(target["head"] + 1, target["end"]):
        if lines[i].strip():
            at = i
    lines[at + 1:at + 1] = steps
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    print("merged %d step(s) into Wave %d: converge" % (len(new), target["num"]))
    sys.exit(8)

if len(converge_waves) >= ROUND_CAP:
    die(5, "stop: round cap, %d converge waves already exist" % len(converge_waves))
if refuted["converge"] and refuted["fixes"] and refuted["fixes"] <= gap_norms:
    die(6, "stop: no progress, the gaps repeat Wave %d's own fix lines" % wave_arg)

new_wave = highest + 1
block = "## Wave %d: converge %d\n" % (new_wave, len(converge_waves) + 1)
for g in gaps:
    block += "- fix: %s → verify: `bash core/infra/completion-gate.sh %s %d`\n" % (g, slug, new_wave)
sep = "" if text.endswith("\n\n") else ("\n" if text.endswith("\n") else "\n\n")
with open(out_path, "w", encoding="utf-8") as f:
    f.write(text + sep + block)
print("appended Wave %d: converge %d (%d steps)" % (new_wave, len(converge_waves) + 1, len(gaps)))
sys.exit(3)
PY

case "$rc" in
  0|2|5|6|7) exit "$rc" ;;
  3|8) ;;
  *) echo "plan-converge: internal error (python exit $rc); plan unchanged" >&2; exit 2 ;;
esac

if cmp -s "$newplan" "$plan"; then exit "$rc"; fi
if ! bash "$lint" "$dir" >&2; then
  echo "plan-converge: plan/spec already fails plan-lint; nothing changed" >&2
  exit 9
fi
mv "$newplan" "$plan"
if ! bash "$lint" "$dir" >&2; then
  cp -p "$backup" "$plan.restore.$$"
  mv "$plan.restore.$$" "$plan"
  echo "plan-converge: written plan failed plan-lint; plan.md restored" >&2
  exit 4
fi
exit "$rc"
