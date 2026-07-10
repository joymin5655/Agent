#!/usr/bin/env bash
# PreToolUse hook — Bash command safety guards
#
# Catches dangerous shell command patterns before they execute:
#   - Broad destructive deletion (rm -rf root/home)
#   - Force push to main/master
#   - git reset --hard
#   - DROP/TRUNCATE TABLE (ask — risk area #1, production-data)
#   - Direct secrets/.env access (deny — risk area #2, secrets)
#     covers 45+ command variants (read, copy, hash, compress, crypto, exfil, redirect, find -exec, xargs)
#   - Hardcoded "data/artifacts/ git add" (project-customizable)
#
# Hook protocol: reads canonical event JSON from stdin, writes decision JSON
# (deny / ask) to stdout, or empty stdout for allow. Exit always 0.
#
# Every deny/ask reason is a TEACHING message (T-1): it carries a `WHY:` line
# (which rule fired and why it exists) and a `FIX:` line (the concrete allowed
# alternative), so a blocked agent can self-correct instead of routing around.
#
# See docs/hook-protocol.md for the canonical contract.

INPUT=$(cat)
TOOL_INPUT=$(echo "$INPUT" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('tool_input',{})))" 2>/dev/null || echo "{}")
COMMAND=$(echo "$TOOL_INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('command',''))" 2>/dev/null || echo "")

emit_deny() {
  local reason="$1"
  python3 - "$reason" <<'PY'
import json
import sys
reason = sys.argv[1]
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason,
    }
}, ensure_ascii=False))
PY
}

emit_ask() {
  local reason="$1"
  python3 - "$reason" <<'PY'
import json
import sys
reason = sys.argv[1]
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "ask",
        "permissionDecisionReason": reason,
    }
}, ensure_ascii=False))
PY
}

# Append to .agent/logs/security-violations.jsonl (silent-fail).
log_violation() {
  local guard="$1" reason="$2" decision="${3:-deny}"
  local repo_root="${AGENT_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}}"
  [[ -z "$repo_root" ]] && return 0
  local log_file="$repo_root/.agent/logs/security-violations.jsonl"
  mkdir -p "$repo_root/.agent/logs" 2>/dev/null || return 0
  local ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local sid="${AGENT_SESSION_ID:-main}"
  local repro="false"
  case "${AGENT_REPRODUCE_TEST:-}" in 1|true|TRUE|True) repro="true" ;; esac
  printf '{"ts":"%s","guard":"%s","hook":"pre-tool-guard.sh","reason":%s,"session_id":"%s","decision":"%s","reproduce_test":%s,"schema_version":"2.0.0"}\n' \
    "$ts" "$guard" "$(printf '%s' "$reason" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo "\"$reason\"")" "$sid" "$decision" "$repro" \
    >> "$log_file" 2>/dev/null || true
  [[ -x "$repo_root/core/infra/agent-session.sh" ]] && \
    "$repo_root/core/infra/agent-session.sh" broadcast blocked \
      "[security] pre-tool-guard.sh: $reason" >/dev/null 2>&1 || true
}

