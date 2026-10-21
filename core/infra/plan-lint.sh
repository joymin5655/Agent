#!/usr/bin/env bash
# plan-lint.sh — deterministic structural lint for .agent/plans/<slug>/plan.md.
#
# Usage: plan-lint.sh <slug|dir>
#   <dir>  an argument containing `/` (or `.`): directory holding plan.md and
#          optionally spec.md
#   <slug> otherwise; must match ^[A-Za-z0-9._-]+$ (not `..`), resolved to
#          .agent/plans/<slug>/ relative to the CWD
#
# Defects (printed as `FAIL <file>:<line>: <reason>`):
#   1. no `## Wave <N>: <name>` header, or any other `## ` header (a `# `
#      line is a title/section break: it ends the current Wave, no steps follow)
#   2. a Wave with no steps; a step (`- `, `* `, `+ `, `1. `, `1) ` at column 0
#      under a Wave) with no `-> verify:` / `→ verify:` marker
#   3. a verify with neither a backticked command nor `reason:` — judged on the
#      text after the LAST marker that is not itself inside a backtick span;
#      indented sub-bullets are not part of the parent's verify text
#   4. spec.md present without a `## Decisions` section
#   5. a spec `## Success criteria` bullet with >=1 backticked term where NONE
#      of its terms occurs in Wave step text (any-hit semantics: one hit per
#      bullet suffices). Boilerplate terms (`→ verify:`, `-> verify:`,
#      `## Wave N:`) are ignored; bullets without usable terms are skipped.
#   6. an empty verify box: `→ verify:` with nothing after it (or only a
#      placeholder: TODO / TBD / ... / <fill ...> / empty backticks) — evidence
#      that was never filled in is not evidence
#   7. an unterminated code fence (it would silently hide the rest of the file)
#   8. spec.md present without a `## Must not` or a `## Edge cases` section
#      (each may hold a single `- none — <reason>` bullet); a present section with
#      no `- ` bullet at all is empty and fails too
#   9. a spec `## Must not` / `## Edge cases` bullet with backticked terms,
#      checked exactly like rule 5 (any-hit, same boilerplate exclusions)
# Fenced code blocks are neither headers nor steps, in plan and spec. Fences
# follow CommonMark: ``` or ~~~, >=3 chars, closed only by the same character
# at >= the opener's length, so a 4-backtick fence may wrap literal ``` lines.
#
# Exit 0: clean. Exit 1: defects. Exit 2: usage / missing plan.md.
set -euo pipefail
export LC_ALL=C

if [[ $# -ne 1 ]]; then
  echo "usage: plan-lint.sh <slug|dir>" >&2
  exit 2
fi

target="$1"
if [[ "$target" == */* || "$target" == "." ]]; then
  dir="$target"
elif [[ "$target" =~ ^[A-Za-z0-9._-]+$ && "$target" != ".." ]]; then
  dir=".agent/plans/$target"
else
  echo "plan-lint: invalid slug '$target' (usage: plan-lint.sh <slug|dir>)" >&2
  exit 2
fi
plan="$dir/plan.md"
spec="$dir/spec.md"
if [[ ! -f "$plan" ]]; then
  echo "plan-lint: no plan.md at $dir (usage: plan-lint.sh <slug|dir>)" >&2
  exit 2
fi

# MODE unset: print defects. MODE=steps: print each step's full text instead.
read -r -d '' PLAN_AWK <<'AWK' || true
function fence_line(line,   s, c, n, rest) {
  s = line; sub(/^[ \t]*/, "", s)
  c = substr(s, 1, 1)
  if (c != "`" && c != "~") return 0
  n = 0
  while (substr(s, n + 1, 1) == c) n++
  if (n < 3) return 0
  rest = substr(s, n + 1)
  if (!fence) {
    if (c == "`" && index(rest, "`") > 0) return 0
    fchar = c; flen = n; fence = 1; fline = FNR
    return 1
  }
  if (c == fchar && n >= flen && rest ~ /^[ \t\r]*$/) fence = 0
  return 1
}
function last_verify(s,   i, n, tick, c, j, k, pos) {
  n = length(s); tick = 0; pos = 0
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "`") { tick = !tick; continue }
    if (tick) continue
    if (substr(s, i, 3) == "→") j = i + 3
    else if (substr(s, i, 2) == "->") j = i + 2
    else continue
    k = j
    while (substr(s, k, 1) == " ") k++
    if (substr(s, k, 7) == "verify:") pos = k + 7
  }
  return pos
}
function flush(   p, v, w) {
  if (!have) return
  have = 0
  if (MODE == "steps") { print buf; return }
  p = last_verify(buf)
  if (p == 0) {
    print "FAIL " F ":" bline ": step has no `→ verify:`"
    return
  }
  v = substr(buf, p)
  w = v; gsub(/`[ \t]*`/, "", w); gsub(/^[ \t]+|[ \t]+$/, "", w)
  if (w == "" || w ~ /^(TODO|TBD|FIXME|\.\.\.|…|<[^>]*>|-|n\/a|N\/A)[ \t.]*$/) {
    print "FAIL " F ":" bline ": verify is empty (nothing after `→ verify:`)"
    return
  }
  if (index(v, "`") == 0 && index(v, "reason:") == 0)
    print "FAIL " F ":" bline ": verify has no backticked command and no `reason:`"
}
function close_wave() {
  if (inwave && wsteps == 0 && MODE != "steps")
    print "FAIL " F ":" wline ": wave has no steps"
  inwave = 0
}
fence_line($0) { flush(); next }
fence { next }
/^# / { flush(); close_wave(); next }
/^## / {
  flush(); close_wave()
  if ($0 ~ /^## Wave [0-9]+: ./) { waves++; inwave = 1; wsteps = 0; wline = NR }
  else if (MODE != "steps") print "FAIL " F ":" NR ": header is not `## Wave <N>: <name>`: " $0
  next
}
/^([-*+]|[0-9]+[.)]) / { flush(); if (inwave) { have = 1; wsteps++; buf = $0; bline = NR } next }
/^[ \t]+([-*+]|[0-9]+[.)]) / { next }
/^[ \t]+[^ \t]/ { if (have) buf = buf " " $0; next }
{ flush() }
END {
  flush(); close_wave()
  if (fence && MODE != "steps") print "FAIL " F ":" fline ": unterminated code fence"
  if (waves == 0 && MODE != "steps") print "FAIL " F ":1: no `## Wave <N>: <name>` header"
}
AWK

