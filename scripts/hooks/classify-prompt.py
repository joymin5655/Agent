#!/usr/bin/env python3
"""Plan-first Clarifying-Q classification hook (M1 dry-run).

영상("AI PM Claude Code Setup") 인사이트 — 자율(research) vs 인터랙티브(feature/refactor)
vs trivial 분류로 가정 진행 오류 방지.

목적:
  사용자 프롬프트를 3-tier (trivial/interactive/autonomous) 로 분류하여
  jsonl 로그에 기록. **M1 dry-run 모드** — stdout/stderr 출력 0 — AI 동작 변경 X.

활성화 단계:
  M1 (현재, 2026-04-29): 분류만 기록, AI 영향 0
  M3 (~2026-05-13): stdout으로 <plan-tier> 태그 주입, AI 동작 분기 활성화

설정:
  settings.local.json UserPromptSubmit hooks 에 등록.
  matcher: "*"  command: python3 .../scripts/hooks/classify-prompt.py

참고:
  - 룰 본문: .claude/rules/policy/plan-first-clarifying.md
  - 로그 경로: .claude/logs/plan-tier-classifications.jsonl (gitignored)
  - 본 plan: ~/.claude/plans/airlens-plan-first-clarifying-q.md
"""

from __future__ import annotations

import datetime as _dt
import importlib.util
import json
import pathlib
import re
import sys

PROJECT_ROOT = pathlib.Path(__file__).resolve().parents[2]
LOG_DIR = PROJECT_ROOT / ".claude" / "logs"
LOG_FILE = LOG_DIR / "plan-tier-classifications.jsonl"
SUPERVISOR_PATH = PROJECT_ROOT / "scripts" / "hooks" / "supervisor.py"

MAX_PROMPT_LEN = 50_000

# ─── 키워드 룰 (rules/plan-first-clarifying.md 동기) ─────────────────

TRIVIAL_PATTERNS: tuple[str, ...] = (
    r"\brename\b",
    r"오타",
    r"\btypo\b",
    r"fix\s*typo",
    r"변수명.*?(바꿔|변경)",
    r"한\s*줄",
    r"한\s*라인",
    r"1[\-\s]?line",
    r"파일\s*1개",
    r"값만",
    r"텍스트만",
    r"이름만",
    r"공백",
    r"포맷팅?만",
)

INTERACTIVE_PATTERNS: tuple[str, ...] = (
    # 작업 동사
    r"추가해",
    r"넣어줘",
    r"\b구현\b",
    r"만들어",
    r"\b신규\b",
    r"\brefactor\b",
    r"리팩토링",
    r"\barchitecture\b",
    r"\b설계\b",
    r"수정해",
    r"변경해",
    r"보여줘",
    # 정렬/정합
    r"\b정합\b",
    r"\b정렬\b",
    r"\b통합\b",
    # 정책/룰
    r"정책\s*(변경|추가)",
    r"룰\s*(변경|추가)",
    r"feedback",
    # commit/PR (자동화 영역 — interactive 로 분류해 명시 확인)
    r"\bcommit\b",
    r"\bPR\s*생성\b",
    r"\b머지\b",
    r"\bpush\b",
    # 자동화 시도
    r"자동화",
    r"skill\s*(생성|만들)",
    r"hook\s*(추가|생성)",
    # 도메인
    r"\b결제\b",
    r"\bbilling\b",
    r"\bRLS\b",
    r"Edge\s*Function",
    r"\bGlobe\b",
    r"ML\s*학습",
    r"\bPRD\b",
    r"요구사항",
    r"\b정본\b",
)

AUTONOMOUS_PATTERNS: tuple[str, ...] = (
    # 영문
    r"\bresearch\b",
    r"deep[\-\s]?research",
    r"\bcomparison\b",
    r"\bsummarize\b",
    # 자연 발화 — 사용자 빈번 (2026-05-07 측정 결과 fallback 90% 의 주범)
    r"\b조사\b",
    r"조사해",
    r"점검해",
    r"확인해",
    r"분석해",
    r"\b찾아\b",
    r"찾아줘",
    r"측정해",
    r"\b비교\b",
    r"\b요약\b",
    # 질문 형태 — read-only 의도가 강함
    r"^어디\b",
    r"^왜\b",
    r"^어떻게\b",
    r"왜\s*(자동\s*안|안\s*돼)",
    # 메타 분석
    r"\b통계\b",
    r"\b빈도\b",
    r"\b분포\b",
    r"\b갭\b",
)

AUTONOMOUS_SLASH_COMMANDS: tuple[str, ...] = (
    "/airlens-research",
    "/dqss-check",
    "/policy-sdid-run",
    "/aod-train",
)


def _match(patterns: tuple[str, ...], prompt: str) -> list[str]:
    """매칭된 패턴 목록 (앞 5개만)."""
    out = []
    for pat in patterns:
        if re.search(pat, prompt, re.IGNORECASE):
            out.append(pat)
            if len(out) >= 5:
                break
    return out


def classify(prompt: str) -> tuple[str, list[str]]:
    """3-tier 분류.

    우선순위: 슬래시 커맨드 → interactive → autonomous → trivial → fallback(interactive).
    """
    # 슬래시 커맨드 강제 autonomous
    for cmd in AUTONOMOUS_SLASH_COMMANDS:
        if cmd in prompt:
            return "autonomous", [cmd]

    matched_interactive = _match(INTERACTIVE_PATTERNS, prompt)
    matched_autonomous = _match(AUTONOMOUS_PATTERNS, prompt)
    matched_trivial = _match(TRIVIAL_PATTERNS, prompt)

    # interactive 우선 (가정 진행 방지 안전책)
    if matched_interactive:
        return "interactive", matched_interactive
    if matched_autonomous:
        return "autonomous", matched_autonomous
    if matched_trivial:
        return "trivial", matched_trivial

    # 모호 → interactive (안전 fallback)
    return "interactive", ["fallback:default"]


def supervisor_analysis(prompt: str) -> dict:
    """Return supervisor.py analysis schema when available.

    classify-prompt remains a dry-run hook, so import failures must not affect
    Claude behavior.  The fallback keeps the original 3-tier record.
    """
    try:
        spec = importlib.util.spec_from_file_location("airlens_supervisor_runtime", SUPERVISOR_PATH)
        if spec is None or spec.loader is None:
            return {}
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        index = module.load_registry_index()
        return module.analyze_prompt(prompt, index)
    except Exception:
        return {}


def main() -> None:
    try:
        raw = sys.stdin.read()
    except (OSError, ValueError):
        sys.exit(0)

    try:
        input_data = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        sys.exit(0)

    prompt = input_data.get("prompt") or input_data.get("user_prompt") or ""
    if not isinstance(prompt, str) or not prompt or len(prompt) > MAX_PROMPT_LEN:
        sys.exit(0)

    tier, matched = classify(prompt)
    analysis = supervisor_analysis(prompt)

    record = {
        "ts": _dt.datetime.now(_dt.timezone.utc).isoformat().replace("+00:00", "Z"),
        "tier": tier,
        "matched": matched,
        "prompt_first_120": prompt[:120],
        "prompt_len": len(prompt),
    }
    if analysis:
        record.update(analysis)

    try:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        with LOG_FILE.open("a", encoding="utf-8") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
    except OSError:
        pass  # 로그 실패는 silent — AI 동작 영향 0

    # M1 dry-run: stdout/stderr 출력 없음 — AI 동작 변경 X
    sys.exit(0)


if __name__ == "__main__":
    main()