# W-7: strip commit-MESSAGE payloads before the destructive guards (1-4), so a
# message that merely MENTIONS a destructive command ("fix: guard rm -rf /")
# is not blocked. Three shapes are stripped, each only when provably inert:
#   - -m "$(cat <<'EOF' ... EOF)"  — the standard multi-line commit idiom; only
#     a bare `cat <<'DELIM'` substitution with a QUOTED heredoc delimiter
#     qualifies. The quote is mandatory: an UNQUOTED `<<DELIM` body still
#     undergoes command substitution at shell-eval time, so `$(rm -rf /)` inside
#     it would execute — those stay scannable. Any other command inside the
#     substitution is a real execution and stays scannable too;
#   - -m '...'                      — single quotes: shell-literal, always inert;
#   - -m "..."                      — only when free of $ and backtick (no
#     expansion/substitution can hide a live command).
# The flag match covers bundled short clusters (-am/-nm) and --message[=].
# Secrets guards (5+) keep scanning the FULL command: -m "$(cat secrets/key)"
# is a real read, not a mention. Python failure falls back to the full command
# (fail-safe = scan more, never less).
SCAN_CMD=$(SCAN_INPUT="$COMMAND" python3 - <<'PY'
import os, re, sys
cmd = os.environ.get("SCAN_INPUT", "")
# \x22/\x27/\x60 = dquote/quote/backtick as regex escapes: bash 3.2 mis-parses
# unpaired quote or backtick characters inside a $(<<heredoc) command
# substitution even when the heredoc delimiter is quoted.
FLAG = r"(\s--?[a-zA-Z]*m(?:essage)?(?:=|\s+))"
cmd = re.sub(r"(?s)" + FLAG +
             r"\x22\$\(\s*cat\s+<<-?[\x27\x22](\w+)[\x27\x22]\n.*?\n\2\n?\s*\)\x22",
             r"\1<msg>", cmd)
cmd = re.sub(FLAG + r"\x27[^\x27]*\x27", r"\1<msg>", cmd)
cmd = re.sub(FLAG + r"\x22[^\x22$\x60\\]*\x22", r"\1<msg>", cmd)
sys.stdout.write(cmd)
PY
) || SCAN_CMD="$COMMAND"
[[ -z "$SCAN_CMD" && -n "$COMMAND" ]] && SCAN_CMD="$COMMAND"

# 1. Broad destructive deletion
if echo "$SCAN_CMD" | grep -qE 'rm\s+(-rf|-fr)\s+(/|~|\$HOME|\.\./)'; then
  log_violation destructive "broad rm -rf blocked"
  emit_deny "Broad rm -rf to root / home / parent blocked.
WHY: destructive-deletion guard — an unscoped recursive delete is unrecoverable and can take the whole workspace with it.
FIX: delete the specific target explicitly (e.g. rm -rf ./<dir>) after verifying it with ls, or move it aside instead of deleting."
  exit 0
fi

# 2. Force push to protected branches
if echo "$SCAN_CMD" | grep -qE 'git\s+push\s+.*--force.*\s+(main|master)'; then
  log_violation destructive "force push to main/master blocked"
  emit_deny "Force push to main/master blocked.
WHY: R6 — rewriting a protected branch's history breaks every other clone and open PR based on it.
FIX: push to a feature branch and open a PR; on your own branch use git push --force-with-lease."
  exit 0
fi

# 3. git reset --hard
if echo "$SCAN_CMD" | grep -qE 'git\s+reset\s+--hard'; then
  log_violation destructive "git reset --hard blocked"
  emit_deny "git reset --hard blocked.
WHY: destructive guard — it discards uncommitted work with no recovery path.
FIX: git stash (keeps the work), git restore <path> for single files, or git revert <sha> for committed changes."
  exit 0
fi

# 4. Risk Area #1 — production data (DROP/TRUNCATE TABLE) — ASK (user confirms)
if echo "$SCAN_CMD" | grep -qiE '(DROP\s+TABLE|TRUNCATE\s+TABLE)'; then
  log_violation production-data "DROP/TRUNCATE TABLE requires user confirmation" "ask"
  emit_ask "DROP/TRUNCATE TABLE — user confirmation required (Risk Area #1: production-data).
WHY: a dropped or truncated table is unrecoverable without a verified backup.
FIX: proceed only if intended; otherwise run it as a reviewed migration with a backup in place."
  exit 0
fi

# 5. Risk Area #2 — secrets — DENY (no bypass).
# Covers many command variants in a single regex (read / hash / archive / encrypt / exfil families).
# To extend: add command name to the alternation. Project-specific paths can be
# added via hook-config.yml: risk_areas[id=secrets].paths.
if echo "$COMMAND" | grep -qE '(cat|tac|nl|head|tail|less|more|awk|sed|grep|egrep|fgrep|rg|ag|bat|hexdump|xxd|od|strings|dd|fold|rev|tee|cp|mv|ln|md5sum|shasum|sha256sum|sha512sum|wc|diff|cmp|gunzip|bunzip2|bzip2|bzcat|xz|xzcat|unxz|lzma|lz4cat|tar|unzip|7z|zip|gpg|openssl|age|rsync|scp)\s+.*secrets/'; then
  log_violation secrets "direct secrets/ access blocked"
  emit_deny "Direct secrets/ access blocked (Risk Area #2: secrets).