plan_defects=$(awk -v F="$plan" "$PLAN_AWK" "$plan")

spec_defects=""
if [[ -f "$spec" ]]; then
  steps=$(awk -v MODE=steps -v F="$plan" "$PLAN_AWK" "$plan")
  spec_defects=$(printf '%s\n' "$steps" | awk -v F="$spec" '
    NR == FNR { plan = plan "\n" $0; next }
    function fence_line(line,   s, c, n, rest) {
      s = line; sub(/^[ \t]*/, "", s)
      c = substr(s, 1, 1)
      if (c != "`" && c != "~") return 0
      n = 0
      while (substr(s, n + 1, 1) == c) n++
      if (n < 3) return 0
      rest = substr(s, n + 1)
      if (!fence) {
        if (c == "`" && index(rest, "`") > 0) return 0
        fchar = c; flen = n; fence = 1; fline = FNR
        return 1
      }
      if (c == fchar && n >= flen && rest ~ /^[ \t\r]*$/) fence = 0
      return 1
    }
    function boilerplate(t) {
      return (t ~ /^(→|->) *verify:?$/ || t ~ /^## Wave/)
    }
    function flush(   s, a, b, term, hit, any) {
      if (!have) return
      have = 0
      s = buf; any = 0; hit = 0
      while ((a = index(s, "`")) > 0) {
        s = substr(s, a + 1)
        b = index(s, "`")
        if (b == 0) break
        term = substr(s, 1, b - 1)
        s = substr(s, b + 1)
        if (term == "" || boilerplate(term)) continue
        any = 1
        if (index(plan, term) > 0) hit = 1
      }
      if (any && !hit) print "FAIL " F ":" bline ": " bkind " not referenced by plan: " buf
    }
    fence_line($0) { flush(); next }
    fence { next }
    /^## / {
      flush()
      sec = ""
      if ($0 ~ /^## Success criteria/) sec = "criterion"
      else if ($0 ~ /^## Must not/) { sec = "must-not"; mn = 1 }
      else if ($0 ~ /^## Edge cases/) { sec = "edge case"; ec = 1 }
      else if ($0 ~ /^## Decisions/) dec = 1
      next
    }
    sec == "" { next }
    /^- / {
      flush(); have = 1; buf = $0; bline = FNR; bkind = sec
      if (sec == "must-not") mn_n++
      else if (sec == "edge case") ec_n++
      next
    }
    /^[ \t]+[^ \t]/ { if (have) buf = buf " " $0; next }
    { flush() }
    END {
      flush()
      if (fence) print "FAIL " F ":" fline ": unterminated code fence"
      if (!dec) print "FAIL " F ":1: spec has no ## Decisions section"
      if (!mn) print "FAIL " F ":1: spec has no ## Must not section"
      else if (!mn_n) print "FAIL " F ":1: spec ## Must not section is empty"
      if (!ec) print "FAIL " F ":1: spec has no ## Edge cases section"
      else if (!ec_n) print "FAIL " F ":1: spec ## Edge cases section is empty"
    }
  ' - "$spec")
fi

if [[ -n "$plan_defects" || -n "$spec_defects" ]]; then
  if [[ -n "$plan_defects" ]]; then printf '%s\n' "$plan_defects"; fi
  if [[ -n "$spec_defects" ]]; then printf '%s\n' "$spec_defects"; fi
  exit 1
fi
echo "PASS plan-lint: $plan"
