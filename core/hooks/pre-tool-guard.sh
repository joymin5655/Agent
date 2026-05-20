#!/bin/bash
# AirLens — PreToolUse [Bash] 보안 가드
# pre-tool-use.sh Bash 부분만 추출

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

# 2026-05-18 wobbly-percolating-panda — block → ask 완화 (§1 production migration 한정, §2 Secret 은 emit_deny 유지)
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

# security-violations.jsonl sink (security-guards.md SOT 정합, schema v2 2026-05-14)
log_violation() {
  local guard="$1" reason="$2" decision="${3:-deny}"
  local repo_root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
  [[ -z "$repo_root" ]] && return 0
  local log_file="$repo_root/.claude/logs/security-violations.jsonl"
  mkdir -p "$repo_root/.claude/logs" 2>/dev/null || return 0
  local ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local sid="${AGENT_SESSION_ID:-main}"
  local repro="false"
  case "${AIRLENS_REPRODUCE_TEST:-}" in 1|true|TRUE|True) repro="true" ;; esac
  printf '{"ts":"%s","guard":%s,"hook":"pre-tool-guard.sh","reason":%s,"session_id":"%s","decision":"%s","reproduce_test":%s,"schema_version":"2.0.0"}\n' \
    "$ts" "$guard" "$(printf '%s' "$reason" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo "\"$reason\"")" "$sid" "$decision" "$repro" \
    >> "$log_file" 2>/dev/null || true
  # work-feed broadcast (R13 — blocked event, multi-agent visibility)
  [[ -x "$repo_root/scripts/infra/agent-session.sh" ]] && \
    "$repo_root/scripts/infra/agent-session.sh" broadcast blocked \
      "[security] pre-tool-guard.sh: $reason" >/dev/null 2>&1 || true
}

# rm -rf 루트/홈
if echo "$COMMAND" | grep -qE 'rm\s+(-rf|-fr)\s+(/|~|\$HOME|\.\./)'; then
  log_violation 0 "광범위 삭제 명령 차단"
  emit_deny "광범위 삭제 명령 차단"
  exit 0
fi
# force push main/master
if echo "$COMMAND" | grep -qE 'git\s+push\s+.*--force.*\s+(main|master)'; then
  log_violation 0 "main/master force push 차단"
  emit_deny "main/master force push 차단"
  exit 0
fi
# git reset --hard
if echo "$COMMAND" | grep -qE 'git\s+reset\s+--hard'; then
  log_violation 0 "git reset --hard 차단"
  emit_deny "git reset --hard 차단"
  exit 0
fi
# DROP/TRUNCATE TABLE (guard 1 — production migration, 2026-05-18 block → ask 완화 wobbly-percolating-panda)
if echo "$COMMAND" | grep -qiE '(DROP\s+TABLE|TRUNCATE\s+TABLE)'; then
  log_violation 1 "DROP/TRUNCATE TABLE 사용자 확인" "ask"
  emit_ask "DROP/TRUNCATE TABLE 사용자 확인 — production migration 가드 §1. 의도된 명령이면 진행."
  exit 0
fi
# secrets/ Bash 접근 (guard 2 — secret 변경)
# 2026-05-14: head/tail/awk/sed/grep/xxd/od/strings/dd/ln 추가 (P1)
# 2026-05-14: rg/ag/bat/md5sum/shasum/sha256sum/sha512sum/wc/diff/cmp 추가 (P4 — secrets-bypass-p4-followup.md)
# 2026-05-14: 압축(gunzip/bunzip2/bzip2/bzcat/xz/xzcat/unxz/lzma/lz4cat/tar/unzip/7z) + crypto(gpg/openssl/age) + rsync/scp 추가 (P5 — secrets-bypass-p5-followup.md)
# 2026-05-14: zip archive 생성 추가 (P6 — secrets-bypass-p6-followup.md, secrets/ 출구 차단)
if echo "$COMMAND" | grep -qE '(cat|tac|nl|head|tail|less|more|awk|sed|grep|egrep|fgrep|rg|ag|bat|hexdump|xxd|od|strings|dd|fold|rev|tee|cp|mv|ln|md5sum|shasum|sha256sum|sha512sum|wc|diff|cmp|gunzip|bunzip2|bzip2|bzcat|xz|xzcat|unxz|lzma|lz4cat|tar|unzip|7z|zip|gpg|openssl|age|rsync|scp)\s+.*secrets/'; then
  log_violation 2 "secrets/ 직접 접근 차단"
  emit_deny "secrets/ 직접 접근 차단"
  exit 0