WHY: reading secret files into a session exposes plaintext credentials to logs and transcripts.
FIX: use environment variables read by your server-side code; for inventory, list key NAMES only (awk -F= on the env file, first field)."
  exit 0
fi

# 6. Risk Area #2 — curl/wget upload-from-secrets (exfiltration)
if echo "$COMMAND" | grep -qE '(curl|wget)\s+.*(--data-binary\s+@|--post-file=|--upload-file\s+|-T\s+|-d\s+@|-F\s+\S*=@).*secrets/'; then
  log_violation secrets "secrets/ remote exfiltration blocked"
  emit_deny "curl/wget upload from secrets/ blocked (Risk Area #2: secrets).
WHY: uploading a secret file over the network is credential exfiltration.
FIX: never send secret files anywhere; pass short-lived tokens via environment variables instead."
  exit 0
fi

# 7. Risk Area #2 — xargs indirection (find ... | xargs cat etc.)
if echo "$COMMAND" | grep -qE 'secrets/.*\|.*xargs|xargs\s+.*\bsecrets/'; then
  log_violation secrets "secrets/ xargs indirection blocked"
  emit_deny "secrets/ xargs indirection blocked (Risk Area #2: secrets).
WHY: piping secret paths through xargs is equivalent to reading them directly (same as find -exec).
FIX: for inventory, list key NAMES only via awk -F= on the env file."
  exit 0
fi

# 8. Risk Area #2 — stdin redirect from secrets/
if echo "$COMMAND" | grep -qE '<\s*[^>]*secrets/'; then
  log_violation secrets "stdin redirect from secrets/ blocked"
  emit_deny "stdin redirect from secrets/ blocked (Risk Area #2: secrets).
WHY: redirecting a secret file into a command reads its plaintext into the session.
FIX: for inventory, use awk -F= on env files (key names only)."
  exit 0
fi

# 9. Risk Area #2 — find ... -exec on secrets/
if echo "$COMMAND" | grep -qE 'find\s+.*secrets/.*-exec'; then
  log_violation secrets "find secrets/ -exec blocked"
  emit_deny "find secrets/ -exec blocked (Risk Area #2: secrets).
WHY: -exec runs an arbitrary reader over every secret file found.
FIX: for inventory, use awk -F= on env files (key names only)."
  exit 0
fi

# 10. Risk Area #2 — source / .  .env  files (plaintext token echo risk)
if echo "$COMMAND" | grep -qE '(^|[;&|`(]|\bset\s+-a\s*&&)\s*(\.\s|source\s).*(secrets/|/\.env(\.|$|\s)|\.env\b)'; then
  log_violation secrets "source secrets/.env blocked — plaintext token exposure risk"
  emit_deny "source secrets/.env blocked (Risk Area #2: secrets).
WHY: sourcing an env file can echo tokens in plaintext into the session environment and transcript.
FIX: let server-side code read env vars at runtime; for inventory, use awk -F= on key names only."
  exit 0
fi

# 11. Risk Area #2 — Python/Node inline secret read (Bash matcher boundary)
if echo "$COMMAND" | grep -qE '(python|python3|node)\s+(-c|-e)\s+["'"'"'].*(secrets/|/\.env|\.env\b)'; then
  log_violation secrets "Python/Node inline secret read blocked"
  emit_deny "Python/Node -c/-e reading secrets/.env blocked (Risk Area #2: secrets).
WHY: an inline one-liner bypasses the file-read guards and prints plaintext credentials.
FIX: read configuration through the app's own env handling (os.environ / process.env) in proper server-side code."
  exit 0
fi

# 12. Project-customizable risk area — `data/artifacts/ git add` (optional default).
# Override by editing this rule or adding to hook-config.yml: risk_areas.
if echo "$COMMAND" | grep -qE 'git\s+add\s+.*data/artifacts/'; then
  log_violation project-policy "data/artifacts/ git add blocked"
  emit_deny "data/artifacts/ git add blocked (project policy).
WHY: large binary artifacts bloat git history permanently and never diff meaningfully.
FIX: keep artifacts out of git (.gitignore) and use artifact/object storage; commit the code that generates them instead."
  exit 0
