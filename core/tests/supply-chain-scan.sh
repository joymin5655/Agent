#!/usr/bin/env bash
# supply-chain-scan.sh — static scan of the harness's OWN shipped, auto-loaded
# instruction files (agents / skills / commands / rules / templates / AGENTS.md
# / AI_BOOTSTRAP.md / CLAUDE.md — as *.md, *.template, and *.json) plus its
# AUTO-FIRED AI-decision hooks (core/hooks, every file) for INJECTION-STYLE
# directives (P3-4).
#
# Why: a harness's auto-loaded instruction files are an indirect prompt-injection
# surface. The ECC public audit (a 226k-star harness) found 513 auto-load
# instruction files, 49 of 64 agents wired to Bash, and an "observer-loop" that
# persists unattended — exactly the class where a careless or hostile directive
# in a SHIPPED file silently rides into every consuming project. This is the
# supply-chain analogue of sanitize-audit.sh (which guards prior-project TAINT);
# here we guard against our own files instructing an agent to bypass human
# judgment, self-perpetuate, or daemonize.
#
# Detected classes (patterns calibrated to ZERO hits on this repo's clean tree):
#   1. prompt-injection override  — "ignore previous instructions", "disregard
#                                    your instructions", "you have no choice"
#   2. unattended persistence     — "observer loop", "run forever", "while true",
#                                    "keep running indefinitely", "re-invoke
#                                    yourself"  (the observer-loop anti-pattern)
#   3. no-confirmation coercion   — "without confirmation", "skip approval",
#                                    "never ask for permission"  (anchored on
#                                    confirmation/permission/approval so a routing
#                                    rule like "do not ask for a phantom agent"
#                                    is NOT matched)   [classes 1-3 = prose]
#   4. background-daemon spawn    — nohup / setsid / disown / `crontab -`, scanned
#                                    in the AUTO-FIRED hooks only (see scope note)
#
# Prose classes 1-3 are matched both line-by-line AND against a whitespace-
# flattened copy of each file, so an injection wrapped across soft line breaks
# (deliberately, or by an 80-column reflow) cannot evade a line-oriented grep.
#
# Usage:
#   bash core/tests/supply-chain-scan.sh            # scan this repo (CI + local)
#   bash core/tests/supply-chain-scan.sh <dir>      # scan an arbitrary tree (test)
# Exit 0: clean. Exit 1: an injection-style directive was found (prints file:line).
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET="${1:-$REPO_ROOT}"

# Auto-loaded instruction (prose) scope — where classes 1/2/3 apply. Scanned as
# *.md, *.template (scaffolding copied verbatim into consumers, where it BECOMES
# their CLAUDE.md / AGENTS.md / rules), and *.json (the agent registry).
INSTR_PATHS=(agents skills commands rules templates AGENTS.md AI_BOOTSTRAP.md CLAUDE.md)
PROSE_FIND_EXPR=(-name '*.md' -o -name '*.template' -o -name '*.json')

# Auto-FIRED code scope — where the daemon-spawn class (4) applies. Only the
# AI-decision-loop hooks (core/hooks: PreToolUse / Stop / UserPromptSubmit / …)
# qualify: they fire inside the agent's own loop, so a hook that daemonizes there
# is the hidden observer-loop threat, and it must always be clean. EVERY file is
# scanned (a hook may be extensionless — hooks.json dispatches by filename).
#
# Deliberately OUT of scope, with sanctioned async primitives documented in
# rules/policy/security-guards.md:
#   - core/git-hooks (git-lifecycle, opt-in install): post-commit autosync
#     backgrounds a ONE-SHOT push+PR (`… & disown`) so a commit isn't blocked.
#   - core/infra, adapters, setup.sh (explicitly invoked): e.g.
#     `agent-session.sh subscribe <name>` launches a user-authored subscriber.
HOOK_DIR="core/hooks"

# Files that legitimately carry these patterns as literals — the scanner, its
# test, and the policy doc that enumerates the patterns — are never scanned.
# Matched by EXACT relative path, not basename: a malicious file merely NAMED
# security-guards.md in another directory must NOT inherit the exemption.
EXCLUDE_PATHS=(
  core/tests/supply-chain-scan.sh
  core/tests/supply-chain-scan-test.sh
  rules/policy/security-guards.md
)