fi
# curl/wget @secrets/ exfiltration (P5 — secrets-bypass-p5-followup.md, 2026-05-14)
# `curl -d @secrets/x` / `curl -F file=@secrets/x` / `curl --data-binary @secrets/x` / `wget --post-file=secrets/x`
# 2026-05-14: `-T secrets/x` / `--upload-file secrets/x` 추가 (P6 — secrets-bypass-p6-followup.md, A1 누락 보강)
if echo "$COMMAND" | grep -qE '(curl|wget)\s+.*(--data-binary\s+@|--post-file=|--upload-file\s+|-T\s+|-d\s+@|-F\s+\S*=@).*secrets/'; then
  log_violation 2 "secrets/ 원격 exfiltration 차단"
  emit_deny "curl/wget @secrets/ exfiltration 차단 — content 원격 전송 위험."
  exit 0
fi
# xargs 인디렉션 (P5, 2026-05-14)
# `echo secrets/x | xargs cat` / `ls secrets/ | xargs -I{} cat ...`
if echo "$COMMAND" | grep -qE 'secrets/.*\|.*xargs|xargs\s+.*\bsecrets/'; then
  log_violation 2 "secrets/ xargs 인디렉션 차단"
  emit_deny "secrets/ xargs 인디렉션 차단 — find -exec 와 동등."
  exit 0
fi
# stdin redirect from secrets/ (P3 — secrets-bypass-p3-followup.md, 2026-05-14)
# `python3 < secrets/x` / `node < secrets/db.env` / `tr a b < secrets/key` 차단
if echo "$COMMAND" | grep -qE '<\s*[^>]*secrets/'; then
  log_violation 2 "stdin redirect from secrets/ 차단"
  emit_deny "stdin redirect from secrets/ 차단 — 길이 인벤토리는 awk -F= 사용."
  exit 0
fi
# find secrets/ -exec indirection (P4 — secrets-bypass-p4-followup.md, 2026-05-14)
# `find secrets/ -exec cat {} \;` / `find . -path '*secrets/*' -exec md5sum {} \;` 차단
if echo "$COMMAND" | grep -qE 'find\s+.*secrets/.*-exec'; then
  log_violation 2 "find secrets/ -exec 차단"
  emit_deny "find secrets/ -exec 차단 — 인벤토리는 awk -F= 사용."
  exit 0
fi
# source secrets/* 또는 source *.env (값 평문 echo 위험 — 2026-04-28 사고 재발 방지) (guard 2)
if echo "$COMMAND" | grep -qE '(^|[;&|`(]|\bset\s+-a\s*&&)\s*(\.\s|source\s).*(secrets/|/\.env(\.|$|\s)|web\.env|models\.env)'; then
  log_violation 2 "source secrets/*.env 차단 — 토큰 평문 노출 위험"
  emit_deny "source secrets/*.env 차단 — 토큰 평문 노출 위험. 길이 인벤토리는 awk -F= 사용."
  exit 0
fi
# Python/Node inline secrets/ read (Bash matcher 한계 보완 — Wave 1.2) (guard 2)
if echo "$COMMAND" | grep -qE '(python|python3|node)\s+(-c|-e)\s+["'"'"'].*(secrets/|/\.env|web\.env|models\.env)'; then
  log_violation 2 "Python/Node inline secret read 차단"
  emit_deny "Python/Node -c/-e 로 secrets/ 직접 읽기 차단. 정식 import + 환경변수 검증 사용."
  exit 0
fi
# data/artifacts/ git add
if echo "$COMMAND" | grep -qE 'git\s+add\s+.*data/artifacts/'; then
  log_violation 0 "data/artifacts/ git add 차단"
  emit_deny "data/artifacts/ git add 차단"
  exit 0
fi

exit 0
