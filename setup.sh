#!/usr/bin/env bash
# setup.sh — install the framework into an AI runtime and/or a project.
#
# Usage:
#   bash setup.sh                  # all 3 AIs (claude + codex + gemini)
#   bash setup.sh --claude         # claude only
#   bash setup.sh --codex          # codex only
#   bash setup.sh --gemini         # gemini only
#   bash setup.sh --antigravity    # antigravity (agy) worker lane + native-hook plugin (opt-in)
#   bash setup.sh --launchers      # purpose launchers (claude-build/quick/research) only
#   bash setup.sh --project        # +current project scaffold (CLAUDE.md, hook-config.yml, etc.)
#   bash setup.sh --hooks-only     # install git-hooks (pre-commit, pre-push) only
#   bash setup.sh --all            # alias for default (all 3 AIs)
#   bash setup.sh --instructions-only  # sync common Claude/Codex policy; preserve personal text
#   bash setup.sh --doctor         # environment diagnosis only — no installs, read-only
#   bash setup.sh --bootstrap      # install MISSING deps (gitleaks/sqlite3/jq/gh) via
#                                   # brew/apt, one y/N prompt per package — never auto-yes
#   bash setup.sh --bootstrap --dry-run   # print the install plan only, install nothing
#
# Combinations OK:
#   bash setup.sh --claude --project
#   bash setup.sh --codex --gemini --hooks-only

set -euo pipefail

FRAMEWORK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DO_CLAUDE=0
DO_CODEX=0
DO_GEMINI=0
DO_PROJECT=0
DO_HOOKS=0
DO_DOCTOR=0
DO_INSTRUCTIONS=0
DO_BOOTSTRAP=0
BOOTSTRAP_DRY_RUN=0

if [[ $# -eq 0 ]]; then
    DO_CLAUDE=1
    DO_CODEX=1
    DO_GEMINI=1
fi
DO_ANTIGRAVITY=${DO_ANTIGRAVITY:-0}
DO_LAUNCHERS=${DO_LAUNCHERS:-0}

for arg in "$@"; do
    case "$arg" in
        --claude)      DO_CLAUDE=1 ;;
        --codex)       DO_CODEX=1 ;;
        --gemini)      DO_GEMINI=1 ;;
        --antigravity) DO_ANTIGRAVITY=1 ;;
        --launchers)   DO_LAUNCHERS=1 ;;
        --project)     DO_PROJECT=1 ;;
        --hooks-only)  DO_HOOKS=1 ;;
        --instructions-only) DO_INSTRUCTIONS=1 ;;
        --doctor)      DO_DOCTOR=1 ;;
        --bootstrap)   DO_BOOTSTRAP=1 ;;
        --dry-run)     BOOTSTRAP_DRY_RUN=1 ;;
        --all)         DO_CLAUDE=1; DO_CODEX=1; DO_GEMINI=1 ;;
        -h|--help)
            sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "ERROR: unknown arg: $arg" >&2
            sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//' >&2
            exit 2
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

confirm() {
    local prompt="$1"
    if [[ "${AGENT_SETUP_YES:-0}" == "1" ]]; then return 0; fi
    read -r -p "$prompt [y/N] " ans
    [[ "$ans" =~ ^[Yy] ]]
}

# PyYAML usable = importable without the working directory on sys.path (a stray
# yaml.py must not pass for it) and exposing safe_load — the same test the
# pre-tool-guard 11b loader applies (P1-9).
pyyaml_usable() {
    python3 -c 'import sys; sys.path[:] = [p for p in sys.path if p not in ("", ".")]
import yaml; assert callable(yaml.safe_load)' >/dev/null 2>&1
}

# Render src -> dst with {{FRAMEWORK_ROOT}} substituted. Idempotent: a dst
# byte-identical to the fresh render is reported up-to-date with no prompt, so
# re-running setup is a no-op update pass; only a dst that actually differs
# (user-customized, or the template changed) asks before overwriting.
apply_template() {
    local src="$1" dst="$2" rendered
    rendered="$(mktemp)"
    # No RETURN trap here: a RETURN trap set inside a function outlives it in
    # bash 5 and re-fires on every later function return, where the local
    # $rendered no longer exists (unbound under set -u). Explicit rm -f on
    # each exit path instead; a sed failure under set -e leaks one temp file,
    # which is acceptable.
    sed "s|{{FRAMEWORK_ROOT}}|$FRAMEWORK_ROOT|g" "$src" > "$rendered"
    if [[ "$src" == "$FRAMEWORK_ROOT/adapters/codex/AGENTS.global.md.template" ]]; then
        python3 - "$FRAMEWORK_ROOT" "$rendered" <<'PY_SYNC'
from pathlib import Path
import runpy
import sys
root, target = map(Path, sys.argv[1:])
render = runpy.run_path(str(root / "core/infra/sync-instructions.py"))["render"]
target.write_text(render(target.read_text(),
                         (root / "rules/policy/operating-contract.md").read_text()))
PY_SYNC
    fi
    if [[ -f "$dst" ]]; then
        if cmp -s "$rendered" "$dst"; then
            echo "  up-to-date: $dst"
            rm -f "$rendered"
            return
        fi
        if ! confirm "  $dst exists and differs. Overwrite?"; then
            echo "  ... skipped: $dst"
            rm -f "$rendered"
            return
        fi
    fi
    mkdir -p "$(dirname "$dst")"
    cat "$rendered" > "$dst"
    rm -f "$rendered"
    echo "  installed: $dst"
}

# ensure_home_bin — create ~/bin (worker/preflight symlinks land there
# unconditionally now) and, if it is not on PATH, print a one-time NOTE
# telling the user how to add it. Never edits shell rc files — that is the
# user's call, not setup.sh's.
ensure_home_bin() {
    mkdir -p "$HOME/bin"
    case ":$PATH:" in
        *":$HOME/bin:"*) ;;
        *) echo "  NOTE: ~/bin is not on your PATH — add:  export PATH=\"\$HOME/bin:\$PATH\"  to your shell profile (workers/preflights resolve from PATH)" ;;
    esac
}

# ---------------------------------------------------------------------------
# Claude Code
# ---------------------------------------------------------------------------
install_claude() {
    echo "=== Claude Code ==="
    local target="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
    local template="$FRAMEWORK_ROOT/adapters/claude-code/settings.json.template"
    apply_template "$template" "$target"
    python3 "$FRAMEWORK_ROOT/core/infra/sync-instructions.py" \
        --claude "${CLAUDE_GLOBAL_INSTRUCTIONS:-$(dirname "$target")/CLAUDE.md}"
    chmod +x "$FRAMEWORK_ROOT/adapters/claude-code/adapter.sh"

    # Agent-brain MCP server. Claude reads MCP from .mcp.json / user config (NOT
    # settings.json), so register it user-scoped — every Claude session then sees
    # the brain, matching the global codex/gemini registrations. Best-effort:
    # only if the claude CLI is present and 'brain' isn't already registered;
    # AGENT_SKIP_CLAUDE_MCP=1 opts out (tests set this so setup never mutates the
    # real user MCP config). Guarded so a failure never aborts setup under set -e.
    local brain_mcp="$FRAMEWORK_ROOT/core/brain/brain-mcp.py"
    if [[ "${AGENT_SKIP_CLAUDE_MCP:-0}" == "1" ]]; then
        echo "  skipped: brain MCP registration (AGENT_SKIP_CLAUDE_MCP=1)"
    elif command -v claude >/dev/null 2>&1; then
        if claude mcp list 2>/dev/null | grep -qE '^brain[: ]'; then
            echo "  up-to-date: claude MCP 'brain' already registered"
        elif claude mcp add brain --scope user -- python3 "$brain_mcp" >/dev/null 2>&1; then
            echo "  installed: claude MCP 'brain' (user scope) -> $brain_mcp"
        else
            echo "  NOTE: could not auto-register brain MCP — copy adapters/claude-code/mcp.json.template to a project .mcp.json (see file)."
        fi
    else
        echo "  NOTE: claude CLI not found — register brain MCP via adapters/claude-code/mcp.json.template (.mcp.json) or 'claude mcp add'."
    fi
}

