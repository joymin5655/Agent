#!/usr/bin/env bash
# doc-reality.sh — the doc-drift gate (P1-1). Guards the harness's OWN docs against
# three regression classes that P0 had to fix by hand (gaps #1/#3/#4):
#
#   (A) PHANTOM PATH REFS   — a current-state doc naming an in-repo file that does
#       not exist (README/AGENTS once pointed at core/tests/adapter-smoke/<ai>/run.sh,
#       cross-ai-parity.sh, verify-all.sh, bootstrap-test.sh — all nonexistent).
#   (B) BACKLOG-COUNT DRIFT — §7 point 4 declares `grep -cE '…' plan` = **N** for each
#       backlog series (P, H-W, T-E, O-L-I, M, A-G); the live grep must equal the declared
#       N (catches a doc that grows the backlog but forgets to update the tally, or vice-versa).
#   (C) ARTIFACT-COUNT DRIFT— §7 point 1 declares `ls <glob> | wc -l` = **N** for
#       hooks / tests / agents / skills; the live count must equal the declared N.
#
# This is pillar-② (CI/CD structural enforcement) applied to the harness's own
# documentation — the harness gating its own doc drift. Sibling self-integrity gates:
# core/tests/sanitize-audit.sh (prior-project taint) and core/tests/supply-chain-scan.sh
# (self-injection directives); this mirrors their shape (REPO_ROOT/TARGET, collect fns,
# HITS accumulation, bash suffix-strip reporting, 0=clean / 1=drift).
#
# ── (A) scope & exclusions (calibrated to ZERO hits on a clean HEAD) ─────────────────
# Doc set: EVERY tracked *.md under the tree, EXCEPT three by-design exclusions —
#   * docs/harness-improvement-plan.md — FORWARD-LOOKING backlog: references not-yet-built
#     deliverables (verify-all.sh, grade.sh, skills/harness-loop/SKILL.md) on purpose. Its
#     numeric claims are gated instead by (B)/(C), which read specific declaration lines.
#   * CHANGELOG.md — BACKWARD-LOOKING history: legitimately names removed/renamed artifacts
#     ("cross-ai-parity.sh … never existed; docs now fixed"), so path-existence is wrong for it.
#   * anything under legacy/ — retired snapshots.
#   Nested docs are IN scope: docs/**/*.md (recursive) and every */README.md — a phantom in
#   core/hooks/README.md is as much a lie as one in the top-level README.
#
# Code-fence rule (documented, defensible): fenced code blocks — ``` or ~~~ indented 0-3 spaces
#   (CommonMark §4.5) — are ILLUSTRATIVE EXAMPLES, stripped before scanning; only INLINE
#   `backtick` paths and bare prose paths are checked. A phantom inside a fence is not flagged;
#   the same path in prose IS. A genuinely UNTERMINATED fence (open at EOF — tracked
#   CommonMark-style: a fence closes only on a >=opener-length run of the same char, so a
#   4-backtick fence wrapping literal ``` lines is NOT mistaken for unbalanced) is itself
#   flagged as a malformed-doc HIT — otherwise it would silently swallow (and blind the scan
#   to) every path below it. NOTE: a >=4-space-indented (or tab-indented) line is CommonMark
#   INDENTED-CODE / paragraph text, NOT a fence — it is NOT auto-stripped, so its neighbouring
#   prose IS scanned (a pair of deep-indented ``` cannot silently hide a phantom between them,
#   and detecting indented blocks to strip them would hide real phantoms in deeply-indented
#   list continuations — a false-negative, worse for a drift gate than a loud, escapable
#   false-positive). So an EXAMPLE path the reader is meant to CREATE must use a 0-3-space
#   ``` / ~~~ fence or a <placeholder> segment — NOT deep indentation — to opt out.
#   A leading ./ is normalized off, so ./core/tests/x.sh is checked like core/tests/x.sh.
#
# Extraction: after fence-stripping, text is tokenized on non-path characters and a token
#   is a candidate iff it BEGINS with a known in-repo top segment
#   (core|adapters|skills|agents|templates|rules|docs|hooks|scripts|evals) AND ends in a
#   .<ext> filename. These classes therefore never form a candidate (excluded BY
#   CONSTRUCTION), which is why HEAD calibrates to 0:
#     * URLs (github.com/…, https://…, youtu.be/…) — do not start with a listed segment.
#     * home / install / runtime paths (~/.claude/…, $HOME/…, /tmp/…, .agent/…, .git/…) —
#       the ~ / $ / leading-slash / leading-dot breaks or disqualifies the token.
#     * glob / placeholder / example tokens (*, **, <ai>, <slug>, {…}, …) — the special
#       char splits the token before a valid file path can form.
#   Additionally dropped: anything matching (^|/)legacy/, and the gate's own two scripts
#   by EXACT path (they carry example phantom literals like core/tests/nonexistent.sh).
#
# Usage:
#   bash core/tests/doc-reality.sh            # gate this repo (CI + local)
#   bash core/tests/doc-reality.sh <dir>      # gate an arbitrary doc-tree (test harness)
# Exit 0: docs match reality. Exit 1: drift found (prints doc:offending-claim).
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET="${1:-$REPO_ROOT}"

