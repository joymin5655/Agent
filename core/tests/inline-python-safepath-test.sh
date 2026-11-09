#!/usr/bin/env bash
# inline-python-safepath-test.sh — inline Python in shipped shell code and skill instructions must
# not import from the working folder.
#
# `python3 -c '…'`, `python3 - <<'PY'` and `python3 -m mod` put the current working folder first on
# sys.path. Hooks and scripts run in the session's folder (the project being worked on), so a file
# there named like a standard module (json.py, re.py, …) or a harness module (hook_config.py) would
# run inside the hook. Two rules keep it out:
#   A  snippet that needs nothing from the user site (standard library only, or harness modules
#      that import only the standard library) -> `python3 -I` (isolated: no cwd, no user
#      site-packages)
#   B  snippet that needs a user-site package (PyYAML) -> its first statements drop the working
#      folder from sys.path (`sys.path[:] = [p for p in sys.path if p not in ("", …)]`) before
#      any import other than os / sys; `-I` would hide PyYAML.
#
# (1) static scan of every shipped shell file and of the shell code blocks in shipped skill, agent,
#     command, rule and template Markdown (git ls-files minus core/tests, docs, evals, .github and
#     the retired lanes in legacy/lanes-2026-10, which setup.sh no longer installs or links;
#     legacy/codex-shell-wrap stays in scope as the documented fallback when Codex native hooks
#     are off). A Python start that takes its program from -c, runs -m, or reads it from stdin
#     (`-`, a here-doc, a here-string, a redirect or a pipe) needs -I or the drop-before-import
#     shape. Code held in a variable is checked where the variable is filled (VAR_CODE); lines
#     that only name Python are in EXEMPT. An entry that no longer matches fails the test, so the
#     lists cannot rot.
# (2) dynamic: a git repo planted with stand-ins for standard and harness modules, each appending
#     its name to a marker file when imported; the scripts run with that folder as the working
#     folder and must neither import a stand-in nor change their decision.
#
# Usage: bash core/tests/inline-python-safepath-test.sh
# Exit 0: all pass. Exit 1: one or more failures.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1 — $2"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export AGENT_LOGS_DIR="$WORK/agent-logs"
export AGENT_GATE_SINK_DIR="$WORK/gate-sink"