# ---------------------------------------------------------------------------
# Codex CLI
# ---------------------------------------------------------------------------
install_codex() {
    echo "=== Codex CLI ==="
    local target="${CODEX_CONFIG:-$HOME/.codex/config.toml}"
    local template="$FRAMEWORK_ROOT/adapters/codex/codex-config.toml.template"
    apply_template "$template" "$target"
    chmod +x "$FRAMEWORK_ROOT/adapters/codex/adapter.sh" \
             "$FRAMEWORK_ROOT/adapters/codex/adapter.py" \
             "$FRAMEWORK_ROOT/adapters/codex/merge-hooks.py"

    # Tier ladder profiles (docs/model-routing.md): quick=LOW, deep=TOP,
    # installed beside the main config so `codex --profile quick|deep` works.
    local codex_dir; codex_dir="$(dirname "$target")"
    local prof
    for prof in quick deep; do
        apply_template "$FRAMEWORK_ROOT/adapters/codex/$prof.config.toml.template" \
                       "$codex_dir/$prof.config.toml"
    done

    # Codex tier families (top=deep, low=quick) live in ~/.agent/codex-tiers.json;
    # core/infra/codex-models.py resolves the actual model from codex's catalog.
    # Copy-if-absent so a user's choice survives re-runs.
    local codex_tiers_file="${AGENT_CODEX_TIERS_FILE:-$HOME/.agent/codex-tiers.json}"
    mkdir -p "$(dirname "$codex_tiers_file")"
    if [[ ! -f "$codex_tiers_file" ]]; then
        local top_family="sol"
        if [[ -t 0 && "${AGENT_SETUP_YES:-}" != "1" ]]; then
            read -r -p "  codex TOP family [sol/astra] (default sol): " top_family || top_family=""
            [[ "$top_family" =~ ^(sol|astra)$ ]] || top_family="sol"
        fi
        sed "s/\"top\": \"sol\"/\"top\": \"$top_family\"/" \
            "$FRAMEWORK_ROOT/adapters/codex/codex-tiers.json.template" > "$codex_tiers_file"
        echo "  installed: ${codex_tiers_file/#$HOME/~} (top=$top_family)"
    fi

    # Global AGENTS.md (read by codex for EVERY session, any repo — distinct
    # from the project-scoped adapters/codex/AGENTS.md.template installed by
    # install_project()). Portable rules only, no repo-specific paths.
    local agents_global_target="${CODEX_GLOBAL_AGENTS:-$HOME/.codex/AGENTS.md}"
    local agents_global_template="$FRAMEWORK_ROOT/adapters/codex/AGENTS.global.md.template"
    apply_template "$agents_global_template" "$agents_global_target"
    python3 "$FRAMEWORK_ROOT/core/infra/sync-instructions.py" --codex "$agents_global_target"

    # Native hooks (W4): merge Agent's entries into the hooks.json beside
    # config.toml. Other tools' hooks in that file are preserved.
    python3 "$FRAMEWORK_ROOT/adapters/codex/merge-hooks.py" \
        "$FRAMEWORK_ROOT/adapters/codex/hooks.json.template" "$FRAMEWORK_ROOT" \
        "$codex_dir/hooks.json"
    echo "  NOTE: Codex runs a new or changed hook only after you trust it — start codex and review them with /hooks."
    echo "        Project-local .codex/ hooks load only in a trusted project ([projects.\"<path>\"] trust_level = \"trusted\");"
    echo "        setup never records trust for you."

    # Skills: Codex reads user skills from ~/.agents/skills and follows symlinks.
    # An entry that already exists and is not our symlink is left alone.
    local skills_dir="$HOME/.agents/skills" skill name linked=0
    mkdir -p "$skills_dir"
    for skill in "$FRAMEWORK_ROOT"/skills/*/; do
        skill="${skill%/}"; name="$(basename "$skill")"
        if [[ -e "$skills_dir/$name" || -L "$skills_dir/$name" ]] &&
           [[ "$(readlink "$skills_dir/$name" 2>/dev/null)" != "$skill" ]]; then
            echo "  skipped: $skills_dir/$name exists and is not an Agent symlink"
            continue
        fi
        ln -sfn "$skill" "$skills_dir/$name"
        linked=$((linked + 1))
    done
    echo "  symlink: ~/.agents/skills/<name> -> skills/<name> ($linked skills)"

    # The shell wrapper retired to legacy/codex-shell-wrap/ (native hooks replace
    # it). A ~/bin/codex-bash symlink an earlier setup created now dangles; repoint
    # it rather than delete it, so a config still naming codex-bash keeps working.
    if [[ -L "$HOME/bin/codex-bash" &&
          "$(readlink "$HOME/bin/codex-bash")" == "$FRAMEWORK_ROOT/adapters/codex/codex-shell-wrap.sh" ]]; then
        ln -sfn "$FRAMEWORK_ROOT/legacy/codex-shell-wrap/codex-shell-wrap.sh" "$HOME/bin/codex-bash"
        echo "  repointed: ~/bin/codex-bash -> legacy/codex-shell-wrap/ (retired; native hooks enforce now)"
    fi
}

# ---------------------------------------------------------------------------
# Gemini CLI
# ---------------------------------------------------------------------------
install_gemini() {
    echo "=== Gemini CLI ==="
    local target="${GEMINI_SETTINGS:-$HOME/.gemini/settings.json}"
    local template="$FRAMEWORK_ROOT/adapters/gemini/gemini-settings.json.template"
    apply_template "$template" "$target"
    chmod +x "$FRAMEWORK_ROOT/adapters/gemini/adapter.sh" \
             "$FRAMEWORK_ROOT/adapters/gemini/adapter.py" \
             "$FRAMEWORK_ROOT/adapters/gemini/gemini-shell-wrap.sh"

    ensure_home_bin
    ln -sf "$FRAMEWORK_ROOT/adapters/gemini/gemini-shell-wrap.sh" "$HOME/bin/gemini-bash"
    echo "  symlink: ~/bin/gemini-bash -> gemini-shell-wrap.sh"

    # Worker lane (cross-vendor second opinions — core/infra/backends.json).
    chmod +x "$FRAMEWORK_ROOT/adapters/gemini/gemini-worker.sh" \
             "$FRAMEWORK_ROOT/adapters/gemini/gemini-preflight.sh"
    ln -sf "$FRAMEWORK_ROOT/adapters/gemini/gemini-worker.sh" "$HOME/bin/gemini-worker"
    ln -sf "$FRAMEWORK_ROOT/adapters/gemini/gemini-preflight.sh" "$HOME/bin/gemini-preflight"
    echo "  symlink: ~/bin/gemini-worker, ~/bin/gemini-preflight"
    if [[ -d "$HOME/.gemini" && ! -f "$HOME/.gemini/agent-tiers.json" ]]; then
        cp "$FRAMEWORK_ROOT/adapters/gemini/gemini-tiers.json.template" "$HOME/.gemini/agent-tiers.json"
        echo "  installed: ~/.gemini/agent-tiers.json (edit to pin a TOP-tier model)"
    elif [[ ! -d "$HOME/.gemini" ]]; then
        echo "  NOTE: gemini CLI not initialized yet (~/.gemini missing) — run the gemini CLI once, then re-run 'setup.sh --gemini' to seed agent-tiers.json"
    fi
}

# ---------------------------------------------------------------------------
# Antigravity (agy) CLI — worker lane + native-hook plugin folder
# (adapters/antigravity/README.md). Successor to the retired gemini CLI review
# lane; default auth lives in the OS keyring, API-key auth is opt-in guidance.
# ---------------------------------------------------------------------------
install_antigravity() {
    echo "=== Antigravity CLI (worker lane + native-hook plugin) ==="
    chmod +x "$FRAMEWORK_ROOT/adapters/antigravity/antigravity-worker.sh" \
             "$FRAMEWORK_ROOT/adapters/antigravity/antigravity-preflight.sh" \
             "$FRAMEWORK_ROOT/adapters/antigravity/adapter.sh" \
             "$FRAMEWORK_ROOT/adapters/antigravity/adapter.py" \
             "$FRAMEWORK_ROOT/adapters/antigravity/install-plugin.py"
    ensure_home_bin
    ln -sf "$FRAMEWORK_ROOT/adapters/antigravity/antigravity-worker.sh" "$HOME/bin/antigravity-worker"
    ln -sf "$FRAMEWORK_ROOT/adapters/antigravity/antigravity-preflight.sh" "$HOME/bin/antigravity-preflight"
    echo "  symlink: ~/bin/antigravity-worker, ~/bin/antigravity-preflight"
    # Tiers file lives under ~/.agent (not the vendor CLI's own config dir) so
    # it does not depend on ~/.gemini/antigravity-cli existing. If only the old
    # path (pre-2026-09) has a file, the worker migrates it on first dispatch —
    # this install step never needs the old dir to be present. (~/.gemini/agent-tiers.json
    # seeded by --gemini belongs to the gemini adapter, not this lane.) The old file is
    # never deleted; --doctor WARNs when both exist and differ.
    mkdir -p "$HOME/.agent"
    if [[ ! -f "$HOME/.agent/antigravity-tiers.json" ]]; then
        OLD_ANTIGRAVITY_TIERS="$HOME/.gemini/antigravity-cli/agent-tiers.json"
        if [[ -f "$OLD_ANTIGRAVITY_TIERS" ]]; then
            echo "  NOTE: found an old-path tiers file ($OLD_ANTIGRAVITY_TIERS) — antigravity-worker migrates it to ~/.agent/antigravity-tiers.json on first dispatch"
        else
            cp "$FRAMEWORK_ROOT/adapters/antigravity/antigravity-tiers.json.template" "$HOME/.agent/antigravity-tiers.json"
            echo "  installed: ~/.agent/antigravity-tiers.json"
        fi
    fi
    # Native hooks: a plugin folder (plugin.json + hooks.json with the absolute
    # adapter path). ~/.gemini/config/hooks.json and settings.json are never
    # touched — other tools register there and agy rewrites settings.json itself.
    python3 "$FRAMEWORK_ROOT/adapters/antigravity/install-plugin.py" --root "$FRAMEWORK_ROOT" \
        || echo "  WARN: antigravity native-hook plugin not installed (see the error above); the rest of the antigravity setup continues"
    echo "  NOTE: restart any running agy session so it loads the plugin's hooks"
    command -v agy >/dev/null 2>&1 || echo "  NOTE: agy CLI not found on PATH yet — install it, then verify with 'agy models' (adapters/antigravity/README.md)"
    # Guidance only — nothing below is applied by this script.
    cat <<'GUIDE'
  Optional, NOT applied by setup (you apply these yourself):
    API-key auth instead of the keyring login (worker lane only):
      security add-generic-password -a "$USER" -s gemini-api-key -w      # prompts for the key; never put it in argv
      export ANTIGRAVITY_AUTH=apikey                                       # antigravity-worker then reads the key from the Keychain
      and set "modelProvider": "gemini" in ~/.gemini/antigravity-cli/settings.json (the env var alone has no effect)
    Suggested permissions.deny rules for ~/.gemini/antigravity-cli/settings.json (agy documents the prefix form
    command(<prefix>) and command(regex:...); glob '*' support is unmeasured, so no '*' is used; setup does not
    edit that file):
      command(rm -rf)   command(sudo)   command(git push --force)   command(git clean -fd)
      command(regex:^git push .*--force)   # for a match in the middle of the command line
GUIDE
}

# ---------------------------------------------------------------------------
# Purpose launchers — session-start rung entry points
# (adapters/claude-code/launchers/README.md). Opt-in.
# ---------------------------------------------------------------------------
install_launchers() {
    echo "=== Purpose launchers ==="
    local ldir="$FRAMEWORK_ROOT/adapters/claude-code/launchers"
    chmod +x "$ldir/claude-build" "$ldir/claude-quick" "$ldir/claude-research"
    ensure_home_bin
    ln -sf "$ldir/claude-build"    "$HOME/bin/claude-build"
    ln -sf "$ldir/claude-quick"    "$HOME/bin/claude-quick"
    ln -sf "$ldir/claude-research" "$HOME/bin/claude-research"
    echo "  symlink: ~/bin/claude-build, ~/bin/claude-quick, ~/bin/claude-research"
}

# ---------------------------------------------------------------------------
# Project scaffold (CLAUDE.md, AGENTS.md, GEMINI.md, hook-config.yml,
# gitleaks.toml in the current repo)
# ---------------------------------------------------------------------------
install_project() {
    echo "=== Project scaffold (cwd: $(pwd)) ==="

    if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
        echo "  ERROR: not in a git repository. cd to your project first." >&2
        return 1
    fi
    local project_root
    project_root="$(git rev-parse --show-toplevel)"

    apply_template "$FRAMEWORK_ROOT/templates/CLAUDE.md.template"      "$project_root/CLAUDE.md"
    apply_template "$FRAMEWORK_ROOT/templates/AGENTS.md.template"      "$project_root/AGENTS.md"
    apply_template "$FRAMEWORK_ROOT/templates/GEMINI.md.template"      "$project_root/GEMINI.md"
    apply_template "$FRAMEWORK_ROOT/templates/hook-config.yml.template" "$project_root/hook-config.yml"
    apply_template "$FRAMEWORK_ROOT/templates/gitleaks.toml.template"  "$project_root/gitleaks.toml"

    install_git_hooks "$project_root"
}

# ---------------------------------------------------------------------------
# Git hooks
# ---------------------------------------------------------------------------
install_git_hooks() {
    local project_root="${1:-}"
    if [[ -z "$project_root" ]]; then
        if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
            echo "  ERROR: not in a git repository." >&2
            return 1
        fi
        project_root="$(git rev-parse --show-toplevel)"
    fi

    echo "=== Git hooks (project: $project_root) ==="

    # Symlink framework's git-hooks directory into the project, then point
    # core.hooksPath at it.
    local hooks_link="$project_root/.git-hooks-framework"
    if [[ ! -L "$hooks_link" ]]; then
        ln -s "$FRAMEWORK_ROOT/core/git-hooks" "$hooks_link"
        echo "  symlink: $hooks_link -> framework core/git-hooks"
    fi

    (cd "$project_root" && git config core.hooksPath .git-hooks-framework)
    echo "  git config: core.hooksPath = .git-hooks-framework"

    chmod +x "$FRAMEWORK_ROOT/core/git-hooks/pre-commit" \
             "$FRAMEWORK_ROOT/core/git-hooks/pre-push" \
             "$FRAMEWORK_ROOT/core/git-hooks/pre-merge-commit" \
             "$FRAMEWORK_ROOT/core/git-hooks/post-commit" \
             "$FRAMEWORK_ROOT/core/git-hooks/scan-push-diff.py" \
             "$FRAMEWORK_ROOT/core/git-hooks/check-staged.py"

    if ! command -v gitleaks >/dev/null 2>&1; then
        echo "  NOTE: gitleaks not installed. Install via:"
        echo "    macOS:    brew install gitleaks"
        echo "    Linux:    https://github.com/gitleaks/gitleaks/releases"
        echo "  Hooks will SKIP secret-scan if gitleaks is missing — CI will still enforce."
    fi
}

# ---------------------------------------------------------------------------
# Display sanitizer
# ---------------------------------------------------------------------------
# Strip terminal-ACTIVE characters from untrusted text (config-derived paths,
# python error text) before it is interpolated into a doctor row.
#
# Every call site used to run `tr -d '\000-\037\177'`, which covers C0 + DEL and
# nothing else. That leaves live display primitives in place:
#   U+0085 NEL              — a line break on terminals that honour C1
#   U+009B CSI              — a single character equivalent to "ESC[", i.e. the
#                             row-spoofing primitive the C0 strip was added for
#   U+202A-U+202E, U+2066-U+2069, U+200E, U+200F
#                           — bidi embedding/override: reverses displayed text,
#                             so a WARN row can be made to read as something else
# `tr` cannot fix this: it deletes BYTES, so deleting \200-\237 in the C locale
# would shred every multi-byte UTF-8 sequence — and this repo's own output
# contains Korean. Hence a character-aware python3 filter; python3 is already a
# hard dependency of the checks that call this (and doctor check 2 verifies it).
#
# Invalid UTF-8 must not blank a row: input is decoded with surrogateescape and
# the resulting lone surrogates are removed by the same character class, so a
# malformed byte sequence costs only the malformed bytes.
sanitize_display() {
    local raw="${1-}" out
    if out="$(printf '%s' "$raw" | python3 -c '
import re, sys
s = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
s = re.sub("[\u0000-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069\ud800-\udfff]", "", s)
sys.stdout.buffer.write(s.encode("utf-8", "replace"))
' 2>/dev/null)"; then
        printf '%s' "$out"
    else
        # python3 absent or crashed (doctor check 2 reports that on its own row):
        # degrade to the byte-level C0+DEL strip rather than emit raw bytes.
        printf '%s' "$raw" | tr -d '\000-\037\177'
    fi
}

# ---------------------------------------------------------------------------
# Environment diagnosis (--doctor) — pure read-only checks, no side effects.
# ---------------------------------------------------------------------------
doctor() {
    local hooks_dir="$FRAMEWORK_ROOT/core/hooks"
    local -a rows=()
    local pass=0 warn=0 fail=0

    add_row() {
        rows+=("$1|$2")
        case "$1" in
            PASS) pass=$((pass + 1)) ;;
            WARN) warn=$((warn + 1)) ;;
            FAIL) fail=$((fail + 1)) ;;
        esac
    }

    # 1. git
    if command -v git >/dev/null 2>&1; then
        add_row PASS "git — $(git --version)"
    else
        add_row FAIL "git — not found"
    fi

    # 2. python3 >= 3.9 (README-declared floor)
    if command -v python3 >/dev/null 2>&1; then
        local py_path py_ver
        py_path="$(command -v python3)"
        py_ver="$(python3 --version 2>&1)"
        if python3 -c 'import sys; sys.exit(0 if sys.version_info[:2] >= (3, 9) else 1)' 2>/dev/null; then
            add_row PASS "python3 — $py_ver at $py_path (>= 3.9 required)"
        else
            add_row FAIL "python3 — $py_ver at $py_path (< 3.9 required by README)"
        fi
    else
        add_row FAIL "python3 — not found (>= 3.9 required by README)"
    fi

    # 3. gitleaks (optional — hooks skip secret-scan without it, CI still enforces)
    if command -v gitleaks >/dev/null 2>&1; then
        add_row PASS "gitleaks — $(command -v gitleaks)"
    else
        add_row WARN "gitleaks — not found; secret-scan git hook will be skipped. Install: brew install gitleaks"
    fi

    # 4. jq — only relevant if a bash hook actually shells out to it
    local jq_users
    jq_users="$( { grep -l 'jq ' "$hooks_dir"/*.sh 2>/dev/null || true; } | xargs -n1 basename 2>/dev/null | paste -sd, - )"
    if [[ -n "$jq_users" ]]; then
        if command -v jq >/dev/null 2>&1; then
            add_row PASS "jq — $(command -v jq) (used by: $jq_users)"
        else
            add_row WARN "jq — not found but used by: $jq_users"
        fi
    else
        add_row PASS "jq — not required (no core/hooks/*.sh shells out to it)"
    fi

    # 4b. PyYAML — hook_config.py needs it to parse hook-config.yml (project
    #     path protection). Absent PyYAML skips the .yml settings; a declared
    #     risk_areas instead fails CLOSED (P1-9: the Bash guard denies the whole
    #     read/copy/upload family), so this is WARN not FAIL (real incident,
    #     2026-09-26: a Mac python3 without PyYAML skipped the config and
    #     4 test batteries failed downstream). The WARN text names both effects
    #     so this row cannot be misread as merely cosmetic.
    if pyyaml_usable; then
        add_row PASS "PyYAML — importable (hook-config.yml path protection active)"
    else
        add_row WARN "PyYAML missing — hook-config.yml settings inactive; declared risk_areas block read/copy commands (python3 -m pip install --user pyyaml)"
    fi

    # 5. core/hooks/*.sh + *.py executable. hook_config.py is a library module
    #    imported by secret-content-scan.py (never invoked directly as a hook
    #    process) and is intentionally exempt from this check.
    local lib_only=("hook_config.py")
    local not_exec=() f base skip m
    for f in "$hooks_dir"/*.sh "$hooks_dir"/*.py; do
        [[ -f "$f" ]] || continue
        base="$(basename "$f")"
        skip=0
        for m in "${lib_only[@]}"; do
            [[ "$base" == "$m" ]] && skip=1
        done
        [[ $skip -eq 1 ]] && continue
        [[ -x "$f" ]] || not_exec+=("$base")
    done
    if [[ ${#not_exec[@]} -eq 0 ]]; then
        add_row PASS "core/hooks/*.sh,*.py — all executable"
    else
        add_row FAIL "core/hooks/*.sh,*.py — not executable: $(IFS=,; echo "${not_exec[*]}")"
    fi

    # 6. adapters/*/adapter.sh executable
    local not_exec_adapters=()
    for f in "$FRAMEWORK_ROOT"/adapters/*/adapter.sh; do
        [[ -f "$f" ]] || continue
        [[ -x "$f" ]] || not_exec_adapters+=("${f#$FRAMEWORK_ROOT/}")
    done
    if [[ ${#not_exec_adapters[@]} -eq 0 ]]; then
        add_row PASS "adapters/*/adapter.sh — all executable"
    else
        add_row FAIL "adapters/*/adapter.sh — not executable: $(IFS=,; echo "${not_exec_adapters[*]}")"
    fi

    # 7. agents/master-registry.json parses; every id has a sibling agents/<id>.md;
    #    each md's `model:` frontmatter matches the registry (same drift guard as CI).
    local reg_out reg_rc
    if reg_out="$(FRAMEWORK_ROOT="$FRAMEWORK_ROOT" python3 - <<'PY' 2>&1
import json, os, pathlib, re, sys
root = pathlib.Path(os.environ["FRAMEWORK_ROOT"])
try:
    reg = json.loads((root / "agents" / "master-registry.json").read_text(encoding="utf-8"))
except Exception as e:
    print(f"registry parse failed: {e}")
    sys.exit(1)
problems = []
for entry in reg.get("agents", []):
    aid, rmodel = entry.get("id"), entry.get("model")
    md = root / "agents" / f"{aid}.md"
    if not md.exists():
        problems.append(f"id '{aid}' has no agents/{aid}.md")
        continue
    parts = md.read_text(encoding="utf-8").split("---", 2)
    mm = re.search(r"(?m)^model:\s*(\S+)", parts[1]) if len(parts) >= 3 else None
    mdmodel = mm.group(1) if mm else None
    if rmodel != mdmodel:
        problems.append(f"model drift: '{aid}' registry={rmodel} md={mdmodel}")
if problems:
    print("; ".join(problems))
    sys.exit(1)
print(f"{len(reg.get('agents', []))} agents OK")
PY
    )"; then
        reg_rc=0
    else
        reg_rc=$?
    fi
    if [[ $reg_rc -eq 0 ]]; then
        add_row PASS "agents/master-registry.json — $reg_out"
    else
        add_row FAIL "agents/master-registry.json — $reg_out"
    fi

    # 8. hooks/hooks.json parses; every referenced hook exists and is executable.
    local hj_out hj_rc
    if hj_out="$(FRAMEWORK_ROOT="$FRAMEWORK_ROOT" python3 - <<'PY' 2>&1
