#!/usr/bin/env bash
# skill-plugin-root-test.sh — shipped skill/agent/command markdown reaches harness files
# through the plugin root, so a skill works from any project folder, not only a checkout.
#
# Claude Code replaces the exact text ${CLAUDE_PLUGIN_ROOT} in skill, command and agent
# bodies when it loads them (plugins-reference "Where each variable resolves"); the
# variable is not in the Bash tool's environment. A ${CLAUDE_PLUGIN_ROOT:-...} default
# form is not replaced, so in the shell it falls back to the cwd — which outside a
# harness checkout has no core/. Supporting files a skill reads are not substituted
# either: they write <harness root>/ and the SKILL.md says what that is.
#
#   (a) no CLAUDE_PLUGIN_ROOT form other than the exact ${CLAUDE_PLUGIN_ROOT}
#   (b) no call-shaped bare reference to a real harness script, no rooted script run
#       without an interpreter, no bare path to a skill's own supporting file, no inline
#       command that uses $HR/ (each Bash call is a fresh shell: it needs a block that sets HR)
#   (c) every ${CLAUDE_PLUGIN_ROOT}/, $HR/ and <harness root>/ path exists
#   (d) the scripts those calls reach find their own companion files when the cwd is a
#       project outside the harness — the project keeps only its .agent/ state
#
# Usage: bash core/tests/skill-plugin-root-test.sh
# shellcheck disable=SC2016  # literal $, ${...} and backticks are the text written and matched
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
check() { if [[ "$2" -eq 0 ]]; then echo "  ok   [$1]"; PASS=$((PASS+1)); else echo "  FAIL [$1]"; FAIL=$((FAIL+1)); fi; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP python3 absent"; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/scan.py" <<'PY'
import os
import re
import sys

root, section = sys.argv[1], sys.argv[2]

# Shipped markdown and the plugin root its ${CLAUDE_PLUGIN_ROOT} names ("" = repo root).
DOC_DIRS = [("skills", ""), ("agents", ""), ("commands", ""),
            ("extras/skills", "extras"), ("extras/agents", "extras")]
# Skills that act on the harness checkout itself, so they stay cwd-relative on purpose.
CHECKOUT_ONLY = {
    "extras/skills/harness-audit/SKILL.md": "audits the harness checkout's own gates",
    "extras/skills/harness-loop/SKILL.md": "edits the harness's own reviewer prompts",
    "extras/skills/loop/SKILL.md": "its default grader replays the harness's own batteries",
}
# (path, line substring, reason): looks call-shaped but is not a harness call.
ALLOW = [
    ("skills/verify-completion/SKILL.md", "wraps `completion-verify.py --require-evidence",
     "describes what the gate wraps"),
    ("extras/skills/brain-ingest/SKILL.md", "`lint.py --strict` at 0 is the",
     "names the gate inside a rule; the call itself is rooted"),
    ("commands/project-init.md", "that `setup.sh --project` currently",
     "names the installer mode this command mirrors; the call itself is rooted"),
    ("extras/skills/manager-audit/SKILL.md", "`$HR/core/infra/telemetry-digest.sh --review",
     "describes what the machine layer runs; it is not an instruction"),
    ("extras/skills/brain-ingest/SKILL.md", '`python3 "$HR/core/brain/store.py" paths` prints',
     "says what the call prints; the block below runs it with HR set"),
]


def walk(rel, exts):
    for d, dirs, files in os.walk(os.path.join(root, rel)):
        dirs[:] = [x for x in dirs if x != "__pycache__"]
        for f in files:
            if f.endswith(exts):
                yield os.path.relpath(os.path.join(d, f), root)


docs = []
for rel, plugin in DOC_DIRS:
    docs += [(p, plugin) for p in sorted(walk(rel, (".md",)))]
scripts = {p for rel in ("core", "extras", "adapters") for p in walk(rel, (".sh", ".py"))}
scripts |= {f for f in os.listdir(root) if f.endswith((".sh", ".py"))}
extras_rel = {p[len("extras/"):] for p in scripts if p.startswith("extras/")}
names = {os.path.basename(p) for p in scripts}


def real_script(tok):
    return (tok in scripts or tok in extras_rel) if "/" in tok else tok in names


def own_skill_file(tok, path, plugin):
    """A bare skills/... path to a file this document reads (its own skill's files)."""
    if not tok.startswith("skills/") or tok.endswith("/SKILL.md"):
        return False                  # a skill's own entry point is already loaded
    if not os.path.isfile(os.path.join(root, plugin, tok)):
        return False
    parts = os.path.relpath(path, os.path.join(root, plugin) if plugin else root).split(os.sep)
    if parts[0] != "skills":          # agents/commands may read any skill's files
        return True
    return tok.startswith("skills/%s/" % parts[1])


FENCE = re.compile(r"^\s*(```|~~~)")


def code(text):
    """(line number, kind, snippet, continuation) for fenced lines and inline spans."""
    out, fence, cont = [], False, False
    lines = text.split("\n")
    # front matter (description, when_to_use) is routing prose, not a run instruction
    start = lines.index("---", 1) + 1 if lines[0] == "---" and "---" in lines[1:] else 0
    prose = []                        # (line number, line) outside fences
    for n, line in enumerate(lines, 1):
        if n <= start:
            continue
        if FENCE.match(line):
            fence, cont = not fence, False
            continue
        if fence:
            body = re.sub(r"(^|\s)#.*$", "", line)
            out.append((n, "fence", body, cont))
            cont = body.rstrip().endswith("\\")
        else:
            prose.append((n, line))
    # inline spans pair up within a paragraph and may wrap across its lines
    paras, cur = [], []
    for n, line in prose:
        if line.strip() and cur and cur[-1][0] == n - 1:
            cur.append((n, line))
            continue
        if cur:
            paras.append(cur)
        cur = [(n, line)] if line.strip() else []
    if cur:
        paras.append(cur)
    for para in paras:
        body = "\n".join(line for _, line in para)
        for m in re.finditer(r"`([^`]+)`", body):
            n = para[0][0] + body.count("\n", 0, m.start())
            out.append((n, "inline", m.group(1).replace("\n", " "), False))
    return sorted(out, key=lambda t: t[0])


ROOTED = r"(?:\$\{CLAUDE_PLUGIN_ROOT\}|\$\{?HR\}?|<harness root>)/"
REF = re.compile(r"(?<![\w/.$}>~-])((?:[\w.-]+/)*[\w.-]+\.(?:sh|py|md|json|ya?ml))(?![\w/-])")
INTERP = re.compile(r"(?:^|[\s;&|(\"'])(?:bash|sh|zsh|source|python3?|uv run(?: --with \S+)*)"
                    r"(?: -[\w-]+)*\s+[\"']?$")
# an assignment value stops at "(" so `VAR="$(bash "<rooted>")"` is not read as a bare run
ENV_PREFIX = r"\s*(?:[A-Za-z_][A-Za-z0-9_]*=[^\s(]*\s+)*[\"']?"
ARG_AFTER = re.compile(r"[\"']?\s+[^\s|;&)`>]")
CMD_ROOTED = re.compile(ENV_PREFIX + ROOTED + r"(?:[\w.-]+/)*[\w.-]+\.(?:sh|py)\b")
BAD_FORM = re.compile(r"\$\{CLAUDE_PLUGIN_ROOT[^}]|\$CLAUDE_PLUGIN_ROOT(?![\w{])")
HR_PATH = re.compile(r"\$\{?HR\}?/")
PATH_REFS = [(re.compile(r"\$\{CLAUDE_PLUGIN_ROOT\}/([^\s\"'`)>|;,]+)"), None),
             (re.compile(r"\$\{?HR\}?/([^\s\"'`)>|;,]+)"), ""),
             (re.compile(r"<harness root>/([^\s\"'`)>|;,]+)"), "")]

found = []
for path, plugin in docs:
    text = open(os.path.join(root, path), encoding="utf-8").read()
    lines = text.split("\n")
    if section == "a":
        for n, line in enumerate(lines, 1):
            if BAD_FORM.search(line):
                found.append("%s:%d: non-exact CLAUDE_PLUGIN_ROOT form" % (path, n))
    elif section == "b" and path not in CHECKOUT_ONLY:
        for n, kind, snip, cont in code(text):
            if any(p == path and s in lines[n - 1] for p, s, _ in ALLOW):
                continue
            for m in REF.finditer(snip):
                tok, before, after = m.group(1), snip[:m.start(1)], snip[m.end(1):]
                if before.count("<") > before.count(">"):
                    continue          # inside a <placeholder>
                # inside a "..." message that does not start with the path: not a call
                quoted = before.count('"') % 2 == 1 and not before.endswith('"')
                if tok.endswith((".sh", ".py")) and real_script(tok):
                    if (INTERP.search(before) or (not quoted and ARG_AFTER.match(after))
                            or (kind == "fence" and not cont and re.fullmatch(ENV_PREFIX, before))):
                        found.append("%s:%d: bare call to a harness script: %s" % (path, n, tok))
                elif own_skill_file(tok, os.path.join(root, path), plugin):
                    found.append("%s:%d: bare path to a skill file: %s" % (path, n, tok))
            if kind == "fence" and not cont and CMD_ROOTED.match(snip):
                found.append("%s:%d: harness script run without an interpreter" % (path, n))
            # a lone path is a mention; a path with more words around it is a command line
            if kind == "inline" and HR_PATH.search(snip) and len(snip.split()) > 1:
                found.append("%s:%d: inline command uses $HR/ - each Bash call is a fresh shell, "
                             "so HR is empty there; put the command in a fenced block that "
                             "sets HR first" % (path, n))
        # each Bash call is a fresh shell: a block that uses $HR resolves it itself
        fence, has_hr = False, False
        for n, line in enumerate(lines, 1):
            if FENCE.match(line):
                fence, has_hr = not fence, False
                continue
            body = re.sub(r"(^|\s)#.*$", "", line)
            if fence and re.match(r"\s*HR=", body):
                has_hr = True
            elif fence and re.search(r"\$\{?HR\}?\b", body) and not has_hr:
                found.append("%s:%d: uses $HR without resolving it in the same block" % (path, n))
    elif section == "c":
        for n, line in enumerate(lines, 1):
            for rx, base in PATH_REFS:
                for m in rx.finditer(line):
                    rel = m.group(1).rstrip(".:")
                    if re.search(r"[<*${]", rel):
                        continue
                    if not os.path.exists(os.path.join(root, plugin if base is None else base, rel)):
                        found.append("%s:%d: rooted path does not exist: %s" % (path, n, rel))
    elif section == "n" and path in CHECKOUT_ONLY and "harness-loop" not in path:
        if not re.search(r"harness checkout", text, re.I):
            found.append("%s: checkout-only skill does not say it runs from a harness checkout" % path)

for f in found:
    print("    " + f)
sys.exit(1 if found else 0)
PY
scan() { python3 -I "$TMP/scan.py" "$REPO_ROOT" "$1"; }

echo "=== (a) only the exact \${CLAUDE_PLUGIN_ROOT} form ==="
scan a; check "exact-plugin-root-form" $?

echo "=== (b) harness scripts and skill files are reached through a root ==="
scan b; check "no-bare-harness-calls" $?
scan n; check "checkout-only-skills-say-so" $?

echo "=== (c) rooted paths exist ==="
scan c; check "rooted-paths-exist" $?

echo "=== (d) scripts find their companion files from a project outside the harness ==="
PROJ="$TMP/project"; mkdir -p "$PROJ" && git -C "$PROJ" init -q
SLUG=plugin-root-fixture
# An empty environment for every call: no inherited AGENT_* variable (registry, harness root,
# plans dir, a memory dir the abort path would write to ...) can steer it off the lookup under test.
mkdir -p "$TMP/home"
CLEAN=(env -i HOME="$TMP/home" PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}")

# dryrun exits 2 only when the liveness canary cannot run the verifier
( cd "$PROJ" && "${CLEAN[@]}" AGENT_VERIFY_BLOCKING=dryrun \
    bash "$REPO_ROOT/core/infra/completion-gate.sh" "$SLUG" 1 >/dev/null 2>&1 )
check "gate-verifier-ships-with-the-gate" $?

if command -v sqlite3 >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  ( cd "$PROJ" && "${CLEAN[@]}" bash "$REPO_ROOT/core/infra/supervisor-goal.sh" init "$SLUG" 2 "" "fixture" >/dev/null 2>&1 )
  check "goal-schema-ships-with-the-helper" $?
  mkdir -p "$PROJ/.agent/plans/$SLUG"
  printf '## Wave 1: gate\n\n- verify: `bash core/infra/completion-gate.sh %s 1`\n\n## Wave 2: miss\n\n- verify: `test -f plugin-root-missing.txt`\n' \
    "$SLUG" > "$PROJ/.agent/plans/$SLUG/plan.md"
  ( cd "$PROJ" && "${CLEAN[@]}" bash "$REPO_ROOT/core/infra/supervisor-goal-audit.sh" "$SLUG" 1 >/dev/null 2>&1 )
  check "audit-runs-the-harness-gate" $?
  ( cd "$PROJ" && "${CLEAN[@]}" bash "$REPO_ROOT/core/infra/supervisor-goal-audit.sh" "$SLUG" 2 >/dev/null 2>&1 )
  RC=$?
  ST="$(cd "$PROJ" && "${CLEAN[@]}" bash "$REPO_ROOT/core/infra/supervisor-goal.sh" status "$SLUG" 2>/dev/null | jq -r '.status' 2>/dev/null)"
  [[ $RC -eq 1 && "$ST" == "aborted" ]]; check "audit-fail-aborts-through-the-harness-helper" $?
else
  echo "  skip [goal-state checks] (sqlite3 or jq absent)"
fi

# manager-audit and auto-ship need a run log / a live PR to reach these lines: pin the source.
RC=0
for f in completion-gate.sh supervisor-goal.sh supervisor-goal-audit.sh manager-audit.sh auto-ship.sh; do
  grep -qE '^HARNESS_ROOT="\$\(cd "\$\(dirname "\$\{BASH_SOURCE\[0\]\}"\)/\.\./\.\." && pwd\)"$' \
    "$REPO_ROOT/core/infra/$f" || { echo "    no HARNESS_ROOT line in $f"; RC=1; }
done
check "harness-root-from-script-location" $RC
grep -qE '^REGISTRY="\$\{AGENT_REGISTRY_PATH:-\$HARNESS_ROOT/agents/master-registry\.json\}"$' \
  "$REPO_ROOT/core/infra/manager-audit.sh"
check "registry-default-ships-with-the-audit" $?
grep -qE '^GUARD_SCAN="\$HARNESS_ROOT/core/infra/auto-ship-guard-scan\.py"$' "$REPO_ROOT/core/infra/auto-ship.sh"
check "guard-scan-ships-with-auto-ship" $?

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
