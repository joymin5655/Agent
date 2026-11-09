#!/usr/bin/env bash
# inline-python-safepath-test.sh — inline Python in shipped shell code must not import from the
# working folder.
#
# `python3 -c '…'`, `python3 - <<'PY'` and `python3 -m mod` put the current working folder first on
# sys.path. Hooks and scripts run in the session's folder (the project being worked on), so a file
# there named like a standard module (json.py, re.py, …) or a harness module (hook_config.py) would
# run inside the hook. Two rules keep it out:
#   A  standard-library-only snippet  -> `python3 -I` (isolated: no cwd, no user site-packages)
#   B  snippet that loads harness modules or PyYAML (user site) -> its first statements drop the
#      working folder from sys.path (`sys.path[:] = [p for p in sys.path if p not in (…)]`) before
#      any import other than os / sys.
#
# (1) static scan of every shipped shell file (git ls-files minus core/tests, docs, evals, .github
#     and the retired lanes in legacy/lanes-2026-10, which setup.sh no longer installs or links;
#     legacy/codex-shell-wrap stays in scope as the documented fallback when Codex native hooks
#     are off): each Python start with -c / - / -m needs -I or the drop-before-import shape. Code
#     held in a variable and text lines are in EXEMPT below; an exemption that no longer matches a
#     line fails the test, so the list cannot rot.
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
(cd "$REPO_ROOT" && git ls-files -z | python3 -I -c '
import re, subprocess, sys

SKIP = ("core/tests/", "docs/", "evals/", "legacy/lanes-2026-10/", ".github/")
# (file, fixed substring, reason) — lines that name Python without starting a snippet here.
EXEMPT = [
    ("core/hooks/pre-tool-guard.sh", "-c \"$_RISK_PY\"",
     "code held in a variable; its first statements are the drop (dynamic check 2b covers it)"),
    ("core/hooks/pre-tool-guard.sh", "or python3 -m pip install --user pyyaml",
     "message text shown to the user"),
    ("setup.sh", "(python3 -m pip install --user pyyaml)", "message text shown to the user"),
    ("setup.sh", "local pip_cmd=\"python3 -m pip install --user pyyaml\"",
     "command text, run through the harness root by the eval call"),
    ("setup.sh", "(python3 -c '"'"'import yaml'"'"' failed)", "message text shown to the user"),
]
DROP = re.compile(r"sys\.path\[:\]\s*=\s*\[p for p in sys\.path if p not in \(")
HEREDOC = re.compile(r"<<-?\s*([\x27\"]?)(\w+)\1")
START = re.compile(r"(?<![\w./$-])python3?\b")

def is_shell(path, text):
    if path.endswith((".sh", ".bash")):
        return True
    first = text.split("\n", 1)[0]
    return first.startswith("#!") and re.search(r"\b(ba)?sh\b", first) is not None

def drop_ok(body):
    m = DROP.search(body)
    if not m:
        return False
    for imp in re.finditer(r"(?:^|[;\n])[ \t]*(?:import[ \t]+([\w., \t]+)|from[ \t]+(\w+)[ \t]+import)", body[:m.start()]):
        names = [n.split(" as ")[0].strip() for n in imp.group(1).split(",")] if imp.group(1) else [imp.group(2)]
        if any(n not in ("os", "sys") for n in names):
            return False
    return True

def start_of(line, at):
    """Return (kind, flags, rest) for a python start with -c / - / -m at `at`, else None."""
    toks = re.compile(r"\s+(\S+)").finditer(line, at + len(START.match(line, at).group(0)))
    flags = []
    for t in toks:
        w = t.group(1).lstrip("\"")
        if re.fullmatch(r"-[A-Za-z]+", w):
            flags.append(w)
            if w[-1] in "cm":
                return ("c" if w[-1] == "c" else "m"), flags, line[t.end():]
            continue
        if w == "-" or w.startswith("-<") or w.startswith("-\x27"):
            return "stdin", flags, line[t.end():]
        return None
    return None

bad = []
matched = set()
files = subprocess.run(["git", "ls-files", "-z"], capture_output=True).stdout.decode().split("\0")
for path in files:
    if not path or path.startswith(SKIP):
        continue
    try:
        text = open(path, encoding="utf-8").read()
    except (OSError, UnicodeDecodeError):
        continue
    if not is_shell(path, text):
        continue
    lines = text.split("\n")
    for i, line in enumerate(lines):
        if line.lstrip().startswith("#"):
            continue
        for m in START.finditer(line):
            s = start_of(line, m.start())
            if not s:
                continue
            kind, flags, rest = s
            exempt = [e for e in EXEMPT if e[0] == path and e[1] in line]
            for e in exempt:
                matched.add(e)
            if exempt or any("I" in f for f in flags):
                continue
            body = None
            if kind == "c":
                q = rest.lstrip()[:1]
                if q in ("\x27", "\""):
                    buf = rest.lstrip()[1:]
                    j = i
                    while q not in buf and j + 1 < len(lines):
                        j += 1
                        buf += "\n" + lines[j]
                    body = buf
            elif kind == "stdin":
                h = HEREDOC.search(line)
                if h:
                    buf = []
                    for k in range(i + 1, len(lines)):
                        if lines[k].strip() == h.group(2):
                            break
                        buf.append(lines[k])
                    body = "\n".join(buf)
            if body is None or not drop_ok(body):
                bad.append("%s:%d: %s" % (path, i + 1, line.strip()[:110]))
stale = [e for e in EXEMPT if e not in matched]
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

# 2a: council-threshold.sh --classify loads project secret paths through hook_config.
printf '%s\n' '{"risk_areas": {"secrets": {"paths": ["vault/"]}}}' > "$PLANT/.agent/hook-config.json"
OUT_A="$(cd "$PLANT" && printf 'vault/token.dat\0docs/readme.txt\0' | bash "$REPO_ROOT/core/infra/council-threshold.sh" --classify 2>/dev/null | tr '\0' '|')"
if [[ "$OUT_A" == "vault/token.dat|" ]]; then
  ok "2a council-threshold --classify still classifies the declared secret path"
else
  bad "2a council-threshold --classify result" "got '$OUT_A', want 'vault/token.dat|'"
fi
check_marker "2a council-threshold --classify"
rm -f "$PLANT/.agent/hook-config.json"

# 2b: pre-tool-guard.sh risk-area extension (_RISK_PY) and the declared secret path (guard 11b).
if ! (cd "$WORK" && python3 -c 'import yaml' 2>/dev/null); then
  echo "  SKIP  2b pre-tool-guard risk extension — PyYAML not importable (the guard's own skip reason)"
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
  EV_B="$(mk_event Bash '{"command":"git add billing/plan.py"}')"
  OUT_B="$(cd "$PLANT" && printf '%s' "$EV_B" | AGENT_PROJECT_DIR="$PLANT" bash "$REPO_ROOT/core/hooks/pre-tool-guard.sh" 2>/dev/null || true)"
  GOT_B="$(decision_of "$OUT_B")"
  if [[ "$GOT_B" == "deny" ]]; then ok "2b risk-area extension still denies a declared payment path"; else bad "2b risk-area decision" "want=deny got=$GOT_B :: $OUT_B"; fi
  check_marker "2b pre-tool-guard risk extension"
  EV_B2="$(mk_event Bash '{"command":"cat vault/notes.txt"}')"
  OUT_B2="$(cd "$PLANT" && printf '%s' "$EV_B2" | AGENT_PROJECT_DIR="$PLANT" bash "$REPO_ROOT/core/hooks/pre-tool-guard.sh" 2>/dev/null || true)"
  GOT_B2="$(decision_of "$OUT_B2")"
  if [[ "$GOT_B2" == "deny" ]]; then ok "2b declared secret path still denied"; else bad "2b secret-path decision" "want=deny got=$GOT_B2 :: $OUT_B2"; fi
  check_marker "2b pre-tool-guard secret path"
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