import json, os, pathlib, sys
root = pathlib.Path(os.environ["FRAMEWORK_ROOT"])
try:
    h = json.loads((root / "hooks" / "hooks.json").read_text(encoding="utf-8"))
except Exception as e:
    print(f"hooks.json parse failed: {e}")
    sys.exit(1)
problems = []
seen = set()
for event, groups in h.get("hooks", {}).items():
    for g in groups:
        for c in g.get("hooks", []):
            hook = c["command"].split()[-1]
            seen.add(hook)
            path = root / "core" / "hooks" / hook
            if not path.exists():
                problems.append(f"missing core/hooks/{hook}")
            elif not os.access(path, os.X_OK):
                problems.append(f"not executable core/hooks/{hook}")
if problems:
    print("; ".join(problems))
    sys.exit(1)
print(f"{len(seen)} distinct hook scripts referenced OK")
PY
    )"; then
        hj_rc=0
    else
        hj_rc=$?
    fi
    if [[ $hj_rc -eq 0 ]]; then
        add_row PASS "hooks/hooks.json — $hj_out"
    else
        add_row FAIL "hooks/hooks.json — $hj_out"
    fi

    # 9. ~/.agent/plans
    if [[ -d "$HOME/.agent/plans" ]]; then
        add_row PASS "~/.agent/plans — exists"
    else
        add_row WARN "~/.agent/plans — missing; mkdir -p ~/.agent/plans"
    fi

    # 10. plugin install cache — more than one cached version of ANY plugin
    #     means a stale copy can keep exposing retired agents/skills/commands
    #     to the runtime long after an update (observed live for this harness
    #     and for a third-party plugin). Scans every <marketplace>/<plugin>/
    #     <version>/ triple under the cache root. Runtime-specific path,
    #     env-overridable; absence is fine. WARN only — observation.
    local cache_root="${AGENT_PLUGIN_CACHE_ROOT:-$HOME/.claude/plugins/cache}"
    local plugin_count=0 multi_list="" pd vd ver_count ver_names
    for pd in "$cache_root"/*/*/; do
        [[ -d "$pd" ]] || continue
        ver_count=0
        ver_names=""
        for vd in "$pd"*/; do
            [[ -d "$vd" ]] || continue
            ver_count=$((ver_count + 1))
            ver_names="${ver_names:+$ver_names,}$(basename "$vd")"
        done
        [[ $ver_count -gt 0 ]] || continue
        plugin_count=$((plugin_count + 1))
        if [[ $ver_count -gt 1 ]]; then
            multi_list="${multi_list:+$multi_list; }$(basename "$(dirname "$pd")")/$(basename "$pd"): $ver_count versions ($ver_names)"
        fi
    done
    if [[ -n "$multi_list" ]]; then
        add_row WARN "plugin cache — multiple cached versions: $multi_list; a stale cache can expose retired agents/skills. Keep only the installed version of each"
    elif [[ $plugin_count -gt 0 ]]; then
        add_row PASS "plugin cache — all $plugin_count cached plugin(s) single-version"
    else
        add_row PASS "plugin cache — no plugin cache under ${cache_root/#$HOME/~} (ok)"
    fi

    # 11. declared global-hook manifest vs live runtime settings. Opt-in: the
    #     manifest lists one expected hook-command substring per line (# and
    #     blank lines ignored). No manifest -> check skipped. Catches silent
    #     drift between what the user believes is registered globally and
    #     what actually is. WARN only — observation, never a blocker.
    local manifest="${AGENT_HOOK_MANIFEST:-$HOME/.claude/LOCAL-LAYER.hooks}"
    local settings="${AGENT_GLOBAL_SETTINGS:-$HOME/.claude/settings.json}"
    if [[ ! -f "$manifest" ]]; then
        add_row PASS "hook manifest — none at ${manifest/#$HOME/~} (check skipped)"
    elif [[ ! -f "$settings" ]]; then
        add_row WARN "hook manifest — declared at ${manifest/#$HOME/~} but no settings file at ${settings/#$HOME/~}"
    else
        local mf_out mf_rc
        if mf_out="$(MANIFEST="$manifest" SETTINGS="$settings" python3 - <<'PY' 2>&1