echo "=== (1) static scan: every inline Python start carries -I or the drop-before-import shape ==="
SCAN_OUT="$WORK/scan.out"
(cd "$REPO_ROOT" && python3 -I -c '
import re, subprocess, sys

SKIP = ("core/tests/", "docs/", "evals/", "legacy/lanes-2026-10/", ".github/")
# Markdown an agent runs commands from: only lines inside shell code blocks count.
MD_DIRS = ("skills/", "extras/skills/", "agents/", "commands/", "rules/", "templates/")
SHELL_FENCES = ("", "bash", "sh", "shell", "zsh", "console")
# (file, fixed substring holding the Python start, reason) — lines that name Python without
# starting a snippet here.
EXEMPT = [
    ("core/hooks/pre-tool-guard.sh", "python3 -c \"$_RISK_PY\"",
     "code held in a variable; VAR_CODE checks the here-doc that fills it"),
    ("core/hooks/pre-tool-guard.sh", "or python3 -m pip install --user pyyaml",
     "message text shown to the user"),
    ("setup.sh", "(python3 -m pip install --user pyyaml)", "message text shown to the user"),
    ("setup.sh", "local pip_cmd=\"python3 -m pip install --user pyyaml\"",
     "command text, run through the harness root by the eval call"),
    ("setup.sh", "(python3 -c '"'"'import yaml'"'"' failed)", "message text shown to the user"),
]
# (file, variable): code read by `read -r -d "" VAR <<TAG` and run with `python3 -c "$VAR"`.
VAR_CODE = [("core/hooks/pre-tool-guard.sh", "_RISK_PY")]
DROP = re.compile(r"sys\.path\[:\]\s*=\s*\[p for p in sys\.path if p not in \(\s*\x22\x22\s*,")
HEREDOC = re.compile(r"<<-?\s*([\x27\"]?)(\w+)\1")
START = re.compile(r"(?<![\w.$-])(?:/[\w.-]+)*/?python3?(?:\.\d+)?\b|\$\{?PY[A-Z_]*(?::-[^}\s]*)?\}?")
IMPORT = re.compile(r"(?:^|[;\n:])[ \t]*(?:import[ \t]+([\w., \t]+)|from[ \t]+(\w+)[ \t]+import)")

def is_shell(path, text):
    if path.endswith((".sh", ".bash")):
        return True
    first = text.split("\n", 1)[0]
    return first.startswith("#!") and re.search(r"\b(ba)?sh\b", first) is not None

def drop_ok(body):
    m = DROP.search(body)
    if not m:
        return False
    head = body[:m.start()]
    if "__import__" in head or "importlib" in head:
        return False
    for imp in IMPORT.finditer(head):
        names = [n.split(" as ")[0].strip() for n in imp.group(1).split(",")] if imp.group(1) else [imp.group(2)]
        if any(n not in ("os", "sys") for n in names):
            return False
    return True

def piped(line, at):  # a shell pipe straight into the interpreter (not `a|python3` in a regex)
    return re.search(r"(?:^|\s)\|\s*[\x27\"]?$", line[:at]) is not None

def start_of(line, m):
    """Return (kind, flags, rest) for the Python start m, else None. kind: c / m / stdin."""
    flags = []
    want_arg = False
    for t in re.finditer(r"\s+(\S+)", line[m.end():]):
        w = t.group(1).lstrip("\"\x27")
        rest = line[m.end() + t.end():]
        if want_arg:  # the value of -W / -X
            want_arg = False
            continue
        if re.fullmatch(r"-[A-Za-z]+", w):
            flags.append(w)
            if w in ("-W", "-X"):
                want_arg = True
            elif w[-1] in "cm":
                return ("c" if w[-1] == "c" else "m"), flags, rest
            continue
        if w == "-" or w.startswith(("-<", "-\x27", "<")):
            return "stdin", flags, rest
        if w[:1] in ")|;&" and piped(line, m.start()):
            return "stdin", flags, rest
        return None
    return ("stdin", flags, "") if piped(line, m.start()) else None

def exempt_for(path, line, at):
    for e in EXEMPT:
        if e[0] != path:
            continue
        p = line.find(e[1])
        while p != -1:
            if p <= at < p + len(e[1]):
                return e
            p = line.find(e[1], p + 1)
    return None

ls = subprocess.run(["git", "ls-files", "-z"], capture_output=True)
if ls.returncode != 0:
    print("SUMMARY git ls-files failed: " + ls.stderr.decode(errors="replace").strip()[:200])
    sys.exit(1)
bad = []
matched = set()
var_seen = set()
for path in ls.stdout.decode().split("\0"):
    if not path or path.startswith(SKIP):
        continue
    try:
        text = open(path, encoding="utf-8").read()
    except (OSError, UnicodeDecodeError):
        continue
    lines = text.split("\n")
    if is_shell(path, text):
        idx = range(len(lines))
    elif path.endswith(".md") and path.startswith(MD_DIRS):
        idx, fence = [], None
        for i, line in enumerate(lines):
            s = line.strip()
            if s.startswith("```"):
                fence = None if fence is not None else s[3:].strip().lower()
                continue
            if fence in SHELL_FENCES:
                idx.append(i)
    else:
        continue
    for vpath, var in VAR_CODE:
        if vpath == path:
            var_seen.add((vpath, var))
            h = re.search(r"read -r -d \x27\x27 " + var + r" <<-?\x27(\w+)\x27", text)
            vbody = text[h.end():].split("\n" + h.group(1) + "\n", 1)[0] if h else ""
            if not drop_ok(vbody):
                bad.append("%s: the code in %s does not drop the working folder first" % (path, var))
    done = -1
    for i in idx:
        if i <= done or lines[i].lstrip().startswith("#"):
            continue
        full, last = lines[i], i
        while full.rstrip().endswith("\\") and last + 1 < len(lines):
            last += 1
            full = full.rstrip()[:-1] + " " + lines[last]
        done = last
        for m in START.finditer(full):
            s = start_of(full, m)
            if not s:
                continue
            kind, flags, rest = s
            e = exempt_for(path, full, m.start())
            if e:
                matched.add(e)
                continue
            if any("I" in f for f in flags):
                continue
            body = None
            if kind == "c":
                q = rest.lstrip()[:1]
                if q in ("\x27", "\""):
                    buf = rest.lstrip()[1:]
                    j = last
                    while q not in buf and j + 1 < len(lines):
                        j += 1
                        buf += "\n" + lines[j]
                    body = buf
            elif kind == "stdin":
                h = HEREDOC.search(full)
                if h:
                    buf = []
                    for k in range(last + 1, len(lines)):
                        if lines[k].strip() == h.group(2):
                            break
                        buf.append(lines[k])
                    body = "\n".join(buf)
            if body is None or not drop_ok(body):
                bad.append("%s:%d: %s" % (path, i + 1, full.strip()[:110]))
stale = [e for e in EXEMPT if e not in matched] + [v for v in VAR_CODE if v not in var_seen]
for b in bad:
    print("VIOLATION " + b)
for e in stale:
    print("STALE-EXEMPTION %s :: %s" % (e[0], e[1]))
print("SUMMARY violations=%d stale=%d" % (len(bad), len(stale)))
' ) > "$SCAN_OUT" 2>&1
if grep -q '^SUMMARY violations=0 stale=0$' "$SCAN_OUT"; then
  ok "static scan — every inline Python start is isolated or drops the working folder"
else
  bad "static scan" "see lines below"
  sed 's/^/        /' "$SCAN_OUT" | head -n 60
fi

echo
echo "=== (2) dynamic: planted stand-in modules in the working folder are never imported ==="
PLANT="$WORK/planted"
mkdir -p "$PLANT/.agent"
git -C "$PLANT" init -q
git -C "$PLANT" config user.email "test@example.com"
git -C "$PLANT" config user.name "test"
for m in json re fnmatch hashlib tempfile datetime yaml hook_config gather_sources; do
  cat > "$PLANT/$m.py" <<PYMOD
import os
with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "IMPORTED.marker"), "a") as _f:
    _f.write("$m\n")
