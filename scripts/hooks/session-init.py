#!/usr/bin/env python3
"""SessionStart hook — 프로젝트 에이전트 시스템 인식.

새 세션 시작 시 AirLens 프로젝트 에이전트 목록과 규칙을
stderr로 출력하여 Claude 컨텍스트에 주입.
"""

import json
import sys
import pathlib

PROJECT_ROOT = pathlib.Path(__file__).resolve().parents[2]
REGISTRY = PROJECT_ROOT / "apps" / "web" / ".claude" / "agents" / "registry.json"


def cleanup_flags() -> None:
    """이전 세션의 임시 플래그 클린업."""
    flags = [
        "/tmp/airlens-intent-feature",
        "/tmp/airlens-plan-approved",
        "/tmp/airlens-harness-mode",
    ]
    for flag in flags:
        p = pathlib.Path(flag)
        p.unlink(missing_ok=True)


def main() -> None:
    raw = sys.stdin.read()

    cleanup_flags()

    agents_info = ""
    if REGISTRY.exists():
        try:
            data = json.loads(REGISTRY.read_text(encoding="utf-8"))
            agent_list = data.get("agents", [])
            if agent_list:
                names = [a.get("id", a.get("name", "?")) for a in agent_list[:10]]
                agents_info = f"프로젝트 에이전트 {len(agent_list)}개 로드됨: {', '.join(names)} ..."
        except (json.JSONDecodeError, OSError):
            pass

    if agents_info:
        print(
            f"[AirLens Session Init] {agents_info}\n"
            f"  규칙: 하드코딩 금지, 타입은 types.ts, i18n 필수, PostToolUse 자동 검증 활성",
            file=sys.stderr,
        )

    # pass-through
    print(raw, end="")


if __name__ == "__main__":
    main()