import json, os, sys
manifest = [l.strip() for l in open(os.environ["MANIFEST"], encoding="utf-8-sig")
            if l.strip() and not l.strip().startswith("#")]
try:
    s = json.load(open(os.environ["SETTINGS"], encoding="utf-8"))
except Exception as e:
    print(f"settings parse failed: {e}")
    sys.exit(1)
live = []
try:
    for event, groups in (s.get("hooks") or {}).items():
        for g in groups:
            for c in g.get("hooks", []):
                live.append(c.get("command", ""))
except (AttributeError, TypeError) as e:
    print(f"settings has malformed hooks structure ({type(e).__name__}) — cannot reconcile")
    sys.exit(1)
missing = [m for m in manifest if not any(m in c for c in live)]
undeclared = sorted({c.split("/")[-1].strip('"') for c in live
                     if not any(m in c for m in manifest)})
if missing or undeclared:
    parts = []
    if missing:
        parts.append("declared-but-not-live: " + ", ".join(missing))
    if undeclared:
        parts.append("live-but-undeclared: " + ", ".join(undeclared))
    print("; ".join(parts))
    sys.exit(1)
print(f"{len(manifest)} declared / {len(live)} live hooks all reconciled")
PY
        )"; then
            mf_rc=0
        else
            mf_rc=$?
        fi
        if [[ $mf_rc -eq 0 ]]; then
            add_row PASS "hook manifest — $mf_out"
        else
            add_row WARN "hook manifest — drift: $mf_out"
        fi
    fi

    # 12. runtime commands dir — phantom script references. A commands/*.md
    #     that instructs the model to run a script which does not resolve on
    #     this machine is a live failure path: the command breaks only at
    #     invocation time (observed 2026-07-10 — an orphaned command file
    #     invoking a repo-relative audit script that ships nowhere locally).
    #     Refs containing unexpanded $VARS are skipped (unresolvable here);
    #     relative refs resolve against the runtime root (commands/..) and the
    #     commands dir itself. WARN only — observation, never a blocker; no
    #     commands dir -> check skipped.
    local cmd_dir="${AGENT_COMMANDS_DIR:-$HOME/.claude/commands}"
    if [[ ! -d "$cmd_dir" ]]; then
        add_row PASS "commands scan — no commands dir at ${cmd_dir/#$HOME/~} (check skipped)"
    else
        local pc_out pc_rc
        if pc_out="$(CMD_DIR="$cmd_dir" python3 - <<'PY' 2>&1
import glob, os, re, sys
cmd_dir = os.path.abspath(os.environ["CMD_DIR"])
runtime_root = os.path.dirname(cmd_dir)
# \x27/\x22/\x60 = quote/dquote/backtick as regex escapes: bash 3.2 mis-parses
# unpaired quote or backtick characters inside a $(<<heredoc) command
# substitution even when the heredoc delimiter is quoted, so the literal
# characters must not appear in this file.
ref_re = re.compile(
    r"""\b(?:node|python3|python|bash|sh)\s+([^\s\x27\x22\x60;|&()<>]+\.(?:js|cjs|mjs|py|sh))\b""")
phantoms = []
files = sorted(glob.glob(os.path.join(cmd_dir, "*.md")))
for f in files:
    try:
        text = open(f, encoding="utf-8", errors="replace").read()
    except OSError:
        continue
    for ref in sorted(set(ref_re.findall(text))):
        if "$" in ref:
            continue  # unexpanded variable — not resolvable from here
        p = os.path.expanduser(ref)
        cands = [p] if os.path.isabs(p) else [
            os.path.join(runtime_root, p), os.path.join(cmd_dir, p)]
        if not any(os.path.isfile(c) for c in cands):
            phantoms.append(f"{os.path.basename(f)} -> {ref}")
if phantoms:
    # strip terminal-active chars before echoing untrusted md content back to a
    # terminal (display-spoofing hardening): C0+DEL, the C1 block (U+0085 NEL,
    # U+009B = a one-character "ESC[") and the bidi overrides.
    print(re.sub(r"[\x00-\x1f\x7f-\x9f\u200e\u200f\u202a-\u202e\u2066-\u2069]", "?",
                 "; ".join(phantoms)))
    sys.exit(1)
