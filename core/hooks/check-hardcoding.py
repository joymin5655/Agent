#!/usr/bin/env python3
"""
PreToolUse hook: Detect hardcoded constants in Write/Edit tool calls.

Checks for common hardcoding patterns:
- Inline color arrays ([r, g, b]) not from config
- Magic numbers (standalone numeric constants)
- Duplicated constant definitions
- Inline gradient strings

Reads tool_input from stdin (JSON).
Exit 0 + empty stdout = allow; Exit 0 + permissionDecision="deny" = block.
"""
import sys
import json
import re

# Files exempt from hardcoding checks
EXEMPT_PATHS = {
    "config.ts",           # config IS the source of truth
    "config.js",
    "config/aqi.ts",       # AQI config is the threshold source of truth
    "types.ts",            # type definitions may have literal unions
    "types.js",
    ".test.",              # test fixtures
    ".spec.",
    "test/",
    "__tests__/",
    ".yml",                # CI workflows
    ".yaml",
    ".md",                 # documentation
    ".json",               # data files
    "tailwind.config",
    "vite.config",
    "tsconfig",
    "eslint",
    "prettier",
    ".html",               # standalone HTML prototypes
    "assets/",             # asset files (prototypes, screenshots)
}

# Patterns that indicate hardcoded data (not config imports)
HARDCODING_PATTERNS = [
    # Inline color segment arrays: [number, [r, g, b]]
    (r'\[\s*\d+\s*,\s*\[\s*\d+\s*,\s*\d+\s*,\s*\d+\s*\]\s*\]', "Inline color segment array — must use config import"),
    # CSS gradient strings with rgb values
    (r"linear-gradient\s*\(\s*\d+deg\s*,\s*rgb\(", "Hardcoded CSS gradient — must derive from config color scale"),
    # Const arrays of tick labels (e.g., ['0', '12', '35'])
    (r"(?:const|let|var)\s+\w*(?:TICK|LABEL|STOP).*=\s*\[", "Hardcoded tick/label array — must use config"),
]

# More specific patterns only for component/hook files
COMPONENT_PATTERNS = [
    # Mode/layer/option arrays defined in components
    (r"(?:const|let|var)\s+(?:MODES|LAYERS|OPTIONS|ALTITUDES|PROJECTIONS)\s*[=:]", "UI metadata array defined in component — must use config import"),
    # Inline AQI/PM2.5 threshold functions (should use pm25ToSimpleTier / pm25ToEpaHex from lib/config/aqi)
    (r"pm25\s*[<>=!]+\s*(?:12|35\.4|55\.4|150\.4|250\.4|50|100|200|300)\b", "Hardcoded PM2.5 threshold — use pm25ToSimpleTier() or pm25ToEpaHex() from lib/config/aqi"),
]


def is_exempt(file_path: str) -> bool:
    for pattern in EXEMPT_PATHS:
        if pattern in file_path:
            return True
    return False


def check_content(content: str, file_path: str) -> list[str]:
    warnings = []

    for pattern, message in HARDCODING_PATTERNS:
        matches = re.findall(pattern, content)
        if matches:
            warnings.append(f"[HARDCODING] {message} (found {len(matches)} match(es))")

    # Component-specific checks
    if "/components/" in file_path or "/hooks/" in file_path or "/pages/" in file_path:
        for pattern, message in COMPONENT_PATTERNS:
            if re.search(pattern, content):
                warnings.append(f"[HARDCODING] {message}")

    return warnings


def emit_deny(reason: str) -> None:
    output = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }
    print(json.dumps(output, ensure_ascii=False))


def main():
    raw = sys.stdin.read().strip()
    if not raw:
        sys.exit(0)

    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        sys.exit(0)

    tool_input = data.get("tool_input", {})

    # Determine file path
    file_path = tool_input.get("file_path", "")
    if not file_path:
        sys.exit(0)

    if is_exempt(file_path):
        sys.exit(0)

    # Get content to check
    content = tool_input.get("content", "")  # Write tool
    if not content:
        content = tool_input.get("new_string", "")  # Edit tool

    if not content:
        sys.exit(0)

    warnings = check_content(content, file_path)

    if warnings:
        print(f"[Hook] BLOCKED: Hardcoding detected in {file_path.split('/')[-1]}", file=sys.stderr)
        for w in warnings:
            print(f"  {w}", file=sys.stderr)
        print(f"\nMove constants to config file (e.g., src/lib/earth/config.ts) and import them.", file=sys.stderr)
        emit_deny("Hardcoding detected in " + file_path.split("/")[-1])
        sys.exit(0)

    # Pass through (empty stdout — Claude Code skips decision parse)
    sys.exit(0)


if __name__ == "__main__":
    main()
