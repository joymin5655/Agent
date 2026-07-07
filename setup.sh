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
#   bash setup.sh --doctor         # environment diagnosis only — no installs, read-only
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
        --doctor)      DO_DOCTOR=1 ;;
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

    # 10. plugin install cache — more than one cached version of this harness
    #     means a stale copy can keep exposing retired agents/skills to the
    #     runtime long after a trim. Runtime-specific path, env-overridable;
    #     absence (not installed as a plugin) is fine.
    local cache_root="${AGENT_PLUGIN_CACHE_ROOT:-$HOME/.claude/plugins/cache}"
    local ver_count=0 ver_names="" vd
    for vd in "$cache_root"/*/agent-harness/*/; do
        [[ -d "$vd" ]] || continue
        ver_count=$((ver_count + 1))
        ver_names="${ver_names:+$ver_names,}$(basename "$vd")"
    done
    if [[ $ver_count -gt 1 ]]; then
        add_row WARN "plugin cache — $ver_count cached agent-harness versions ($ver_names); a stale cache can expose retired agents/skills. Keep only the installed version"
    elif [[ $ver_count -eq 1 ]]; then
        add_row PASS "plugin cache — single agent-harness version cached ($ver_names)"
    else
        add_row PASS "plugin cache — no agent-harness plugin cache under ${cache_root/#$HOME/~} (ok)"
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

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

echo "Framework root: $FRAMEWORK_ROOT"
echo

if [[ $DO_DOCTOR -eq 1 ]]; then
    doctor
    exit $?
fi

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