print(f"{len(files)} command file(s), all script refs resolve")
PY
        )"; then
            pc_rc=0
        else
            pc_rc=$?
        fi
        if [[ $pc_rc -eq 0 ]]; then
            add_row PASS "commands scan — $pc_out"
        else
            add_row WARN "commands scan — phantom script refs (a command file invokes a script that does not exist on this machine): $pc_out"
        fi
    fi

    # 13. codex tier profiles — the model-routing ladder expects quick/deep
    #     profile files NEXT TO the local codex config (recent Codex CLI builds
    #     reject inline [profiles.*] tables; see docs/model-routing.md). The
    #     templates have no drift detection after copy time, so this is the
    #     same "declared vs actual" observer family as checks 11/12. WARN
    #     only; no codex config -> check skipped (codex not installed here).
    #     Present profiles are also compared with codex's own model catalog
    #     (core/infra/codex-models.py check): exit 10 = a pin lags -> WARN with
    #     the apply command; exit 2 (no catalog) stays a plain PASS.
    local codex_cfg="${CODEX_CONFIG:-$HOME/.codex/config.toml}"
    if [[ ! -f "$codex_cfg" ]]; then
        add_row PASS "codex tier profiles — no codex config at ${codex_cfg/#$HOME/~} (check skipped)"
    else
        local codex_dir prof missing_profiles=""
        codex_dir="$(dirname "$codex_cfg")"
        for prof in quick deep; do
            [[ -f "$codex_dir/$prof.config.toml" ]] || missing_profiles="${missing_profiles:+$missing_profiles, }$prof.config.toml"
        done
        if [[ -z "$missing_profiles" ]]; then
            local cm_rc=0
            CODEX_HOME="$codex_dir" python3 "$FRAMEWORK_ROOT/core/infra/codex-models.py" check >/dev/null 2>&1 || cm_rc=$?
            if [[ $cm_rc -eq 10 ]]; then
                add_row WARN "codex tier profiles — a pinned model differs from codex's catalog; review with: python3 $FRAMEWORK_ROOT/core/infra/codex-models.py check, then: python3 $FRAMEWORK_ROOT/core/infra/codex-models.py apply"
            else
                add_row PASS "codex tier profiles — quick/deep profiles present beside ${codex_cfg/#$HOME/~}"
            fi
        else
            add_row WARN "codex tier profiles — missing $missing_profiles beside ${codex_cfg/#$HOME/~}; copy adapters/codex/{quick,deep}.config.toml.template or re-run setup.sh --codex (tier ladder: docs/model-routing.md)"
        fi
    fi

    # 14. goal-mode deps — core/infra/supervisor-goal.sh hard-requires BOTH
    #     sqlite3 and jq (exit 127), and check 4 never sees it (it only scans
    #     core/hooks/*.sh). goal-mode is an optional feature, so WARN not
    #     FAIL; without these /supervise --goal-mode is unavailable and the
    #     manager-audit token lane degrades.
    local goal_missing=""
    for f in sqlite3 jq; do
        command -v "$f" >/dev/null 2>&1 || goal_missing="${goal_missing:+$goal_missing, }$f"
    done
    if [[ -z "$goal_missing" ]]; then
        add_row PASS "goal-mode deps — sqlite3 + jq present (/supervise --goal-mode available)"
    else
        add_row WARN "goal-mode deps — missing: $goal_missing; /supervise --goal-mode will hard-fail (supervisor-goal.sh exit 127), manager-audit token lane degrades. Install: brew/apt install sqlite3 jq"
    fi

    # 15. codex wiring — check 13 verifies tier profiles; this verifies the
    #     brain MCP declaration points to a file. This static check does NOT
    #     prove a live MCP connection or native hook interception.
    #     Obsolete shell-wrapper config is reported separately. Absent config -> skipped.
    #     Wiring absent -> WARN (setup.sh can install it, but nothing before
    #     this check verified it STAYED installed). Wiring present but
    #     pointing at a file that does not exist -> FAIL (the config claims a
    #     harness that is not on disk — stale config or moved checkout).
    if [[ ! -f "$codex_cfg" ]]; then
        add_row PASS "codex wiring — no codex config at ${codex_cfg/#$HOME/~} (check skipped)"
    else
        local cx_missing="" cx_broken="" cx_path cx_shown
        if grep -q '^\[mcp_servers\.brain\]' "$codex_cfg" 2>/dev/null; then
            # Extraction scoped to the [mcp_servers.brain] section body so a
            # brain-mcp.py-shaped string under another section can't leak in.
            # `|| true`: a present header with an atypical path shape must
            # CLASSIFY below (not-wired), never abort the doctor under
            # set -e/pipefail (grep -o exits 1 on no match).
            cx_path="$(sed -n '/^\[mcp_servers\.brain\]/,/^\[/p' "$codex_cfg" 2>/dev/null \
                | grep -o '"[^"]*brain-mcp\.py"' | head -1 | tr -d '"' || true)"
            if [[ -z "$cx_path" ]]; then
                cx_missing="brain MCP ([mcp_servers.brain] present but no quoted brain-mcp.py path in its section)"
            elif [[ ! -f "$cx_path" ]]; then
                # strip terminal-active chars before echoing config-derived
                # bytes back to a terminal (escape-sequence display spoofing —
                # same hardening as check 12)
                cx_shown="$(sanitize_display "$cx_path")"
                cx_broken="brain-mcp.py -> $cx_shown"
            fi
        else
            cx_missing="brain MCP ([mcp_servers.brain])"
        fi
        # A config string naming a wrapper does not prove native tool interception.
        # Current Codex does not route shell tools via the legacy [tools.shell] table.
        if grep -q '^\[tools\.shell\]' "$codex_cfg" 2>/dev/null; then
            add_row WARN "codex wiring — legacy [tools.shell] is not proof of native hook enforcement; migrate the obsolete table"
        fi
        if [[ -n "$cx_broken" ]]; then
            add_row FAIL "codex wiring — wired path missing on disk: $cx_broken"
        elif [[ -n "$cx_missing" ]]; then
            add_row WARN "codex wiring — not wired: $cx_missing; see adapters/codex/codex-config.toml.template (bash setup.sh --codex installs it)"
        else
            add_row PASS "codex wiring — brain MCP path exists in ${codex_cfg/#$HOME/~}; runtime registration and native hook coverage require a live check"
        fi
    fi

    # 15b. codex native hooks (W4) — the enforcement path on Codex >= 0.157.
    #      Agent's adapter entries must be in the hooks.json beside config.toml
    #      and resolve on disk; `[features] hooks = false` switches every hook off;
    #      Codex runs a hook only after /hooks trust, so no pre_tool_use trust
    #      record means nothing is enforced yet. A trust record's hash freshness
    #      (Codex re-asks after a hook changes) is not verified here. Key format
    #      observed in a real codex-cli 0.157.0 config.toml after /hooks approval:
    #      [hooks.state."<abs hooks.json>:session_start:0:0"] trusted_hash = ...;
    #      the pre_tool_use event token is inferred from that snake_case scheme.
    if [[ ! -f "$codex_cfg" ]]; then
        add_row PASS "codex native hooks — no codex config at ${codex_cfg/#$HOME/~} (check skipped)"
    else
        local cx_hooks cx_state
        cx_hooks="$(dirname "$codex_cfg")/hooks.json"
        cx_state="$(python3 - "$cx_hooks" <<'PY' 2>/dev/null || echo "UNREADABLE"
import json, os, re, sys
path = sys.argv[1]
if not os.path.exists(path):
    print("NONE"); sys.exit()
cmds = [h.get("command", "") for gs in (json.load(open(path)).get("hooks") or {}).values()
        for g in gs for h in g.get("hooks", [])]
ours = [c for c in cmds if "/adapters/codex/adapter.sh" in c]
if not ours:
    print("NONE"); sys.exit()
missing = sorted({m.group(1) for c in ours for m in [re.match(r'^"?([^"]*/adapters/codex/adapter\.sh)', c)]
                  if m and not os.path.exists(m.group(1))})
print("BROKEN " + missing[0] if missing else f"OK {len(ours)}")
PY
)"
        if sed -n '/^\[features\]/,/^\[/p' "$codex_cfg" | grep -qE '^[[:space:]]*hooks[[:space:]]*=[[:space:]]*false'; then
            add_row WARN "codex native hooks — [features] hooks = false in ${codex_cfg/#$HOME/~}: no Agent gate runs in Codex (legacy fallback: legacy/codex-shell-wrap/)"
        elif [[ "$cx_state" == NONE ]]; then
            add_row WARN "codex native hooks — not installed in ${cx_hooks/#$HOME/~}: Codex tool calls are unguarded; run setup.sh --codex"
        elif [[ "$cx_state" == UNREADABLE ]]; then
            add_row FAIL "codex native hooks — ${cx_hooks/#$HOME/~} is not valid JSON; Codex cannot load any hook from it"
        elif [[ "$cx_state" == BROKEN* ]]; then
            add_row FAIL "codex native hooks — wired adapter missing on disk: $(sanitize_display "${cx_state#BROKEN }") (moved checkout? re-run setup.sh --codex)"
        elif ! grep -qF "\"$cx_hooks:pre_tool_use:" "$codex_cfg"; then
            add_row WARN "codex native hooks — ${cx_state#OK } entries installed but no PreToolUse trust record found: start codex and approve them with /hooks"
        else
            add_row PASS "codex native hooks — ${cx_state#OK } entries in ${cx_hooks/#$HOME/~} with a PreToolUse trust record (re-trust after hook changes)"
        fi
    fi

    # 15c. antigravity native hooks (W5) — the plugin folder agy loads hooks
    #      from. State comes from install-plugin.py --check (one definition of
    #      "ours", shared with the installer): NONE / BROKEN <why> / OK <n>.
    #      NONE is only a WARN when agy is on PATH (an installed agy runs
    #      unguarded); the lane is opt-in, so no agy = nothing to check.
    local ag_dir ag_state
    ag_dir="${AGENT_ANTIGRAVITY_PLUGIN_DIR:-$HOME/.gemini/config/plugins/agent-harness}"
    ag_state="$(python3 "$FRAMEWORK_ROOT/adapters/antigravity/install-plugin.py" --check 2>/dev/null || echo "BROKEN check could not run")"
    case "$ag_state" in
        OK*)     add_row PASS "antigravity native hooks — ${ag_state#OK } hook entries in ${ag_dir/#$HOME/~} point at an executable adapter" ;;
        BROKEN*) add_row FAIL "antigravity native hooks — plugin in ${ag_dir/#$HOME/~} is broken: $(sanitize_display "${ag_state#BROKEN }") (re-run setup.sh --antigravity)" ;;
        *)
            if command -v agy >/dev/null 2>&1; then
                add_row WARN "antigravity native hooks — not installed in ${ag_dir/#$HOME/~}: agy tool calls are unguarded; run setup.sh --antigravity"
            else
                add_row PASS "antigravity native hooks — not installed (opt-in lane; agy not on PATH, check skipped)"
            fi
            ;;
    esac

    # 15d. antigravity tiers file — the canonical path is ~/.agent/antigravity-tiers.json;
    #      the pre-2026-09 path under the vendor CLI dir is a read-only legacy copy the
    #      worker migrates when it is the only one. Both present AND different means an
    #      edit to one is silently ignored (the worker uses the canonical path), so WARN.
    #      Never deletes either file.
    local ag_tiers_new="$HOME/.agent/antigravity-tiers.json"
    local ag_tiers_old="$HOME/.gemini/antigravity-cli/agent-tiers.json"
    if [[ -f "$ag_tiers_new" && -f "$ag_tiers_old" ]]; then
        local ag_cmp=0
        cmp -s "$ag_tiers_new" "$ag_tiers_old" || ag_cmp=$?
        if [[ $ag_cmp -eq 1 ]]; then
            add_row WARN "antigravity tiers file — ${ag_tiers_old/#$HOME/~} differs from the canonical ${ag_tiers_new/#$HOME/~}; only the canonical file is read, so edits to the legacy copy are ignored — merge what you need into the canonical file, then remove the legacy one by hand"
        elif [[ $ag_cmp -ne 0 ]]; then
            add_row WARN "antigravity tiers file — could not compare ${ag_tiers_old/#$HOME/~} with ${ag_tiers_new/#$HOME/~} (unreadable); fix the permissions, then re-run --doctor"
        fi
    fi

    # 16. gemini wiring — same declared-vs-actual family for the gemini
    #     settings (previously doctor had NO gemini checks at all). Same
    #     policy as 15: skipped / WARN not-wired / FAIL wired-but-missing.
    local gemini_settings="${GEMINI_SETTINGS:-$HOME/.gemini/settings.json}"
    if [[ ! -f "$gemini_settings" ]]; then
        add_row PASS "gemini wiring — no gemini settings at ${gemini_settings/#$HOME/~} (check skipped)"
    else
        local gm_out gm_rc
        if gm_out="$(GEMINI_SETTINGS_FILE="$gemini_settings" AGENT_FRAMEWORK_ROOT="$FRAMEWORK_ROOT" python3 - <<'PY' 2>&1
import json, os, re, sys

def clean(s):
    # strip terminal-active chars before echoing settings-derived strings back to
    # a terminal (display spoofing — same hardening as check 12); JSON
    # \u-escapes can decode to a live ESC, to U+009B (a one-character "ESC[") or
    # to a bidi override that reverses the rest of the row.
    return re.sub(r"[\x00-\x1f\x7f-\x9f\u200e\u200f\u202a-\u202e\u2066-\u2069]", "?", s)

def resolved(p):
    # canonical, symlink-resolved form; realpath raises on an embedded NUL
    # (a crafted config can carry \u0000) and an unresolvable arg is simply
    # not the framework server.
    #
    # NOT a security boundary: this resolution (and the isfile() below) is
    # inherently TOCTOU — a path validated here can be retargeted before the MCP
    # client ever launches it. Doctor is an observational check, not an
    # enforcement point; do not build locking or re-validation on top of it.
    try:
        return os.path.realpath(os.path.expanduser(p))
    except (OSError, ValueError):
        return ""

try:
    s = json.load(open(os.environ["GEMINI_SETTINGS_FILE"], encoding="utf-8"))
except Exception as e:
    print(clean(f"settings parse failed: {e}"))
    sys.exit(2)
missing, broken, foreign, relative = [], [], [], []
brain = (s.get("mcpServers") or {}).get("brain") or {}
# a suffix test (a.endswith("brain-mcp.py")) accepted any string merely ENDING
# in the filename — "--payload=brain-mcp.py", "/tmp/evil/brain-mcp.py" — as the
# framework server. Select by path shape, then require the RESOLVED path to equal
# the FRAMEWORK_ROOT core/brain/brain-mcp.py.
brain_mcp = resolved(os.path.join(os.environ["AGENT_FRAMEWORK_ROOT"], "core/brain/brain-mcp.py"))
mcp = next((a for a in (brain.get("args") or [])
            if isinstance(a, str)
            and os.path.basename(os.path.expanduser(a)) == "brain-mcp.py"), None)
if mcp is None:
    missing.append("brain MCP (mcpServers.brain -> brain-mcp.py)")
elif not os.path.isabs(os.path.expanduser(mcp)):
    # a RELATIVE arg gets resolved against whatever directory doctor happens to
    # run in — never the runtime CWD of the MCP client, so blessing it would bless
    # a file the client may not even have. setup.sh writes absolute paths.
    # (no apostrophes in this heredoc: bash 3.2 mis-parses them here — see check 12)
    relative.append(clean(f"brain-mcp.py -> {mcp}"))
elif not os.path.isfile(os.path.expanduser(mcp)):
    broken.append(clean(f"brain-mcp.py -> {mcp}"))
elif resolved(mcp) != brain_mcp:
    foreign.append(clean(f"brain-mcp.py -> {mcp}"))
wrap = ((s.get("tools") or {}).get("shell") or {}).get("command") or ""
if "gemini-shell-wrap.sh" not in wrap:
    missing.append("shell wrapper (gemini-shell-wrap.sh)")
elif not os.path.isfile(os.path.expanduser(wrap)):
    broken.append(clean(f"shell wrapper -> {wrap}"))
if relative:
    print("wired to a non-absolute path (resolved against the CWD of doctor, not "
          "of the MCP client): " + "; ".join(relative))
    sys.exit(1)
if broken:
    print("wired path missing on disk: " + "; ".join(broken))
    sys.exit(1)
if foreign:
    print("wired to a brain-mcp.py outside this framework: " + "; ".join(foreign))
    sys.exit(1)
if missing:
    print("not wired: " + ", ".join(missing))
    sys.exit(3)