fi

# 13. Verification-gate bypass — `git commit/push --no-verify` (or `git commit -n`).
# These skip the repo's own pre-commit / pre-push hooks (gitleaks + sanitize),
# which is exactly how an unscanned secret or prior-project taint slips in. ASK
# (not deny): a gate bypass is reversible, and ask keeps a commit that merely
# mentions "-n" in its MESSAGE from being hard-blocked. `git push -n` is
# --dry-run, NOT no-verify, so push only matches the long `--no-verify` form.
#
# Match, on the message-stripped command, so the flag — not a -m "..." message
# that says "-n" — is what triggers:
#   - `--no-verify` after a `git commit`/`git push` (allowing global opts such as
#     `-c key=val` between `git` and the subcommand);
#   - any single-dash short-flag CLUSTER containing -n on commit — `-n`, `-nm`,
#     `-vn` (git parses `-nm` as `-n -m`). `(\s|^)-[a-z]*n[a-z]*(\s|$)` matches a
#     lowercase short cluster only, so a --long flag (`--amend`), a `-C<value>`
#     reuse arg, or an n-free cluster (`-am`) never false-positives;
#   - `core.hooksPath=` inline config, which disables hooks with no --no-verify.
_CMD_NG=$(printf '%s' "$COMMAND" | sed -E "s/'[^']*'//g; s/\"[^\"]*\"//g")
if echo "$_CMD_NG" | grep -qE 'git\s+([^ ;|&`]+\s+)*commit\b[^|;&]*(--no-verify|(\s|^)-[a-z]*n[a-z]*(\s|$))' \
   || echo "$_CMD_NG" | grep -qE 'git\s+([^ ;|&`]+\s+)*push\b[^|;&]*--no-verify' \
   || echo "$_CMD_NG" | grep -qE 'git\s+[^;|&]*\bcore\.hooksPath='; then
  log_violation verify-bypass "git --no-verify skips the commit/push gate" "ask"
  emit_ask "git --no-verify (or -n / -nm / core.hooksPath=) skips the repo's own pre-commit/pre-push gate.
WHY: verify-bypass guard — those hooks run gitleaks + sanitize; bypassing them is exactly how an unscanned secret or prior-project taint slips in.
FIX: commit through the normal path and fix the failing hook; confirm only if you truly intend to skip secret/taint scanning."
  exit 0
fi

# 14. Linter/gate config tampering via Bash — disabling a check to make code
# "pass" instead of fixing the code (the ECC-flagged anti-pattern). Matches a
# MUTATING shell op (sed -i / redirect / rm / mv / tee / truncate) whose TARGET
# is a known linter/formatter/gate config. ASK — config edits can be legitimate;
# the user confirms it is not a check being silently weakened. Reading a config
# (cat/grep) is not matched — and neither is a read that merely redirects its
# output ELSEWHERE (`cat .eslintrc.json > backup.txt`), because the redirect
# branch requires the config to be the redirect target. tsconfig/pyproject are
# intentionally out of scope (too broad, edited routinely) to avoid false positives.
_LINT_CFG='(\.eslintrc[a-zA-Z.]*|eslint\.config\.[a-zA-Z]+|\.prettierrc[a-zA-Z.]*|prettier\.config\.[a-zA-Z]+|\.?ruff\.toml|\.flake8|biome\.jsonc?|\.golangci\.ya?ml|\.pre-commit-config\.ya?ml|gitleaks\.toml)'
if echo "$COMMAND" | grep -qE "(sed\s+-i[^;|&]*|>>?\s*|\brm\s+[^;|&]*|\bmv\s+[^;|&]*|\btee\s+[^;|&]*|\btruncate\s+[^;|&]*)$_LINT_CFG"; then
  log_violation lint-tamper "linter/gate config modified via shell" "ask"
  emit_ask "This modifies a linter/formatter/gate config file.
WHY: gate-tamper guard — disabling a check to make code pass hides the defect instead of fixing it.
FIX: fix the flagged code itself; edit the config only when the rule change is the actual, reviewed intent. (Reading configs never asks.)"
  exit 0
fi

exit 0
