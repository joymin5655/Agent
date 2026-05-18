#!/bin/bash
# AirLens — Stop 통합 훅
# 통합: manual-action-guide.sh + supervisor-session-close.sh + stop-notion-check.sh + macOS 알림

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TODO_FILE="$PROJECT_ROOT/.archive/TODO.md"

# ── 1. 세션 저장 안내 ──
echo "[SESSION SAVE] 세션 종료 전 작업 기록을 저장합니다."
echo "Obsidian-airlens/raw/sessions/ 에 날짜별 파일로 저장하세요."
echo "저장 후 touch /tmp/airlens-session-saved 를 실행하세요."

# ── 2. TODO.md 미완료 확인 ──
if [ -f "$TODO_FILE" ]; then
  PENDING=$(grep -c '^\- \[ \]' "$TODO_FILE" 2>/dev/null) || PENDING=0
  if [ "$PENDING" -gt 0 ]; then
    echo "[SUPERVISOR] TODO.md에 미완료 항목 ${PENDING}건 남아있습니다."
  fi
fi

# ── 3. 학습 기록 완료 여부 ──
BLOCKS_LOG="$PROJECT_ROOT/.claude/logs/policy-blocks.log"
LEARN_FLAG="/tmp/airlens-learn-done-$(date +%Y%m%d)"
if [ -f "$BLOCKS_LOG" ]; then
  TODAY_BLOCKS=$(grep -c "$(date +%Y-%m-%d)" "$BLOCKS_LOG" 2>/dev/null) || TODAY_BLOCKS=0
  if [ "$TODAY_BLOCKS" -gt 0 ] && [ ! -f "$LEARN_FLAG" ]; then
    echo "[SUPERVISOR] 오늘 정책 차단 ${TODAY_BLOCKS}건 — 학습 기록 확인 필요"
  fi
fi

# ── 4. 임시 플래그 정리 ──
rm -f /tmp/airlens-dept-* 2>/dev/null
rm -f /tmp/airlens-harness-checked 2>/dev/null
rm -f /tmp/airlens-importance-checked 2>/dev/null
rm -f /tmp/airlens-purpose-declared 2>/dev/null
rm -f /tmp/airlens-harness-bypass 2>/dev/null
rm -f /tmp/airlens-build-error 2>/dev/null
rm -f /tmp/airlens-advisor-consulted 2>/dev/null
rm -f /tmp/airlens-intent-feature 2>/dev/null
rm -f /tmp/airlens-review-model 2>/dev/null

# ── 5. macOS 알림 ──
osascript -e 'display notification "작업 완료" with title "AirLens Agent" sound name "Purr"' &>/dev/null &

# ── 6. Tier 2 — broadcast 'done' event for cross-session visibility ──
SESSION_SH="$PROJECT_ROOT/scripts/infra/agent-session.sh"
if [ -x "$SESSION_SH" ]; then
  "$SESSION_SH" broadcast done "session ended" 2>/dev/null || true
fi

exit 0
