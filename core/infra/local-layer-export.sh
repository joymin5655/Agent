#!/usr/bin/env bash
# local-layer-export.sh — export the GLOBAL AI-runtime layer (registered hooks +
# cached plugins + installed skills) into one generic, portable YAML manifest, so
# a second machine can review what was installed without re-deriving it by hand.
#
# READ-ONLY on every source it inspects (settings.json, the plugin cache, the
# skills dir) and writes to exactly ONE destination file — the path given as $1.
# No other file on disk is touched.
#
# SAVE GATE (the reason this script exists rather than a one-line `cat` job): the
# rendered manifest is gitleaks-scanned BEFORE it is written to the destination.
# Only a 0-findings scan is saved — a positive scan refuses to save and prints the
# findings instead. This is fail-CLOSED: gitleaks itself missing also refuses to
# save (we cannot claim "0 findings" without having run the scanner). A hook
# command string that happens to embed a credential (misconfigured global
# settings, a copy-pasted debug line, etc.) must never round-trip into an
# exported, shareable file.
#
# Usage:
#   bash core/infra/local-layer-export.sh <output-file>
#
# Env seams (test/override):
#   AGENT_GLOBAL_SETTINGS     hooks source (default: $HOME/.claude/settings.json)
#   AGENT_PLUGIN_CACHE_ROOT   plugin cache root (default: $HOME/.claude/plugins/cache)
#   AGENT_GLOBAL_SKILLS_DIR   skills dir (default: $HOME/.claude/skills)
#   AGENT_GITLEAKS_CONFIG     gitleaks config (default: <repo-root>/gitleaks.toml)
#   AGENT_EXPORT_SCANNER      scanner binary/path (default: gitleaks) — a test seam
#                             ONLY: production behavior (fail-closed if the named
#                             scanner is absent) is unchanged; this just lets a
#                             gitleaks-less CI runner point at a deterministic stub
#                             that speaks the same `detect --no-git --source <f>`
#                             CLI surface, instead of skipping real coverage.
#
# Exit 0: manifest rendered, scanned clean, written to <output-file>.
# Exit 1: rendered manifest failed the gitleaks scan — NOT written; findings printed.
# Exit 2: usage error, or gitleaks is not installed (fail-closed — cannot prove
#         0 findings without it).
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

OUT="${1:-}"
if [[ -z "$OUT" ]]; then
    echo "Usage: bash core/infra/local-layer-export.sh <output-file>" >&2
    exit 2
fi

SCANNER="${AGENT_EXPORT_SCANNER:-gitleaks}"
if ! command -v "$SCANNER" >/dev/null 2>&1; then
    echo "ERROR: $SCANNER not installed — refusing to export (cannot verify 0 findings without it)." >&2
    echo "Install: brew install gitleaks (macOS) or https://github.com/gitleaks/gitleaks/releases" >&2
    exit 2
fi

GITLEAKS_CONFIG="${AGENT_GITLEAKS_CONFIG:-$REPO_ROOT/gitleaks.toml}"
SETTINGS="${AGENT_GLOBAL_SETTINGS:-$HOME/.claude/settings.json}"
CACHE_ROOT="${AGENT_PLUGIN_CACHE_ROOT:-$HOME/.claude/plugins/cache}"
SKILLS_DIR="${AGENT_GLOBAL_SKILLS_DIR:-$HOME/.claude/skills}"

