#!/usr/bin/env bash
# supply-chain-scan.sh — static scan of the harness's OWN shipped, auto-loaded
# instruction files (agents / skills / commands / rules / templates / AGENTS.md
# / AI_BOOTSTRAP.md / CLAUDE.md) plus its AUTO-FIRED hooks (core/hooks,
# core/git-hooks) for INJECTION-STYLE directives (P3-4).
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
#                                    is NOT matched)
#   4. background-daemon spawn    — nohup / setsid / disown / `crontab -`  (in
#                                    prose OR shipped code)
#
# Usage:
#   bash core/tests/supply-chain-scan.sh            # scan this repo (CI + local)
#   bash core/tests/supply-chain-scan.sh <dir>      # scan an arbitrary tree (test)
# Exit 0: clean. Exit 1: an injection-style directive was found (prints file:line).
set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TARGET="${1:-$REPO_ROOT}"

# Auto-loaded instruction (prose) scope — where 1/2/3 apply.
INSTR_PATHS=(agents skills commands rules templates AGENTS.md AI_BOOTSTRAP.md CLAUDE.md)
# Auto-FIRED code scope — where the daemon-spawn class (4) also applies. Only
# the AI-decision-loop hooks (core/hooks: PreToolUse / Stop / UserPromptSubmit /
# etc.) qualify: they fire inside the agent's own loop, so a hook that daemonizes
# there is the hidden observer-loop threat, and it must always be clean.
#
# Deliberately OUT of scope, with sanctioned async primitives documented in
# rules/policy/security-guards.md:
#   - core/git-hooks (git-lifecycle): post-commit autosync backgrounds a ONE-SHOT
#     push+PR (`… & disown`) so a commit isn't blocked — fire-and-forget, not a
#     persistent loop.
#   - core/infra, adapters, setup.sh (explicitly invoked): e.g.
#     `agent-session.sh subscribe <name>` launches a user-authored subscriber,
#     the same way `npm run dev` starts a server.
CODE_PATHS=(core/hooks)

# Files that legitimately carry these patterns as literals — the scanner, its
# test, and the policy doc that enumerates the patterns — are never scanned (the
# same self-reference exemption sanitize-audit.sh makes for itself).
EXCLUDE_NAMES="supply-chain-scan.sh|supply-chain-scan-test.sh|security-guards.md"

# --- pattern groups (ERE) ---------------------------------------------------
P_OVERRIDE='ignore (all |the )?(previous|prior|above) (instruction|direction|rule)|disregard (all |the |any |your )?(previous|prior|safety|instruction)|you have no choice|you must always|regardless of (what|any)[^.]{0,20}(the user|instruction)'
P_LOOP='observer[ -]loop|runs? forever|running forever|while true|run continuously|running continuously|keep running (until|forever|indefinitely)|loop(s|ing)? indefinitely|re-?invoke your ?self|re-?launch your ?self|spawn[^.]{0,30}background[^.]{0,30}(loop|watcher|daemon)'
P_NOCONFIRM="without (asking for |seeking |any )?(confirmation|permission|approval)|(skip|skipping|bypass|bypassing|suppress|suppressing)[^.]{0,20}(confirmation|approval|human (review|confirmation))|(do not|don't|never) (ask|asking|prompt|request)[^.]{0,20}(for )?(confirmation|permission|approval)|no (confirmation|approval) (is )?(needed|required)"
P_DAEMON='\<nohup\>|\<setsid\>|\<disown\>|crontab[[:space:]]+-'

PROSE_PATTERN="$P_OVERRIDE|$P_LOOP|$P_NOCONFIRM"

# collect_files <glob-ext> <path...> — echo matching files under TARGET, minus
# excluded names and legacy/.
collect_files() {
  local ext="$1"; shift
  local base
  for base in "$@"; do
    [[ -e "$TARGET/$base" ]] || continue
    find "$TARGET/$base" -type f -name "$ext" 2>/dev/null
  done | grep -vE "/(legacy)/" | grep -vE "/($EXCLUDE_NAMES)$" || true
}

HITS=""

# 1/2/3 — prose injection directives in auto-loaded instruction files (.md)
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  m=$(grep -nHiE "$PROSE_PATTERN" "$f" 2>/dev/null || true)
  [[ -n "$m" ]] && HITS+="$m"$'\n'
done < <(collect_files '*.md' "${INSTR_PATHS[@]}")

# 4 — background-daemon spawn in instruction prose AND shipped code
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  m=$(grep -nHiE "$P_DAEMON" "$f" 2>/dev/null || true)
  [[ -n "$m" ]] && HITS+="$m"$'\n'
done < <( { collect_files '*.md' "${INSTR_PATHS[@]}"
           collect_files '*.sh' "${CODE_PATHS[@]}"
           collect_files '*.py' "${CODE_PATHS[@]}"; } | sort -u)

if [[ -n "${HITS//[$'\n']/}" ]]; then
  echo "FAIL — injection-style directive(s) in shipped harness files:"
  printf '%s' "$HITS" | sed "s#^$TARGET/##; s/^/  /"
  echo ""
  echo "A shipped, auto-loaded file must not instruct an agent to bypass human"
  echo "confirmation, self-perpetuate (observer-loop), or daemonize. Remove the"
  echo "directive, or if it is a legitimate documented example, move it out of the"
  echo "auto-loaded instruction scope. See rules/policy/security-guards.md."
  exit 1
fi

echo "PASS — no injection-style directives in shipped instruction/code files"
exit 0