PYMOD
done
MARKER="$PLANT/IMPORTED.marker"

# Event JSON is built from a neutral folder so the planted files never touch the harness-side calls.
mk_event() {  # mk_event <tool_name> <tool_input-json>
  (cd "$WORK" && python3 -I -c 'import json,sys; print(json.dumps({"event":"PreToolUse","hook_event_name":"PreToolUse","tool_name":sys.argv[1],"tool_input":json.loads(sys.argv[2])}))' "$1" "$2")
}
decision_of() {
  case "$1" in
    *'"permissionDecision": "deny"'*) echo deny ;;
    *'"permissionDecision": "ask"'*)  echo ask ;;
    *)                                echo allow ;;
  esac
}
check_marker() {  # check_marker <label>
  if [[ -e "$MARKER" ]]; then
    bad "$1" "a planted module was imported: $(tr '\n' ' ' < "$MARKER")"
  else
    ok "$1 — no planted module imported"
  fi
  rm -f "$MARKER"
}

# 2a: council-threshold.sh --classify loads project secret paths through hook_config. The project
# folder is pinned: the script prefers AGENT_PROJECT_DIR / CLAUDE_PROJECT_DIR over git.
printf '%s\n' '{"risk_areas": {"secrets": {"paths": ["vault/"]}}}' > "$PLANT/.agent/hook-config.json"
OUT_A="$(cd "$PLANT" && printf 'vault/token.dat\0docs/readme.txt\0' | AGENT_PROJECT_DIR="$PLANT" bash "$REPO_ROOT/core/infra/council-threshold.sh" --classify 2>/dev/null | tr '\0' '|')"
if [[ "$OUT_A" == "vault/token.dat|" ]]; then
  ok "2a council-threshold --classify still classifies the declared secret path"
