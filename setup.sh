#!/usr/bin/env bash
# setup.sh — install the framework into an AI runtime and/or a project.
#
# Usage:
#   bash setup.sh                  # all 3 AIs (claude + codex + gemini)
#   bash setup.sh --claude         # claude only
#   bash setup.sh --codex          # codex only
#   bash setup.sh --gemini         # gemini only
#   bash setup.sh --project        # +current project scaffold (CLAUDE.md, hook-config.yml, etc.)
#   bash setup.sh --hooks-only     # install git-hooks (pre-commit, pre-push) only
#   bash setup.sh --all            # alias for default (all 3 AIs)
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

if [[ $# -eq 0 ]]; then
    DO_CLAUDE=1
    DO_CODEX=1
    DO_GEMINI=1
fi

for arg in "$@"; do
    case "$arg" in
        --claude)      DO_CLAUDE=1 ;;
        --codex)       DO_CODEX=1 ;;
        --gemini)      DO_GEMINI=1 ;;
        --project)     DO_PROJECT=1 ;;
        --hooks-only)  DO_HOOKS=1 ;;
        --all)         DO_CLAUDE=1; DO_CODEX=1; DO_GEMINI=1 ;;
        -h|--help)
            sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "ERROR: unknown arg: $arg" >&2
            sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//' >&2
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

apply_template() {
    local src="$1" dst="$2"
    if [[ -f "$dst" ]]; then
        if ! confirm "  $dst exists. Overwrite?"; then
            echo "  ... skipped: $dst"
            return
        fi
    fi
    mkdir -p "$(dirname "$dst")"
    sed "s|{{FRAMEWORK_ROOT}}|$FRAMEWORK_ROOT|g" "$src" > "$dst"
    echo "  installed: $dst"
}

# ---------------------------------------------------------------------------
# Claude Code
# ---------------------------------------------------------------------------
install_claude() {
    echo "=== Claude Code ==="
    local target="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
    local template="$FRAMEWORK_ROOT/adapters/claude-code/settings.json.template"
    apply_template "$template" "$target"
    chmod +x "$FRAMEWORK_ROOT/adapters/claude-code/adapter.sh"
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
             "$FRAMEWORK_ROOT/adapters/codex/codex-shell-wrap.sh"

    # Put wrapper on PATH (if user has ~/bin and it's on PATH)
    if [[ -d "$HOME/bin" ]]; then
        ln -sf "$FRAMEWORK_ROOT/adapters/codex/codex-shell-wrap.sh" "$HOME/bin/codex-bash"
        echo "  symlink: ~/bin/codex-bash -> codex-shell-wrap.sh"
    else
        echo "  NOTE: ~/bin doesn't exist. Put codex-shell-wrap.sh on your PATH manually."
    fi

    # Symlink skills directory if user opts in
    local skills_target="$HOME/.codex/skills"
    if [[ ! -e "$skills_target" ]]; then
        if confirm "  Symlink ~/.codex/skills -> framework codex-skills?"; then
            mkdir -p "$(dirname "$skills_target")"
            ln -sf "$FRAMEWORK_ROOT/codex-skills" "$skills_target"
            echo "  symlink: $skills_target -> $FRAMEWORK_ROOT/codex-skills"
        fi
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

    if [[ -d "$HOME/bin" ]]; then
        ln -sf "$FRAMEWORK_ROOT/adapters/gemini/gemini-shell-wrap.sh" "$HOME/bin/gemini-bash"
        echo "  symlink: ~/bin/gemini-bash -> gemini-shell-wrap.sh"
    else
        echo "  NOTE: ~/bin doesn't exist. Put gemini-shell-wrap.sh on your PATH manually."
    fi
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
# Run
# ---------------------------------------------------------------------------

echo "Framework root: $FRAMEWORK_ROOT"
echo

[[ $DO_HOOKS -eq 1 ]]  && install_git_hooks
[[ $DO_CLAUDE -eq 1 ]] && install_claude
[[ $DO_CODEX -eq 1 ]]  && install_codex
[[ $DO_GEMINI -eq 1 ]] && install_gemini
[[ $DO_PROJECT -eq 1 ]] && install_project

echo
echo "=== Setup complete ==="
echo "Next steps:"
echo "  - Verify hooks work: bash $FRAMEWORK_ROOT/core/tests/sanitize-audit.sh"
echo "  - Test adapters: bash $FRAMEWORK_ROOT/core/tests/adapter-parity.sh"
echo "  - Read docs: $FRAMEWORK_ROOT/docs/getting-started.md"
