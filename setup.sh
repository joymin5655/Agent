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

# ---------------------------------------------------------------------------
# Claude Code
# ---------------------------------------------------------------------------
install_claude() {
    echo "=== Claude Code ==="
    local target="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
    local template="$FRAMEWORK_ROOT/adapters/claude-code/settings.json.template"
    apply_template "$template" "$target"
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
    # strip control chars before echoing untrusted md content back to a
    # terminal (escape-sequence display spoofing hardening)
    print(re.sub(r"[\x00-\x1f\x7f]", "?", "; ".join(phantoms)))
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
            add_row PASS "codex tier profiles — quick/deep profiles present beside ${codex_cfg/#$HOME/~}"
        else
            add_row WARN "codex tier profiles — missing $missing_profiles beside ${codex_cfg/#$HOME/~}; copy adapters/codex/{quick,deep}.config.toml.template (tier ladder: docs/model-routing.md)"
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
    #     framework is actually WIRED into the codex config: the brain MCP
    #     server ([mcp_servers.brain] -> core/brain/brain-mcp.py) and the
    #     shell wrapper (codex-shell-wrap.sh). Absent config -> skipped.
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
                # strip control chars before echoing config-derived bytes back
                # to a terminal (escape-sequence display spoofing — same
                # hardening as check 12)
                cx_shown="$(printf '%s' "$cx_path" | tr -d '\000-\037\177')"
                cx_broken="brain-mcp.py -> $cx_shown"
            fi
        else
            cx_missing="brain MCP ([mcp_servers.brain])"
        fi
        # Unanchored substring heuristic: a comment mentioning the wrapper also
        # matches — acceptable under the WARN policy (asymmetric on purpose with
        # the anchored section-header check above; TOML has no fixed home for
        # the wrapper command). Same || true guard as the brain extraction.
        if grep -q 'codex-shell-wrap\.sh' "$codex_cfg" 2>/dev/null; then
            cx_path="$(grep -o '"[^"]*codex-shell-wrap\.sh"' "$codex_cfg" 2>/dev/null | head -1 | tr -d '"' || true)"
            if [[ -z "$cx_path" ]]; then
                cx_missing="${cx_missing:+$cx_missing, }shell wrapper (codex-shell-wrap.sh mentioned but no quoted path)"
            elif [[ ! -f "$cx_path" ]]; then
                cx_shown="$(printf '%s' "$cx_path" | tr -d '\000-\037\177')"
                cx_broken="${cx_broken:+$cx_broken; }shell wrapper -> $cx_shown"
            fi
        else
            cx_missing="${cx_missing:+$cx_missing, }shell wrapper (codex-shell-wrap.sh)"
        fi
        if [[ -n "$cx_broken" ]]; then
            add_row FAIL "codex wiring — wired path missing on disk: $cx_broken"
        elif [[ -n "$cx_missing" ]]; then
            add_row WARN "codex wiring — not wired: $cx_missing; see adapters/codex/codex-config.toml.template (bash setup.sh --codex installs it)"
        else
            add_row PASS "codex wiring — brain MCP + shell wrapper wired in ${codex_cfg/#$HOME/~}"
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
        if gm_out="$(GEMINI_SETTINGS_FILE="$gemini_settings" python3 - <<'PY' 2>&1
import json, os, re, sys

def clean(s):
    # strip control chars before echoing settings-derived strings back to a
    # terminal (escape-sequence display spoofing — same hardening as check 12);
    # JSON \u-escapes can decode to live ESC bytes.
    return re.sub(r"[\x00-\x1f\x7f]", "?", s)

try:
    s = json.load(open(os.environ["GEMINI_SETTINGS_FILE"], encoding="utf-8"))
except Exception as e:
    print(clean(f"settings parse failed: {e}"))
    sys.exit(2)
missing, broken = [], []
brain = (s.get("mcpServers") or {}).get("brain") or {}
mcp = next((a for a in (brain.get("args") or [])
            if isinstance(a, str) and a.endswith("brain-mcp.py")), None)
if mcp is None:
    missing.append("brain MCP (mcpServers.brain -> brain-mcp.py)")
elif not os.path.isfile(os.path.expanduser(mcp)):
    broken.append(clean(f"brain-mcp.py -> {mcp}"))
wrap = ((s.get("tools") or {}).get("shell") or {}).get("command") or ""
if "gemini-shell-wrap.sh" not in wrap:
    missing.append("shell wrapper (gemini-shell-wrap.sh)")
elif not os.path.isfile(os.path.expanduser(wrap)):
    broken.append(clean(f"shell wrapper -> {wrap}"))
if broken:
    print("wired path missing on disk: " + "; ".join(broken))
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
    if command -v gh >/dev/null 2>&1; then
        add_row PASS "gh — $(gh --version 2>&1 | head -1)"
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
    local brain_reg_cmd="claude mcp add brain --scope user -- python3 $FRAMEWORK_ROOT/core/brain/brain-mcp.py"
    if [[ $plugin_active -ne 1 || $shell_active -eq 1 ]]; then
        add_row PASS "brain MCP (plugin path) — not a plugin-only install (check scoped to plugin-path installs)"
    elif [[ ! -f "$claude_user_cfg" ]]; then
        add_row WARN "brain MCP (plugin path) — no user config at ${claude_user_cfg/#$HOME/~}; opt in with: $brain_reg_cmd (never auto-registered)"
    else
        local bm_out bm_rc
        if bm_out="$(CLAUDE_USER_CFG="$claude_user_cfg" python3 - <<'PY' 2>&1
import json, os, sys
try:
    d = json.load(open(os.environ["CLAUDE_USER_CFG"], encoding="utf-8"))
except Exception as e:
    print(f"user config parse failed: {e}")
    sys.exit(2)
brain = (d.get("mcpServers") or {}).get("brain")
if brain is None:
    print("not registered")
    sys.exit(3)
args = brain.get("args") or []
if not any(isinstance(a, str) and a.endswith("brain-mcp.py") for a in args):
    print("registered but does not point at brain-mcp.py")
    sys.exit(3)
print("registered")
PY
        )"; then
            bm_rc=0
        else
            bm_rc=$?
        fi
        case $bm_rc in
            0) add_row PASS "brain MCP (plugin path) — registered in ${claude_user_cfg/#$HOME/~}" ;;
            2) add_row WARN "brain MCP (plugin path) — $bm_out" ;;
            *) add_row WARN "brain MCP (plugin path) — $bm_out; opt in with: $brain_reg_cmd (never auto-registered)" ;;
        esac
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
echo "Next steps:"
echo "  - Verify hooks work: bash $FRAMEWORK_ROOT/core/tests/sanitize-audit.sh"
echo "  - Test adapters: bash $FRAMEWORK_ROOT/core/tests/adapter-parity.sh"
echo "  - Read docs: $FRAMEWORK_ROOT/docs/getting-started.md"
