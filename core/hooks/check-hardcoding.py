#!/usr/bin/env python3
"""PreToolUse hook — Detect hardcoded constants in Write/Edit content.

Blocks common hardcoding anti-patterns:
  - Inline RGB color arrays (style values that should live in a theme/config)
  - Linear-gradient strings with hardcoded RGB values
  - Const arrays of tick/label/stop strings (chart data that should come from config)

The 3 default patterns target UI/design hardcoding. Project-specific patterns
can be added via `hook-config.yml: hardcoding_patterns[]`.

Hook protocol: reads canonical event JSON from stdin, writes decision JSON (deny)
to stdout on match, or empty stdout (allow) otherwise. Exit always 0.
"""
import sys
import json
import re

# Files / path patterns exempt from hardcoding checks
EXEMPT_PATHS = {
    "config.ts",
    "config.js",
    "config.py",
    "types.ts",
    "types.js",
    ".test.",
    ".spec.",
    "test/",
    "__tests__/",
    ".yml",
    ".yaml",
    ".md",
    ".json",
    "tailwind.config",
    "vite.config",
    "webpack.config",
    "rollup.config",
    "tsconfig",
    "eslint",
    "prettier",
    ".html",
    "assets/",
    "/fixtures/",
    "/legacy/",
    # Self + sibling test script (cite the same patterns as fixtures —
    # same precedent as secret-content-scan.py's self-exemption)
    "check-hardcoding.py",
    "check-hardcoding-test.sh",
}

# Generic hardcoding patterns. Extend via hook-config.yml: hardcoding_patterns[].
HARDCODING_PATTERNS = [
    # Inline color segment arrays: [number, [r, g, b]]
    (
        r'\[\s*\d+\s*,\s*\[\s*\d+\s*,\s*\d+\s*,\s*\d+\s*\]\s*\]',
        "Inline color segment array — define in a theme/config file and import",
    ),
    # CSS gradient strings with rgb values
    (
        r"linear-gradient\s*\(\s*\d+deg\s*,\s*rgb\(",
        "Hardcoded CSS gradient — derive from a config color scale",
    ),
    # Const arrays of tick/label/stop strings
    (
        r"(?:const|let|var)\s+\w*(?:TICK|LABEL|STOP).*=\s*\[",
        "Hardcoded tick/label/stop array — define in a config file and import",
    ),
]

# Component-area specific check. Only fires on files in components / hooks / pages dirs.
COMPONENT_PATTERNS = [
    (
        r"(?:const|let|var)\s+(?:MODES|LAYERS|OPTIONS)\s*[=:]",
        "UI metadata array defined in component — extract to a config file and import",
    ),
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
    file_path = tool_input.get("file_path", "")
    if not file_path:
        sys.exit(0)

    if is_exempt(file_path):
        sys.exit(0)

    content = tool_input.get("content", "")
    if not content:
        content = tool_input.get("new_string", "")
    if not content:
        sys.exit(0)

    warnings = check_content(content, file_path)
    if warnings:
        print(f"[Hook] BLOCKED: Hardcoding detected in {file_path.split('/')[-1]}", file=sys.stderr)
        for w in warnings:
            print(f"  {w}", file=sys.stderr)
        print("\nExtract constants to a config file and import them. To customize patterns, "
              "edit hook-config.yml: hardcoding_patterns[].", file=sys.stderr)
        # Teaching format (T-1): WHY + FIX so the agent can self-correct.
        emit_deny(
            "Hardcoding detected in " + file_path.split("/")[-1] + "\n"
            "WHY: design-hardcoding guard — inline style/config constants drift from the "
            "theme and dodge the config review path.\n"
            "FIX: extract the values to a config/theme file and import them; to customize "
            "what this guard matches, edit hook-config.yml: hardcoding_patterns[]."
        )
        sys.exit(0)

    sys.exit(0)


if __name__ == "__main__":
    main()