# --- pattern groups (ERE) ---------------------------------------------------
P_OVERRIDE='ignore (all |the )?(previous|prior|above) (instruction|direction|rule)|disregard (all |the |any |your )?(previous|prior|safety|instruction)|you have no choice|regardless of (what|any)[^.]{0,20}(the user|instruction)'
P_LOOP='observer[ -]loop|runs? forever|running forever|while true|run continuously|running continuously|keep running (until|forever|indefinitely)|loop(s|ing)? indefinitely|re-?invoke your ?self|re-?launch your ?self|spawn[^.]{0,30}background[^.]{0,30}(loop|watcher|daemon)'
P_NOCONFIRM="without (asking for |seeking |any )?(confirmation|permission|approval)|(skip|skipping|bypass|bypassing|suppress|suppressing)[^.]{0,20}(confirmation|approval|human (review|confirmation))|(do not|don't|never) (ask|asking|prompt|request)[^.]{0,20}(for )?(confirmation|permission|approval)|no (confirmation|approval) (is )?(needed|required)"
P_DAEMON='\<nohup\>|\<setsid\>|\<disown\>|crontab[[:space:]]+-'

PROSE_PATTERN="$P_OVERRIDE|$P_LOOP|$P_NOCONFIRM"

# collect_prose — instruction files (md/template/json) under INSTR_PATHS, minus
# legacy/ and the exact-path self-reference exemptions.
collect_prose() {
  local base excl=() e
  for e in "${EXCLUDE_PATHS[@]}"; do excl+=(-e "$TARGET/$e"); done
  { for base in "${INSTR_PATHS[@]}"; do
      [[ -e "$TARGET/$base" ]] || continue
      find "$TARGET/$base" -type f \( "${PROSE_FIND_EXPR[@]}" \) 2>/dev/null
    done; } | grep -vE "/(legacy)/" | grep -vxF "${excl[@]}" || true
}

# collect_hooks — EVERY file under the auto-fired hook dir (extensionless too).
collect_hooks() {
  [[ -e "$TARGET/$HOOK_DIR" ]] || return 0
  find "$TARGET/$HOOK_DIR" -type f 2>/dev/null | grep -vE "/(legacy)/" || true
}

HITS=""

# classes 1-3 — prose injection directives, line-by-line …
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  m=$(grep -nHiE "$PROSE_PATTERN" "$f" 2>/dev/null || true)
  [[ -n "$m" ]] && HITS+="$m"$'\n'
  # … and against a whitespace-flattened copy, so a directive wrapped across
  # soft line breaks (attacker or 80-col reflow) cannot slip past line-oriented
  # grep. Reported as "(wrapped)" since a line number is not meaningful.
  w=$(tr '\n' ' ' < "$f" 2>/dev/null | tr -s '[:space:]' ' ' | grep -oiE "$PROSE_PATTERN" | head -1 || true)
  [[ -n "$w" ]] && [[ -z "$m" ]] && HITS+="$f (wrapped): $w"$'\n'
done < <(collect_prose)

# class 4 — background-daemon spawn in the auto-fired hooks
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  m=$(grep -nHiE "$P_DAEMON" "$f" 2>/dev/null || true)
  [[ -n "$m" ]] && HITS+="$m"$'\n'
done < <(collect_hooks)

if [[ -n "${HITS//[$'\n']/}" ]]; then
  echo "FAIL — injection-style directive(s) in shipped harness files:"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    printf '  %s\n' "${line#"$TARGET"/}"
  done <<< "$HITS"
  echo ""
  echo "A shipped, auto-loaded file must not instruct an agent to bypass human"
  echo "confirmation, self-perpetuate (observer-loop), or daemonize. Remove the"
  echo "directive, or if it is a legitimate documented example, move it out of the"
  echo "auto-loaded instruction scope. See rules/policy/security-guards.md."
  exit 1
fi

echo "PASS — no injection-style directives in shipped instruction/code files"
exit 0