else
  bad "2a council-threshold --classify result" "got '$OUT_A', want 'vault/token.dat|'"
fi
check_marker "2a council-threshold --classify"
rm -f "$PLANT/.agent/hook-config.json"

# 2b: pre-tool-guard.sh risk-area extension (_RISK_PY) and the declared secret path (guard 11b).
# Declared in JSON (needs no PyYAML, so it always runs) and, when PyYAML is importable, in YAML —
# the case rule B exists for: PyYAML must stay importable from the user site.
run_2b() {  # run_2b <label>
  local ev out got
  ev="$(mk_event Bash '{"command":"git add billing/plan.py"}')"
  out="$(cd "$PLANT" && printf '%s' "$ev" | AGENT_PROJECT_DIR="$PLANT" bash "$REPO_ROOT/core/hooks/pre-tool-guard.sh" 2>/dev/null || true)"
  got="$(decision_of "$out")"
  if [[ "$got" == "deny" ]]; then ok "2b $1: risk-area extension still denies a declared payment path"; else bad "2b $1: risk-area decision" "want=deny got=$got :: $out"; fi
  check_marker "2b $1: pre-tool-guard risk extension"
  ev="$(mk_event Bash '{"command":"cat vault/notes.txt"}')"
  out="$(cd "$PLANT" && printf '%s' "$ev" | AGENT_PROJECT_DIR="$PLANT" bash "$REPO_ROOT/core/hooks/pre-tool-guard.sh" 2>/dev/null || true)"
  got="$(decision_of "$out")"
  if [[ "$got" == "deny" ]]; then ok "2b $1: declared secret path still denied"; else bad "2b $1: secret-path decision" "want=deny got=$got :: $out"; fi
  check_marker "2b $1: pre-tool-guard secret path"
}
printf '%s\n' '{"risk_areas": {"secrets": {"paths": ["vault/**"], "decision": "deny"}, "payment": {"pattern": "^billing/", "decision": "deny"}}}' > "$PLANT/.agent/hook-config.json"
run_2b json
rm -f "$PLANT/.agent/hook-config.json"
if ! (cd "$WORK" && python3 -c 'import yaml' 2>/dev/null); then
  echo "  SKIP  2b yaml — PyYAML not importable (the JSON run above covers the same snippet)"
else
  cat > "$PLANT/.agent/hook-config.yml" <<'YML'
risk_areas:
  secrets:
    paths:
      - 'vault/**'
    decision: deny
  payment:
    pattern: '^billing/'
    decision: deny
YML
  run_2b yaml
  rm -f "$PLANT/.agent/hook-config.yml"
fi

# 2c: a Rule A hook on its Python path — context-mode-guard.sh deny (log line + decision JSON).
if ! command -v jq >/dev/null 2>&1; then
  echo "  SKIP  2c context-mode-guard — jq not installed (the guard needs it)"
else
  SEC="secr""ets/"   # assembled: keeps a literal secrets/ read out of this file's source text
  EV_C="$(mk_event mcp__plugin_context-mode_context-mode__ctx_execute "{\"language\":\"shell\",\"code\":\"cat ${SEC}app.key\"}")"
  OUT_C="$(cd "$PLANT" && printf '%s' "$EV_C" | bash "$REPO_ROOT/adapters/claude-code/adapter.sh" context-mode-guard.sh 2>/dev/null || true)"
  GOT_C="$(decision_of "$OUT_C")"
  if [[ "$GOT_C" == "deny" ]]; then ok "2c context-mode-guard still denies a secret-path read"; else bad "2c context-mode-guard decision" "want=deny got=$GOT_C :: $OUT_C"; fi
  check_marker "2c context-mode-guard"
fi

echo
echo "$PASS passed / $FAIL failed"
[[ "$FAIL" -eq 0 ]]