PLAN_REL="docs/harness-improvement-plan.md"
PLAN="$TARGET/$PLAN_REL"

# (A) known in-repo top-level segments — a path ref must start with one of these.
SEG='core|adapters|skills|agents|templates|rules|docs|hooks|scripts|evals'

# self-exemption (EXACT path) — the gate + its test carry example phantom literals.
SELF_EXEMPT=(
  core/tests/doc-reality.sh
  core/tests/doc-reality-test.sh
)

HITS=""

# ── (A) referenced-path existence ────────────────────────────────────────────────────
# collect_docs_A — every current-state *.md (recursive), minus the forward-looking backlog,
# the backward-looking CHANGELOG, and legacy/. `find` (not a glob) so nested docs — docs/**
# and every */README.md — are covered; both prune terms are portable to BSD + GNU find.
collect_docs_A() {
  find "$TARGET" \( -name .git -o -name legacy \) -prune -o \
       -type f -name '*.md' -print 2>/dev/null \
    | grep -vxF "$PLAN" \
    | grep -vxF "$TARGET/CHANGELOG.md" \
    | sort -u || true
}

# ── shared CommonMark-aware fence tracker ────────────────────────────────────────────
# Used by BOTH the strip (scan_paths_A) and the parity check (fence_balanced) so the two
# can never disagree. A fenced block OPENS on a run of >=3 backticks or >=3 tildes (any
# leading indent) and CLOSES only on a later line of the SAME char whose run is >= the
# opener's length, with nothing after it but whitespace (CommonMark §4.5). So a 4-backtick
# fence may legitimately contain literal ``` lines (a doc ABOUT fences) WITHOUT looking
# unbalanced — a naive odd/even toggle wrongly failed that. Per line it sets `infence`
# (1 for the opener/interior/closer lines, 0 outside); `open`!=0 at END means a genuinely
# UNTERMINATED fence (which would blind the scan to everything below it). The regexes use
# `````* = 3+ backticks / ~~~~* = 3+ tildes to avoid the {n,} interval quantifier (BSD awk).
FENCE_AWK='
{
  s=$0; ind=0
  while (substr(s,1,1)==" ") { s=substr(s,2); ind++ }
  # CommonMark §4.5: a fence may be indented 0-3 spaces; a >=4-space (or tab) indent makes the
  # line indented-code / paragraph text, NOT a fence delimiter — so its neighbouring prose is
  # still scanned (a pair of deep-indented ``` must NOT silently swallow a phantom between them).
  fenceable = (ind<=3 && $0 !~ /^\t/)
  if (open==0) {
    if (fenceable && match(s, /^(````*|~~~~*)/)) { opench=substr(s,1,1); openlen=RLENGTH; open=1; infence=1 }
    else { infence=0 }
  } else {
    infence=1
    if (fenceable && match(s, /^(````*|~~~~*)[[:space:]]*$/)) {
      m=substr(s,RSTART,RLENGTH); sub(/[[:space:]]*$/,"",m)
      if (substr(m,1,1)==opench && length(m)>=openlen) { open=0 }
    }
  }
}'

# fence_balanced <docfile> — exit 0 if every fence is properly terminated, 1 if a fence is
# left open at EOF (which would blind the scan to every path below it).
fence_balanced() {
  awk "$FENCE_AWK"'
    END { exit (open?1:0) }' "$1"
}

# scan_paths_A <docfile> — emit unique candidate in-repo path tokens (fenced blocks dropped).
# The first `sed` strips trailing non-alnum glued on by tokenization — chiefly a sentence
# period ("the runner is core/tests/foo.sh.") — so a bare-prose phantom that ends a
# sentence is still caught. The second `sed` normalizes a leading ./ so ./core/tests/x.sh
# is anchored like core/tests/x.sh. Both only rescue real `.ext` tokens; dir-ish tokens (no
# extension) still fail the anchored regex, so they add no HEAD false-positive.
scan_paths_A() {
  awk "$FENCE_AWK"'
    infence==0' "$1" \
    | tr -c 'A-Za-z0-9_./-' '\n' \
    | sed -E 's/[^A-Za-z0-9]+$//' \
    | sed -E 's#^\./##' \
    | grep -E "^($SEG)/[A-Za-z0-9_./-]*\.[A-Za-z0-9]+$" \
    | grep -vE '(^|/)legacy/' \
    | sort -u
}

