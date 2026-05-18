#!/usr/bin/env python3
"""PreToolUse [Edit] — App.tsx Route 레이아웃 일관성 가드.

App.tsx에 Route를 추가/이동할 때 PublicLayout vs AppShell 배치가
올바른지 경고. 잘못된 레이아웃에 페이지를 배치하면 UI 통일성이 깨짐.

참조: Obsidian-airlens/wiki/entities/page-guides.md
"""

import json
import re
import sys

# Pages that MUST be in AppShell (Protected)
APPSHELL_PAGES = {
    "Today", "EarthDev", "News", "PolicyIntelligence",
    "CameraAI", "Profile", "AdminDashboard", "PolicyProof",
}

# Pages that MUST be in PublicLayout
PUBLIC_PAGES = {
    "Landing", "About", "Auth", "Pricing",
    "Privacy", "Terms", "ResearchArticle",
}


def main() -> None:
    try:
        input_data = json.load(sys.stdin)
    except (json.JSONDecodeError, EOFError):
        print(json.dumps({"decision": "allow"}))
        sys.exit(0)

    tool_input = input_data.get("tool_input", {})
    file_path: str = tool_input.get("file_path", "")

    # Only guard App.tsx edits
    if not file_path.endswith("App.tsx"):
        print(json.dumps({"decision": "allow"}))
        sys.exit(0)

    new_string: str = tool_input.get("new_string", "")
    old_string: str = tool_input.get("old_string", "")

    # Check if Route is being added or moved
    if "<Route" not in new_string and "Route" not in old_string:
        print(json.dumps({"decision": "allow"}))
        sys.exit(0)

    warnings: list[str] = []

    # Detect component names in the new Route definition
    components_in_new = re.findall(r"element=\{<(\w+)", new_string)

    for comp in components_in_new:
        if comp in APPSHELL_PAGES:
            # Check if it's being placed in PublicLayout context
            if "PublicLayout" in old_string or "PublicLayout" in new_string:
                warnings.append(
                    f"[LAYOUT MISMATCH] {comp}는 AppShell(Protected) 안에 배치해야 합니다. "
                    f"PublicLayout에 넣으면 SideNav/CommandBar 없이 렌더됩니다."
                )
        elif comp in PUBLIC_PAGES:
            if "AppShell" in old_string or "ProtectedRoute" in old_string:
                warnings.append(
                    f"[LAYOUT MISMATCH] {comp}는 PublicLayout에 배치해야 합니다. "
                    f"AppShell에 넣으면 인증 필요 + SideNav가 표시됩니다."
                )

    if not warnings:
        # Still show a reminder for any Route change
        message = (
            "Route 변경 감지. 레이아웃 배치를 확인하세요:\n"
            "  - Public 페이지 → PublicLayout (Navbar + Footer)\n"
            "  - App 페이지 → AppShell (SideNav + CommandBar)\n"
            "  - 참조: wiki/entities/page-guides.md"
        )
        print(json.dumps({"decision": "allow", "systemMessage": message}))
        sys.exit(0)

    message = (
        "ROUTE GUARD 경고:\n"
        + "\n".join(f"  - {w}" for w in warnings)
        + "\n\n참조: Obsidian-airlens/wiki/entities/page-guides.md"
        + "\n권장: fe-architect 에이전트로 레이아웃 검증"
    )

    # Allow but warn (don't block — the developer may have a valid reason)
    print(json.dumps({"decision": "allow", "systemMessage": message}))
    sys.exit(0)


if __name__ == "__main__":
    main()
