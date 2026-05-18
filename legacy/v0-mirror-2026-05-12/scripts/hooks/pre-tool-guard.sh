#!/bin/bash
# AirLens — PreToolUse [Bash] 보안 가드
# pre-tool-use.sh Bash 부분만 추출

INPUT=$(cat)
TOOL_INPUT=$(echo "$INPUT" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('tool_input',{})))" 2>/dev/null || echo "{}")
COMMAND=$(echo "$TOOL_INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('command',''))" 2>/dev/null || echo "")

# security-violations.jsonl sink (security-guards.md SOT 정합)
log_violation() {
  local guard="$1" reason="$2"
  local repo_root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
  [[ -z "$repo_root" ]] && return 0
  local log_file="$repo_root/.claude/logs/security-violations.jsonl"
  mkdir -p "$repo_root/.claude/logs" 2>/dev/null || return 0
  local ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local sid="${AGENT_SESSION_ID:-main}"
  printf '{"ts":"%s","guard":%s,"hook":"pre-tool-guard.sh","reason":%s,"session_id":"%s","decision":"deny"}\n' \
    "$ts" "$guard" "$(printf '%s' "$reason" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo "\"$reason\"")" "$sid" \
    >> "$log_file" 2>/dev/null || true
  # work-feed broadcast (R13 — blocked event, multi-agent visibility)
  [[ -x "$repo_root/scripts/infra/agent-session.sh" ]] && \
    "$repo_root/scripts/infra/agent-session.sh" broadcast blocked \
      "[security] pre-tool-guard.sh: $reason" >/dev/null 2>&1 || true
}

# rm -rf 루트/홈
if echo "$COMMAND" | grep -qE 'rm\s+(-rf|-fr)\s+(/|~|\$HOME|\.\./)'; then
  log_violation 0 "광범위 삭제 명령 차단"
  echo '{"decision":"deny","reason":"광범위 삭제 명령 차단"}'
  exit 0
fi
# force push main/master
if echo "$COMMAND" | grep -qE 'git\s+push\s+.*--force.*\s+(main|master)'; then
  log_violation 0 "main/master force push 차단"
  echo '{"decision":"deny","reason":"main/master force push 차단"}'
  exit 0
fi
# git reset --hard
if echo "$COMMAND" | grep -qE 'git\s+reset\s+--hard'; then
  log_violation 0 "git reset --hard 차단"
  echo '{"decision":"deny","reason":"git reset --hard 차단"}'
  exit 0
fi
# DROP/TRUNCATE TABLE (guard 1 — production migration)
if echo "$COMMAND" | grep -qiE '(DROP\s+TABLE|TRUNCATE\s+TABLE)'; then
  log_violation 1 "DROP/TRUNCATE TABLE 차단"
  echo '{"decision":"deny","reason":"DROP/TRUNCATE TABLE 차단"}'
  exit 0
fi
# secrets/ Bash 접근 (guard 2 — secret 변경)
if echo "$COMMAND" | grep -qE '(cat|echo|tee|cp|mv)\s+.*secrets/'; then
  log_violation 2 "secrets/ 직접 접근 차단"
  echo '{"decision":"deny","reason":"secrets/ 직접 접근 차단"}'
  exit 0
fi
# source secrets/* 또는 source *.env (값 평문 echo 위험 — 2026-04-28 사고 재발 방지) (guard 2)
if echo "$COMMAND" | grep -qE '(^|[;&|`(]|\bset\s+-a\s*&&)\s*(\.\s|source\s).*(secrets/|/\.env(\.|$|\s)|web\.env|models\.env)'; then
  log_violation 2 "source secrets/*.env 차단 — 토큰 평문 노출 위험"
  echo '{"decision":"deny","reason":"source secrets/*.env 차단 — 토큰 평문 노출 위험. 길이 인벤토리는 awk -F= 사용."}'
  exit 0
fi
# Python/Node inline secrets/ read (Bash matcher 한계 보완 — Wave 1.2) (guard 2)
if echo "$COMMAND" | grep -qE '(python|python3|node)\s+(-c|-e)\s+["'"'"'].*(secrets/|/\.env|web\.env|models\.env)'; then
  log_violation 2 "Python/Node inline secret read 차단"
  echo '{"decision":"deny","reason":"Python/Node -c/-e 로 secrets/ 직접 읽기 차단. 정식 import + 환경변수 검증 사용."}'
  exit 0
fi
# data/artifacts/ git add
if echo "$COMMAND" | grep -qE 'git\s+add\s+.*data/artifacts/'; then
  log_violation 0 "data/artifacts/ git add 차단"
  echo '{"decision":"deny","reason":"data/artifacts/ git add 차단"}'
  exit 0
fi

echo '{"decision":"allow"}'
