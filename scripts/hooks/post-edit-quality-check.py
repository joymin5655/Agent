#!/usr/bin/env python3
"""PostToolUse [Edit|Write] — AirLens 코드 품질 자동 검사.

변경된 파일에 대해 프로젝트 규칙 위반을 감지하고 systemMessage로 경고.
검사 항목:
  1. 인라인 타입 정의 (src/pages/*.tsx, src/components/**/*.tsx)
  2. App.tsx Route 변경 시 레이아웃 일관성
  3. 하드코딩 색상/숫자
  4. i18n 번역 키 누락
"""

import json
import os
import re
import sys

def main() -> None:
    try:
        input_data = json.load(sys.stdin)
    except (json.JSONDecodeError, EOFError):
        print(json.dumps({}))
        sys.exit(0)

    tool_input = input_data.get("tool_input", {})
    file_path: str = tool_input.get("file_path", "")

    if not file_path:
        print(json.dumps({}))
        sys.exit(0)

    # Only check apps/web source files (post 2026-04-30 monorepo)
    if "apps/web/src/" not in file_path:
        print(json.dumps({}))
        sys.exit(0)

    warnings: list[str] = []
    agents: list[str] = []

    # Read the actual file content (post-edit, so file is already modified)
    content = ""
    abs_path = file_path
    if not os.path.isabs(file_path):
        abs_path = os.path.join(os.getcwd(), file_path)
    try:
        with open(abs_path, encoding="utf-8") as f:
            content = f.read()
    except OSError:
        print(json.dumps({}))
        sys.exit(0)

    # ── 1. Inline type definitions in pages/components ──
    if re.search(r"src/pages/.*\.tsx$", file_path) or re.search(r"src/components/.*\.tsx$", file_path):
        # Check for interface/type exports that should be in types.ts
        inline_types = re.findall(
            r"^(?:export\s+)?(?:interface|type)\s+(\w+)",
            content,
            re.MULTILINE,
        )
        # Filter out common React patterns (Props suffix is OK inline)
        non_props = [t for t in inline_types if not t.endswith("Props") and t != "Props"]
        if non_props:
            warnings.append(
                f"[AirLens Rule #1] 인라인 타입 정의: {', '.join(non_props[:3])} → src/types.ts로 이동 필요"
            )
            agents.append("style-reviewer")

    # ── 2. App.tsx Route layout consistency ──
    if file_path.endswith("App.tsx"):
        warnings.append(
            "[Layout] App.tsx Route 변경 감지. PublicLayout vs AppShell 배치가 올바른지 확인하세요.\n"
            "  참고: wiki/entities/page-guides.md 라우팅 요약 테이블"
        )
        agents.append("fe-architect")

    # ── 3. Hardcoded colors/numbers ──
    if re.search(r"src/(pages|components)/.*\.tsx$", file_path):
        hex_colors = re.findall(r'["\']#[0-9a-fA-F]{3,8}["\']', content)
        arbitrary_colors = re.findall(r"\[#[0-9a-fA-F]{3,8}\]", content)
        if hex_colors or arbitrary_colors:
            count = len(hex_colors) + len(arbitrary_colors)
            warnings.append(
                f"[Design Token] 하드코딩 색상 {count}건 감지. Tailwind 테마 토큰 사용 권장"
            )

    # ── 4. Missing i18n ──
    if re.search(r"src/(pages|components)/.*\.tsx$", file_path):
        # Detect hardcoded user-facing strings in JSX (>Word patterns)
        hardcoded_strings = re.findall(r">[A-Z][a-z]{3,}[^<]{0,50}<", content)
        # Filter out common false positives
        hardcoded_strings = [
            s for s in hardcoded_strings
            if not re.search(r"className|style|key|ref|aria-", s)
        ]
        if len(hardcoded_strings) > 2:
            warnings.append(
                f"[i18n] 하드코딩 문자열 {len(hardcoded_strings)}건 감지. t() 래핑 확인 필요"
            )
            agents.append("i18n-specialist")

    if not warnings:
        print(json.dumps({}))
        sys.exit(0)

    # Build systemMessage
    agent_hint = ""
    if agents:
        unique_agents = list(dict.fromkeys(agents))
        agent_hint = "\n권장 에이전트: " + ", ".join(unique_agents)

    message = (
        "POST-EDIT 품질 검사 결과:\n"
        + "\n".join(f"  - {w}" for w in warnings)
        + agent_hint
    )

    print(json.dumps({"systemMessage": message}))
    sys.exit(0)


if __name__ == "__main__":
    main()
