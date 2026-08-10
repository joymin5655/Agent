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
#                             ONLY: it lets a gitleaks-less CI runner point at a
#                             deterministic stub that speaks the same
#                             `detect --no-git --source <f>` CLI surface. A
#                             non-default value prints a loud stderr WARNING, and
#                             a scanner that cannot flag the liveness canary (see
#                             below) fails closed — the seam cannot silently
#                             disable the gate.
#
# Exit 0: manifest rendered, scanned clean, written to <output-file>.
# Exit 1: rendered manifest failed the gitleaks scan — NOT written; findings printed.
# Exit 2: usage error; gitleaks not installed; ruleset (gitleaks.toml) not found;
#         or the liveness canary proved the gate dead — all fail-closed (a clean
#         result cannot be trusted, so nothing is written).
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

OUT="${1:-}"
if [[ -z "$OUT" ]]; then
    echo "Usage: bash core/infra/local-layer-export.sh <output-file>" >&2
    exit 2
fi

SCANNER="${AGENT_EXPORT_SCANNER:-gitleaks}"
# The scanner override is a TEST-ONLY seam. Announce loudly on stderr whenever it
# is not the production gitleaks binary, so a stray exported var or a copy-pasted
# CI wrapper can never SILENTLY neutralize the save gate (it stays visible in the
# terminal and in any transcript that captures this run).
if [[ "$SCANNER" != "gitleaks" ]]; then
    echo "WARNING: secret gate is using a NON-DEFAULT scanner ('$SCANNER') via AGENT_EXPORT_SCANNER — this is a test-only seam and is NOT the production gitleaks gate." >&2
fi
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
import json, os, re, sys
from datetime import datetime, timezone

_SCRIPT_EXT = re.compile(r"\.(sh|py|js|mjs|cjs|ts|rb|pl)$")


def yaml_str(s):
    # minimal, safe scalar quoting: always double-quote and escape backslash/quote
    # so a value containing YAML-special characters can never break the structure.
    # Control bytes (newline/CR/tab) are C-escaped too — a raw newline in a
    # double-quoted scalar is invalid per the YAML spec (parser-dependent) and
    # would also skew the grep-based counts this script prints.
    return '"' + (
        str(s)
        .replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
    ) + '"'


def hook_script_name(cmd):
    # Emit a SCRIPT identifier, never an ARGUMENT VALUE (a secret in `--key=…`,
    # PII in `--user <name>` / `--home /home/<name>`). Everything from the first
    # flag (`-…`) onward is arguments, so only the leading tokens are considered
    # — this is what keeps an arg whose value ends in .py/.sh from displacing the
    # script name. Among those leading tokens take the LAST script-extension
    # basename (adapter-wrapped hooks put the real script last:
    # `adapter.sh real-hook.sh`); if none has an extension, fall back to the
    # FIRST token's basename (the executable: rtk / node / curl) so an
    # extension-less or piped-shell hook stays VISIBLE to a reviewer rather than
    # silently vanishing from the manifest.
    toks = [t.strip('"').strip("'") for t in cmd.split()]
    toks = [t for t in toks if t]
    if not toks:
        return ""
    head = []
    for t in toks:
        if t.startswith("-"):
            break
        head.append(t)
    if not head:
        head = [toks[0]]
    script = ""
    for t in head:
        base = t.rsplit("/", 1)[-1]
        if _SCRIPT_EXT.search(base):
            script = base
    if not script:
        script = head[0].rsplit("/", 1)[-1]
    return script


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
                base = hook_script_name(c.get("command", ""))
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
# WHY fail-closed on an absent ruleset: gitleaks' BUILT-IN rules MISS the sk-ant-
# session/oauth/variant credential shapes that this repo's gitleaks.toml catches
# (measured — built-in flags 0/3, repo config 3/3). A config-less scan is a
# materially weaker gate, not an equivalent one, so "could not load the ruleset"
# is the same epistemic state as "could not run the scanner": both exit 2. This
# also neutralizes a symlink invocation (REPO_ROOT via dirname would miss
# gitleaks.toml) — it fails closed instead of silently down-scanning.
# (No array for the args — bash 3.2 treats "${arr[@]}" on an empty array as
# unbound under set -u, and that crash inside $() would masquerade as a refusal.)
if [[ ! -f "$GITLEAKS_CONFIG" ]]; then
    echo "ERROR: gitleaks ruleset not found at $GITLEAKS_CONFIG — refusing to export." >&2
    echo "The built-in rules miss sk-ant- credential shapes; cannot prove 0 findings without the repo ruleset." >&2
    echo "(If invoked via a symlink, run the script at its real path so \$REPO_ROOT/gitleaks.toml resolves, or set AGENT_GITLEAKS_CONFIG to a real config.)" >&2
    exit 2
fi

# --- gate liveness canary: prove the scanner+ruleset actually flag a KNOWN
# credential shape before we trust a "clean" verdict on the real manifest. A
# clean scan is meaningless if the gate is dead — an empty/wrong ruleset (the
# -f test above only proves the file EXISTS, not that it carries rules), a
# stubbed AGENT_EXPORT_SCANNER, or a PATH-planted always-exit-0 binary all
# produce "0 findings" on anything. The canary is indifferent to WHY the gate
# is dead: if the scanner fails to catch a planted secret, we refuse. (Splice
# the token at runtime — Z — so no contiguous literal lives in this file.)
Z_C="ant"
CANARY="$WORK/gate-canary.txt"
printf 'canary: "sk-%s-api03-AA00aa11bb22cc33dd44ee55ff66gg77hh88ii99"\n' "$Z_C" > "$CANARY"
if "$SCANNER" detect --no-git --source "$CANARY" --config "$GITLEAKS_CONFIG" --redact >/dev/null 2>&1; then
    # exit 0 on the canary = the gate did NOT flag a definite secret -> it is dead.
    echo "ERROR: secret-scan gate is not functioning — the scanner+ruleset failed to flag a known test credential." >&2
    echo "Refusing to export: a 'clean' result cannot be trusted. Verify gitleaks and the ruleset at $GITLEAKS_CONFIG." >&2
    exit 2
fi

# --redact: the refusal path echoes $GL_OUT to stderr, which /record can capture
# into the brain vault — never let a finding body carry a cleartext secret there.
GL_OUT="$("$SCANNER" detect --no-git --source "$RENDERED" --config "$GITLEAKS_CONFIG" --redact 2>&1)"
GL_RC=$?

if [[ $GL_RC -ne 0 ]]; then
    echo "REFUSED — the rendered manifest failed the gitleaks scan and was NOT saved to $OUT." >&2
    echo "$GL_OUT" >&2
    echo "Fix the source (global settings.json / plugin metadata) and re-export." >&2
    exit 1
fi

mkdir -p "$(dirname "$OUT")" || { echo "ERROR: cannot create output directory for $OUT" >&2; exit 2; }
cp "$RENDERED" "$OUT" || { echo "ERROR: failed to write $OUT (the scan passed, but the file was not saved)." >&2; exit 2; }
echo "Exported: $OUT"
echo "  hooks:   $(grep -c '^  - event:' "$RENDERED" || true)"
echo "  plugins: $(grep -c '^  - marketplace:' "$RENDERED" || true)"
echo "  skills:  $(grep -c '^  - "' "$RENDERED" || true)"
exit 0