while IFS= read -r doc; do
  [[ -z "$doc" ]] && continue
  # an unterminated fence would silently drop every path below it — flag it loudly instead
  fence_balanced "$doc" || HITS+="$doc: malformed — unterminated code fence (an open fence blinds the phantom-path scan below)"$'\n'
  while IFS= read -r tok; do
    [[ -z "$tok" ]] && continue
    # self-exemption by exact path
    case " ${SELF_EXEMPT[*]} " in *" $tok "*) continue ;; esac
    [[ -e "$TARGET/$tok" ]] || HITS+="$doc: referenced path missing -> $tok"$'\n'
  done < <(scan_paths_A "$doc")
done < <(collect_docs_A)

# ── (B)/(C) declared-vs-live counts (only if the plan doc is present) ─────────────────
# extract_declared <file> <anchor> — find the FIRST line containing the literal <anchor>
# string, then print the first **N** that follows it. The anchor is passed via ENVIRON
# (NOT awk -v) so backslashes in ERE anchors like '^\| P…' survive verbatim; index() is a
# literal search, so regex metacharacters in the anchor are matched literally.
extract_declared() {
  ANCHOR="$2" awk '
    { i = index($0, ENVIRON["ANCHOR"])
      if (i) {
        rest = substr($0, i + length(ENVIRON["ANCHOR"]))
        if (match(rest, /\*\*[0-9]+\*\*/)) { print substr(rest, RSTART + 2, RLENGTH - 4); exit }
      } }' "$1"
}

# check_backlog <label> <ere-pattern> — the pattern doubles as the live `grep -cE` and as
# the literal declaration anchor in the doc (`grep -cE '<pattern>' … = **N**`).
check_backlog() {
  local declared live
  declared="$(extract_declared "$PLAN" "$2")"
  [[ -z "$declared" ]] && return 0   # not declared here -> nothing to compare
  live="$(grep -cE "$2" "$PLAN")"
  if [[ "$declared" != "$live" ]]; then
    HITS+="$PLAN: backlog count [$1] declares **$declared** but live grep = $live"$'\n'
  fi
}

# check_artifact <label> <ls-anchor> <glob-string> — <ls-anchor> is the literal counting
# command declared in the doc (`<ls-anchor>` = **N**); <glob-string> is the same glob(s)
# expanded against TARGET to get the live count. ONE documented method per artifact.
check_artifact() {
  local declared live
  declared="$(extract_declared "$PLAN" "$2")"
  [[ -z "$declared" ]] && return 0
  live="$(cd "$TARGET" 2>/dev/null && ls $3 2>/dev/null | wc -l | tr -d ' ')"
  [[ -z "$live" ]] && live=0
  if [[ "$declared" != "$live" ]]; then
    HITS+="$PLAN: artifact count [$1] declares **$declared** but live \`ls $3\` = $live"$'\n'
  fi
}

if [[ -f "$PLAN" ]]; then
  check_backlog  "P-rows"   '^\| P[0-3]-[0-9]+'
  check_backlog  "HW-rows"  '^\| [HW]-[0-9]+'
  check_backlog  "TE-rows"  '^\| [TE]-[0-9]+'
  check_backlog  "OLI-rows" '^\| [OLI]-[0-9]+'
  check_backlog  "M-rows"   '^\| M-[0-9]+'
  check_backlog  "AG-rows"  '^\| [AG]-[0-9]+'
  check_artifact "hooks"  'ls core/hooks/*.py core/hooks/*.sh | wc -l' 'core/hooks/*.py core/hooks/*.sh'
  check_artifact "tests"  'ls core/tests/*.sh | wc -l'                 'core/tests/*.sh'
  check_artifact "agents" 'ls agents/*.md | wc -l'                     'agents/*.md'
  check_artifact "skills" 'ls skills/*/SKILL.md | wc -l'               'skills/*/SKILL.md'
fi

# ── report ───────────────────────────────────────────────────────────────────────────
if [[ -n "${HITS//[$'\n']/}" ]]; then
  echo "FAIL — documentation does not match repository reality:"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    printf '  %s\n' "${line#"$TARGET"/}"
  done <<< "$HITS"
  echo ""
  echo "A shipped doc must not name an in-repo file that does not exist, nor declare a"
  echo "count that disagrees with the live repo. Fix the doc (or ship the file). An"
  echo "illustrative EXAMPLE path (a file to be created) belongs in a fenced block or a"
  echo "<placeholder>. See docs/harness-improvement-plan.md §7 (self-verification)."
  exit 1
fi

echo "PASS — doc path references resolve and declared counts match reality"
exit 0
