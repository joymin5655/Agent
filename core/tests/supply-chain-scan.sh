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
#   5. fetch-and-execute          — `curl|wget … | sh`, `bash <(curl …)`,
#                                    `eval "$(curl …)"`. Always a hit in auto-fired
#                                    hooks and hook/MCP manifests; in prose only
#                                    when a URL host on that line is not in
#                                    core/tests/supply-chain-allowlist.txt
#                                    (documented vendor installers are allowed)
#   6. unpinned remote package    — `npx -y <pkg>` without an @version in hooks or
#                                    manifests: every run executes whatever is
#                                    latest on the registry
#   7. off-allowlist URL host     — any http(s) host referenced by an auto-fired
#                                    hook or a hook/MCP manifest that is not in
#                                    the allowlist   [classes 5-7: ECC v2.2
#                                    pi/core build checks, adapted]
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

# --- classes 5-7: remote-code supply chain -----------------------------------
# Manifests that wire auto-fired code: plugin hook manifests and MCP server
# configs. Scanned together with core/hooks for classes 5-7. plugin.json and
# .claude-plugin/*.json are metadata only (homepage/repository/$schema URLs) and
# wire no code, so they are out of scope.
collect_manifests() {
  local f
  for f in "$TARGET"/hooks/*.json "$TARGET"/.mcp.json; do
    [[ -f "$f" ]] && printf '%s\n' "$f"
  done
}

ALLOWLIST_FILE="$REPO_ROOT/core/tests/supply-chain-allowlist.txt"
ALLOWED_HOSTS=()
if [[ -f "$ALLOWLIST_FILE" ]]; then
  while IFS= read -r h; do
    h="${h%%#*}"; h="${h//[[:space:]]/}"
    [[ -n "$h" ]] && ALLOWED_HOSTS+=("$h")
  done < "$ALLOWLIST_FILE"
fi
host_allowed() {
  local h
  for h in ${ALLOWED_HOSTS[@]+"${ALLOWED_HOSTS[@]}"}; do
    [[ "$1" == "$h" ]] && return 0
  done
  return 1
}
# url_hosts <text> — one lowercase host per line for every http(s) URL in text.
# Parses the authority (up to / ? # or whitespace) and drops a :port. IP and
# `localhost` hosts count as hosts. An authority carrying userinfo
# (https://allowed.com@evil.example) is emitted whole, so it can never match the
# allowlist. Other dotless names (doc placeholders such as https://host/OWNER)
# are skipped.
url_hosts() {
  local a h
  printf '%s\n' "$1" | grep -oiE 'https?://[^]/?#[:space:]"'"'"'`<>()]+' \
    | sed -E 's#^[A-Za-z]+://##' | tr 'A-Z' 'a-z' \
    | while IFS= read -r a; do
        if [[ "$a" == *@* ]]; then printf '%s\n' "$a"; continue; fi
        h="${a%%:*}"; h="${h%.}"
        [[ "$h" == *.* || "$h" == localhost ]] && printf '%s\n' "$h"
      done || true
}
# version_pinned <pkg> — true when <pkg> ends in @<version>. A dist-tag such as
# @latest / @next is NOT a pin: it resolves to whatever the registry serves today.
version_pinned() {
  local bare="${1#@*/}"                     # drop an @scope/ prefix
  [[ "$bare" == *@* ]] || return 1
  [[ "${bare##*@}" =~ ^[~^=v]?[0-9] ]]
}

P_PIPE_EXEC='(curl|wget)[^|;&]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z|da)?sh([^A-Za-z0-9_]|$)|(ba|z)?sh[[:space:]]+<\([[:space:]]*(curl|wget)|(eval|source)[[:space:]]+"?(\$\(|<\()[[:space:]]*(curl|wget)'
P_NPX_YES='npx[[:space:]]+(-y|--yes)[[:space:]]+[^[:space:]"'"'"']+'

# class 5 (prose) — pipe-to-shell is tolerated only from an allowlisted host
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    bad=1
    hosts=$(url_hosts "$m")
    if [[ -n "$hosts" ]]; then
      bad=0
      while IFS= read -r h; do host_allowed "$h" || bad=1; done <<< "$hosts"
    fi
    [[ $bad -eq 1 ]] && HITS+="$f:${m}"$'\n'
  done < <(grep -nE "$P_PIPE_EXEC" "$f" 2>/dev/null || true)
done < <(collect_prose)

# classes 5-7 (auto-fired code) — hooks and manifests
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  m=$(grep -nHE "$P_PIPE_EXEC" "$f" 2>/dev/null || true)
  [[ -n "$m" ]] && HITS+="$m"$'\n'
  while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    pkg="${m##* }"; pkg="${pkg%%[\"\',]*}"
    version_pinned "$pkg" || HITS+="$f: unpinned remote package: $m"$'\n'
  done < <(grep -oE "$P_NPX_YES" "$f" 2>/dev/null || true)
  while IFS= read -r h; do
    [[ -z "$h" ]] && continue
    host_allowed "$h" || HITS+="$f: off-allowlist URL host: $h"$'\n'
  done < <(url_hosts "$(cat "$f" 2>/dev/null)" | sort -u)
done < <({ collect_hooks; collect_manifests; })

# class 6 (manifest array form) — MCP configs spell the command as JSON,
# {"command":"npx","args":["-y","pkg",…]}, which the text pattern cannot see.
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    HITS+="$f: unpinned remote package: npx -y $pkg"$'\n'
  done < <(python3 - "$f" <<'PY' 2>/dev/null || true
import json, re, sys
def walk(o):
    if isinstance(o, dict):
        cmd, args = o.get("command"), o.get("args")
        if isinstance(cmd, str) and cmd.rsplit("/", 1)[-1] == "npx" and isinstance(args, list):
            a = [x for x in args if isinstance(x, str)]
            if "-y" in a or "--yes" in a:
                pkgs = [x for x in a if not x.startswith("-")]
                if pkgs:
                    bare = pkgs[0].split("/", 1)[1] if pkgs[0].startswith("@") and "/" in pkgs[0] else pkgs[0]
                    ver = bare.rsplit("@", 1)[1] if "@" in bare else ""
                    if not re.match(r"[~^=v]?[0-9]", ver):
                        print(pkgs[0])
        for v in o.values():
            walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)
try:
    walk(json.load(open(sys.argv[1])))
except Exception:
    pass
PY
)
done < <(collect_manifests)

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
  echo "auto-loaded instruction scope. Remote code (classes 5-7): pin the version,"
  echo "or add the host to core/tests/supply-chain-allowlist.txt with a reason."
  echo "See rules/policy/security-guards.md."
  exit 1
fi

echo "PASS — no injection-style directives in shipped instruction/code files"
exit 0