print("brain MCP + shell wrapper wired")
PY
        )"; then
            gm_rc=0
        else
            gm_rc=$?
        fi
        # $gm_out is python output derived from a user-controlled settings.json;
        # clean() covers the strings this block interpolates itself, but an
        # unexpected python traceback reaches this row unfiltered — strip at the
        # boundary too (same treatment as $bm_out in check 20).
        gm_out="$(sanitize_display "$gm_out")"
        case $gm_rc in
            0) add_row PASS "gemini wiring — $gm_out in ${gemini_settings/#$HOME/~}" ;;
            1) add_row FAIL "gemini wiring — $gm_out" ;;
            *) add_row WARN "gemini wiring — $gm_out; see adapters/gemini/gemini-settings.json.template (bash setup.sh --gemini installs it)" ;;
        esac
    fi

    # 17. claude install path — which of the two install paths is live here:
    #     the plugin (a cached agent-harness under the plugin cache) or the
    #     shell install (global settings wiring adapters/claude-code/
    #     adapter.sh). Exactly one -> PASS. Both -> WARN (the same hook chain
    #     can fire twice). Neither -> WARN (harness not wired into Claude
    #     Code on this machine). Never FAIL — machine state, not repo
    #     integrity. Reuses the check-10 cache root and check-11 settings
    #     seams.
    local plugin_active=0 shell_active=0 ip
    for ip in "$cache_root"/*/agent-harness/; do
        [[ -d "$ip" ]] && { plugin_active=1; break; }
    done
    if [[ -f "$settings" ]] && grep -q 'adapters/claude-code/adapter\.sh' "$settings" 2>/dev/null; then
        shell_active=1
    fi
    if [[ $plugin_active -eq 1 && $shell_active -eq 1 ]]; then
        add_row WARN "claude install path — BOTH plugin cache and shell-install settings are wired; the hook chain can run twice. Keep one (plugin recommended)"
    elif [[ $plugin_active -eq 1 ]]; then
        add_row PASS "claude install path — plugin (agent-harness in ${cache_root/#$HOME/~})"
    elif [[ $shell_active -eq 1 ]]; then
        add_row PASS "claude install path — shell install (adapter wired in ${settings/#$HOME/~})"
    else
        add_row WARN "claude install path — neither plugin cache nor shell-install wiring found; harness not active in Claude Code on this machine"
    fi

    # 18. brain strict lint — the live store's promotion-gate health. notes/
    #     absent -> skipped (no brain seeded here). Strict-clean -> PASS.
    #     Warnings -> WARN: a red strict gate stops every /brain-ingest
    #     promotion. WARN, never FAIL — a dirty personal store must not
    #     redden the repo suite.
    local brain_dir="${AGENT_BRAIN_DIR:-$HOME/.agent/brain}" brain_out brain_rc
    if [[ ! -d "$brain_dir/notes" ]]; then
        add_row PASS "brain lint — no store at ${brain_dir/#$HOME/~}/notes (check skipped)"
    else
        if brain_out="$(AGENT_BRAIN_DIR="$brain_dir" python3 "$FRAMEWORK_ROOT/core/brain/lint.py" --strict 2>&1)"; then
            brain_rc=0
        else
            brain_rc=$?
        fi
        brain_out="$(printf '%s\n' "$brain_out" | tail -1)"
        if [[ $brain_rc -eq 0 ]]; then
            add_row PASS "brain lint — ${brain_dir/#$HOME/~}: $brain_out"
        else
            add_row WARN "brain lint — ${brain_dir/#$HOME/~}: $brain_out; /brain-ingest promotion is blocked until strict is clean (run core/brain/lint.py --strict for details)"
        fi
    fi

    # 19. gh CLI — optional (getting-started.md declares it for repo operations:
    #     `gh repo clone`, PR creation). Same WARN-only observer family as gitleaks
    #     (check 3): absence never fails the harness, it just narrows what's usable.
    #     PRESENCE ONLY — never invoke `gh` itself: on a clean $HOME, `gh --version`
    #     writes ~/.local/state/gh/device-id (a UUID), which is a doctor read-only
    #     contract violation (same class of bug as the OpenKnowledge REJECT
    #     precedent — an unconsented write under the user's home on a check that
    #     promises to only look). `command -v` is the same presence-only shape
    #     check 3 (gitleaks) already uses.
    if command -v gh >/dev/null 2>&1; then
        add_row PASS "gh — $(command -v gh)"
    else
        add_row WARN "gh — not found; repo operations (gh repo clone, gh pr create) unavailable. Install: brew install gh (macOS) or https://cli.github.com"
    fi

    # 20. brain MCP registration on the PLUGIN install path — DETECT-AND-GUIDE ONLY.
    #     install_claude() (the shell-install path) offers to register the brain MCP
    #     during setup; a plugin/marketplace install has no equivalent step, so the
    #     server can stay silently unregistered forever with no signal anywhere.
    #     This check never writes to ~/.claude.json (or any user config) — it only
    #     reads the user-scope MCP registry (Claude Code stores user-scope MCP
    #     servers under top-level "mcpServers" in ~/.claude.json, NOT settings.json —
    #     same non-settings.json fact install_claude()'s comment already documents)
    #     and prints the exact opt-in command for the user to run themselves
    #     (consent-first: unconsented ~/.claude writes are this project's named
    #     failure mode — see the OpenKnowledge REJECT precedent). Reuses check 17's
    #     plugin_active/shell_active/settings locals (same function scope, no
    #     subshell between them). Scoped to plugin-only installs: a shell install
    #     already gets registration guidance from install_claude() itself, and a
    #     "both" install is check 17's problem to flag, not this one's.
    local claude_user_cfg="${AGENT_CLAUDE_USER_CONFIG:-$HOME/.claude.json}"
    # printf %q on the interpolated path: an unquoted $FRAMEWORK_ROOT in a
    # copy-pasteable shell command is a command-injection vector for any path
    # containing shell metacharacters (spaces, $(), backticks, ;) — install_claude()
    # (line ~120) already quotes its own brain_mcp path for the same reason.
    local brain_reg_cmd="claude mcp add brain --scope user -- python3 $(printf '%q' "$FRAMEWORK_ROOT")/core/brain/brain-mcp.py"
    # strip terminal-active chars before echoing a config-derived path back to a
    # terminal (display spoofing — same hardening as checks 12/15/16).
    local claude_user_cfg_shown
    claude_user_cfg_shown="$(sanitize_display "${claude_user_cfg/#$HOME/~}")"
    if [[ $plugin_active -ne 1 || $shell_active -eq 1 ]]; then
        add_row PASS "brain MCP (plugin path) — not a plugin-only install (check scoped to plugin-path installs)"
    elif [[ ! -f "$claude_user_cfg" ]]; then
        add_row WARN "brain MCP (plugin path) — no user config at $claude_user_cfg_shown; opt in with: $brain_reg_cmd (never auto-registered)"
    else
        local bm_out bm_rc
        if bm_out="$(CLAUDE_USER_CFG="$claude_user_cfg" AGENT_FRAMEWORK_ROOT="$FRAMEWORK_ROOT" python3 - <<'PY' 2>&1
import json, os, sys

def resolved(p):
    # canonical, symlink-resolved form; realpath raises on an embedded NUL
    # (a crafted config can carry \u0000) and an unresolvable arg is simply
    # not the framework server.
    #
    # NOT a security boundary: resolution here is inherently TOCTOU — a path
    # validated here can be retargeted before the MCP client launches it. Doctor
    # is an observational check, not an enforcement point; do not build locking
    # or re-validation on top of it.
    try:
        return os.path.realpath(os.path.expanduser(p))
    except (OSError, ValueError):
        return ""

try:
    d = json.load(open(os.environ["CLAUDE_USER_CFG"], encoding="utf-8"))
except Exception as e:
    print(f"user config parse failed: {e}")
    sys.exit(2)
brain = (d.get("mcpServers") or {}).get("brain")
if brain is None:
    print("not registered")
    sys.exit(3)
# a malformed config can carry a non-list "args" (int/str/dict/bool) — `or []`
# only guards the FALSY cases; a truthy non-list (e.g. args: 12345) reached the
# `for a in args` below and raised an uncaught TypeError, whose traceback leaked
# into the WARN row. Type-check instead of relying on truthiness.
args = brain.get("args")
if not isinstance(args, list):
    args = []
# a suffix test (a.endswith("brain-mcp.py")) accepted any string merely ENDING
# in the filename — "--payload=brain-mcp.py", "/tmp/evil/brain-mcp.py" — as a
# legitimate registration. Compare the RESOLVED path against the FRAMEWORK_ROOT
# core/brain/brain-mcp.py instead.
brain_mcp = resolved(os.path.join(os.environ["AGENT_FRAMEWORK_ROOT"], "core/brain/brain-mcp.py"))
hits = [a for a in args if isinstance(a, str) and resolved(a) == brain_mcp]
# a RELATIVE arg only resolved to that file because doctor happened to run in the
# right directory; the MCP client is launched elsewhere and would execute a
# different file, or none. Never report it as a valid registration. setup.sh and
# claude mcp add both write absolute paths, so nothing legitimate regresses.
# (no apostrophes in this heredoc: bash 3.2 mis-parses them — see check 12)
if not any(os.path.isabs(os.path.expanduser(a)) for a in hits):
    if hits:
        print("registered with a non-absolute path (resolved against the CWD of "
              f"doctor, not of the MCP client): {hits[0]}")
        sys.exit(3)
    print("registered but does not point at brain-mcp.py")
    sys.exit(3)
print("registered")
PY
        )"; then
            bm_rc=0
        else
            bm_rc=$?
        fi
        # $bm_out carries python stderr derived from user-controlled ~/.claude.json
        # content — strip terminal-active chars before it reaches a terminal row
        # (same hardening as $claude_user_cfg_shown above and checks 12/15/16).
        bm_out="$(sanitize_display "$bm_out")"
        case $bm_rc in
            0) add_row PASS "brain MCP (plugin path) — registered in $claude_user_cfg_shown" ;;
            2) add_row WARN "brain MCP (plugin path) — $bm_out" ;;
            *) add_row WARN "brain MCP (plugin path) — $bm_out; opt in with: $brain_reg_cmd (never auto-registered)" ;;
        esac
    fi

    # -- worker symlink dir: ~/bin exists AND is on PATH. Every install_* above
    # now creates ~/bin unconditionally (ensure_home_bin) and lands its
    # worker/preflight symlinks there, so this is a companion check to the
    # generic worker-lane sweep below — that sweep can only see a symlink if
    # this half is also true. WARN only: an absent/off-PATH ~/bin degrades
    # worker lanes, it does not break the harness itself.
    local hb_exists=0 hb_on_path=0
    [[ -d "$HOME/bin" ]] && hb_exists=1
    case ":$PATH:" in *":$HOME/bin:"*) hb_on_path=1 ;; esac
    if [[ $hb_exists -eq 1 && $hb_on_path -eq 1 ]]; then
        add_row PASS "worker symlink dir — ~/bin exists and is on PATH"
    elif [[ $hb_exists -eq 0 && $hb_on_path -eq 0 ]]; then
        add_row WARN "worker symlink dir — ~/bin missing and not on PATH; add: export PATH=\"\$HOME/bin:\$PATH\" to your shell profile, then re-run an install_* flag"
    elif [[ $hb_exists -eq 0 ]]; then
        add_row WARN "worker symlink dir — ~/bin missing (create it: mkdir -p ~/bin, or re-run an install_* flag)"
    else
        add_row WARN "worker symlink dir — ~/bin exists but is not on PATH; add: export PATH=\"\$HOME/bin:\$PATH\" to your shell profile"
    fi

    # -- worker lanes (generic): every ENABLED backend in the registry must
    # resolve its cmd[0] and its preflight[0] on PATH. call-worker.sh execs
    # both argvs verbatim, so an unresolvable one is a dead lane (exit 127),
    # not merely an unhardened one.
    if command -v jq >/dev/null 2>&1 && [[ -f "$FRAMEWORK_ROOT/core/infra/backends.json" ]]; then
        local wl_missing="" wl_lanes="" wl_row
        while IFS=$'\t' read -r wl_lane wl_bin; do
            [[ -n "$wl_bin" ]] || continue
            case ",$wl_lanes," in *",$wl_lane,"*) ;; *) wl_lanes="${wl_lanes:+$wl_lanes,}$wl_lane" ;; esac
            command -v "$wl_bin" >/dev/null 2>&1 \
                || wl_missing="${wl_missing:+$wl_missing, }$wl_lane -> $wl_bin"
        done < <(jq -r '.backends | to_entries[] | select(.value.enabled == true)
                        | .key as $l | ((.value.cmd // [])[0] // ""), ((.value.preflight // [])[0] // "")
                        | [$l, .] | @tsv' "$FRAMEWORK_ROOT/core/infra/backends.json" 2>/dev/null)
        if [[ -n "$wl_missing" ]]; then
            add_row WARN "worker lanes — enabled backend(s) whose cmd[0]/preflight[0] is not resolvable on PATH: $wl_missing; call-worker.sh execs the registry argv verbatim, so the lane reports UNAVAILABLE (exit 127). Install the symlinks (setup.sh --codex/--gemini/--antigravity, or ln -sf by hand — see the adapter README), and note a lane also needs its vendor CLI installed and authenticated — /worker-setup walks that per lane"
        elif [[ -n "$wl_lanes" ]]; then
            add_row PASS "worker lanes — enabled backend(s) resolvable on PATH: $wl_lanes"
        fi
    fi

    # Runtime profile (informational): set by `runtime-profile.py save` / the setup prompt.
    # Only allow-listed vendor names are rendered, so a crafted file cannot forge rows.
    local profile_file="${AGENT_PROFILE_FILE:-$HOME/.agent/profile.json}" profile_msg=""
    if [[ -f "$profile_file" ]] && command -v python3 >/dev/null 2>&1; then
        profile_msg="$(python3 -c '
import json, sys
ok = {"anthropic", "openai", "google"}
d = json.load(open(sys.argv[1]))
m, r = d["main_vendor"], d["reviewers"]
assert m in ok and isinstance(r, list) and all(x in ok for x in r)
print("main=%s reviewers=%s" % (m, ",".join(r) or "-"))' "$profile_file" 2>/dev/null)" || profile_msg=""
    fi
    if [[ -n "$profile_msg" ]]; then
        add_row PASS "runtime profile — $profile_msg"
    elif [[ -f "$profile_file" ]]; then
        add_row WARN "runtime profile — unreadable or invalid; re-run: python3 $FRAMEWORK_ROOT/core/infra/runtime-profile.py save"
    else
        add_row WARN "runtime profile — not recorded; run: python3 $FRAMEWORK_ROOT/core/infra/runtime-profile.py save"
    fi

    # 22. gate-sink pollution (AG9, X-5 follow-up). AGENT_GATE_SINK_DIR (+ same-purpose test
    #     vars) exists so TEST runners divert gate records away from the live sinks. Left in a
    #     runtime settings `env` block / shell profile it silently diverts LIVE gate records and
    #     makes telemetry-digest under-count. Test runners also export
    #     AGENT_GATE_SINK_TEST_RUN=<same path> (verify-all.sh), so "sink dir set without a
    #     matching marker" = pollution. Read-only; WARN only. Claude files are parsed as JSON
    #     (`env` block; base dir honors CLAUDE_CONFIG_DIR like CODEX_CONFIG/GEMINI_SETTINGS
    #     do); codex/gemini configs are text-scanned for the names (a mention inside a
    #     comment also warns). Limit: sink dir + marker leaked together with the SAME path
    #     (e.g. both in one settings env block) look like a runner to the process-env test —
    #     the settings-file scan is what catches that case.
    local gs_root gs_hits="" gs_checked=0 gs_f gs_out gs_rc
    gs_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    local gs_cdir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    local -a gs_claude=("$gs_cdir/settings.json" "$gs_cdir/settings.local.json")
    # repo == HOME would list the same two files again (duplicate rows)
    [[ "$(cd "$gs_root" 2>/dev/null && pwd -P)" == "$(cd "$HOME" 2>/dev/null && pwd -P)" ]] ||
        gs_claude+=("$gs_root/.claude/settings.json" "$gs_root/.claude/settings.local.json")
    local -a gs_other=(
        "${CODEX_CONFIG:-$HOME/.codex/config.toml}" "${GEMINI_SETTINGS:-$HOME/.gemini/settings.json}"
    )
    if [[ -n "${AGENT_GATE_SINK_DIR:-}" && "${AGENT_GATE_SINK_TEST_RUN:-}" != "$AGENT_GATE_SINK_DIR" ]]; then
        gs_hits="process env AGENT_GATE_SINK_DIR=$(sanitize_display "$AGENT_GATE_SINK_DIR")"
    elif [[ -n "${AGENT_GATE_SINK_TEST_RUN:-}" && "${AGENT_GATE_SINK_DIR:-}" != "$AGENT_GATE_SINK_TEST_RUN" ]]; then
        gs_hits="process env AGENT_GATE_SINK_TEST_RUN=$(sanitize_display "$AGENT_GATE_SINK_TEST_RUN") without a matching AGENT_GATE_SINK_DIR"
    fi
    for gs_f in "${gs_claude[@]}"; do
        [[ -f "$gs_f" ]] || continue
        gs_checked=$((gs_checked + 1))
        if gs_out="$(GS_FILE="$gs_f" python3 - <<'PY' 2>/dev/null
import json, os, sys
names = ("AGENT_GATE_SINK_DIR", "AGENT_GATE_SINK_TEST_RUN", "AGENT_REPRODUCE_TEST")
try:
    with open(os.environ["GS_FILE"], encoding="utf-8-sig") as fh:
        doc = json.load(fh)
except Exception as e:
    print("unparseable (%s)" % type(e).__name__)
    sys.exit(2)
env = doc.get("env") if isinstance(doc, dict) else None
if not isinstance(env, dict):
    sys.exit(0)
hit = [n for n in names if n in env]
if env.get("AGENT_LOG_ORIGIN") == "test":
    hit.append("AGENT_LOG_ORIGIN=test")
if hit:
    print(", ".join(hit))
    sys.exit(1)
PY
        )"; then gs_rc=0; else gs_rc=$?; fi
        case $gs_rc in
            0) ;;
            1|2) gs_hits="${gs_hits:+$gs_hits; }$(sanitize_display "${gs_f/#$HOME/~}"): $(sanitize_display "$gs_out")" ;;
            *) gs_hits="${gs_hits:+$gs_hits; }$(sanitize_display "${gs_f/#$HOME/~}"): scan failed (python3 exit $gs_rc)" ;;
        esac
    done
    for gs_f in "${gs_other[@]}"; do
        [[ -f "$gs_f" ]] || continue
        gs_checked=$((gs_checked + 1))
        gs_rc=0
        grep -qE 'AGENT_GATE_SINK_DIR|AGENT_GATE_SINK_TEST_RUN|AGENT_REPRODUCE_TEST' "$gs_f" 2>/dev/null || gs_rc=$?
        case $gs_rc in
            0) gs_hits="${gs_hits:+$gs_hits; }$(sanitize_display "${gs_f/#$HOME/~}"): mentions a gate test-only variable (may be inside a comment)" ;;
            1) ;;
            *) gs_hits="${gs_hits:+$gs_hits; }$(sanitize_display "${gs_f/#$HOME/~}"): scan failed (grep exit $gs_rc — unreadable?)" ;;
        esac
    done
    if [[ -n "$gs_hits" ]]; then
        add_row WARN "gate sink pollution — $gs_hits; test-only vars divert live gate records and make telemetry-digest under-count. Remove them from the runtime settings/profile (only test runners should set them)"
    else
        add_row PASS "gate sink pollution — no AGENT_GATE_SINK_DIR in process env or $gs_checked runtime settings file(s)"
    fi

    echo "=== Environment diagnosis (--doctor) ==="
    local row status msg
    for row in "${rows[@]}"; do
        status="${row%%|*}"
        msg="${row#*|}"
        printf '  [%-4s] %s\n' "$status" "$msg"
    done
    echo
    echo "doctor: $pass pass, $warn warn, $fail fail"
    [[ $fail -eq 0 ]]
}

# Runtime profile (main vendor + reviewer vendors): interactive-only, so scripted installs
# (CI, </dev/null, piped output) never prompt or hang. Skipped without python3.
offer_runtime_profile() {
    local rp="$FRAMEWORK_ROOT/core/infra/runtime-profile.py"
    [[ "${AGENT_SETUP_NO_PROFILE:-0}" == "1" || "${AGENT_SETUP_NO_DOCTOR:-0}" == "1" ]] && return 0
    command -v python3 >/dev/null 2>&1 || return 0
    if [[ ! -t 0 || ! -t 1 ]]; then
        echo "Tip: run 'python3 $rp save' to record your main/reviewer vendors."
        return 0
    fi
    local rec main answer
    rec="$(python3 "$rp" recommend --json 2>/dev/null)" || return 0
    main="$(printf '%s' "$rec" | python3 -c 'import json,sys; print(json.load(sys.stdin)["main_vendor"])' 2>/dev/null)" || return 0
    local pf="${AGENT_PROFILE_FILE:-$HOME/.agent/profile.json}" saved=""
    # a previously saved choice wins over the fresh recommendation
    if [[ -f "$pf" ]]; then
        saved="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["main_vendor"])' "$pf" 2>/dev/null)" || saved=""
        case "$saved" in anthropic|openai|google) main="$saved" ;; esac
    fi
    echo
    echo "=== Runtime profile ==="
    python3 "$rp" detect 2>/dev/null || true
    read -r -p "Main vendor [$main] (anthropic/openai/google): " answer || answer=""
    answer="${answer:-$main}"
    python3 "$rp" save --main "$answer" || echo "Profile not saved (valid: anthropic, openai, google)." >&2
}

# ---------------------------------------------------------------------------
# Dependency bootstrap (--bootstrap [--dry-run]) — installs what doctor only
# WARNs about (checks 3/4b/14/19: gitleaks, sqlite3, jq, gh, PyYAML). Unlike every other
# install_* function above, this one mutates the SYSTEM (package manager), not
# just $HOME config files — so its consent model is deliberately stricter and
# does NOT read AGENT_SETUP_YES (that var means "skip template-overwrite
# prompts", not "install system packages without asking"; conflating the two
# would make an unrelated env var silently authorize package installs). Every
# missing dependency gets its OWN y/N prompt; --dry-run (or non-interactive
# stdin, detected and forced) never installs anything.
# ---------------------------------------------------------------------------

# bootstrap_stdin_is_tty — real `[[ -t 0 ]]`, overridable only for tests via
# AGENT_BOOTSTRAP_STDIN_IS_TTY (a piped/redirected stdin is never a tty, so a
# test that wants to drive the interactive per-package prompts with scripted
# answers has no other way to simulate "yes this is a real terminal").
#
# SECURITY: the override is honored ONLY when AGENT_BOOTSTRAP_PKG_MGR is also set
# (the mocked-installer seam the battery always pairs it with). Alone, forcing
# the tty check true while stdin is a pipe would let `yes y | ...` auto-consent
# to a REAL `sudo apt-get install` on a NOPASSWD host. A real interactive run
# never sets either seam (pkg_mgr is auto-detected), so this coupling makes the
# override inert outside the test harness while leaving every test working
# (sections (d)/(e) set both). Belt-and-suspenders with confirm_bootstrap()'s
# refusal to consult AGENT_SETUP_YES.
bootstrap_stdin_is_tty() {
    if [[ -n "${AGENT_BOOTSTRAP_STDIN_IS_TTY:-}" && -n "${AGENT_BOOTSTRAP_PKG_MGR+x}" ]]; then
        [[ "$AGENT_BOOTSTRAP_STDIN_IS_TTY" == "1" ]]
        return
    fi
    [[ -t 0 ]]
}

# confirm_bootstrap — intentionally separate from confirm() above: does NOT
# consult AGENT_SETUP_YES. A package install is a system-level mutation, not a
# config-template overwrite, and the delegation contract for this feature is
# explicit — "auto-yes absolutely forbidden". The only way to skip a prompt is
# --dry-run (prints the plan, installs nothing) or genuinely answering y.
confirm_bootstrap() {
    local prompt="$1" ans
    read -r -p "$prompt [y/N] " ans
    [[ "$ans" =~ ^[Yy] ]]
}

bootstrap() {
    echo "=== Dependency bootstrap (--bootstrap) ==="
    local -a deps=(gitleaks sqlite3 jq gh)
    local -a missing=()
    local d
    for d in "${deps[@]}"; do
        command -v "$d" >/dev/null 2>&1 || missing+=("$d")
    done

    # PyYAML (python3 -c 'import yaml') is checked alongside the PATH-binary
    # deps above but is a language-level module, not an OS package — it is
    # installed via pip below, independent of the brew/apt detection that
    # follows, so a host with no supported OS package manager can still get
    # PyYAML guidance instead of bailing out before reaching it.
    local pyyaml_missing=0
    pyyaml_usable || pyyaml_missing=1

    if [[ ${#missing[@]} -eq 0 && $pyyaml_missing -eq 0 ]]; then
        echo "All bootstrap-managed dependencies already present: ${deps[*]} pyyaml"
        return 0
    fi

    local -a installed=() skipped=() failed=()
    local no_pkg_mgr=0

    if [[ ${#missing[@]} -gt 0 ]]; then
        # AGENT_BOOTSTRAP_PKG_MGR (test seam): SET (even to "") short-circuits real
        # OS/package-manager detection — the only way to exercise the apt branch
        # (or the unsupported-OS branch) from a macOS dev/CI box, since `uname -s`
        # itself can't be usefully faked without root or a PATH-stub arms race.
        local pkg_mgr
        if [[ -n "${AGENT_BOOTSTRAP_PKG_MGR+x}" ]]; then
            pkg_mgr="$AGENT_BOOTSTRAP_PKG_MGR"
        else
            case "$(uname -s)" in
                Darwin) pkg_mgr="brew" ;;
                Linux)  command -v apt-get >/dev/null 2>&1 && pkg_mgr="apt" || pkg_mgr="" ;;
                *)      pkg_mgr="" ;;
            esac
        fi

        # No usable OS package manager: report the missing binaries but fall
        # through so the PyYAML (pip) step below still runs; exit 1 at the end.
        if [[ -z "$pkg_mgr" ]]; then
            echo "No supported package manager detected (supported: macOS/brew, Linux/apt)."
            echo "Missing: ${missing[*]} — install manually. See docs/getting-started.md prerequisites."
            no_pkg_mgr=1
        elif [[ "$pkg_mgr" == "brew" ]] && ! command -v brew >/dev/null 2>&1; then
            echo "macOS detected but Homebrew not found. Install from https://brew.sh, then re-run --bootstrap."
            echo "Missing: ${missing[*]}"
            no_pkg_mgr=1
        else
            echo "Missing dependencies: ${missing[*]}"
            echo "Package manager: $pkg_mgr"
            echo
        fi
    fi

    # Non-interactive stdin -> forced dry-run downgrade. This is unconditional
    # (checked even if the caller didn't pass --dry-run) — a script piping into
    # this command (CI, another tool, `echo | setup.sh --bootstrap`) must NEVER
    # be able to trigger a real system install just by having something, or
    # nothing, on the other end of the pipe.
    local effective_dry_run=$BOOTSTRAP_DRY_RUN
    local downgrade_note=""
    if [[ $effective_dry_run -eq 0 ]] && ! bootstrap_stdin_is_tty; then
        effective_dry_run=1
        downgrade_note="NOTE: stdin is not a terminal (non-interactive) — downgraded to --dry-run. Nothing was installed. Re-run interactively (or pass --dry-run explicitly to suppress this note)."
    fi

    if [[ ${#missing[@]} -gt 0 && $no_pkg_mgr -eq 0 ]]; then
        for d in "${missing[@]}"; do
            local install_cmd=""
            case "$pkg_mgr" in
                brew) install_cmd="brew install $d" ;;
                apt)  install_cmd="sudo apt-get install -y $d" ;;
                *)
                    # Unreachable via real OS detection (brew/apt/"" only) — but the
                    # AGENT_BOOTSTRAP_PKG_MGR seam is a public test hook, and a bogus
                    # value must fail loud, not eval "" and report "installed".
                    echo "  ERROR: unrecognized package manager '$pkg_mgr' — cannot install $d" >&2
                    failed+=("$d")
                    continue
                    ;;
            esac
            if [[ $effective_dry_run -eq 1 ]]; then
                echo "  [dry-run] would run: $install_cmd"
                continue
            fi
            if confirm_bootstrap "  Install $d via $pkg_mgr? ($install_cmd)"; then
                echo "  Installing $d ..."
                if eval "$install_cmd"; then
                    installed+=("$d")
                else
                    echo "  ERROR: install failed for $d (command: $install_cmd)" >&2
                    failed+=("$d")
                fi
            else
                echo "  ... skipped: $d"
                skipped+=("$d")
            fi
        done
    fi

    # PyYAML — pip install, same asks-first policy as the OS-package deps
    # above (no auto-yes, --dry-run only prints the plan).
    if [[ $pyyaml_missing -eq 1 ]]; then
        local pip_cmd="python3 -m pip install --user pyyaml"
        echo "Missing: PyYAML (python3 -c 'import yaml' failed)"
        if [[ $effective_dry_run -eq 1 ]]; then
            echo "  [dry-run] would run: $pip_cmd"
        elif confirm_bootstrap "  Install PyYAML via pip? ($pip_cmd)"; then
            echo "  Installing PyYAML ..."
            if eval "$pip_cmd"; then
                installed+=("pyyaml")
            else
                echo "  ERROR: install failed for PyYAML (command: $pip_cmd)" >&2
                failed+=("pyyaml")
            fi
        else
            echo "  ... skipped: pyyaml"
            skipped+=("pyyaml")
        fi
    fi

    echo
    if [[ $effective_dry_run -eq 1 ]]; then
        echo "=== Dry run complete — no installs performed ==="
        [[ -n "$downgrade_note" ]] && echo "$downgrade_note"
    else
        echo "=== Bootstrap complete — installed: ${installed[*]:-none}; skipped: ${skipped[*]:-none}; failed: ${failed[*]:-none} ==="
    fi
    [[ $no_pkg_mgr -eq 1 ]] && return 1
    return 0
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

echo "Framework root: $FRAMEWORK_ROOT"
echo

if [[ $DO_INSTRUCTIONS -eq 1 ]]; then
    if [[ $DO_CLAUDE -eq 1 || $DO_CODEX -eq 1 || $DO_GEMINI -eq 1 ||
          $DO_PROJECT -eq 1 || $DO_HOOKS -eq 1 || $DO_BOOTSTRAP -eq 1 ||
          $DO_DOCTOR -eq 1 || $DO_ANTIGRAVITY -eq 1 || $DO_LAUNCHERS -eq 1 ]]; then
        echo "--instructions-only cannot be combined with other install modes" >&2
        exit 2
    fi
    instruction_mode=()
    if [[ $BOOTSTRAP_DRY_RUN -eq 1 ]]; then
        instruction_mode=(--check)
    fi
    python3 "$FRAMEWORK_ROOT/core/infra/sync-instructions.py" \
        --claude "${CLAUDE_GLOBAL_INSTRUCTIONS:-$HOME/.claude/CLAUDE.md}" \
        --codex "${CODEX_GLOBAL_AGENTS:-${CODEX_HOME:-$HOME/.codex}/AGENTS.md}" \
        ${instruction_mode[@]+"${instruction_mode[@]}"}
    exit $?
fi

if [[ $DO_DOCTOR -eq 1 ]]; then
    doctor
    exit $?
fi

if [[ $DO_BOOTSTRAP -eq 1 ]]; then
    bootstrap
    exit $?
fi

[[ $DO_HOOKS -eq 1 ]]  && install_git_hooks
[[ $DO_CLAUDE -eq 1 ]] && install_claude
[[ $DO_CODEX -eq 1 ]]  && install_codex
[[ $DO_GEMINI -eq 1 ]] && install_gemini
[[ $DO_ANTIGRAVITY -eq 1 ]] && install_antigravity
[[ $DO_LAUNCHERS -eq 1 ]] && install_launchers
[[ $DO_PROJECT -eq 1 ]] && install_project

# Self-heal exec bits before validating: distribution paths that drop POSIX
# exec bits (ZIP download, some copy tools) would otherwise hard-fail doctor
# checks 5/6 with no in-script remediation. hook_config.py stays a library
# module (same exemption as doctor check 5).
for f in "$FRAMEWORK_ROOT"/core/hooks/*.sh "$FRAMEWORK_ROOT"/core/hooks/*.py \
         "$FRAMEWORK_ROOT"/adapters/*/adapter.sh; do
    [[ -f "$f" && "$(basename "$f")" != "hook_config.py" && ! -x "$f" ]] && chmod +x "$f"
done

# Post-install validation: every install path ends in the same read-only
# diagnosis a user would run by hand (--doctor), so a broken install fails
# loudly at install time instead of at first use. AGENT_SETUP_NO_DOCTOR=1
# skips it (test seam / air-gapped bootstrap).
echo
if [[ "${AGENT_SETUP_NO_DOCTOR:-0}" == "1" ]]; then
    echo "=== Setup complete (post-install validation skipped: AGENT_SETUP_NO_DOCTOR=1) ==="
elif doctor; then
    echo
    echo "=== Setup complete — post-install validation PASS ==="
else
    echo
    echo "=== Setup finished, but post-install validation FAILED (see doctor output above) ===" >&2
    exit 1
fi
offer_runtime_profile
echo "Next steps:"
echo "  - Verify hooks work: bash $FRAMEWORK_ROOT/core/tests/sanitize-audit.sh"
echo "  - Test adapters: bash $FRAMEWORK_ROOT/core/tests/adapter-parity.sh"
echo "  - Read docs: $FRAMEWORK_ROOT/docs/getting-started.md"