WORK="$(mktemp -d)" || { echo "ERROR: mktemp -d failed" >&2; exit 2; }
[[ -n "$WORK" && -d "$WORK" ]] || { echo "ERROR: mktemp -d produced no directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT
RENDERED="$WORK/local-layer-manifest.yml"

# --- render (python3 stdlib only — no PyYAML dependency; the schema here is
#     flat enough that a small hand-rolled emitter is simpler and more portable
#     than requiring a non-stdlib import on every machine this ever runs on) ---
SETTINGS="$SETTINGS" CACHE_ROOT="$CACHE_ROOT" SKILLS_DIR="$SKILLS_DIR" \
    python3 - > "$RENDERED" <<'PY'
import json, os, sys
from datetime import datetime, timezone


def yaml_str(s):
    # minimal, safe scalar quoting: always double-quote and escape backslash/quote
    # so a value containing YAML-special characters can never break the structure.
    return '"' + str(s).replace("\\", "\\\\").replace('"', '\\"') + '"'


settings_path = os.environ["SETTINGS"]
cache_root = os.environ["CACHE_ROOT"]
skills_dir = os.environ["SKILLS_DIR"]

# --- hooks: event + command basename (no absolute paths — those are
#     machine-specific and not part of a portable, generic manifest) ---
hooks = []
try:
    with open(settings_path, encoding="utf-8") as f:
        s = json.load(f)
    for event, groups in (s.get("hooks") or {}).items():
        for g in groups or []:
            for c in g.get("hooks") or []:
                cmd = c.get("command", "")
                # last whitespace-separated token, quote-stripped — the actual
                # hook script name, same extraction doctor's manifest check uses.
                base = cmd.split()[-1].strip('"') if cmd.split() else ""
                base = base.rsplit("/", 1)[-1]
                if base:
                    hooks.append((event, base))
except (FileNotFoundError, json.JSONDecodeError, AttributeError, TypeError):
    pass
hooks.sort()

# --- plugins: <cache_root>/<marketplace>/<plugin>/<version>/ triples. Multiple
#     cached versions of the same plugin -> export the lexicographically-highest
#     (a "latest wins" heuristic; doctor check 10 separately flags multi-version
#     staleness — this export is not that gate, it just needs ONE version per
#     plugin to be a useful, non-ambiguous manifest entry). ---
plugins = {}
if os.path.isdir(cache_root):
    for market in sorted(os.listdir(cache_root)):
        market_dir = os.path.join(cache_root, market)
        if not os.path.isdir(market_dir):
            continue
        for plugin in sorted(os.listdir(market_dir)):
            plugin_dir = os.path.join(market_dir, plugin)
            if not os.path.isdir(plugin_dir):
                continue
            versions = sorted(
                v for v in os.listdir(plugin_dir)
                if os.path.isdir(os.path.join(plugin_dir, v))
            )
            if versions:
                plugins[(market, plugin)] = versions[-1]

# --- skills: top-level skill directory names (basenames only) ---
skills = []
if os.path.isdir(skills_dir):
    for name in sorted(os.listdir(skills_dir)):
        if os.path.isdir(os.path.join(skills_dir, name)):
            skills.append(name)

# --- emit ---
out = []
out.append("# local-layer-manifest.yml — exported global AI-runtime layer (generic, portable).")
out.append("# Generated by core/infra/local-layer-export.sh — do not hand-edit; re-export instead.")
out.append(f"schema_version: 1")
out.append(f"exported_at: {yaml_str(datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))}")

out.append("hooks:")
if hooks:
    for event, base in hooks:
        out.append(f"  - event: {yaml_str(event)}")
        out.append(f"    command: {yaml_str(base)}")
else:
    out.append("  []")

out.append("plugins:")
if plugins:
    for (market, plugin), version in sorted(plugins.items()):
        out.append(f"  - marketplace: {yaml_str(market)}")
        out.append(f"    name: {yaml_str(plugin)}")
        out.append(f"    version: {yaml_str(version)}")
else:
    out.append("  []")

out.append("skills:")
if skills:
    for name in skills:
        out.append(f"  - {yaml_str(name)}")
else:
    out.append("  []")

print("\n".join(out))
PY
RENDER_RC=$?
if [[ $RENDER_RC -ne 0 ]]; then
    echo "ERROR: manifest render failed (python3 exit $RENDER_RC)" >&2
    exit 2
fi

# --- save gate: gitleaks-scan the RENDERED file before it ever reaches $OUT ---
# WHY: no array here — bash 3.2 (macOS /bin/bash) treats "${arr[@]}" on an
# empty array as unbound under set -u, and the crash inside the $() subshell
# would masquerade as a scan refusal (GL_RC=1, empty findings body).
if [[ -f "$GITLEAKS_CONFIG" ]]; then
    GL_OUT="$("$SCANNER" detect --no-git --source "$RENDERED" --config "$GITLEAKS_CONFIG" 2>&1)"
else
    GL_OUT="$("$SCANNER" detect --no-git --source "$RENDERED" 2>&1)"
fi
GL_RC=$?

if [[ $GL_RC -ne 0 ]]; then
    echo "REFUSED — the rendered manifest failed the gitleaks scan and was NOT saved to $OUT." >&2
    echo "$GL_OUT" >&2
    echo "Fix the source (global settings.json / plugin metadata) and re-export." >&2
    exit 1
fi

mkdir -p "$(dirname "$OUT")"
cp "$RENDERED" "$OUT"
echo "Exported: $OUT"
echo "  hooks:   $(grep -c '^  - event:' "$RENDERED" || true)"
echo "  plugins: $(grep -c '^  - marketplace:' "$RENDERED" || true)"
echo "  skills:  $(grep -c '^  - "' "$RENDERED" || true)"
exit 0
