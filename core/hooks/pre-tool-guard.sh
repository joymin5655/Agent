#!/usr/bin/env bash
# PreToolUse hook — Bash command safety guards
#
# Catches dangerous shell command patterns before they execute:
#   - Broad destructive deletion (rm -r at / ~ $HOME ../, find -delete, rsync --delete, git clean -f)
#   - Force push to main/master (--force, -f, --force-with-lease, +main)
#   - git reset --hard; checkout -- / restore / switch --discard-changes on a dirty tree
#   - Environment dumps (env, printenv, export -p, declare -x, set, ps eww) - guard 3a
#   - DROP/TRUNCATE TABLE (ask — risk area #1, production-data)
#   - Direct secrets/.env access (deny — risk area #2, secrets)
#     covers 45+ command variants (read, copy, hash, compress, crypto, exfil, redirect, find -exec, xargs)
#   - Hardcoded "data/artifacts/ git add" (project-customizable)
#
# Hook protocol: reads canonical event JSON from stdin, writes decision JSON
# (deny / ask) to stdout, or empty stdout for allow. Exit always 0.
#
# Every deny/ask reason is a TEACHING message (T-1): it carries a `WHY:` line
# (which rule fired and why it exists) and a `FIX:` line (the concrete allowed
# alternative), so a blocked agent can self-correct instead of routing around.
#
# See docs/hook-protocol.md for the canonical contract.

# python3 runs with -I here: a json.py (or re.py) in the working directory would otherwise be
# imported in place of the standard module, and a stub that exits quietly blanks the parsed command
# so that every guard sees nothing. (The PyYAML probe further down keeps the user site on purpose
# and removes the working directory from sys.path itself.)
INPUT=$(cat)
# AG21: decode the command in ONE step that cannot raise on text. A lone surrogate (`\ud800`) is legal
# JSON and loads fine, but printing the str raised UnicodeEncodeError, and the old `2>/dev/null || echo ""`
# turned that into an empty command that every guard below allowed. Surrogates are written as visible
# `\udXXX` text instead, so the guards see the rest of the command unchanged. A decode that fails
# (not JSON, not an object, tool_input of the wrong type, interpreter error) exits non-zero and is
# denied further down, once emit_deny exists - never read as "no command". No event, or an event
# with no tool_input.command (another tool), is not a failure and stays an allow.
COMMAND=$(printf '%s' "$INPUT" | python3 -I -c '
import json, sys
raw = sys.stdin.buffer.read().decode("utf-8", "replace")
if not raw.strip():
    sys.exit(0)
try:
    event = json.loads(raw)
except ValueError:
    sys.exit(3)
if not isinstance(event, dict):
    sys.exit(3)
tool_input = event.get("tool_input")
if tool_input is None:
    sys.exit(0)
if not isinstance(tool_input, dict):
    sys.exit(3)
command = tool_input.get("command")
if command is None:
    command = ""
elif not isinstance(command, str):
    command = str(command)
sys.stdout.buffer.write(command.encode("utf-8", "backslashreplace"))
'); _DECODE_RC=$?

# The guard finds event_decode.sh next to its real file, however it was started: a bare relative
# path has no slash in BASH_SOURCE (so ${x%/*} would be the file name itself) and a symlink points
# elsewhere. If the helper cannot be loaded the guard cannot decide anything, and an empty stdout
# would read as allow: print a minimal deny (no helper, no python3 needed) and stop.
_GUARD_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_GUARD_SRC" ]]; do
  _GUARD_LINK=$(readlink "$_GUARD_SRC") || break
  case "$_GUARD_LINK" in
    /*) _GUARD_SRC="$_GUARD_LINK" ;;
    *)  _GUARD_SRC="$(dirname "$_GUARD_SRC")/$_GUARD_LINK" ;;
  esac
done
case "$_GUARD_SRC" in */*) _GUARD_DIR="${_GUARD_SRC%/*}" ;; *) _GUARD_DIR="." ;; esac
# shellcheck source=event_decode.sh
if ! source "$_GUARD_DIR/event_decode.sh" 2>/dev/null; then
  printf '%s\n' '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "pre-tool-guard.sh could not load event_decode.sh from its own directory (blocked fail-closed).\nWHY: without the helper no guard can read or answer the command, and an empty answer would read as allow.\nFIX: restore core/hooks/event_decode.sh next to pre-tool-guard.sh (re-run setup.sh or git checkout the file)."}}'
  exit 0
fi

emit_deny() { hook_emit_decision deny "$1"; }

emit_ask() { hook_emit_decision ask "$1"; }

# Append to .agent/logs/security-violations.jsonl (silent-fail).
log_violation() {
  local guard="$1" reason="$2" decision="${3:-deny}"
  local repo_root="${AGENT_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}}"
  [[ -z "$repo_root" ]] && return 0
  # AGENT_GATE_SINK_DIR (X-5): test runners redirect gate records away from the live sink.
  local log_dir="${AGENT_GATE_SINK_DIR:-$repo_root/.agent/logs}"
  local log_file="$log_dir/security-violations.jsonl"
  mkdir -p "$log_dir" 2>/dev/null || return 0
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local sid="${AGENT_SESSION_ID:-main}"
  local repro="false"
  case "${AGENT_REPRODUCE_TEST:-}" in 1|true|TRUE|True) repro="true" ;; esac
  # W1-4: origin tags the record so a test-battery-produced block is
  # distinguishable from a real-session block (all 7,443 prior records carry
  # session_id=main, so origin is the only way to tell them apart).
  local origin="${AGENT_LOG_ORIGIN:-session}"
  origin="${origin//[^A-Za-z0-9_.-]/}"   # keep the JSON well-formed whatever the env holds
  printf '{"ts":"%s","guard":"%s","hook":"pre-tool-guard.sh","reason":%s,"session_id":"%s","decision":"%s","reproduce_test":%s,"origin":"%s","schema_version":"2.0.0"}\n' \
    "$ts" "$guard" "$(printf '%s' "$reason" | python3 -I -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo "\"$reason\"")" "$sid" "$decision" "$repro" "$origin" \
    >> "$log_file" 2>/dev/null || true
  [[ -x "$repo_root/core/infra/agent-session.sh" ]] && \
    "$repo_root/core/infra/agent-session.sh" broadcast blocked \
      "[security] pre-tool-guard.sh: $reason" >/dev/null 2>&1 || true
}

if [[ $_DECODE_RC -ne 0 ]]; then
  log_violation decode "hook input could not be decoded (rc=$_DECODE_RC)"
  emit_deny "Hook input could not be decoded, so no guard could read the command (blocked fail-closed).
WHY: an undecodable event looks the same to every guard as an empty command, and an empty command passes them all; allowing it would let any text the decoder chokes on carry a blocked command through.
FIX: send the tool call again as plain JSON text; if the event itself is malformed, report it - do not wrap the command to dodge this check."
  exit 0
fi

# W-7: strip commit-MESSAGE payloads before the destructive guards (1-4 and the ones after), so a
# message that merely MENTIONS a destructive command ("fix: guard rm -rf /") is not blocked.
# AG22 r1: the stripper works on SHELL WORDS. It replaces the value word of a message option
# (-m, -am, -nm, --message, --message=) of git commit/tag/merge/notes/stash, and only when that word
# is exactly one quoted string:
#   - single quotes                  - shell-literal, always inert;
#   - double quotes                  - only when free of $ and backtick (nothing can expand) and of
#     backslashes other than the surrogate spelling \udXXX the decoder writes;
#   - "$(cat <<'EOF' ... EOF)"       - the standard multi-line idiom; the heredoc delimiter must be
#     QUOTED (an unquoted body still undergoes command substitution).
# A " -m " inside another quoted string (echo, printf, ...), a message option of any other command, a
# word that is not one whole quoted string, and anything the lexer cannot read with certainty (an
# unterminated quote, an unmatched parenthesis) stay in the scanned text: the old regex matched the
# flag anywhere and its double-quote pattern ran across quote boundaries to the next quote character,
# which hid real commands (rm, force push, reset, DROP) between two quoted flag-like texts.
# Secrets guards (5+) keep scanning the FULL command: -m "$(cat secrets/key)" is a real read, not a
# mention. A python failure falls back to the full command (fail-safe = scan more, never less).
# The program has no apostrophe or backtick on purpose and is read into a variable first (bash 3.2
# mis-parses unpaired ones inside a command substitution that holds a heredoc).
IFS= read -r -d '' _STRIP_PY <<'PY'
import re
import sys

# Commit-message stripper (W-7), word based. Only the value word of a message option of a git
# subcommand that takes one is replaced, and only when that word is one whole quoted string.
# Anything the lexer cannot read with certainty leaves the command untouched (more scanning).

SEPARATORS = ";&|()\n"
HEREDOC_MSG = re.compile(r"\x22\$\(\s*cat\s+<<-?[\x27\x22](\w+)[\x27\x22]\n.*?\n\1\n?\s*\)\x22", re.S)
SURROGATE_TEXT = r"\\u[dD][89a-fA-F][0-9a-fA-F]{2}"
DQ_INERT = re.compile(r"(?:[^\x22$\x60\\]|" + SURROGATE_TEXT + r")*")
MSG_OPTION = re.compile(r"-[A-Za-z]*m")
ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=\S*")
PREFIX_WORDS = {"command", "env", "exec", "sudo", "time", "nice", "then", "do", "else", "!", "{"}
GIT_OPTIONS_WITH_VALUE = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"}
MESSAGE_SUBCOMMANDS = {"commit", "tag", "merge", "notes", "stash"}
QUICK = re.compile(r"\s-[A-Za-z]*m(?![A-Za-z])|\s--message")


class Unreadable(Exception):
    pass


def skip_double(s, i):
    # s[i] is a double quote; return the index after the closing one
    n = len(s)
    i += 1
    while i < n:
        c = s[i]
        if c == "\\":
            i += 2
        elif c == "\x22":
            return i + 1
        elif c == "$" and s.startswith("(", i + 1):
            i = skip_paren(s, i + 1)
        elif c == "\x60":
            i = skip_tick(s, i)
        else:
            i += 1
    raise Unreadable()


def skip_tick(s, i):
    j = i + 1
    while j < len(s):
        if s[j] == "\\":
            j += 2
        elif s[j] == "\x60":
            return j + 1
        else:
            j += 1
    raise Unreadable()


def skip_paren(s, i):
    # s[i] is an opening paren; return the index after its matching close
    depth = 0
    n = len(s)
    while i < n:
        c = s[i]
        if c == "\\":
            i += 2
            continue
        if c == "\x27":
            j = s.find("\x27", i + 1)
            if j < 0:
                raise Unreadable()
            i = j + 1
            continue
        if c == "\x22":
            i = skip_double(s, i)
            continue
        if c == "\x60":
            i = skip_tick(s, i)
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise Unreadable()


def read_word(s, i):
    n = len(s)
    while i < n:
        c = s[i]
        if c in " \t" or c in SEPARATORS:
            break
        if c == "\\":
            i += 2
        elif c == "\x27":
            j = s.find("\x27", i + 1)
            if j < 0:
                raise Unreadable()
            i = j + 1
        elif c == "\x22":
            i = skip_double(s, i)
        elif c == "\x60":
            i = skip_tick(s, i)
        elif c == "$" and s.startswith("(", i + 1):
            i = skip_paren(s, i + 1)
        else:
            i += 1
    return min(i, n)


def lex(s):
    # simple commands as lists of (start, end, kind); kind is heredoc for the cat idiom, else word
    commands = []
    current = []
    i = 0
    n = len(s)
    while i < n:
        c = s[i]
        if c in " \t":
            i += 1
        elif c in SEPARATORS:
            if current:
                commands.append(current)
                current = []
            i += 1
        elif c == "#":
            j = s.find("\n", i)
            i = n if j < 0 else j
        else:
            m = HEREDOC_MSG.match(s, i) if c == "\x22" else None
            if m:
                current.append((i, m.end(), "heredoc"))
                i = m.end()
            else:
                j = read_word(s, i)
                if j <= i:
                    raise Unreadable()
                current.append((i, j, "word"))
                i = j
    if current:
        commands.append(current)
    return commands


def message_replacement(s, start, end, kind):
    # (start, end) of the text to replace when the word is an inert whole quoted string, else None
    raw = s[start:end]
    if kind == "heredoc":
        return (start, end)
    if len(raw) >= 2 and raw[0] == "\x27" and raw[-1] == "\x27" and "\x27" not in raw[1:-1]:
        return (start, end)
    if len(raw) >= 2 and raw[0] == "\x22" and raw[-1] == "\x22" and DQ_INERT.fullmatch(raw[1:-1]):
        return (start, end)
    return None


def git_message_start(s, words):
    # index of the first word after the git subcommand when the command takes message options
    k = 0
    while k < len(words):
        raw = s[words[k][0]:words[k][1]]
        if ASSIGNMENT.fullmatch(raw) or raw in PREFIX_WORDS:
            k += 1
        else:
            break
    if k >= len(words) or s[words[k][0]:words[k][1]] != "git":
        return None
    k += 1
    while k < len(words):
        raw = s[words[k][0]:words[k][1]]
        if raw in GIT_OPTIONS_WITH_VALUE:
            k += 2
        elif raw.startswith("-"):
            k += 1
        else:
            break
    if k >= len(words) or s[words[k][0]:words[k][1]] not in MESSAGE_SUBCOMMANDS:
        return None
    return k + 1


def strip(s):
    if not QUICK.search(s):
        return s
    try:
        commands = lex(s)
    except (Unreadable, RecursionError):
        return s
    edits = []
    for words in commands:
        k = git_message_start(s, words)
        if k is None:
            continue
        while k < len(words):
            start, end, kind = words[k]
            raw = s[start:end]
            if kind == "word" and (MSG_OPTION.fullmatch(raw) or raw == "--message"):
                if k + 1 < len(words):
                    hit = message_replacement(s, *words[k + 1])
                    if hit:
                        edits.append(hit)
                k += 2
            elif kind == "word" and raw.startswith("--message="):
                body = start + len("--message=")
                hit = message_replacement(s, body, end, "word")
                if hit:
                    edits.append(hit)
                k += 1
            else:
                k += 1
    for start, end in sorted(set(edits), reverse=True):
        s = s[:start] + "<msg>" + s[end:]
    return s


if __name__ == "__main__":
    raw = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
    sys.stdout.buffer.write(strip(raw).encode("utf-8", "surrogateescape"))
PY
SCAN_CMD=$(printf '%s' "$COMMAND" | python3 -I -c "$_STRIP_PY"
) || SCAN_CMD="$COMMAND"
[[ -z "$SCAN_CMD" && -n "$COMMAND" ]] && SCAN_CMD="$COMMAND"

# 1. Broad destructive deletion
if echo "$SCAN_CMD" | grep -qE 'rm\s+(-rf|-fr)\s+(/|~|\$HOME|\.\./)'; then
  log_violation destructive "broad rm -rf blocked"
  emit_deny "Broad rm -rf to root / home / parent blocked.
WHY: destructive-deletion guard — an unscoped recursive delete is unrecoverable and can take the whole workspace with it.
FIX: delete the specific target explicitly (e.g. rm -rf ./<dir>) after verifying it with ls, or move it aside instead of deleting."
  exit 0
fi

# 2. Force push to protected branches
if echo "$SCAN_CMD" | grep -qE 'git\s+push\s+.*--force.*\s+(main|master)'; then
  log_violation destructive "force push to main/master blocked"
  emit_deny "Force push to main/master blocked.
WHY: R6 — rewriting a protected branch's history breaks every other clone and open PR based on it.
FIX: push to a feature branch and open a PR; on your own branch use git push --force-with-lease."
  exit 0
fi

# 3. git reset --hard
if echo "$SCAN_CMD" | grep -qE 'git\s+reset\s+--hard'; then
  log_violation destructive "git reset --hard blocked"
  emit_deny "git reset --hard blocked.
WHY: destructive guard — it discards uncommitted work with no recovery path.
FIX: git stash (keeps the work), git restore <path> for single files, or git revert <sha> for committed changes."
  exit 0
fi

# 3a. Dangerous commands in command position, judged on guard 5's Lexer (stage 2 below shares one
# program text, $_S5_PY: the same quote / substitution / heredoc / ANSI-C handling, depth and work
# limits, and a wall-clock alarm). Rules: git clean -f, the discard-changes family (checkout -- / restore /
# switch --discard-changes, stash drop|clear), force push to main/master in short forms (-f, --force-with-
# lease, +main), environment dumps (env / printenv / export -p / declare -x / set / ps e|eww|-E, a
# /proc/<pid>/environ read), recursive rm at / ~ $HOME ../, find -delete|-exec rm and rsync --delete* at
# those roots. Ported from the local destructive-guard / env-dump-guard. git clean / discard decisions
# probe `git status` (memoised, capped, 4 s each, 10 s total) and ask when the work tree state cannot be
# established (a cd, GIT_DIR, --git-dir, repeated -C or an earlier non-read-only command in the chain).
# A deny is emitted here; an ask is held to the end of the file so any later deny (4a/4b, secrets, risk
# areas) still wins. NO answer from the scan (crash, kill, alarm, garbled output) is a deny, like stage 2.
# A command the Lexer cannot parse, or a shell fed by a pipe, is denied only when a dangerous word is
# present (coarse text match). Not covered: $( ) values built at run time, python -c one-liners, scripts
# written and run later.
IFS= read -r -d '' _S5_PY <<'PY'
import fnmatch
import os
import re
import shlex
import signal
import sys

# Stage 2 of guard 5 (secrets/ read). Prints one word: `reader` (a guard verb reads a
# secrets/ operand), `doubt` (no such operand, but the secrets/ path can still reach a reader
# through a variable, loop, substitution, cd or a program this scan does not know), `inert`
# (parsed, and provably neither), `unparseable` (a construct this scan does not model, or one that
# bash and zsh read differently), `limit` (the work or nesting budget ran out) or `error` (a bug).
# The caller denies on anything but `inert` (stage-1 candidates), so a lexer limit, an
# unbalanced quote, a crash, a spent work budget or a killed process (no output at all) can
# only ever keep the old deny, never open a hole.
# A path need not be written out: `spells` also reads an operand by its shape (a glob, a brace group, or
# pieces such as "$A"rets), and `carries` a word that hands a name on (D=secrets, for d in s*, echo secrets).
MAX_DEPTH = 8
MAX_WORK = 400000  # word visits per command line: a launcher chain re-searches its own tail (2^n)
BUDGET_SECONDS = 2.0  # wall clock; a hook that outlives its own timeout lets the call through
PH = "\x00"  # stands for an expansion whose value is unknown
DYN = "\x01"  # marks a plain $name / $1 / $@ expansion inside a word
SPL = "\x02"  # marks an unquoted expansion: its result is split into words
RSH = "\x03"  # marks a value a command or a ${x#y} may have reshaped, quoted or not: $(echo ' a' | cut -d' ' -f2)
IN = "\x04"  # leads a redirect target that is read from (< and <>)
END = "\x05"  # closes the expansion that DYN or PH opened: $name, ${...}, $(...), `...`, <(...)
UNK = "\x06"  # stands for a whole expansion while the shape of a word is compared with a directory name
SEC = re.compile((END + "*").join("secrets") + END + "*/", re.I)  # END may sit anywhere in it: ${A:-secrets}/k
PATHY = re.compile(r"(?:^|\n)\S*" + SEC.pattern, re.I)  # secrets/ in the first token of a word: a path, not prose
# ${name}, ${name:-word}, ${#name}: the value itself (or a default / alternate word, which is part of the text)
PLAIN_PARAM = re.compile(r"(?:[A-Za-z_][A-Za-z0-9_]*|[0-9]+|[@*#?$!-])(?:\[[^\]]*\])?(?:\}|:?[-=+?])"
                         r"|#[A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]*\])?\}")
FLAGS = {}  # per verdict(): mention, loose, dyn, split, cwd, verb, doubt, chdir
NAMED = []  # per verdict(): the secrets/ paths the line names outside any reader's operands (None: a name only)
ROOTS = []  # per verdict(): where the readers that walk into directories start (None: a root not placed)
WORK = [0]  # per verdict(): units spent against MAX_WORK
RPAREN = re.compile(r"[ \t]*\)")
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(\[[^\]]*\])?\+?=")
IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*$")
SUBSCRIPT_ODD = re.compile(r"[\s;|&<>()#'\"`\\]|\$\(")
EXCL_PATHSPEC = re.compile(r"^:(!|\^|\([^)]*\bexclude\b[^)]*\))")
ANSI_ESC = re.compile(r"x[0-9a-fA-F]{1,2}|[0-7]{1,3}|u[0-9a-fA-F]{1,4}|U[0-9a-fA-F]{1,8}")
# the $'...' escapes that bash 3.2, bash 5 and zsh turn into the same single byte (checked byte for byte)
ANSI_PLAIN = {"n": "\n", "t": "\t", "r": "\r", "a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b", "f": "\f", "v": "\v",
              "\\": "\\", "'": "'", '"': '"', "?": "?"}

VERBS = frozenset(
    "cat tac nl head tail less more awk sed grep egrep fgrep rg ag bat hexdump xxd od strings "
    "dd fold rev tee cp mv ln md5sum shasum sha256sum sha512sum wc diff cmp gunzip bunzip2 "
    "bzip2 bzcat xz xzcat unxz lzma lz4cat tar unzip 7z zip gpg openssl age rsync scp".split()
) | frozenset(os.environ.get("SCAN_READERS", "").split("|")) - {""}  # the list in _SECRET_MORE_READERS
SHELLS = frozenset("sh bash zsh dash ksh ash".split())
BACKGROUNDERS = {"nohup", "setsid"}  # supply-chain-scan: allow-literal wrapper names, not a spawn
LAUNCHERS = frozenset(
    "sudo doas env command builtin exec time nice ionice timeout gtimeout stdbuf rtk xargs "
    "watch flock chrt taskset caffeinate unbuffer script arch su runuser busybox fakeroot "
    "parallel ssh tmux screen byobu byobu-tmux byobu-screen zellij".split()) | BACKGROUNDERS
# quoted args are code: ssh joins them into the remote command line, a multiplexer types or runs them
# (the tmux command names cover a tmux command string handed to tmux itself: `if-shell c 'run-shell ...'`)
CARRIERS = frozenset(
    "ssh su watch script flock runuser parallel tmux screen byobu byobu-tmux byobu-screen zellij "
    "send-keys run-shell if-shell "
    "new-session new-window split-window respawn-pane respawn-window pipe-pane display-popup "
    "display-message".split())
# Inside a command string handed to tmux or screen (`tmux if true 'run "..."'`, `screen -X eval 'stuff "..."'`)
# the abbreviated command names and the rest of the family run or type their own quoted argument too.
# Scoped to such strings, so an unrelated program called run or display is not touched elsewhere.
MUXHOSTS = frozenset("tmux screen byobu byobu-tmux byobu-screen".split())
MUXCMDS = frozenset(
    "if send run new neww splitw respawnp respawnw pipep popup display confirm confirm-before "
    "command-prompt bind bind-key set-hook stuff".split())
MUX = [0]  # per verdict(): how many multiplexer command strings enclose the text being scanned
HEADS = VERBS | SHELLS | LAUNCHERS | {"git", "eval", "find"}
# a heredoc/here-string fed to these is code (tmux source-file - reads tmux commands, run-shell among them)
SHELLISH = SHELLS | {"ssh", "su", "source", ".", "tmux", "screen", "byobu", "byobu-tmux", "byobu-screen"}
INERT = frozenset("echo printf print true false : cd pwd test [ [[ export unset set".split())
SAFE = frozenset(  # name a path (or its metadata) without printing what is inside it
    "ls stat file du tree mkdir rmdir touch chmod chown chgrp rm realpath readlink basename dirname "
    "which type whereis open".split())
LISTFILE = {  # the exceptions among SAFE: an option that reads its file as a list and prints what it finds
    "file": re.compile(r"-[A-Za-z]*[fmMD]|--(files-from|magic-file)(=|$)"),
    "tree": re.compile(r"--fromfile(=|$)"),
    "du": re.compile(r"--files0-from(=|$)"),
}
CALM = INERT | SAFE | {"git", "find"}  # a secrets/ operand of these is no read by itself
CWD = frozenset(["cd", "pushd", "chdir"])
INTERP = re.compile(  # inline code (-e/-c/-r strings) can open the path itself
    r"^(python|pypy|perl|ruby|node|nodejs|deno|bun|php|lua|luajit|julia|tclsh|wish|pwsh|osascript|"
    r"sqlite3|psql|mysql|rscript)[0-9.]*$", re.I)
RESERVED = frozenset("! { } if then elif else fi while until do done in esac function coproc always".split())
LEAD = RESERVED | {"for"}  # words that may precede an arithmetic (( ))
PAREN_KEYWORDS = frozenset("if elif while until for select then do else time".split())  # may touch a `(`
PAREN_OK = LEAD | PAREN_KEYWORDS  # words after which a blank and a `(` still open a subshell
GREPS = frozenset("grep egrep fgrep rg ag zgrep bzgrep xzgrep".split())
GIT_READ = frozenset("show diff log blame annotate grep cat-file archive format-patch "
                     "diff-tree diff-index interpret-trailers".split())
# -F FILE / --file FILE: git stores the file as a message (commit, tag, merge, commit-tree, notes) or prints its
# first bad line (fmt-merge-msg), and a later git log / tag -n / notes show prints it
GIT_FILE_MSG = frozenset("commit tag merge commit-tree notes fmt-merge-msg".split())
GIT_RUN_OPTS = ("--upload-pack", "--receive-pack", "--exec")  # a command line that fetch, push, clone ... run
GIT_QUIET = frozenset(  # subcommands that name paths without printing their content
    "add rm mv status commit checkout restore reset clean check-ignore check-attr ls-files ls-tree "
    "rev-parse rev-list hash-object update-index config branch tag remote fetch push pull clone init "
    "worktree submodule switch merge rebase cherry-pick revert apply am gc prune count-objects "
    "help version".split())
GIT_RUNNERS = frozenset("difftool mergetool filter-branch bisect".split())  # subcommands that run a command line
GIT_PATTERN_OPTS = frozenset(["--grep", "-S", "-G", "--author", "--committer"])
GIT_META_OPT = re.compile(  # options of `git log|show` that print commits, names or counts, never file content
    r"-[0-9]+|-n[0-9]*|--max-count(=.*)?|--skip(=.*)?|--oneline|--abbrev-commit|--no-abbrev-commit|--abbrev(=.*)?"
    r"|--graph|--decorate(=.*)?|--no-decorate|--decorate-refs(-exclude)?=.*|--clear-decorations"
    r"|--all|--branches(=.*)?|--tags(=.*)?|--remotes(=.*)?|--glob=.*|--exclude=.*|--first-parent|--no-merges"
    r"|--merges|--reverse|--follow|--pretty(=.*)?|--format(=.*)?|--date(=.*)?|--relative-date|--since(=.*)?"
    r"|--until(=.*)?|--after(=.*)?|--before(=.*)?|--since-as-filter=.*|--author(=.*)?|--committer(=.*)?"
    r"|--grep(=.*)?|-i|--regexp-ignore-case|-E|--extended-regexp|-F|--fixed-strings|--basic-regexp|-P"
    r"|--perl-regexp|--all-match|--invert-grep|--no-color|--color(=.*)?|--source|--left-right"
    r"|--topo-order|--date-order|--author-date-order|--ancestry-path(=.*)?|--simplify-by-decoration"
    r"|--simplify-merges|--full-history|--sparse|--dense|--show-pulls|--children|--parents|--boundary"
    r"|--cherry|--cherry-pick|--cherry-mark|--no-walk(=.*)?|--do-walk|--merge|--min-parents=.*"
    r"|--max-parents=.*|--no-min-parents|--no-max-parents|--diff-filter=.*|--use-mailmap|--no-use-mailmap"
    r"|--mailmap|--no-mailmap|--encoding=.*|--expand-tabs(=.*)?|--no-expand-tabs|--relative(=.*)?"
    r"|--no-relative|-z|--log-size|--full-diff|-M[0-9%]*|--find-renames(=.*)?|-C[0-9%]*|--find-copies(=.*)?"
    r"|--find-copies-harder|--no-renames|--stat(=.*)?|--stat-[a-z-]+(=.*)?|--shortstat|--numstat"
    r"|--dirstat(=.*)?|--cumulative|--compact-summary|--name-only|--name-status|--summary|--raw|-s|--no-patch")
GIT_NO_PATCH = frozenset(  # `git show` prints the patch unless one of these replaces it
    "--stat --shortstat --numstat --name-only --name-status --summary --raw -s --no-patch".split())
EXCL_LONG = frozenset(["--exclude", "--exclude-dir"])  # --include SELECTS what rsync/tar read: not in this list
STDIN_SCRIPT = re.compile(  # script text read from stdin or an fd
    r"^(-|/dev/stdin|/dev/fd/[0-9]+|/proc/(self|[0-9]+)/fd/[0-9]+)$")
SHORT_VAL = {"grep": "efmABCdD", "egrep": "efmABCdD", "fgrep": "efmABCdD", "rg": "efgtTmjMrEABCd",
             "ag": "GgmpW", "zgrep": "efmABCdD", "bzgrep": "efmABCdD", "xzgrep": "efmABCdD"}  # ag: -G/-g PATTERN, -m/-W NUM, -p FILE; its -A/-B/-C take an optional number
READ_VAL = frozenset(["file", "exclude-from", "ignore-file", "pre", "pre-glob", "pager", "path-to-ignore"])
NONREAD_VAL = frozenset(  # pager: ag runs it
    "regexp include include-dir exclude exclude-dir glob iglob type type-not type-add type-clear "
    "label group-separator replace encoding max-count context after-context before-context "
    "binary-files devices directories colors engine path-separator sort sortr threads "
    "max-depth max-filesize max-columns".split())
# valued for one tool only (--color is a flag for GNU grep, whose value is attached): rg from `rg --help`, ag from its manual
TOOL_VAL = {
    "rg": frozenset("color context-separator dfa-size-limit field-context-separator field-match-separator generate "
                    "hostname-bin hyperlink-format regex-size-limit".split()),
    "ag": frozenset("depth file-search-regex ignore ignore-dir max-count path-to-ignore pager workers width".split()),
}
# The values of these options pick the files that are read (GNU grep sees a base name, BSD grep the whole path, rg
# and ag a path below the working directory): a glob or regex that can spell the directory selects it, like an operand
SELECT_LONG = frozenset(["include", "include-dir", "glob", "iglob", "type-add", "file-search-regex"])
SELECT_SHORT = {"rg": "g", "ag": "Gg"}  # rg -g GLOB, ag -G REGEX and -g REGEX (ag -g takes no other pattern)
# ag is not installed here: only the options of its manual (doc/ag.1.md) count as checked. -A -B -C take an optional
# number and so cannot be told from a pattern; the file-type options (--html) are generated. Both make the line doubt
AG_SHORT = frozenset("acDfFHilLnoQrsStuUvVwz0")
AG_LONG = frozenset(
    "ackmate affinity noaffinity all-types break nobreak count color nocolor column debug filename nofilename "
    "follow nofollow fixed-strings group nogroup heading noheading hidden ignore-case files-with-matches "
    "files-without-matches list-file-types mmap nommap multiline nomultiline norecurse numbers nonumbers "
    "only-matching one-device nopager parallel print-long-lines passthrough passthru literal recurse "
    "case-sensitive smart-case search-binary silent stats stats-only all-text unrestricted skip-vcs-ignores "
    "invert-match version vimgrep word-regexp search-zip null print0".split())


class Fail(Exception):
    pass


class Limit(Exception):
    """The scan ran out of work or nesting depth: no verdict (not the same as a construct it declined to model)."""


def mark(buf, q, reshaped):
    """Tell the consumers what an expansion's result is: split into words unless it sits in double quotes,
    and possibly reshaped (then a text that names no path yet can end up as one)."""
    if not q:
        buf.append(SPL)
    if reshaped:
        buf.append(RSH)


def spend(units):
    """Charge work to this command line; a scan that cannot finish within budget has no verdict."""
    WORK[0] += units
    if WORK[0] > MAX_WORK:
        raise Limit("work budget")


def odd_subscript(s, i):
    """s[i - 1] is a `[` that starts name[...]= or an array literal's [sub]=. Bash reads such a subscript up to
    its matching `]` as part of one word, operators and blanks included, where zsh cuts it at them.
    True when the span holds such a character, so the two shells disagree about where code goes on."""
    depth = 0
    for j in range(i, len(s)):
        if s[j] == "[":
            depth += 1
        elif s[j] == "]":
            if not depth:
                spend(j - i)
                return bool(SUBSCRIPT_ODD.search(s, i, j))
            depth -= 1
    spend(len(s) - i)
    return False


def norm(text):
    return text.rsplit("/", 1)[-1].lower()


VERBS_LONGEST_FIRST = sorted(VERBS, key=len, reverse=True)


def verb_of(name):
    """The guard verb a command word stands for: itself or any word ending in one (gcat, zgrep, gzip)."""
    return next((v for v in VERBS_LONGEST_FIRST if name.endswith(v)), None)


class Lexer:
    """Splits a command line into simple commands: (words, redirect-targets, bodies).

    words = [(text, bare)] with quotes removed; bare = no quoting/expansion was involved.
    Substitutions are lexed recursively and their commands land in the same flat list."""

    def __init__(self, s, depth):
        if depth > MAX_DEPTH:
            raise Limit("depth")
        self.s, self.n, self.i, self.depth = s, len(s), 0, depth
        self.cmds = []
        self.locale = False  # a $"..." sits in the word being read: bash drops the dollar sign, zsh keeps it
        spend(self.n // 16 + 1)

    def single(self, buf):
        j = self.s.find("'", self.i)
        if j < 0:
            raise Fail("quote")
        buf.append(self.s[self.i:j])
        self.i = j + 1

    def ansi(self, buf):  # $'...'
        """The shells read an escape that is not one of ANSI_PLAIN or a one- to three-digit octal or one- or
        two-digit hex code from 7 to 127 in ways of their own: \\c, \\u and \\U (bash 3.2 has no \\u), a code of
        0 (bash ends the word there, zsh keeps a NUL), a code from 128 up (a byte, not a character), and an
        unknown escape (bash keeps the backslash, zsh drops it). Which word, and which heredoc delimiter, they
        see is then not known here."""
        s = self.s
        while True:
            if self.i >= self.n:
                raise Fail("quote")
            c = s[self.i]
            if c == "'":
                self.i += 1
                return
            if c == "\\" and self.i + 1 < self.n:
                m = ANSI_ESC.match(s, self.i + 1)
                if m and m.group(0)[0] not in "uU":
                    tok = m.group(0)
                    code = int(tok[1:], 16) if tok[0] == "x" else int(tok, 8)
                    if not 7 <= code <= 127:
                        raise Fail("$'...' code the shells read differently")
                    buf.append(chr(code))
                    self.i += 1 + len(tok)
                elif not m and s[self.i + 1] in ANSI_PLAIN:
                    buf.append(ANSI_PLAIN[s[self.i + 1]])
                    self.i += 2
                else:
                    raise Fail("$'...' escape the shells read differently")
            else:
                buf.append(c)
                self.i += 1

    def dquote(self, buf, closing=True):  # "..." ; closing=False scans a heredoc body
        s = self.s
        while True:
            if self.i >= self.n:
                if closing:
                    raise Fail("quote")
                return
            c = s[self.i]
            if closing and c == '"':
                self.i += 1
                return
            if c == "\\":
                nxt = s[self.i + 1] if self.i + 1 < self.n else ""
                if nxt in ('"', "\\", "$", "`"):
                    buf.append(nxt)
                    self.i += 2
                elif nxt == "\n":
                    self.i += 2
                else:
                    buf.append(c)
                    self.i += 1
            elif c == "$":
                self.dollar(buf, True)
            elif c == "`":
                self.backtick(buf, True)
            else:
                buf.append(c)
                self.i += 1

    def dollar(self, buf, q=False):  # self.i is on a '$'; q = inside double quotes
        j, joined = self.i + 1, 0
        while self.s.startswith("\\\n", j):  # `$\<newline>((`: the shell joins the lines before it reads the token
            j += 2
            joined += 1
        if joined > 1:
            raise Fail("several line continuations after a dollar")  # zsh then reads the `$` as a plain character
        self.i = j - 1  # as if the `$` sat right in front of what it introduces
        nxt = self.s[self.i + 1] if self.i + 1 < self.n else ""
        if nxt == "(" and self.s.startswith("((", self.i + 1):
            self.i += 3
            self.arith(buf)
        elif nxt == "(":
            self.i += 2
            self.depth += 1
            if self.depth > MAX_DEPTH:
                raise Limit("depth")
            start = len(self.cmds)
            self.commands(True)
            self.depth -= 1
            buf.append(PH)
            mark(buf, q, reshapes(self.cmds[start:]))
            buf.append(END)
        elif nxt == "{":
            self.i += 2
            buf.append(PH)
            mark(buf, q, not PLAIN_PARAM.match(self.s, self.i))
            self.param(buf, q)
            buf.append(END)
        elif nxt == "[":
            raise Fail("legacy $[ ] arithmetic")  # its `<<` is a shift, not a heredoc; shells differ on the rest
        elif nxt == "'" and not q:  # inside double quotes `$'` is just a dollar sign and a quote
            self.i += 2
            self.ansi(buf)
        elif nxt == '"' and not q:  # ... and `$"` ends the string after a literal dollar sign
            self.i += 2
            self.locale = True
            self.dquote(buf)
        else:
            if nxt == "$":  # `$$` is the process id; a brace or quote after it is read differently by the shells
                k = self.i + 2
                while self.s.startswith("\\\n", k):
                    k += 2
                if self.s[k:k + 1] == "{" or (self.s[k:k + 1] == "'" and not q):
                    raise Fail("$$ before a brace or quote")
            named = bool(nxt) and (nxt.isalnum() or nxt in "_@*#?$!-")
            if named:
                buf.append(DYN)
                mark(buf, q, False)
            buf.append("$")
            self.i += 1
            if named:  # take the name here, so that text glued on after a quote is not read as a part of it
                j = self.i
                if nxt.isascii() and (nxt.isalpha() or nxt == "_"):
                    while j < self.n and self.s[j].isascii() and (self.s[j].isalnum() or self.s[j] == "_"):
                        j += 1
                elif nxt != "$":  # the second $ of $$ starts an expansion of its own, which is checked below
                    j += 1
                buf.append(self.s[self.i:j])
                self.i = j
                buf.append(END)

    def arith(self, buf):  # after $(( or ((: `<<` is a shift here, not a heredoc
        s, depth = self.s, 0
        while True:
            if self.i >= self.n:
                raise Fail("arith")
            c = s[self.i]
            if c == "(":
                depth += 1
                self.i += 1
            elif c == ")":
                if not depth:
                    if s[self.i + 1:self.i + 2] != ")":
                        raise Fail("arith")  # $( (list) ... ) rather than arithmetic
                    self.i += 2
                    break
                depth -= 1
                self.i += 1
            elif c in "'\"`" or s.startswith("$(", self.i):
                # bash and zsh tokenise a quote or substitution inside (( )) differently, and zsh may
                # re-read the whole span as $( (list) ): not provable, so the nominating deny stands
                raise Fail("arith")
            else:
                self.i += 1
        buf.append(PH)
        buf.append(END)

    def param(self, buf, q=False):  # ${...}: keep the inner text, it may be a default value
        s = self.s
        while True:
            if self.i >= self.n:
                raise Fail("param")
            c = s[self.i]
            if c == "}":
                self.i += 1
                return
            if c == "\\" and self.i + 1 < self.n:
                buf.append(s[self.i + 1])
                self.i += 2
            elif c == "'":
                if q:
                    raise Fail("quote inside a double-quoted ${ }")  # literal in some shells, a quote in others
                self.i += 1
                self.single(buf)
            elif c == '"':
                self.i += 1
                self.dquote(buf)
            elif c == "$":
                if q and s[self.i + 1:self.i + 2] in ("'", '"'):
                    raise Fail("$' or $\" inside a double-quoted ${ }")  # bash and zsh differ here
                self.dollar(buf, q)
            elif c == "`":
                self.backtick(buf, q)
            elif c == "{":
                raise Fail("brace inside ${ }")  # bash ends the expansion at the first }, zsh counts nested braces
            else:
                buf.append(c)
                self.i += 1

    def backtick(self, buf, q=False):
        s, j, inner = self.s, self.i + 1, []
        while True:
            if j >= self.n:
                raise Fail("backtick")
            c = s[j]
            if c == "`":
                break
            if c == "\\" and j + 1 < self.n and s[j + 1] in "`\\$":
                inner.append(s[j + 1])
                j += 2
            else:
                inner.append(c)
                j += 1
        sub = Lexer("".join(inner), self.depth + 1)
        sub.commands(False)
        self.cmds.extend(sub.cmds)
        self.i = j + 1
        buf.append(PH)
        mark(buf, q, reshapes(sub.cmds))
        buf.append(END)

    def heredocs(self, pending):  # self.i is at the first line of the bodies
        for delim, quoted, strip, target in pending:
            if strip and delim[:1] == "\t":  # <<-'\tEOF': bash needs the tab on the end line, zsh strips it from both
                raise Fail("<<- delimiter that begins with a tab")
            lines, joined, zjoined, cont = [], "", "", False
            while self.i < self.n:
                j = self.s.find("\n", self.i)
                j = self.n if j < 0 else j
                line = self.s[self.i:j]
                self.i = min(j + 1, self.n)
                # bash and zsh join `EO\<newline>F` into the delimiter of an unquoted heredoc. Where the joined
                # line and the physical line disagree about the end, the body may run on or stop: unprovable
                # (reading it as code would also be wrong, since it can open a heredoc of its own). For `<<-`
                # bash strips the tabs of the joined line, zsh those of its first physical line only (zjoined).
                hit = (line.lstrip("\t") if strip else line) == delim
                if cont and (hit != (((joined + line).lstrip("\t") if strip else joined + line) == delim)
                             or hit != (zjoined + line == delim)):
                    raise Fail("heredoc terminator depends on a line continuation")
                if hit:
                    break
                lines.append(line)
                first = line.lstrip("\t") if strip and not cont else line
                cont = not quoted and (len(line) - len(line.rstrip("\\"))) % 2 == 1
                joined = (joined + line)[:-1] if cont else ""
                zjoined = (zjoined + first)[:-1] if cont else ""
            body = "\n".join(lines)
            target.append(body)
            if not quoted:  # an unquoted delimiter still expands $( ) and backticks
                sub = Lexer(body, self.depth + 1)
                sub.dquote([], closing=False)
                self.cmds.extend(sub.cmds)
        del pending[:]

    def commands(self, in_paren):
        s, n = self.s, self.n
        words, redirs, bodies, pending = [], [], [], []
        buf, bare, inword, expect, par = [], True, False, None, 0
        arrays = []  # the paren depths that are NAME=( ... ) array literals
        cond = False  # between a command's [[ and its ]]
        rx = False  # after the =~ of such a test: bash reads the regex operand by rules of its own
        braces = 0  # `{` opened inside the current word and not yet closed: a brace expansion, `{}`, `stash@{0}`

        def flush():
            nonlocal buf, bare, inword, expect, cond, rx, braces
            if not inword:
                return
            text = "".join(buf)
            if expect is None:
                if in_paren and bare and text == "case":
                    raise Fail("case inside a substitution")  # its pattern `)` would end the $( ) early
                words.append((text, bare))
                if arrays and arrays[-1] == par:
                    note_element(text)  # NAME=(secrets x): a later "${NAME[@]}"/k can name the directory
                if bare and text == "]]":
                    cond = rx = False
                elif bare and text == "[[" and all(w[0] in LEAD for w in words[:-1]):
                    cond = True
                elif bare and text == "=~" and cond:
                    rx = True
            elif expect in ("<<", "<<-"):
                if any(m in text for m in (DYN, PH, SPL, RSH)):
                    raise Fail("heredoc delimiter comes from an expansion")  # the shell takes `$X` literally here
                if self.locale:
                    raise Fail('heredoc delimiter with a $"..." string')  # EOF for bash, $EOF for zsh
                pending.append((text, not bare, expect == "<<-", bodies))
            elif expect == "<<<":
                bodies.append(text)
                if PATHY.search(text) or carries(text):
                    note_mention()  # a here-string can hand `read` or xargs a path
            else:
                redirs.append(IN + text if expect in ("<", "<>") else text)
            expect = None
            buf, bare, inword, braces = [], True, False, 0
            self.locale = False

        def end():
            nonlocal words, redirs, bodies, expect
            flush()
            expect = None
            if words or redirs or bodies:
                self.cmds.append((words, redirs, bodies))
            words, redirs, bodies = [], [], []

        while True:
            if self.i >= n:
                if in_paren:
                    raise Fail("paren")
                end()
                return
            c = s[self.i]
            if c in " \t":
                flush()
                self.i += 1
            elif c == "\n":
                end()
                self.i += 1
                if pending:
                    self.heredocs(pending)
            elif c == "\\":
                nxt = s[self.i + 1] if self.i + 1 < n else ""
                if nxt == "\n":
                    if self.i and s[self.i - 1] not in " \t\n|&;":
                        raise Fail("line continuation inside a token")  # `(\<nl>(`: the shell joins the halves
                    self.i += 2
                elif nxt:
                    buf.append(nxt)
                    bare, inword = False, True
                    self.i += 2
                else:
                    self.i += 1
            elif c == "'":
                self.i += 1
                self.single(buf)
                bare, inword = False, True
            elif c == '"':
                self.i += 1
                self.dquote(buf)
                bare, inword = False, True
            elif c == "$":
                if rx and s[self.i + 1:self.i + 2] == "{" and not PLAIN_PARAM.match(s, self.i + 2):
                    raise Fail("malformed ${ in the regex operand of [[ ]]")  # bash takes `(${)` as regex text
                size = len(buf)
                self.dollar(buf)
                bare, inword = bare and buf[size:] == ["$"], True  # a lone `$` is a plain character
            elif c == "`":
                self.backtick(buf)
                bare, inword = False, True
            elif c == "#" and not inword:
                if cond:
                    raise Fail("# inside [[ ]]: a comment for bash, part of a pattern for zsh")
                j = s.find("\n", self.i)
                self.i = n if j < 0 else j
            elif c in "<>" and s[self.i + 1:self.i + 2] == "(":  # process substitution
                self.i += 2
                self.depth += 1
                if self.depth > MAX_DEPTH:
                    raise Limit("depth")
                self.commands(True)
                self.depth -= 1
                buf.append(PH)
                buf.append(END)
                bare, inword = False, True
            elif c in "<>" or (c == "&" and s[self.i + 1:self.i + 2] == ">"):
                if inword and bare and "".join(buf).isdigit():
                    buf, inword = [], False  # a leading fd number: 2>file
                else:
                    flush()
                op = next((o for o in ("<<<", "<<-", "<<", ">>", ">|", ">&", "<&", "<>", "&>>", "&>")
                           if s.startswith(o, self.i)), c)
                self.i += len(op)
                if op in ("<<", "<<-", "<<<") and s[self.i:self.i + 1] == "(":
                    raise Fail("heredoc operator against a parenthesis")  # zsh: `<` + `<( )`; bash: a syntax error
                if (arrays and arrays[-1] == par) or rx or (op in ("<<", "<<-") and cond):
                    # inside NAME=( ) or a [[ ]] regex bash keeps the operator as text; zsh may open a here-document
                    # or refuse the line, and a quote after it then ends in a different place
                    raise Fail("redirection operator inside an array literal or [[ ]]")
                expect = op
            elif c in ";&|":
                end()
                self.i += 1
            elif c == "(":
                if (inword or words) and RPAREN.match(s, self.i + 1):
                    raise Fail("function definition")  # name() { ...; }: the body runs later
                glued = inword and bare and not words and "".join(buf) in PAREN_KEYWORDS
                at_arith = s.startswith("((", self.i) and (glued or not inword)
                if at_arith and all(w[0] in LEAD for w in words):
                    if glued:
                        flush()  # `for((i=0;i<1<<2;i++))`: the keyword, then an arithmetic list
                    self.i += 2  # (( expr )) command
                    self.arith([])
                    end()  # zsh: `for ((;;)) cmd`, `if (( x )) cmd` run what follows as their body
                    continue
                if not inword and not cond and (redirs or any(w[0] not in PAREN_OK for w in words)):
                    if not (words and words[0][0] == "case"):  # `case x in (pat)` is a pattern in both shells
                        raise Fail("parenthesis after a command word")  # bash: syntax error; zsh: a glob across lines
                literal = False
                if inword:  # NAME=( is an array literal, while(( a keyword; any other word + ( is a zsh glob
                    head = "".join(buf)
                    named = ASSIGN.match(head)
                    literal = bool(named and named.end() == len(head))
                    if not (literal or (bare and not words and head in PAREN_KEYWORDS)):
                        raise Fail("parenthesis attached to a word")
                end()
                self.i += 1
                par += 1
                if literal:
                    arrays.append(par)
            elif c == ")":
                end()
                self.i += 1
                if par:
                    if arrays and arrays[-1] == par:
                        arrays.pop()
                    par -= 1
                elif in_paren:
                    return
            else:
                if c == "[":
                    after_name = inword and bare and IDENT.match("".join(buf))
                    element = not inword and arrays and arrays[-1] == par
                    if (after_name or element) and odd_subscript(s, self.i + 1):
                        raise Fail("operator or blank inside a subscript")  # bash: one word; zsh: cut at it
                elif c == "{":
                    braces += 1
                elif c == "}":
                    if braces:
                        braces -= 1
                    elif inword:  # `<<EOF}`, `echo a}`: bash keeps it in the word, zsh ends the word and closes a group
                        raise Fail("unmatched } inside a word")
                buf.append(c)
                inword = True
                self.i += 1


def shape(t):
    """t with every expansion folded into one UNK: $A, ${A:-x}y and $(cmd) each count as a single unknown piece."""
    out, depth = [], 0
    for ch in t:
        if ch == DYN or ch == PH:
            if not depth:
                out.append(UNK)
            depth += 1
        elif ch == END:
            depth = max(depth - 1, 0)
        elif not depth and ch not in (SPL, RSH, IN):
            out.append(ch)
    return "".join(out)


BRACE_WORDS = 64  # a brace expansion that makes more words than this is not enumerated
BRACE_SEQ = re.compile(r"\{[^{},]*\.\.[^{},]*\}")  # {1..9}, {a..e}: any word
BRACE_ALT = re.compile(r"\{([^{}]*,[^{}]*)\}")  # {a,b}: an innermost group with a comma
FORMATTED = re.compile(r"\\(?:[0-7]{1,3}|x[0-9A-Fa-f]{1,2}|u[0-9A-Fa-f]{1,4}|U[0-9A-Fa-f]{1,8})"
                       r"|%[-+ #0-9.*']*[A-Za-z]")  # \057 \x2f / %s %b: printf and echo -e make text of these


def brace_words(s):
    """The words a brace expansion makes of s ({a,b}c -> ac bc; a {1..9} sequence stands as one `*`), or None
    when there would be more than BRACE_WORDS of them. A lone {}, {a} or an unclosed { stays as it is."""
    out, todo = [], [BRACE_SEQ.sub("*", s)]
    while todo:
        w = todo.pop()
        spend(len(w) // 16 + 1)
        m = BRACE_ALT.search(w)
        if m is None:
            out.append(w)
        else:
            todo.extend(w[:m.start()] + alt + w[m.end():] for alt in m.group(1).split(","))
        if len(out) + len(todo) > BRACE_WORDS:
            return None
    return out


STAR, ANY1 = object(), object()  # pattern tokens: `*` (also an expansion) and `?`
SECRETS = "secrets"


def glob_set(body):
    """The letters of `secrets` that the bracket expression [body] can match: [t], [!x], [a-f], [[:alpha:]]."""
    neg = body[:1] in ("!", "^")
    body = body[1:] if neg else body
    if "[:" in body:
        return frozenset(SECRETS)  # a character class: any letter may do
    hit, i = set(), 0
    while i < len(body):
        if i + 2 < len(body) and body[i + 1] == "-":
            hit.update(c for c in SECRETS if body[i].lower() <= c <= body[i + 2].lower())
            i += 3
        else:
            hit.add(body[i].lower())
            i += 1
    return frozenset(c for c in SECRETS if (c in hit) != neg)


def bracket_end(comp, k):
    """The index of the ] that closes the bracket expression whose members begin at k, or -1."""
    if comp[k:k + 1] == "]":
        k += 1  # a ] right after the [ or [! is a member
    while k < len(comp):
        if comp.startswith("[:", k) and ":]" in comp[k + 2:]:
            k = comp.index(":]", k + 2) + 2  # [:alpha:]
        elif comp[k] == "]":
            return k
        else:
            k += 1
    return -1


def glob_tokens(comp):
    """One path component as pattern tokens: a lower-case character, STAR, ANY1 or the set a [..] can match."""
    toks, i, n = [], 0, len(comp)
    while i < n:
        c = comp[i]
        if c == "*" or c == UNK:
            toks.append(STAR)
        elif c == "?":
            toks.append(ANY1)
        elif c == "[":
            j = i + 1 + (comp[i + 1:i + 2] in ("!", "^"))
            k = bracket_end(comp, j)
            if k < 0:
                toks.append("[")
            else:
                toks.append(glob_set(comp[i + 1:k]))
                i = k
        else:
            toks.append(c.lower())
        i += 1
    return toks


def can_be_secrets(toks, tail=False, solid=False, within=False):
    """Can the tokens read as the word `secrets`, all of it and nothing else? With `tail`: or as a name that ends
    in it, and with `solid` that ending has a character of its own, not only stars and expansions. With `within`
    the name may also have more behind it (secretsX), and it has a character of its own."""
    states = {(0, False)}  # (letters of `secrets` matched, one of them came from a character and not from a star)
    for t in toks:
        nxt = set()
        for s, own in states:
            if t is STAR:
                nxt.update((j, own) for j in range(s, 8))
            elif s < 7:
                want = SECRETS[s]
                if t is ANY1 or t == want or (type(t) is frozenset and want in t):
                    nxt.add((s + 1, True))
        states = nxt | {(0, False)} if tail else nxt  # tail: whatever came before the word may be anything
        if within and any(s == 7 and own for s, own in states):
            return True
        if not states:
            return False
    return any(s == 7 and (own or not solid) for s, own in states)


def reads_as_secrets(comp, before_slash=False, carried=False):
    """A path component that can read as `secrets`, also behind an `=` or a `:` (if=NAME, host:NAME). Before a
    slash it may also be a name that ends in it, as the written-out x-secrets/ is. So may a last component that ends
    in an expansion (x-secre"$A": the value can finish the name and add the slash), if it has a character of that
    ending of its own (not fire=$?, not data_*). A name that is handed on to a later $A/k (carried) may have the
    directory name anywhere in it, for ${A%X} or ${A:0:7} to cut it out (secretsX, Xsecrets)."""
    for part in (comp, comp.rpartition("=")[2], comp.rpartition(":")[2]):
        toks = glob_tokens(part) if part != UNK else []
        if (can_be_secrets(toks, before_slash) or (part.endswith(UNK) and can_be_secrets(toks, True, True))
                or (carried and can_be_secrets(toks, True, True, True))):
            return True
    return False


def spells(t, final=True, carried=False):
    """t, taken as a path, may run through a directory called secrets or ending in it (with `final`: or the last
    component is called secrets): written out, or spelled with a glob (secre[t]s, s*), a brace group ({secrets,x})
    or an expansion beside the rest of the name ($A$B, "$A"rets). A component that is one expansion and nothing else
    stays unjudged: its value is not known here."""
    if SEC.search(t):
        return True
    t = FORMATTED.sub(UNK, shape(t))  # a character code or a conversion can stand for a letter or the slash
    spend(len(t) // 8 + 1)
    words = brace_words(t)
    if words is None:
        return True
    for w in words:
        for v in (w, w.replace(UNK, "/" + UNK + "/")) if UNK in w else (w,):  # an expansion may bring a slash
            comps = v.split("/")
            for n, comp in enumerate(comps):
                if (final or n < len(comps) - 1) and reads_as_secrets(comp, n < len(comps) - 1, carried):
                    return True
    return False


TOKEN = re.compile(r"\S+")
GLOBBY = re.compile("[*?\\[{" + DYN + PH + "]")


CODE_PIECE = re.compile(r"[^\s\"'`()<>;,|&]+")  # a path-like piece of code: the blanks, quotes and brackets of the
#                                                 language cut it out, the glob characters stay in it
CODE_BRACE = re.compile(r"[^\s\"'`()<>;|&]+")  # the same, with the commas of a brace group: secret{s,}/k
UNQUOTE = re.compile(r"['\"\\]")  # a shell reads secr\ets, sec''rets and "sec"rets as one word
BRACKET_CLASS = re.compile(r"\[[^\]]*\]?")


def may_spell(p):
    """A piece of code that can be the name: a path (a slash) or a word with a letter of its own. The `*` of `2 * 3`
    and the `[a-z]*` of a regex are wildcards only."""
    return "/" in p or re.search(r"[A-Za-z]", BRACKET_CLASS.sub("", p)) is not None


def names_dir(t):
    """Text that a program runs or reads as code (a git -c value, a runner's command, an interpreter's code string,
    a tmux format) names the directory: written out, or a piece of it spelled with a glob, a brace group, a quote
    or an expansion (secre[t]s/k in Dir["secre[t]s/*"], <secre[t]s/*>, alias.x=!cat s*/k, !cat secrets''/k)."""
    for text in (t, UNQUOTE.sub("", t)):
        if SEC.search(text):
            return True
        for rx in (CODE_PIECE, CODE_BRACE):
            if any(GLOBBY.search(p) and may_spell(p) and spells(p) for p in rx.findall(text)):
                return True
    return False


def named_word(t, final, plain):
    """A word of a command that is no reader: does the first token of one of its lines (the rest is prose) run
    through a secrets directory? `plain`: a name written out counts; otherwise only a glob, a brace group or an
    expansion that spells it does. A name handed on (`plain`) may also have it inside: x-secrets, secretsX."""
    for line in t.split("\n"):
        m = TOKEN.match(line)
        if m and (plain or GLOBBY.search(m.group(0))) and spells(m.group(0), final, plain):
            return True
    return False


def carries(t):
    """A word that a later $var, loop or cd can take the directory name from: `secrets`, ./secrets, secre[t]s ..."""
    return named_word(t, True, True)


def carries_only(t):
    """A word that hands the name on without being a path to it (secrets, ./secrets, x-secrets), where a path word
    (x/secrets/k) says where the directory is."""
    for line in t.split("\n"):
        m = TOKEN.match(line)
        if m:
            tok = m.group(0)
            if spells(tok, True, True) and not (SEC.search(tok) or (GLOBBY.search(tok) and spells(tok, False, False))):
                return True
    return False


def note_assign(t):
    """NAME=value or NAME[key]=value: the value, or the key of an associative array, is a name for a later $NAME,
    ${!NAME[@]} or cd (CDPATH, OLDPWD) to use."""
    m = ASSIGN.match(t)
    if m and any(carries(x) for x in (t[m.end():], (m.group(1) or "")[1:-1])):
        note_mention()
        if t.startswith(("CDPATH=", "OLDPWD=")):
            FLAGS["cwd"] = True


def note_element(t):
    """An element of an array literal NAME=( ... ), or its [key]=value: a name for a later "${NAME[@]}" to use."""
    key = re.match(r"\[([^\]]*)\]=", t)
    if carries(t) or (key and carries(key.group(1))):
        note_mention()


LISTED = re.compile(r"[^\s,;:|&()<>]+")  # one item of a list: blanks and the usual separators cut it


def later_names(t):
    """Does a text carry the directory name in an item that is not its first (D="x secrets", a,secrets,b)? A
    consumer that splits the text (an unquoted expansion, read, xargs, set --) hands each item on as a word."""
    for line in t.split("\n"):
        for i, word in enumerate(line.split()):
            items = LISTED.findall(word)
            if (i or len(items) > 1) and any(spells(item, True, True) for item in items):
                return True
    return False


REWRITERS = frozenset(["sed", "awk"])  # readers whose program text can print a name of its own


def is_program(name):
    """A command whose argument is code that can print a name of its own: sed, awk, jq, an interpreter."""
    return name in REWRITERS or name in ("jq", "yq", "gojq") or bool(INTERP.match(name))

PRINTERS = frozenset("echo printf print".split())
OPTION = re.compile(r"--?[A-Za-z]*$")
PIECES = 24  # the words of a row of printers that are put side by side


def note_pieces(words, run):
    """Consecutive printers print their words side by side: `echo -n secr; echo -n ets/k`, `printf %s secr ets/k`.
    `run` holds the words of the printers in a row (a bare assignment, : or true does not break it, any other
    command does). A word that names the directory by itself is judged on its own and ends the row; when the
    last few of the others could spell it together, the line hands a name on."""
    k = 0
    while k < len(words) and (words[k][0] in RESERVED or ASSIGN.match(words[k][0])):
        k += 1
    rest = words[k:]
    name = norm(rest[0][0]) if rest else ""
    if name in PRINTERS:
        new = [t for t, _ in rest[1:] if not OPTION.match(t)]
        if any(spells(t, True, True) for t in new):
            del run[:]
            return
        run.extend(new)
        del run[:-PIECES]
        joined = "".join(run)
        letters = any(c in SECRETS for c in shape(joined).lower())
        if len(run) > 1 and letters and (carries(joined) or later_names(joined)):
            note_mention()
    elif rest and name not in (":", "true", "false"):
        del run[:]


def note_mention(*paths):
    """The line names a secrets/ path in a command that reads nothing, or hands a name on (then no path: None)."""
    FLAGS["mention"] = True
    NAMED.extend(paths or (None,))


def path_words(words, redirs):
    """The words of a command that run through a secrets directory as a path (the first token of a line, the rest is
    prose): written out, or spelled by a glob, a brace group or an expansion."""
    out = []
    for t in [w for w, _ in words] + redirs:
        for line in t.split("\n"):
            m = TOKEN.match(line)
            if m and (SEC.search(m.group(0)) or (GLOBBY.search(m.group(0)) and spells(m.group(0), False, False))):
                out.append(m.group(0))
    return out


def note_roots(paths, matches=False):
    """Where a reader that walks into directories starts. A path this scan cannot place is None: host:dir, :(glob)x,
    an @listfile, and with `matches` (zip, 7z) a pattern, which the program itself matches across directories."""
    for t in paths:
        ROOTS.append(None if re.match(r"[^/]*:|@", t) or (matches and re.search(r"[*?\[]", t)) else t)


def option_walk(args, short_val="", long_val=(), list_val=()):
    """(flags, words) of a command line: the option letters and long names it holds, and the words that are no option
    and no option's value. The letters in short_val and the long names in long_val take a value; those in list_val
    (zip -x, -i) take every word up to the next option."""
    flags, words, k, listed = set(), [], 0, False
    while k < len(args):
        a = args[k]
        if a == "--":
            words += args[k + 1:]
            break
        listed = False
        if a[:2] == "--":
            opt, eq, _ = a[2:].partition("=")
            flags.add(opt)
            listed = opt in list_val
            if opt in long_val and not eq:
                k += 1
        elif a[:1] == "-" and len(a) > 1:
            for m in range(1, len(a)):
                flags.add(a[m])
                if a[m] in short_val:
                    if m + 1 == len(a):
                        k += 1
                    break
            else:
                listed = a[-1] in list_val
        else:
            words.append(a)
            k += 1
            continue
        k += 1
        while listed and k < len(args) and not (args[k][:1] == "-" and len(args[k]) > 1):
            k += 1  # the words of the list are patterns, no files
    return flags, words


TAR_VAL = "fCTXbIN"  # the letters of tar that take a value (-s -H -L mean different things to GNU and BSD tar: not here)
TAR_LONG = frozenset(
    "file directory files-from exclude exclude-from exclude-tag newer newer-mtime after-date transform xform "
    "use-compress-program owner group mode mtime suffix index-file label rsh-command blocking-factor strip-components "
    "format listed-incremental level checkpoint-action warning add-file pax-option to-command include options "
    "older newer-than older-than uid gid uname gname".split())
WALKS = {  # verb: letters with a value, long names with a value, letters and long names that make it walk into directories
    "cp": ("tS", frozenset(["target-directory", "suffix"]), "rRa", ("recursive", "archive")),
    "scp": ("cDFiJloPSX", frozenset(), "r", ()),
    "rsync": ("efBMT", frozenset(
        "exclude include exclude-from include-from files-from filter rsh rsync-path partial-dir temp-dir compare-dest "
        "copy-dest link-dest backup-dir suffix bwlimit port timeout contimeout log-file out-format info debug chmod "
        "chown usermap groupmap max-size min-size modify-window block-size address sockopts remote-option read-batch "
        "write-batch only-write-batch protocol iconv checksum-choice checksum-seed compress-choice compress-level "
        "compress-threads skip-compress max-delete max-alloc outbuf password-file stop-after stop-at confine-root "
        "copy-as early-input log-file-format stderr".split()), "ra", ("recursive", "archive")),
    "diff": ("xXIUCWDFLSA", frozenset(  # --unified and --context take no word of their own
        "exclude exclude-from ignore-matching-lines show-function-line label starting-file ifdef width tabsize "
        "from-file to-file horizon-lines algorithm changed-group-format unchanged-group-format old-group-format "
        "new-group-format line-format old-line-format new-line-format unchanged-line-format".split()),
             "r", ("recursive",)),
    "zip": ("bnOPtsZ", frozenset(), "rR", ("recurse-paths",)),  # -T is a flag (-TT takes a command)
    "gunzip": ("", frozenset(["suffix"]), "r", ("recursive",)),
}


def has_flag(flags, letters, names):
    """Is one of the option letters or long names among the flags, or an abbreviation of a long name (getopt_long
    takes any unique prefix: `cp --recurs`, `tar --creat`)?"""
    return bool(flags & set(letters)) or any(n.startswith(f) for f in flags if len(f) > 1 for n in names)


def walk_roots(verb, cmd, args):
    """Readers that go through every file below the paths they are given (tar c, cp -r, rsync -a, scp -r, zip -r,
    7z a, diff -r, gunzip -r): where they start, for note_roots. cmd is the word that was run: gzip ends in the
    guard verb zip, but its first word is a file, not an archive."""
    if verb == "tar":
        flags, rest = set(), args
        if args and args[0][:1] != "-" and args[0].isalpha():  # `tar czf a.tgz dir`: the first word holds the letters
            flags, rest = set(args[0]), args[1 + sum(c in TAR_VAL for c in args[0]):]
        more, words = option_walk(rest, TAR_VAL, TAR_LONG)
        flags |= more  # `tar czf a.tgz -T list` mixes the two forms
        if has_flag(flags, "cru", ("create", "append", "update")):  # a mode that reads the files it is given
            if has_flag(flags, "CT", ("directory", "files-from", "add-file")):
                ROOTS.append(None)  # another directory, or a list of paths in a file: not placed
            note_roots(words)
    elif verb == "7z":
        words = option_walk(args)[1]
        if words[:1] in (["a"], ["u"]):
            note_roots(words[2:], True)
    elif verb in WALKS:
        sv, lv, letters, names = WALKS[verb]
        flags, words = option_walk(args, sv, lv, ("x", "i", "exclude", "include") if verb == "zip" else ())
        if has_flag(flags, letters, names):
            if verb == "zip" and "@" in flags:
                ROOTS.append(None)  # the names come from stdin
            if verb == "zip":
                roots = words[1:] if cmd == "zip" else words  # zip ARCHIVE FILE...; gzip FILE...
            elif verb in ("gunzip", "diff") or (verb == "cp" and has_flag(flags, "t", ("target-directory",))):
                roots = words
            else:
                roots = words[:-1] or words  # cp, scp, rsync: the last word is where it all goes
            note_roots(roots, verb == "zip")


# a pattern (also a zsh or ksh glob operator), an unclosed brace group or an expansion: not a fixed name
UNSURE = re.compile("[*?\\[{^~#<>()|@+!" + UNK + "]")
UNPLAIN = re.compile(r"[()|^~#<>@+]|(?<!\[)!|\[[:=.]")  # glob operators that fnmatch does not read as the shell does


def differ(a, b):
    """Two path components that can never name the same entry: two fixed names, or a fixed name and a pattern that
    cannot match it. Case is ignored, as on a case-insensitive disk."""
    a, b = a.lower(), b.lower()
    pa, pb = bool(UNSURE.search(a)), bool(UNSURE.search(b))
    if pa and pb:
        return False
    if not pa and not pb:
        return a != b
    fixed, pat = (b, a) if pa else (a, b)
    return UNK not in pat and "{" not in pat and not UNPLAIN.search(pat) and not fnmatch.fnmatchcase(fixed, pat)


def apart1(r, p):
    """Do the root r and the path p lie side by side, neither one inside the other? Only plain paths that part ways
    at a name: not `..`, `~`, an absolute path against a relative one, or anything a pattern or expansion may match."""
    if r[:1] == "~" or p[:1] == "~" or (r[:1] == "/") != (p[:1] == "/"):
        return False
    rc = [c for c in r.split("/") if c not in ("", ".")]
    pc = [c for c in p.split("/") if c not in ("", ".")]
    return ".." not in rc and ".." not in pc and any(differ(a, b) for a, b in zip(rc, pc))


def apart(root, path):
    if root is None or path is None:
        return False
    rs, ps = brace_words(shape(root)), brace_words(shape(path))
    if rs is None or ps is None:
        return False
    spend(len(rs) * len(ps))
    return all(apart1(r, p) for r in rs for p in ps)


def walked_over():
    """A reader that walks into directories starts at (or above) a secrets/ path that the line names elsewhere. A cd
    on the line, or a root or a path this scan cannot place, counts as walking over it."""
    if not (ROOTS and NAMED):
        return False
    spend(len(ROOTS) * len(NAMED))
    return FLAGS["chdir"] or any(not apart(r, p) for r in ROOTS for p in NAMED)


def grep_operands(name, args):
    """What a grep-like command reads, as (ops, files, walks). ops: the operands read as files, also the values of
    options that name a file or pick the files to read (-f FILE, --include GLOB, rg -g GLOB, ag -G REGEX). files:
    the paths it searches, walks: it searches directories. The PATTERN (first non-option word, or the -e/--regexp
    value, none with rg --files or ag -g) is no operand, and an exclusion (--exclude-dir, rg -g '!GLOB') picks nothing."""
    sv, tv, ops, positional, pat, k = SHORT_VAL[name], TOOL_VAL.get(name, ()), [], [], False, 0
    walks = name in ("rg", "ag")
    while k < len(args):
        a = args[k]
        if a == "--":
            positional += args[k + 1:]
            break
        if a.startswith("--"):
            opt, eq, val = a[2:].partition("=")
            if name == "ag" and opt not in AG_LONG and opt not in tv:
                FLAGS["doubt"] = True  # an option of ag that nothing checked: it may take the next word
            walks = walks or (opt != "" and ("recursive".startswith(opt) or "dereference-recursive".startswith(opt)))
            pat = pat or (name == "rg" and opt == "files")
            dirs = len(opt) > 2 and "directories".startswith(opt)  # --dir=recurse: getopt_long takes a unique prefix
            if not eq and (opt in NONREAD_VAL or opt in READ_VAL or opt in tv or dirs):  # --opt VALUE
                eq, val = "=", args[k + 1] if k + 1 < len(args) else ""
                k += 1
            if eq:
                pat = pat or opt in ("regexp", "file")
                walks = walks or (dirs and val == "recurse")
                if (opt in READ_VAL or opt in SELECT_LONG and not (opt in ("glob", "iglob") and val[:1] == "!")
                        or opt not in NONREAD_VAL and opt not in tv):
                    ops.append(val)  # a file to read or pick, or an unknown --opt=VALUE: stay conservative
        elif len(a) > 1 and a[0] == "-":
            for m in range(1, len(a)):
                c = a[m]
                if name == "ag" and c not in AG_SHORT and c not in sv:
                    FLAGS["doubt"] = True  # -A -B -C take an optional number: not told from a pattern
                walks = walks or (c in "rR" and c not in sv)
                if c in sv:
                    if m + 1 < len(a):
                        val = a[m + 1:]
                    else:
                        val = args[k + 1] if k + 1 < len(args) else ""
                        k += 1
                    pat = pat or c in "ef" or (name == "ag" and c == "g")
                    walks = walks or (c == "d" and name != "rg" and val == "recurse")
                    if (c == "f" or (c == "p" and name == "ag")
                            or (c in SELECT_SHORT.get(name, "") and not (name == "rg" and val[:1] == "!"))):
                        ops.append(val)
                    break
        else:
            positional.append(a)
        k += 1
    files = positional if pat else positional[1:]
    return ops + files, files, walks


def verb_reads(name, words, redirs):
    args = [t for t, _ in words[1:]]
    if name in GREPS and name in SHORT_VAL:
        ops, files, walks = grep_operands(name, args)
        if walks or norm(words[0][0]).endswith("rgrep"):  # rgrep is grep -r
            note_roots(files or ["."])  # no operand: the working directory
    else:
        ops, k = [], 0
        while k < len(args):
            a = args[k]
            if a == "--":
                ops += args[k + 1:]  # after -- every argument is an operand, an --exclude too
                break
            if a in EXCL_LONG:
                k += 2
            elif a.partition("=")[0] in EXCL_LONG and "=" in a:
                k += 1
            else:
                ops.append(a)
                k += 1
        walk_roots(name, norm(words[0][0]), args)
    FLAGS["verb"] = True
    if name in REWRITERS and any(carries(a) or later_names(a) for a in args):
        note_mention()  # sed 's|x|secrets|', awk '{print "secrets"}': the program can hand the name on
    note_dyn(ops + redirs)  # the path may come from a variable, a loop, a substitution or xargs
    return any(spells(t) for t in ops + redirs)


def dynamic(texts):
    return any(DYN in t or PH in t or "{}" in t or (t[:1] == "~" and t[1:2] not in ("", "/", "+", "-"))
               for t in texts)  # ~name: a named directory (zsh hash -d, a home) is a value this scan does not know


def splitting(texts):
    return any(SPL in t or RSH in t for t in texts)


def reshapes(cmds):
    """Does a substitution inside double quotes hand on anything but one unchanged word? Not when every
    command only prints its own words (echo, printf, a heredoc through cat), and not when no command
    touches a secrets/ path, a variable or another substitution: nothing it could reshape reaches it."""
    literal, linked = True, False
    for words, redirs, bodies in cmds:
        name = words[0][0] if words and words[0][1] else ""
        if name not in ("echo", "printf", "print") and not (name == "cat" and len(words) == 1 and bodies):
            literal = False
        linked = linked or any(SEC.search(t) or DYN in t or PH in t
                               for t in [w for w, _ in words] + redirs + bodies)
    return not literal and linked


def note_dyn(texts):
    """Operands of a reader (or of a program that may be one) that a variable, loop, substitution or xargs
    fills in. `split`: the filled-in text is also split into words or reshaped on its way."""
    if dynamic(texts):
        FLAGS["dyn"] = True
        if splitting(texts):
            FLAGS["split"] = True


def note_loose(texts):
    """A secrets/ path named anywhere in a text, also in a later token of a quoted one (' secrets/k'), or the
    directory name in a later item of a list (D="x secrets"). A splitting consumer (an unquoted expansion, xargs,
    read) turns such text into path words of its own."""
    if any(SEC.search(t) or later_names(t) for t in texts):
        FLAGS["loose"] = True


def pathy(words, redirs):
    return bool(path_words(words, redirs))


def note_leaf(name, words, redirs):
    """A command that is no guard verb names a secrets/ path. It reads nothing here, but it is where a
    later $var, loop, substitution or cd can pick the path up -- or a program this scan knows nothing about."""
    args = [t for t, _ in words[1:]]
    note_loose([t for t, _ in words] + redirs)
    if any(RSH in t for t in args + redirs):
        FLAGS["split"] = True  # printf -v P "$(echo ' x' | cut ...)": a variable can capture reshaped text
    if INTERP.match(name) and any(names_dir(t) for t in args):
        FLAGS["doubt"] = True  # an interpreter whose code string names the path: not prose
    if name not in CALM:
        note_dyn(args + redirs)  # a program the verb list does not know may read what $var / $( ) names
    if name in CWD and any(spells(a) for a in args):
        note_mention()  # cd secre[t]s, cd secrets: what follows is relative to it
        FLAGS["cwd"] = True
    if any(carries_only(a) for a in args) or (is_program(name) and any(later_names(a) for a in args)):
        note_mention()  # echo secrets | xargs ..., export D=secrets, perl -e 'print "secrets"': a name to use
    for a in args:
        note_assign(a)  # export m[secrets]=1, export CDPATH=secrets
    named = path_words(words, redirs)
    if not named:
        return
    note_mention(*named)
    if name in CWD:
        FLAGS["cwd"] = True
    if name not in CALM:
        FLAGS["doubt"] = True


def named_files(rest, short, longs):
    """The values of git options that name a file: `short` (a letter: -f FILE, -fFILE, bundles such as
    -lf FILE) and `longs` (--file FILE, --file=FILE). git takes a unique prefix of a long option for it (--fil,
    --pathspec-from); every prefix after the dashes of a listed option counts here, unique or not, which can only
    deny more. The bare `--` ends the options and is no prefix."""
    out, j = [], 0
    while j < len(rest):
        a, nxt = rest[j], rest[j + 1] if j + 1 < len(rest) else ""
        name, eq, val = a.partition("=")
        if name in longs or (name[:2] == "--" and len(name) > 2 and any(x.startswith(name) for x in longs)):
            out.append(val if eq else nxt)
            j += 0 if eq else 1
        elif short and a[:1] == "-" and a[:2] != "--" and short in a:
            tail = a.partition(short)[2]
            out.append(tail or nxt)
            j += 0 if tail else 1
        j += 1
    return out


def git_command_lines(sub, rest):
    """The command lines git hands to a shell: `rebase -x CMD` / `--exec CMD`, `submodule foreach CMD`, and the
    program that fetch, pull, push, clone, ls-remote and archive start on the other side (--upload-pack, clone's
    -u, --receive-pack, --exec)."""
    if sub == "rebase":
        return named_files(rest, "x", ("--exec",))
    if sub == "submodule" and "foreach" in rest:
        return [" ".join(rest[rest.index("foreach") + 1:])]
    if sub in ("fetch", "pull", "push", "clone", "ls-remote", "archive"):
        return named_files(rest, "u" if sub == "clone" else "", GIT_RUN_OPTS)
    return []


def git_meta_only(sub, rest):
    """True for a `git log|show` none of whose options prints file content: a secrets/ path among its
    operands then only selects commits. An option, a value or an expansion this does not know keeps the
    answer a read (an unquoted expansion may split into options of its own). -p, -u and --patch are not
    among the listed options and keep the read wherever they stand: git lets the last of -p and
    -s/--no-patch win, and this does not try to say which one that is."""
    quiet = sub == "log"
    for a in rest:
        if PH in a or DYN in a or SPL in a or RSH in a:
            return False
        if a == "--":
            break
        if a[:1] == "-" and len(a) > 1:
            if not GIT_META_OPT.fullmatch(a):
                return False
            quiet = quiet or a.partition("=")[0] in GIT_NO_PATCH
        elif ":" in a and spells(a):
            return False  # REV:path names a blob, and `git show` prints a blob whatever the options say
    return quiet


def git_reads(words, redirs, depth):
    args, k, pre = [t for t, _ in words[1:]], 0, []
    while k < len(args) and args[k].startswith("-"):
        if args[k] in ("-C", "--git-dir", "--work-tree", "--namespace", "--super-prefix"):
            pre.append(args[k + 1] if k + 1 < len(args) else "")
            k += 2
        elif args[k] in ("-c", "--config-env", "--attr-source"):
            if k + 1 < len(args) and names_dir(args[k + 1]):
                FLAGS["doubt"] = True  # -c alias.x='!cat ...' / core.pager=...: git runs a configured command line
            k += 2
        else:
            pre.append(args[k])
            k += 1
    sub, rest = (args[k], args[k + 1:]) if k < len(args) else ("", [])
    srcs = named_files(rest, "", ("--pathspec-from-file",))  # git prints the pathspecs it cannot match
    if sub == "config":
        srcs += named_files(rest, "f", ("--file", "--blob"))
    elif sub in GIT_FILE_MSG:
        srcs += named_files(rest, "F", ("--file",))  # commit prints the subject line of the message file
        if sub == "commit":
            srcs += named_files(rest, "t", ("--template",))
    elif sub == "credential-store":
        srcs += named_files(rest, "", ("--file",))  # `get` prints the credentials the file holds
    elif sub in ("fast-export", "fast-import"):  # the marks file: git prints the line it cannot parse
        srcs += named_files(rest, "", ("--import-marks", "--import-marks-if-exists", "--export-marks"))
    if srcs:  # config -f FILE -l prints that file: the quiet subcommand becomes a reader
        FLAGS["verb"] = True
        note_dyn(srcs + pre + redirs)
        if any(spells(t) for t in srcs + pre + redirs):
            return True
    for line in git_command_lines(sub, rest):
        if scan(line, depth + 1):
            return True
    if sub not in GIT_READ:
        # any other subcommand (stash show, reflog, whatchanged ...) is calm only if known not to print content
        calm = not sub or sub in GIT_QUIET
        if sub in GIT_RUNNERS and any(names_dir(t) for t in rest):
            FLAGS["doubt"] = True  # difftool -x CMD, filter-branch --tree-filter CMD, bisect run CMD
        note_leaf("git" if calm else "git " + sub, words, redirs)
        return False
    if sub in ("log", "show") and not any(spells(t) for t in pre + redirs) and git_meta_only(sub, rest):
        FLAGS["verb"] = True  # a cd into the directory still counts: `git show --stat HEAD:./k` prints a blob
        note_dyn(rest + pre + redirs)
        note_leaf("git", words, redirs)
        return False
    if sub == "grep":
        ops, files, _ = grep_operands("grep", rest)
        note_roots([t for t in files if not EXCL_PATHSPEC.match(t)] or ["."])  # no pathspec: the whole work tree
        if any(p[:1] != "-" for p in pre):
            ROOTS.append(None)  # -C DIR, --git-dir=...: another tree
    else:
        ops, j = [], 0
        blamer = sub in ("blame", "annotate")  # blame -S FILE reads revisions from a file; log's -S is a string
        patterns = GIT_PATTERN_OPTS - {"-S"} if blamer else GIT_PATTERN_OPTS
        while j < len(rest):
            a = rest[j]
            if a == "--":
                ops += rest[j + 1:]  # after -- every argument is a pathspec, --author and -S included
                break
            if a in patterns:
                j += 2
            elif a.partition("=")[0] in patterns or (a[:2] in ("-S", "-G") and len(a) > 2
                                                     and not (blamer and a[:2] == "-S")):
                j += 1
            else:
                ops.append(a)
                j += 1
    ops = [t for t in ops if not EXCL_PATHSPEC.match(t)]
    FLAGS["verb"] = True
    note_dyn(ops + pre + redirs)
    return any(spells(t) for t in ops + pre + redirs)


def shell_reads(name, words, redirs, bodies, depth):
    args, k, has_c, has_s = [t for t, _ in words[1:]], 0, False, False
    while k < len(args):
        if args[k] in ("-o", "+o", "-O", "+O"):
            k += 2
        elif args[k] == "--":
            k += 1
            break
        elif args[k][:1] in "-+" and len(args[k]) > 1:
            short = args[k][0] == "-" and not args[k].startswith("--")
            has_c = has_c or (short and "c" in args[k])
            has_s = has_s or (short and "s" in args[k])  # -s: read the script from stdin, the rest are $1 $2
            k += 1
        else:
            break
    if k >= len(args) or (not has_c and (has_s or STDIN_SCRIPT.match(args[k]))):
        if bodies and not has_c:
            return False  # the heredoc / here-string body was scanned as code by check()
        raise Fail("shell script comes from stdin")
    if not has_c:
        if PH in args[k]:
            raise Fail("script comes from an expansion")
        # a script FILE is opaque, like any other program; its arguments may still name a reader
        return tail_reads(name, words, redirs, bodies, depth)
    return scan(args[k], depth + 1) or any(spells(t) for t in args[k + 1:])


def eval_reads(words, depth):
    args = [t for t, _ in words[1:]]
    if any("$" in t or PH in t for t in args):
        raise Fail("eval of an expansion")
    return scan(" ".join(args), depth + 1)


def find_reads(words, depth):
    args, k = words[1:], 0
    while k < len(args):
        if args[k][0] in ("-exec", "-execdir", "-ok", "-okdir"):
            if splitting([t for t, _ in args]):
                FLAGS["split"] = True  # find $DIR -exec cat {} +: the start points are what the reader opens
            sub, k = [], k + 1
            while k < len(args) and args[k][0] not in (";", "+"):
                sub.append(args[k])
                k += 1
            if sub and check(sub, [], [], depth):
                return True
        k += 1
    return False


CHDIR_OPT = re.compile(r"-[A-Za-z]*[CD]|--(chdir|cwd|directory)")  # a launcher option that may change directory


def tail_reads(name, words, redirs, bodies, depth):
    """A launcher or an unknown program: its own arguments may carry the real command."""
    found = False
    if name in ("xargs", "parallel"):
        FLAGS["dyn"] = True  # the operands of the wrapped command arrive on stdin, split into words
        FLAGS["split"] = True
    for j in range(1, len(words)):
        text, bare = words[j]
        head = norm(text)
        if (head in HEADS and (bare or name in LAUNCHERS)) or (name in LAUNCHERS and verb_of(head)):
            found = True
            if pathy(words[1:j], []) or any(carries(t) for t, _ in words[1:j]):
                FLAGS["doubt"] = True  # env -C DIR cat x: an option of the launcher names the path
            if any(CHDIR_OPT.match(t) for t, _ in words[1:j]):
                FLAGS["chdir"] = True  # env -C DIR, sudo -D DIR: the command runs somewhere else
            if check(words[j:], redirs, bodies, depth):
                return True
    if name in CARRIERS or (MUX[0] and name in MUXCMDS):
        host = int(name in MUXHOSTS)
        for text, bare in words[1:]:
            if not bare and re.search(r"\s", text):
                found = True
                MUX[0] += host
                try:
                    if scan(text, depth + 1):
                        return True
                finally:
                    MUX[0] -= host
        if dynamic([t for t, _ in words[1:]]):
            FLAGS["doubt"] = True  # the code string itself may sit in a variable or a substitution
        if any("#(" in t and names_dir(t) for t, _ in words[1:]):
            FLAGS["doubt"] = True  # tmux runs the command inside a #( ) format expansion
        if name in MUXHOSTS and any(t == "-" for t, _ in words[1:]):
            FLAGS["doubt"] = True  # load-buffer - / source-file -: text from stdin ends up typed or run
        note_leaf(name, words, redirs)  # a bare path operand still joins the command line it runs
    code = shell_string(name, words)
    if code is not None:
        found = True
        if scan(code, depth + 1):
            return True
    if not found:
        note_leaf(name, words, redirs)
    return False


def shell_string(name, words):
    """The command line a launcher hands to a shell: `env -S 'cmd args'`, `sudo -s|-i 'cmd args'`."""
    args = [t for t, _ in words[1:]]
    if name == "env":
        for k, a in enumerate(args):
            if a == "-S" or a == "--split-string":
                return args[k + 1] if k + 1 < len(args) else ""
            if a.startswith("--split-string="):
                return a.partition("=")[2]
            if a.startswith("-S") and len(a) > 2:
                return a[2:]
    elif name in ("sudo", "doas"):
        for k, a in enumerate(args):
            if a in ("-s", "-i", "--shell", "--login"):
                return " ".join(args[k + 1:])
    return None


def check(words, redirs, bodies, depth):
    spend(len(words) + 1)
    k = 0
    # inside a tmux command string `if` is the abbreviated if-shell, not the shell keyword
    while k < len(words) and ((words[k][0] in RESERVED and not (MUX[0] and words[k][0] == "if"))
                              or ASSIGN.match(words[k][0])):
        if words[k][0] == "function":
            raise Fail("function definition")  # the body runs later, under another name
        k += 1
    note_loose([t for t, _ in words[:k]] + bodies)
    if any(RSH in t for t, _ in words[:k]):
        FLAGS["split"] = True  # NAME=$(echo ' x' | cut ...): the variable holds reshaped text
    if pathy(words[:k], []):
        note_mention()  # NAME=...secrets/...: a later $NAME may read it
    for t, _ in words[:k]:
        note_assign(t)  # NAME=secrets, NAME[secrets]=1: a later $NAME or ${!NAME[@]} may name it
    words = words[k:]
    if not words and any(t[:1] == IN and spells(t) for t in redirs):
        return True  # zsh runs $READNULLCMD for `< file`, and a loop or group fed by it reads the file
    for j in range(1, len(words) - 1):
        if words[j][1] and words[j][0] in ("]]", "}"):  # zsh: `if [[ t ]] cmd`, `if { t } cmd` end the test here
            if check(words[j + 1:], redirs, bodies, depth):
                return True  # bash keeps the longer reading (`}` is an operand), which is checked below
            break  # a later closer is found by the call above
    if not words or words[0][0] in ("for", "case", "select"):
        # their operands are loop words / patterns; the body commands are lexed apart
        note_loose([t for t, _ in words] + redirs)
        if words and words[0][0] != "case" and splitting([t for t, _ in words[1:]]):
            FLAGS["split"] = True  # for f in $(...): the loop variable holds the split words
        if (pathy(words, redirs) or any(PATHY.search(b) or carries(b) for b in bodies)
                or (words and words[0][0] != "case" and any(carries(t) for t, _ in words[1:]))):
            note_mention()  # for f in secrets/*; do ... "$f"; a heredoc fed to `done`
        return False
    name = norm(words[0][0])
    if "$" in name or PH in name or "{}" in name:
        raise Fail("command word comes from an expansion")
    if words[0][0] not in ("[", "[[") and re.search(r"[*?\[{]", words[0][0]):
        raise Fail("command word is a glob or brace pattern")
    if name in CWD or name == "popd":
        FLAGS["chdir"] = True  # relative paths after it start elsewhere: no root can be told from a path by its name
    verb = None if name in CALM else verb_of(name)  # chmod ends in "od", but it is no octal dump
    # a heredoc / here-string is code when a shell-like word runs it; a guard verb, echo or ls only takes it as text
    if (bodies and not verb and name not in INERT and name not in SAFE
            and any(norm(t) in SHELLISH for t, _ in words) and any(scan(b, depth + 1) for b in bodies)):
        return True
    if verb:
        return verb_reads(verb, words, redirs)
    if name in SHELLS:
        return shell_reads(name, words, redirs, bodies, depth)
    if name == "eval":
        return eval_reads(words, depth)
    if name == "zmodload" and any("mapfile" in t for t, _ in words[1:]):
        raise Fail("zsh/mapfile: ${mapfile[path]} reads a file")
    if name in ("setopt", "unsetopt", "set", "shopt", "emulate") and any(
            re.search("extendedglob|extglob", t.lower().replace("_", "").replace("-", "")) for t, _ in words[1:]):
        raise Fail("extended glob: ^x, a~b and a# match in ways this scan does not model")
    if name == "trap":  # the handler string is code
        return any(scan(t, depth + 1) for t, _ in words[1:2])
    if name == "alias":  # name='cmd args': the value is code
        if any(carries(t.partition("=")[2]) for t, _ in words[1:]):
            FLAGS["doubt"] = True  # alias -g P=secrets (zsh): P stands for the name wherever it is written
        return any(scan(t.partition("=")[2], depth + 1) for t, _ in words[1:])
    if name in ("source", "."):
        if any(PH in t for t, _ in words[1:]):
            raise Fail("sourced text comes from an expansion")
        if words[1:2] and STDIN_SCRIPT.match(words[1][0]):
            if bodies:
                return False  # the heredoc / here-string body was scanned as code above
            raise Fail("sourced text comes from stdin")
        note_leaf(name, words, redirs)
        return False
    if name == "git":
        return git_reads(words, redirs, depth)
    if name == "find":
        note_leaf(name, words, redirs)
        return find_reads(words, depth)
    if name in ("read", "mapfile", "readarray"):
        FLAGS["split"] = True  # stdin is cut into variables, whatever later quotes them
        if any(PATHY.search(b) or carries(b) for b in bodies):
            note_mention()  # the variable takes its value from a body that names a path
    if name in INERT or name in SAFE:
        args = [t for t, _ in words[1:]]
        if name in CWD:
            note_dyn(args)  # cd "$D": the directory may be a secrets/ one
        elif name == "set" and splitting(args):
            FLAGS["split"] = True  # set -- $(...): the positional parameters hold the split words
        elif name in LISTFILE and any(LISTFILE[name].match(t) for t in args):
            FLAGS["verb"] = True
            note_dyn(args + redirs)
            if any(spells(t) for t in args + redirs):
                return True  # file -f secrets/k: the names it cannot open are the lines of the file
        note_leaf(name, words, redirs)
        return False
    return tail_reads(name, words, redirs, bodies, depth)


def scan(text, depth):
    lx = Lexer(text, depth)
    lx.commands(False)
    failed, run = False, []
    for words, redirs, bodies in lx.cmds:
        note_pieces(words, run)
        try:
            if check(words, redirs, bodies, depth):
                return True
        except Fail:
            failed = True
    if failed:
        raise Fail("unprovable")
    return False


def verdict(cmd):
    FLAGS.update(mention=False, loose=False, dyn=False, split=False, cwd=False, verb=False, doubt=False, chdir=False)
    del NAMED[:], ROOTS[:]
    WORK[0] = 0
    MUX[0] = 0
    try:
        if scan(cmd, 0):
            return "reader"
        walked = walked_over()
    except Fail:
        return "unparseable"
    except Limit:
        return "limit"
    except Exception:  # a bug, or an interpreter limit (RecursionError, MemoryError): the scan did not finish
        return "error"
    # No guard verb names a secrets/ operand. Stage 1 still saw `verb ... secrets/` on one line, so the
    # path may reach a reader without being its operand: stay denied unless that is ruled out.
    if (FLAGS["doubt"] or (FLAGS["mention"] and FLAGS["dyn"]) or (FLAGS["loose"] and FLAGS["split"])
            or (FLAGS["cwd"] and FLAGS["verb"]) or walked or "mapfile[" in cmd):  # zsh/mapfile: ${mapfile[path]}
        return "doubt"
    return "inert"


def arm_alarm():
    """End this process, printing nothing, after BUDGET_SECONDS of wall clock. SIGALRM is left at its
    default action so that not even a long C-level call can delay it; the caller reads a missing
    answer as a deny. AGENT_SECRETS_SCAN_BUDGET (seconds) can only shorten the budget."""
    if not hasattr(signal, "setitimer"):
        return
    try:
        asked = float(os.environ.get("AGENT_SECRETS_SCAN_BUDGET", ""))
    except ValueError:
        asked = BUDGET_SECONDS
    signal.signal(signal.SIGALRM, signal.SIG_DFL)  # an inherited SIG_IGN would disarm the alarm
    signal.setitimer(signal.ITIMER_REAL, min(BUDGET_SECONDS, max(asked, 0.001)))


if __name__ == "__main__" and not os.environ.get("S5_LIB"):
    arm_alarm()
    sys.stdout.write(verdict(os.environ.get("SCAN_INPUT", "")))
PY
IFS= read -r -d '' _G3_PY <<'PY'

# ---------------------------------------------------------------------------------------------------
# Guard 3a, run on top of the stage-2 Lexer above (this text is appended to it, S5_LIB=1 keeps stage 2
# from running its own verdict). The command text arrives on fd 3. Output, first line: allow, or
# "deny|ask <TAB> guard <TAB> log reason" followed by the teaching reason. A missing or garbled answer
# (crash, kill, alarm) is read by the caller as a deny.
# Judged: git clean -f, the discard-changes family, short-form force push to main/master, environment
# dumps, recursive rm at / ~ $HOME ../, find -delete|-exec rm and rsync --delete* at those roots. Only
# simple commands are judged; the Lexer flattens $( ) and backtick bodies into the same list, shell -c /
# eval / carrier strings / heredocs fed to a shell are scanned as code. Known gap: python -c style
# one-liners, values built from variables, scripts written and run later.
# ---------------------------------------------------------------------------------------------------
import subprocess
import time

G3_MARKS = re.compile("[\x01-\x06]")
G3_TOP = re.compile(r"^(?:(?:/|~|\$HOME|\$\{HOME\}|\.\.)(?:/\*?)?|/\*)$")  # a root, not a path below it
G3_DEAD = "\x22${NAME+x}\x22"
G3_HEADS = frozenset("git rm find rsync env printenv export declare typeset set ps eval command builtin".split()) | SHELLS | LAUNCHERS
G3_COARSE = re.compile(
    r"(?<![\w/.-])(?:env|printenv|export|declare|typeset|set|ps|rm|find|rsync)(?![\w-])"
    r"|git\b.{0,200}?\b(?:clean|checkout|restore|switch|stash|push)\b|/proc/[^/\s]+/environ", re.S)
G3_GIT_VALUE = {"-c", "--namespace", "--super-prefix", "--exec-path", "--config-env"}
G3_ENV_VALUE = {"-u", "-P", "-C", "--unset", "--chdir"}
G3_RSYNC_VALUE = {
    "-e", "--rsh", "--exclude", "--include", "--exclude-from", "--include-from", "--filter", "-f",
    "--files-from", "--log-file", "--backup-dir", "--suffix", "--partial-dir", "--temp-dir", "-T",
    "--bwlimit", "--port", "--timeout", "--rsync-path", "--max-size", "--min-size",
    "--compare-dest", "--copy-dest", "--link-dest", "--chmod", "--chown", "--usermap",
    "--groupmap", "--out-format", "--info", "--debug",
}
G3_PS_VALUE = {"-o", "-p", "-u", "-t", "-g", "-G", "-U", "-C", "-O", "-s", "-D", "-L", "-N"}
# a command that cannot change the work tree: a probe after it still tells the truth
G3_READONLY = frozenset("echo printf ls pwd true false : test [ [[ cat head tail wc grep egrep fgrep rg sleep date "
                        "whoami basename dirname which type stat file du id uname hostname".split())
G3_GIT_READONLY = frozenset("status log diff show rev-parse rev-list branch remote describe ls-files ls-tree "
                            "blame shortlog cat-file config fetch".split())
G3 = {"deny": [], "ask": [], "unsure": False, "unknown_state": False, "probes": {}, "n": 0, "branch": {}}
G3_DEADLINE = [0.0]


def g3_lit(t):
    # ${HOME} reaches the word as PH + HOME: read it back as $HOME
    return G3_MARKS.sub("", t).replace(PH + "HOME", "$HOME")


def g3_deny(guard, log, why, fix):
    G3["deny"].append((guard, log, why + "\nFIX: " + fix))


def g3_ask(guard, log, why, fix):
    G3["ask"].append((guard, log, why + "\nFIX: " + fix))


def g3_dump(form):
    g3_deny(
        "env-dump", "environment dump blocked: " + form.split(" ")[0],
        form + " blocked.\nWHY: env-dump guard - dumping the whole environment prints every secret the "
        "session holds (API keys, tokens) into the transcript, where it is stored and may be read back.",
        "test whether one variable is set without printing it: test -n " + G3_DEAD + " && echo set",
    )


def g3_short(a, letters):
    return a.startswith("-") and not a.startswith("--") and any(ch in a[1:] for ch in letters)


def g3_run(cdir, argv):
    """git <argv> in cdir, memoised; None when it cannot be answered (budget, error, not a repository)."""
    key = (cdir, tuple(argv))
    if key in G3["probes"]:
        return G3["probes"][key]
    left = G3_DEADLINE[0] - time.monotonic()
    out = None
    if G3["n"] < 6 and left > 0.3 and not (cdir and re.search(r"[$\x00-\x06\x60]", cdir)):
        G3["n"] += 1
        try:
            r = subprocess.run(
                ["git", "--no-optional-locks", "-c", "core.fsmonitor=false"] + (["-C", cdir] if cdir else []) + argv,
                stdin=subprocess.DEVNULL, capture_output=True, text=True, errors="replace",
                timeout=min(4.0, left), env=dict(os.environ, GIT_OPTIONAL_LOCKS="0"))
            out = r.stdout if r.returncode == 0 else None
        except Exception:
            out = None
    G3["probes"][key] = out
    return out


def g3_state_unknown(cdir_count, extra):
    return G3["unknown_state"] or cdir_count > 1 or extra


def g3_push(args, cdir, unsure):
    force, dry, repo = False, False, False
    pos = []
    k = 0
    while k < len(args):
        a = args[k]
        k += 1
        if a == "--":
            pos.extend(args[k:])
            break
        if a.startswith("--"):
            name = a.split("=", 1)[0]
            if name.startswith("--forc"):
                force = True
            elif name.startswith("--dry"):
                dry = True
            elif name == "--repo":
                repo = True
                if "=" not in a:
                    k += 1
            elif name in ("--receive-pack", "--exec", "--push-option") and "=" not in a:
                k += 1
        elif a.startswith("-") and len(a) > 1:
            if g3_short(a, "f"):
                force = True
            if g3_short(a, "n"):
                dry = True
            if a == "-o":
                k += 1
        else:
            pos.append(a)
    if dry:
        return
    refs = pos if repo else pos[1:]
    hit = False
    for ref in refs:
        plus = ref.startswith("+")
        dst = ref.lstrip("+").split(":")[-1]
        if dst.startswith("refs/heads/"):
            dst = dst[len("refs/heads/"):]
        if (force or plus) and dst in ("main", "master"):
            hit = True
    cur = [r for r in refs if r.lstrip("+").split(":")[-1] in ("HEAD", "")] if refs else []
    if force and (not refs or cur) and not hit:
        # force with no named branch: the current branch is what goes
        if unsure:
            br = None
        else:
            if (cdir,) not in G3["branch"]:
                out = g3_run(cdir, ["symbolic-ref", "--short", "-q", "HEAD"])
                G3["branch"][(cdir,)] = out.strip() if out is not None else None
            br = G3["branch"][(cdir,)]
        if br in ("main", "master"):
            hit = True
        elif br is None:
            g3_ask(
                "destructive", "force push without a named branch: current branch unknown",
                "git push --force without a branch name - user confirmation required.\nWHY: R6 - the current "
                "branch could not be read, and force-pushing main/master breaks every other clone.",
                "name the branch explicitly (git push --force-with-lease origin <feature-branch>).")
    if hit:
        g3_deny(
            "destructive", "force push to main/master blocked",
            "Force push to main/master blocked.\nWHY: R6 - rewriting a protected branch history breaks "
            "every other clone and open PR based on it.",
            "push to a feature branch and open a PR; on your own branch use git push --force-with-lease.")


def g3_discard_ask(sub, unknown):
    g3_ask(
        "destructive", "git " + sub + " discard: work tree state unknown",
        "git " + sub + " may discard changes - user confirmation required.\nWHY: destructive guard - the "
        "work tree status could not be established (" + ("an earlier command or a directory/option may have changed it"
                                                      if unknown else "the status check did not run") + ").",
        "run git status first; stash (git stash) or commit what you want to keep.")


def g3_git(lits, prior_unsafe):
    args = lits[1:]
    k, cdirs, extra = 0, [], False
    while k < len(args):
        a = args[k]
        if a == "-C" and k + 1 < len(args):
            cdirs.append(args[k + 1])
            k += 2
        elif a in ("--git-dir", "--work-tree") or a.startswith(("--git-dir=", "--work-tree=")):
            extra = True
            k += 1 if "=" in a else 2
        elif a in G3_GIT_VALUE:
            k += 2
        elif a.startswith("-"):
            k += 1
        else:
            break
    if k >= len(args):
        return
    sub, rest = args[k], args[k + 1:]
    cdir = cdirs[-1] if cdirs else None
    if cdir is not None and cdir.startswith("-"):
        cdir = "./" + cdir
    unknown = G3["unknown_state"] or prior_unsafe or len(cdirs) > 1 or extra
    if sub == "push":
        g3_push(rest, cdir, unknown)
    elif sub == "clean":
        flags, k = [], 0
        while k < len(rest):
            a = rest[k]
            k += 1
            if a == "--":
                break
            if a.startswith("--"):
                if a == "--exclude":
                    k += 1
                elif not a.startswith("--exclude="):
                    flags.append(a)
            elif a.startswith("-") and len(a) > 1:
                cut = a.find("e")
                if cut > 0:  # -e takes the rest of the bundle, or the next word, as its value
                    flags.append(a[:cut])
                    if cut == len(a) - 1:
                        k += 1
                else:
                    flags.append(a)
        if any(a == "--dry-run" or g3_short(a, "n") for a in flags):
            return
        if not any(a == "--force" or g3_short(a, "f") for a in flags):
            return
        if any(g3_short(a, "xX") for a in flags):
            g3_deny(
                "destructive", "git clean -x/-X blocked",
                "git clean with -x/-X blocked.\nWHY: destructive guard - it deletes ignored files too "
                "(.env, build output, local data) and none of it can be restored from git.",
                "preview with git clean -n, then delete the specific paths explicitly.")
            return
        out = None if unknown else g3_run(cdir, ["status", "--porcelain"])
        if out is not None and any(line.startswith("??") for line in out.splitlines()):
            g3_deny(
                "destructive", "git clean -f would delete untracked files",
                "git clean -f blocked: untracked files exist and would be deleted.\nWHY: destructive guard - "
                "untracked files are in no commit, so deletion cannot be undone.",
                "preview with git clean -n, commit or stash -u what you need, or delete specific paths explicitly.")
            return
        g3_ask(
            "destructive", "git clean -f requires confirmation",
            "git clean -f - user confirmation required.\nWHY: destructive guard - it deletes files from the work "
            "tree" + ("" if out is not None else " (the work tree state could not be established, so nothing was "
                                                  "verified)") + ".",
            "run git clean -n first and confirm the list is what you want removed.")
    elif sub in ("checkout", "restore", "switch"):
        flags = [a for a in rest if a.startswith("-") and a != "--"]
        if sub == "checkout":
            hit = "--" in rest or "." in rest or any(a == "--force" or g3_short(a, "f") for a in flags)
            pos = [a for a in rest if not a.startswith("-")]
            if not hit and pos and not any(a in ("-b", "-B", "--orphan", "-t", "--track", "--detach", "-d")
                                           or g3_short(a, "bBtd") for a in flags):
                # no --: git checkout <path> or <rev> <path> overwrites files; <branch> alone does not
                first_is_rev = g3_run(cdir, ["rev-parse", "--verify", "--quiet", pos[0] + "^{commit}"]) is not None
                if len(pos) >= 2 and first_is_rev:
                    hit = True
                elif not first_is_rev and not unknown and os.path.exists(os.path.join(cdir or ".", pos[0])):
                    hit = True
        elif sub == "restore":
            staged = any(a == "--staged" or g3_short(a, "S") for a in flags)
            tree = any(a == "--worktree" or g3_short(a, "W") for a in flags)
            hit = not staged or tree
        else:
            hit = any(a in ("--discard-changes", "--force") or g3_short(a, "f") for a in flags)
        if not hit:
            return
        out = None if unknown else g3_run(cdir, ["status", "--porcelain", "--untracked-files=no"])
        if out is None:
            g3_discard_ask(sub, unknown)
        elif out.strip():
            g3_deny(
                "destructive", "git " + sub + " would discard uncommitted changes",
                "git " + sub + " blocked: the work tree has uncommitted changes it would overwrite.\nWHY: "
                "destructive guard - discarded edits are in no commit and cannot be recovered.",
                "git stash (keeps the work) or commit first, then retry; use git restore --staged to only unstage.")
    elif sub == "stash" and rest[:1] in (["drop"], ["clear"]):
        g3_ask(
            "destructive", "git stash " + rest[0] + " requires confirmation",
            "git stash " + rest[0] + " - user confirmation required.\nWHY: destructive guard - a dropped "
            "stash is only recoverable through git fsck, not by a normal command.",
            "list it with git stash list and apply it (git stash apply) first if you may still need it.")


def g3_rm(args):
    recursive, operands, dd = False, [], False
    for a in args:
        if dd or not a.startswith("-") or a == "-":
            operands.append(a)
        elif a == "--":
            dd = True
        elif a.startswith("--rec") or (not a.startswith("--") and re.search(r"[rR]", a)):
            recursive = True
    if recursive and any(G3_TOP.match(o) for o in operands):
        g3_deny(
            "destructive", "recursive rm at a root blocked",
            "Recursive rm of root / home / parent blocked.\nWHY: destructive-deletion guard - an "
            "unscoped recursive delete is unrecoverable and can take the whole workspace with it.",
            "delete the specific target explicitly (e.g. rm -r ./<dir>) after verifying it with ls, or move "
            "it aside instead of deleting.")


def g3_sweep(kind, targets):
    if any(G3_TOP.match(t) for t in targets):
        g3_deny(
            "destructive", kind + " at a root blocked",
            kind + " aimed at root / home / parent blocked.\nWHY: destructive-deletion guard - a bulk "
            "delete or mirror-delete outside the project cannot be undone.",
            "name the exact project-local directory, run it without the delete option first (find without "
            "-delete, rsync --dry-run) and review the list.")
    else:
        g3_ask(
            "destructive", kind + " requires confirmation",
            kind + " - user confirmation required.\nWHY: destructive-deletion guard - it removes many files "
            "in one step and the list is not shown before it runs.",
            "preview first (find without -delete, rsync --dry-run) and confirm the target is the intended one.")


def g3_exec_rm(sub):
    """Does the -exec body (up to its ; or +) run rm, possibly behind launchers and their options?"""
    for w in sub:
        if w in (";", "+"):
            return False
        n = norm(w)
        if n == "rm":
            return True
        if n in LAUNCHERS or w.startswith("-") or ASSIGN.match(w) or w.isdigit():
            continue
        return False
    return False


def g3_find(args):
    k = 0
    while k < len(args) and (args[k] in ("-H", "-L", "-P") or args[k].startswith(("-D", "-O"))):
        k += 1
    roots = []
    while k < len(args) and not args[k].startswith("-") and args[k] not in ("(", "!"):
        roots.append(args[k])
        k += 1
    body = args[k:]
    rm_exec = any(a in ("-exec", "-execdir", "-ok", "-okdir") and g3_exec_rm(body[i + 1:])
                  for i, a in enumerate(body))
    if "-delete" in body or rm_exec:
        g3_sweep("find -delete" if "-delete" in body else "find -exec rm", roots or ["."])


def g3_rsync(args):
    flags = [a for a in args if re.match(r"--(?:del|delete(?:-[a-z-]+)?|remove-(?:source|sent)-files)$", a)]
    if not flags:
        return
    if any(a == "--dry-run" or g3_short(a, "n") for a in args if a.startswith("-")):
        return
    ops, k, dd = [], 0, False
    while k < len(args):
        a = args[k]
        if not dd and a == "--":
            dd = True
        elif not dd and a.startswith("-") and a != "-":
            if a in G3_RSYNC_VALUE or (not a.startswith("--") and a[-1:] in "efT"):
                k += 1
        elif re.match(r"(?:rsync://|(?:[^/:@]+@)?[^/:]+:)", a):
            ops.append("remote:")
        else:
            ops.append(a)
        k += 1
    remove_src = any("remove" in f for f in flags)
    targets = ops[-1:] + (ops[:-1] if remove_src else [])
    g3_sweep("rsync " + flags[0], [t for t in targets if t != "remote:"] or ["remote:"])


def g3_ps(args):
    k = 0
    while k < len(args):
        a = args[k]
        if a.startswith("--"):
            k += 1
            continue
        if a.startswith("-"):
            m = re.match(r"-([A-Za-z]+)", a)
            if m and "E" in m.group(1):
                g3_dump("ps " + a)
                return
            k += 2 if a in G3_PS_VALUE else 1
            continue
        if re.fullmatch(r"[A-Za-z]+", a) and "e" in a:
            g3_dump("ps " + a)
            return
        k += 1


def g3_env(words, lits, redirs, bodies, depth):
    args = lits[1:]
    k = 0
    while k < len(args):
        a = args[k]
        if a == "--":
            k += 1
            break
        if a in ("--help", "--version"):
            return
        if a.startswith("-S") or a.startswith("--split-string"):
            if a in ("-S", "--split-string"):
                text, rest = (args[k + 1] if k + 1 < len(args) else ""), args[k + 2:]
            else:
                text = a.split("=", 1)[1] if a.startswith("--split-string=") else a[2:]
                rest = args[k + 1:]
            try:
                parts = shlex.split(text)
            except ValueError:
                G3["unsure"] = True
                return
            g3_scan("env " + " ".join(shlex.quote(p) for p in parts + rest), depth + 1)
            return
        if a in G3_ENV_VALUE:
            k += 2
        elif a == "-" or a.startswith("-") or ASSIGN.match(a):
            k += 1
        else:
            break
    if k >= len(args):
        g3_dump("env" + (" (%d arguments)" % len(args) if args else ""))
    else:
        g3_cmd(words[1 + k:], redirs, bodies, depth + 1, False)


def g3_cmd(words, redirs, bodies, depth, prior_unsafe):
    """Judge one simple command; returns True when it may change the work tree or the directory."""
    spend(len(words) + 1)
    if depth > MAX_DEPTH:
        raise Limit("depth")
    k = 0
    while k < len(words) and (words[k][0] in RESERVED or ASSIGN.match(g3_lit(words[k][0]))):
        t = g3_lit(words[k][0])
        if re.match(r"(?:GIT_DIR|GIT_WORK_TREE|GIT_INDEX_FILE|GIT_COMMON_DIR|GIT_CEILING_DIRECTORIES)=", t):
            G3["unknown_state"] = True
        k += 1
    words = words[k:]
    for r in redirs:
        if re.search(r"/proc/[^/]+/environ", g3_lit(r)):
            g3_deny("env-dump", "environment read blocked: /proc environ",
                    "Reading /proc/<pid>/environ blocked.\nWHY: env-dump guard - it is the whole environment, "
                    "including every secret the process holds.",
                    "test whether one variable is set without printing it: test -n " + G3_DEAD + " && echo set")
    if not words:
        return bool(redirs)
    lits = [g3_lit(t) for t, _ in words]
    name = norm(lits[0])
    if "$" in name or PH in words[0][0] or "{}" in name:
        G3["unsure"] = True
        return True
    args = lits[1:]
    changes = name not in G3_READONLY and not (name == "git" and args[:1] and args[0] in G3_GIT_READONLY)
    if redirs and any(not r.startswith(IN) for r in redirs):
        changes = True
    if any(norm(x) in SHELLISH for x in lits) and bodies:
        for b in bodies:
            g3_scan(b, depth + 1)
    if name not in ("echo", "printf", "ls", "stat") and any(re.search(r"/proc/[^/]+/environ", x) for x in args):
        g3_deny("env-dump", "environment read blocked: /proc environ",
                "Reading /proc/<pid>/environ blocked.\nWHY: env-dump guard - it is the whole environment, "
                "including every secret the process holds.",
                "test whether one variable is set without printing it: test -n " + G3_DEAD + " && echo set")
    if name in CWD or name == "popd":
        G3["unknown_state"] = True
        return True
    if name in ("command", "builtin"):
        j = 1
        while j < len(lits) and lits[j].startswith("-"):
            if re.match(r"-[A-Za-z]*[vV]", lits[j]):
                return False
            j += 1
        if j < len(words):
            return g3_cmd(words[j:], redirs, bodies, depth + 1, prior_unsafe)
        return False
    if name == "env":
        g3_env(words, lits, redirs, bodies, depth)
        return True
    if name == "git":
        g3_git(lits, prior_unsafe)
        return changes
    if name == "rm":
        g3_rm(args)
        return True
    if name == "find":
        g3_find(args)
        return True
    if name == "rsync":
        g3_rsync(args)
        return True
    if name == "ps":
        g3_ps(args)
        return False
    if name == "printenv":
        if not any(a in ("--help", "--version") for a in args) and not [a for a in args if not a.startswith("-")]:
            g3_dump("printenv")
        return False
    if name in ("export", "declare", "typeset"):
        if all(a in ("-p", "-x", "-px", "-xp", "--") for a in args):
            g3_dump(" ".join([name] + args))
        return True
    if name == "set":
        if not args:
            g3_dump("set")
        return True
    if name in SHELLS:
        j, has_c = 0, False
        while j < len(args):
            if args[j] in ("-o", "+o", "-O", "+O"):
                j += 2
            elif args[j] == "--":
                j += 1
                break
            elif args[j][:1] in "-+" and len(args[j]) > 1:
                has_c = has_c or (args[j][0] == "-" and not args[j].startswith("--") and "c" in args[j])
                j += 1
            else:
                break
        if has_c and j < len(args):
            g3_scan(args[j], depth + 1)
        elif not has_c and (j >= len(args) or STDIN_SCRIPT.match(args[j])
                            or any(a.startswith("-") and not a.startswith("--") and "s" in a[1:] for a in args[:j])):
            if not bodies:
                G3["unsure"] = True  # the script comes from a pipe or the terminal: not visible here
        return True
    if name == "eval":
        if any("$" in a or PH in a for a in args):
            G3["unsure"] = True
        else:
            g3_scan(" ".join(args), depth + 1)
        return True
    if name in LAUNCHERS or name in ("rtk",):
        if name in CARRIERS:
            for (text, bare), lit in zip(words[1:], args):
                if not bare and re.search(r"\s", lit):
                    g3_scan(lit, depth + 1)
        for j in range(1, len(lits)):
            if norm(lits[j]) in G3_HEADS and not lits[j].startswith("-"):
                g3_cmd(words[j:], redirs, bodies, depth + 1, prior_unsafe)
                break
        return True
    return changes


def g3_scan(text, depth):
    if depth > MAX_DEPTH:
        raise Limit("depth")
    lx = Lexer(text, depth)
    lx.commands(False)
    unsafe = False
    for words, redirs, bodies in lx.cmds:
        if G3["deny"]:
            return
        try:
            if g3_cmd(words, redirs, bodies, depth, unsafe):
                unsafe = True
        except (Fail, Limit):
            raise
        except Exception:
            G3["crash"] = True
            return


def g3_main():
    text = os.fdopen(3, "rb").read().decode("utf-8", "replace")
    G3_DEADLINE[0] = time.monotonic() + 10.0
    verdict_reset()
    try:
        g3_scan(text, 0)
    except Limit:
        g3_deny("destructive", "command too deep or too large to scan",
                "Command too deeply nested or too large to scan (blocked fail-closed).\nWHY: the danger scan "
                "could not finish, so it cannot rule out a destructive command.",
                "split the command into smaller steps without deep wrapper chains.")
    except Fail:
        if G3_COARSE.search(text):
            g3_deny("destructive", "unparseable command with a dangerous word",
                    "A command the scan cannot parse names a destructive word (blocked fail-closed).\nWHY: bash "
                    "and zsh may read it differently, so the danger scan cannot say what runs.",
                    "write the command in plain form: one command per line, no unusual quoting.")
    if G3.get("crash") and not G3["deny"]:
        g3_deny("destructive", "danger scan internal error",
                "The danger scan failed internally (blocked fail-closed).\nWHY: no verdict means no proof the "
                "command is safe.",
                "retry; if it persists, report it with the command shape (not its text).")
    if G3["unsure"] and not G3["deny"] and G3_COARSE.search(text):
        g3_deny("destructive", "command text comes from a pipe or an expansion, with a dangerous word",
                "A shell fed from a pipe or an expansion names a destructive word (blocked fail-closed).\nWHY: "
                "the text that will run is not visible to the scan.",
                "put the command in the script text directly instead of piping or expanding it.")
    pick = G3["deny"][0] if G3["deny"] else (G3["ask"][0] if G3["ask"] else None)
    if not pick:
        sys.stdout.write("allow")
        return
    guard, log, body = pick
    sys.stdout.write(("deny" if G3["deny"] else "ask") + "\t" + guard + "\t" + log + "\n" + body)


def verdict_reset():
    FLAGS.update(mention=False, loose=False, dyn=False, split=False, cwd=False, verb=False, doubt=False, chdir=False)
    del NAMED[:], ROOTS[:]
    WORK[0] = 0
    MUX[0] = 0


signal.signal(signal.SIGALRM, signal.SIG_DFL)
signal.setitimer(signal.ITIMER_REAL, 14.0)
g3_main()
PY
_DG_ASK=""
# cheap pre-filter on the quote-stripped text: only commands that name a judged verb pay for the scan
_DG_FLAT=$(printf '%s' "$SCAN_CMD" | tr -d "\\\\\"'")
if printf '%s' "$_DG_FLAT" | grep -qE '(^|[^[:alnum:]_.-])(git|rm|find|rsync|env|printenv|export|declare|typeset|set|ps|eval|sh|bash|zsh|dash|ksh|ash|command|builtin)([^[:alnum:]_-]|$)|/proc/[^/ ]+/environ|\$'"'"'' ; then
  _DG_OUT=$({ printf '%s\n' "$_S5_PY"; printf '%s\n' "$_G3_PY"; } | S5_LIB=1 python3 -I - 3<<<"$SCAN_CMD" 2>/dev/null) || _DG_OUT=""
  _DG_HEAD="${_DG_OUT%%$'\n'*}"
  case "$_DG_HEAD" in
    allow) ;;
    deny$'\t'* | ask$'\t'*)
      _DG_BODY="${_DG_OUT#*$'\n'}"
      IFS=$'\t' read -r _DG_DEC _DG_GUARD _DG_LOG <<<"$_DG_HEAD"
      if [[ "$_DG_DEC" == "deny" ]]; then
        log_violation "$_DG_GUARD" "$_DG_LOG"
        emit_deny "$_DG_BODY"
        exit 0
      fi
      _DG_ASK=1
      ;;
    *)
      log_violation destructive "danger scan gave no usable answer"
      emit_deny "The danger scan (guard 3a) gave no usable answer (blocked fail-closed).
WHY: a crashed, killed or timed-out scan cannot rule out a destructive command or an environment dump, and an empty answer would read as allow.
FIX: retry the command; if it keeps failing, split it into smaller steps."
      exit 0
      ;;
  esac
fi

# 4a. Gate-config variables. AGENT_REVIEW_OVERRIDE is the USER's escape from the commit
# review gate; AGENT_WORKERS_DIR / AGENT_LOGS_DIR relocate the evidence ledger the gate
# reads; GITHEAD_<hex> is git's merged-head variable. An agent that sets any of them can
# approve its own risk-area commit, so DENY an assignment `NAME=` / `NAME+=` / `NAME:=`
# ANYWHERE in the quote- and backslash-stripped, message-stripped command ($SCAN_CMD, so a
# -m message body is not scanned) — a launcher prefix (timeout, nice, env, bash -o … -c)
# is covered by construction, not by enumeration. Also the builtins that name one
# (export/declare/typeset/local/readonly/read/mapfile/readarray/printf -v), and `set -a`
# in a command that mentions one. Mentions without `=` (grep NAME f, echo "$NAME",
# unset NAME, [[ "$NAME" == "" ]]) never match. Placed before the ask guards so a compound
# command still gets deny. Denies the recognised assignment forms and logs the attempt; a
# speed bump, not a boundary (brace/variable indirection, interpreter one-liners such as
# python/perl/node -e, and scripts written then run evade it).
_CMD_RO=$(printf '%s' "$SCAN_CMD" | tr -d "\\\\\"'")
_RO_NAMES='(AGENT_REVIEW_OVERRIDE|AGENT_WORKERS_DIR|AGENT_LOGS_DIR|GITHEAD_[0-9a-fA-F]+)'
_RO_LEAD='(^|[;&|({`]|(^|[[:space:];&|(])(ba|z|da|k)?sh([[:space:]]+-[A-Za-z]+)*[[:space:]]+-[A-Za-z]*c[A-Za-z]*[[:space:]]+|(^|[[:space:]])eval[[:space:]]+)[[:space:]]*((then|do|else|elif|if|while|until|time|!)[[:space:]]+)*'
if echo "$_CMD_RO" | grep -qE "(^|[^A-Za-z0-9_])${_RO_NAMES}[:+]?=" \
   || echo "$_CMD_RO" | grep -qE "${_RO_LEAD}(export|declare|typeset|local|readonly|read|mapfile|readarray|printf[[:space:]]+-v)[[:space:]]+[^;&|]*${_RO_NAMES}" \
   || { echo "$_CMD_RO" | grep -qE "${_RO_LEAD}set[[:space:]]+(-[A-Za-z]*a|-o[[:space:]]+allexport)" \
        && echo "$_CMD_RO" | grep -qE "${_RO_NAMES}"; }; then
  log_violation review-override "agent attempted to set a gate-config variable (AGENT_REVIEW_OVERRIDE/AGENT_WORKERS_DIR/AGENT_LOGS_DIR/GITHEAD_*)"
  emit_deny "Setting AGENT_REVIEW_OVERRIDE, AGENT_WORKERS_DIR, AGENT_LOGS_DIR or GITHEAD_* from an agent command is blocked.
WHY: review-override guard — these control the risk-area commit review gate (user-only escape, evidence-ledger location, merged heads); an agent setting one could approve its own commit.
FIX: run /council-review --staged and commit normally; if every external lane is down, ask the user to run the commit in their own terminal. If you only mention a variable in prose, write the message to a file and use git commit -F."
  exit 0
fi

# 4b. Evidence ledgers (reviews.jsonl, review-override.jsonl) are written only by
# call-worker.sh and review-evidence.py — their appends happen inside those scripts,
# not in an agent command string. DENY (case-insensitive: APFS) a Bash command that
# writes them: a `>`/`>>`/`>|` redirect onto one; a write verb (tee/cp/mv/ln/dd/rsync/
# scp/install/truncate/rm/shred/unzip/7z/tar/gpg/openssl/age — the write-capable members
# of the secrets guard's verb list) with a ledger name or the .agent/workers directory
# as ANY argument; sed -i naming one; or python open(...,'a'|'w'|'x'|'+') naming one.
# Reading (cat, grep, jq, open(...,'r')) is allowed. Same speed-bump caveat as 4a.
# basename boundary: the name must start the word or follow / = or whitespace, so
# my_reviews.jsonl is not a ledger. _LEDGER_Q is the same boundary for the quote-preserving
# python check (quote or / before the name).
_LEDGER='(^|[[:space:]/=])(reviews|review-override)\.jsonl'
_LEDGER_Q='[/"'"'"'](reviews|review-override)\.jsonl'
_WRITE_VERBS='tee|cp|mv|ln|dd|rsync|scp|install|truncate|rm|shred|unzip|7z|tar|gpg|openssl|age'
if echo "$_CMD_RO" | grep -qiE ">[>|]?[[:space:]]*([^[:space:];&|]*/)?(reviews|review-override)\.jsonl" \
   || echo "$_CMD_RO" | grep -qiE "(^|[^A-Za-z0-9_./-])(${_WRITE_VERBS})[[:space:]]+([^;&|]*[[:space:]/=])?((reviews|review-override)\.jsonl|\.agent/workers)" \
   || echo "$_CMD_RO" | grep -qiE "(^|[^A-Za-z0-9_./-])sed[[:space:]]+[^;&|]*-[A-Za-z]*i[^;&|]*${_LEDGER}" \
   || echo "$SCAN_CMD" | grep -qiE "open\([^)]*${_LEDGER_Q}[^)]*,[[:space:]]*[\"'][abwx+]"; then
  log_violation evidence-ledger "agent command writes a review evidence ledger"
  emit_deny "Writing a review evidence ledger (reviews.jsonl / review-override.jsonl) from an agent command is blocked.
WHY: evidence-ledger guard — these files are the proof the commit gate trusts and are written only by call-worker.sh and review-evidence.py; an agent-written row would forge a review.
FIX: produce the row by running /council-review (call-worker.sh appends it); reading the ledger (cat, grep, jq) is fine."
  exit 0
fi

# 4. Risk Area #1 — production data (DROP/TRUNCATE TABLE) — ASK (user confirms)
if echo "$SCAN_CMD" | grep -qiE '(DROP\s+TABLE|TRUNCATE\s+TABLE)'; then
  log_violation production-data "DROP/TRUNCATE TABLE requires user confirmation" "ask"
  emit_ask "DROP/TRUNCATE TABLE — user confirmation required (Risk Area #1: production-data).
WHY: a dropped or truncated table is unrecoverable without a verified backup.
FIX: proceed only if intended; otherwise run it as a reviewed migration with a backup in place."
  exit 0
fi

# 5. Risk Area #2 — secrets — DENY (no bypass).
# Covers many command variants in a single regex (read / hash / archive / encrypt / exfil families).
# To extend: add command name to the alternation. Project-specific paths can be
# added via hook-config.yml: risk_areas[id=secrets].paths.
# All secrets branches (5-11, 11b) match CASE-INSENSITIVELY (-qiE): on a
# case-insensitive filesystem (macOS APFS default) `cat SECRETS/key` reads the
# SAME file as `cat secrets/key`, so a case-sensitive match would be a trivial
# bypass. The command verbs are lowercase, so -i adds no meaningful false positives.
#
# Two stages, to stop false positives without opening a hole. Stage 1 is the regex below,
# unchanged: it only NOMINATES a command (no word boundary, no notion of command position, so
# it also fires on a grep PATTERN, a commit message or `head -n 2; ls x/secrets/`). Stage 2
# (_secrets_verdict) lexes the command like a shell and prints one word: `reader` (a guard verb
# is the command word and a `secrets/` operand is read), `doubt` (no such operand, but the path
# can still reach a reader through a $variable, a loop, a substitution, a cd or a program stage 2
# does not know), `inert` (parsed, provably neither), `unparseable` (a construct it does not
# model, or one on which bash and zsh disagree), `limit` (its work or nesting budget ran out)
# or `error`. A nominated command is denied unless stage 2 says exactly `inert`, so a lexer
# limit, an unbalanced quote, a crash, a missing python3, a non-zero exit, a killed process and
# an empty, garbled or truncated answer can only keep the old deny.
# Stage 1 never nominated `git show|blame|cat-file REV:secrets/x`, `git config -f secrets/x -l`
# nor `git tag|commit|merge -F secrets/x` (git stores the file as a message, which a later `git
# tag -n` or `git log` prints), and 0.8.0 allowed every `git log ... secrets/`. A second,
# additive candidate regex catches those. It denies a parsed `reader` and anything that is not an
# answer; `inert`, `doubt` and `unparseable` (a finished scan that found no read) are allowed, as
# before: a path that comes out of an expansion is a known gap, pinned in the test. A `git
# log|show` whose options all print commits, names or counts (--oneline, --name-only, --stat ...)
# only selects commits by the path and is inert; -p anywhere, -c, -L, --word-diff, a pickaxe, an
# option the scan does not know and REV:path are not.
# A secrets/ path inside a quoted word that has blanks (' secrets/k', 'x secrets/k') is no path of
# its own, but an unquoted $( ), $var, ${x#y}, xargs or read splits or reshapes it into one: stage 2
# notes such a mention (`loose`) and denies when a splitting consumer exists too. Prose next to a
# quoted "$f" or a heredoc inside "$( )" stays allowed.
# Stage 1 only sees a literal secrets/, so a path spelled otherwise is judged by its shape. An
# operand (also a cd target, a git pathspec or -C directory, a launcher's directory option) with a
# component that can read as the word secrets is a read: written out, with a glob (secre[t]s, s*),
# a brace group ({secrets,x}) or pieces ("$A"rets, $A$B, $(echo sec)rets, printf 'secrets\057k').
# Before a slash it may also end in the word, as the written-out x-secrets/ does (data_*/k). A name
# that an assignment (value or [key]), an array literal, a for list, the arguments of another
# command, a here-string, an alias or a launcher option carries on to a later $var, ${!m[@]} or cd
# is doubt: the word, a spelling of it, a name that ends in it (x-secrets) or holds it (secretsX,
# for ${D%X}), the pieces of consecutive echo or printf commands side by side, and an item after
# the first of a list that a splitting consumer hands on (D="x secrets"). A component that is one
# bare expansion ("$D"/k) is not judged: its value is unknown here.
# The value of an option that picks the files a reader reads is an operand too (rg -g, --glob,
# --iglob; ag -G, --file-search-regex; grep --include; rsync and tar --include): a glob that can
# spell the directory selects it. An exclusion (rg -g '!GLOB', --exclude-dir) picks nothing. A
# reader that walks into directories (grep -r, rg, ag, git grep, tar c, zip -r, cp -r, rsync -a,
# scp -r, 7z a, diff -r, gunzip -r) starts at its roots (no operand: the working directory). When
# the line also names a secrets/ path as a path elsewhere (ls secrets/), a root that is, holds or
# may hold it makes the line doubt. A root is cleared only when it provably lies apart from the
# path: both relative (or both absolute) with a different name at the same depth. ~, .., a
# variable, a pattern, a cd, a launcher's -C or -D, tar -C or -T and git -C leave it doubt.
# A command that never names the directory (find . -exec cat {} +, xargs cat, grep -r PATTERN .)
# is no read of it, with or without a mention that is only a pattern or prose.
# Where bash and zsh read the same text differently, a hand-written lexer cannot tell which text is
# code, so stage 2 says `unparseable` and the nominating deny stands: an expansion as a heredoc
# delimiter, $[ ], a quote inside a double-quoted ${ }, <<( ), a ( glued to a word, a line
# continuation inside a token or in a heredoc end, a subscript or array literal that holds a blank
# or an operator, a << or a # inside [[ ]], a } that closes nothing, a $'...' escape that the
# shells turn into different bytes (\c, \u, a code of 0 or from 128 up, an unknown escape: bash
# ends a word at a NUL, and so a heredoc delimiter), a $"..." heredoc delimiter (zsh keeps the
# dollar sign), and a shell or `source` that reads its script from stdin (sh -, bash -s,
# /dev/stdin); core/hooks/README.md lists them all.
# `git -c name=value` with the path in the value, written out or spelled, runs as a command
# (alias.x=!cmd, core.pager), and so do the program of --upload-pack and --receive-pack, the
# argument of difftool -x and the code string of an interpreter; rsync/tar --include selects what
# they read.
# Stage 2 spends a bounded amount of work (MAX_WORK word visits, MAX_DEPTH levels of nesting:
# `limit`) and arms a 2 s wall-clock alarm. hooks.json gives this hook a 30 s timeout (docs/
# hook-protocol.md section 14), and a hook the host kills prints no decision, which lets the call
# through: the deny has to be decided inside our own budget. The alarm kills stage 2 without an
# answer, which is a deny, so the worst case is 2 s plus the interpreter start-up.
# AGENT_SECRETS_SCAN_BUDGET=<seconds> can only shorten the alarm (a test seam).
# Not covered by stage 2, by design: text handed to an interpreter (python/perl/ruby/... bodies
# and -e strings: guard 11 still covers python/node -c|-e), script files, aliases defined
# elsewhere, a code string that reaches a program only through a variable (python3 -c "$X"),
# a name assembled from data the command line does not spell out (decoded text, a file's content,
# the environment), and a program that runs a quoted string but is not a code carrier stage 2 knows
# (shell -c, eval, ssh, su, watch and the terminal multiplexers are known; another tool with a
# command-line option of its own is not): its strings read as prose. Stage 2 is a speed bump
# against careless reads, like the rest of this file.
# Readers beyond the original list. One source for stage 1 (nominates a line), stage 2 (a VERBS
# member is a reader of its secrets/ operands; handed over as SCAN_READERS) and guard 11b. A line
# whose only reader is missing here is never nominated, so it never reaches stage 2. Stage 2 keeps
# precision: `ls secrets/ | sort` and a commit message that names the path stay allowed.
# Not listed on purpose: gzip, zcat, zless, zmore, batcat ... already end in a listed verb and stage 2
# denies them as unknown programs; as VERBS members they would count as known non-walking readers
# and let `gzip -r . ; ls secrets/` through. (zgrep, bzgrep and xzgrep need the list: stage 2 allowed them.)
# Inline interpreter code that 11b and its fail-closed branch look for: the interpreter, any words
# (options such as -I or -W "ignore", quoted or not) and then a code flag: -c -e -E -p -r, bundled
# (-le, -pe), --eval, --print, or deno's `eval` word, then the code: opened by a quote, glued
# (-c"x", -e'x') or spaced, plain or $'...', or unquoted with a backslash in it (node -p
# require\(...\)): a shell needs that escape for any code with a parenthesis, and the backslash
# keeps `pytest -p no:cacheprovider` and `pip install -r reqs.txt` out. Words in between are not
# told apart from a script name, so `python3 tool.py -e "vault/x"` also matches; that only costs
# when a declared path is named too.
_SECRET_INTERP='(python[0-9.]*|pypy[0-9]*|node|nodejs|deno|bun|perl|ruby|php)'
_SECRET_CODE_OPEN='(\$?["'"'"']|[^[:space:]]*\\)'
_SECRET_INLINE_CODE="${_SECRET_INTERP}([[:space:]]+[^[:space:];|&<>]+)*[[:space:]]+(-[a-zA-Z]*[ceEpr]|--eval|--print|eval)(=|[[:space:]]+)?[[:space:]]*${_SECRET_CODE_OPEN}"
# An interpreter fed a here-string reads its program from it (python3 <<< "open('p')"); echo "x" <<< "p"
# is only text and stays out.
_SECRET_HERESTRING="${_SECRET_INTERP}([[:space:]]+[^[:space:];|&<>]+)*[[:space:]]*<<<"
# `pr` is not listed: the unanchored match would nominate every `gh pr create --body ...secrets/...`,
# and stage 2 reads `pr` as a known reader of that body text (gh-pr-body-allow); coreutils pr is rare.
# `install` (a copy) is nominated and judged by stages 1-2 only: in 11b a bare word match would also
# catch `pip install` / `npm install`, including the remediation hint of the fail-closed branch, so
# 11b matches it as a command word instead (_SECRET_CMD_START_READERS).
_SECRET_STAGE12_ONLY='install'
# timeout/gtimeout read their options with getopt_long (GNU "+fk:ps:v", FreeBSD "+fhk:ps:v"): a short bundle
# that ends in k or s (-k, -vk, -fk) and a long option written out or as an unambiguous prefix (--kill-after,
# --kill, --k, --signal, --sig, --s) take the next word as their value; every other option (--foreground,
# --preserve-status, -v, -f, -p, --, and the glued -k5 / --signal=KILL forms) takes none, so the word after it is
# the duration. The duration is a word that looks like one - a number (5, .5, 5e0, 0x5, +5, or -0 right after
# --), inf / infinity with an optional unit (infs), a variable ($T, ${T}, "$T"), a quoted word ('5') - so the
# program name after it ("pip") is not. Words are capped at 64 characters: this regex is compiled for every
# command once risk_areas are declared, and an unbounded run that fails to match is quadratic in a UTF-8
# locale in glibc (a 400 KB word took 10 s); a longer word is not read as a duration or an option.
_SECRET_TIMEOUT='g?timeout([[:space:]]+((-[A-Za-z]{0,63}[ks]|--[ks][a-z-]{0,63})[[:space:]]+[^[:space:]-][^[:space:]]{0,63}|-[^[:space:]]{1,63}))*[[:space:]]+(inf(inity)?[smhd]?|-?[0-9.+][^[:space:]]{0,63}|\$[^[:space:]]{0,63}|["'"'"'][^[:space:]]{0,63})'  # supply-chain-scan: allow-literal wrapper name in a command-word regex, not a spawn
# A wrapper in front (env, time, timeout/gtimeout with its duration, command, exec, sudo, xargs with its
# options, NAME=value, a background launcher) or a
# path (/usr/bin/install) does not hide it; `pip install`, `npm install`, `make install` are not it.
_SECRET_CMD_START='(^|[;&|(`]|&&)[[:space:]]*(((env|nohup|time|command|exec|sudo|doas|nice|xargs|stdbuf)([[:space:]]+-[^[:space:]]+([[:space:]]+[^[:space:]-][^[:space:]]*)?)*|'"$_SECRET_TIMEOUT"'|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*)[[:space:]]+)*([^[:space:]]*/)?install[[:space:]]+'  # supply-chain-scan: allow-literal wrapper names in a command-word regex, not a spawn
_SECRET_MORE_READERS='base64|base32|basenc|sort|uniq|cut|paste|column|join|comm|expand|unexpand|fmt|shuf|cksum|b2sum|sha1sum|sha224sum|sha384sum|zgrep|bzgrep|xzgrep|iconv|split|look|vim|nano|emacs|jq|yq'
_secrets_verdict() {
  # a python3 that is missing, exits non-zero or is killed leaves `error` behind, never an allow
  printf '%s\n' "$_S5_PY" | SCAN_INPUT="$1" SCAN_READERS="$_SECRET_MORE_READERS|$_SECRET_STAGE12_ONLY" python3 -I - 2>/dev/null || printf 'error'
}
_S5_BLOCK=""
_S5_WHY=""
if echo "$COMMAND" | grep -qiE "(cat|tac|nl|head|tail|less|more|awk|sed|grep|egrep|fgrep|rg|ag|bat|hexdump|xxd|od|strings|dd|fold|rev|tee|cp|mv|ln|md5sum|shasum|sha256sum|sha512sum|wc|diff|cmp|gunzip|bunzip2|bzip2|bzcat|xz|xzcat|unxz|lzma|lz4cat|tar|unzip|7z|zip|gpg|openssl|age|rsync|scp|$_SECRET_MORE_READERS|$_SECRET_STAGE12_ONLY)\s+.*secrets/"; then
  _S5_V=$(_secrets_verdict "$COMMAND")
  case "$_S5_V" in
    inert) ;;
    reader) _S5_BLOCK="direct secrets/ access blocked" ;;
    doubt)
      _S5_BLOCK="direct secrets/ access blocked (path may reach a reader)"
      _S5_WHY="The scan could not rule out that the path reaches a reader (a variable, loop, substitution, cd or an unknown program) or that a recursive reader on the line (grep -r, rg, tar c, cp -r, rsync -a) walks into it." ;;
    unparseable)
      _S5_BLOCK="direct secrets/ access blocked (command not parseable)"
      _S5_WHY="The scan cannot tell what this command does (an unbalanced quote, or a construct bash and zsh read differently)." ;;
    *)  # limit, error, empty, garbled or truncated: no usable answer
      _S5_BLOCK="direct secrets/ access blocked (scan did not finish)"
      _S5_WHY="The scan gave no usable answer (time or work budget, or an internal error), so the old deny stands." ;;
  esac
elif echo "$COMMAND" | grep -qiE 'git\s+.*(show|log|blame|annotate|cat-file|archive|format-patch|diff-tree|diff-index|config|interpret-trailers|commit|commit-tree|tag|merge|notes|fmt-merge-msg|credential-store|fast-export|fast-import|add|stage|rm|reset|restore|checkout|stash)\s+.*secrets/'; then
  _S5_V=$(_secrets_verdict "$COMMAND")
  case "$_S5_V" in
    inert | doubt | unparseable) ;;  # a scan that finished and found no read: allowed, as in 0.8.0
    reader) _S5_BLOCK="direct secrets/ access blocked (git history or config read)" ;;
    *)  # limit, error, empty, garbled or truncated: no usable answer
      _S5_BLOCK="direct secrets/ access blocked (git history or config read, scan did not finish)"
      _S5_WHY="The scan gave no usable answer (time or work budget, or an internal error), so the old deny stands." ;;
  esac
fi
if [[ -n "$_S5_BLOCK" ]]; then
  log_violation secrets "$_S5_BLOCK"
  emit_deny "Direct secrets/ access blocked (Risk Area #2: secrets).${_S5_WHY:+ $_S5_WHY}
WHY: reading secret files into a session exposes plaintext credentials to logs and transcripts.
FIX: use environment variables read by your server-side code; for inventory, list key NAMES only (awk -F= on the env file, first field)."
  exit 0
fi

# 6. Risk Area #2 — curl/wget upload-from-secrets (exfiltration)
if echo "$COMMAND" | grep -qiE '(curl|wget)\s+.*(--data-binary\s+@|--post-file=|--upload-file\s+|-T\s+|-d\s+@|-F\s+\S*=@).*secrets/'; then
  log_violation secrets "secrets/ remote exfiltration blocked"
  emit_deny "curl/wget upload from secrets/ blocked (Risk Area #2: secrets).
WHY: uploading a secret file over the network is credential exfiltration.
FIX: never send secret files anywhere; pass short-lived tokens via environment variables instead."
  exit 0
fi

# 7. Risk Area #2 — xargs indirection (find ... | xargs cat etc.)
if echo "$COMMAND" | grep -qiE 'secrets/.*\|.*xargs|xargs\s+.*\bsecrets/'; then
  log_violation secrets "secrets/ xargs indirection blocked"
  emit_deny "secrets/ xargs indirection blocked (Risk Area #2: secrets).
WHY: piping secret paths through xargs is equivalent to reading them directly (same as find -exec).
FIX: for inventory, list key NAMES only via awk -F= on the env file."
  exit 0
fi

# 8. Risk Area #2 — stdin redirect from secrets/
if echo "$COMMAND" | grep -qiE '<>?\s*[^>]*secrets/'; then
  log_violation secrets "stdin redirect from secrets/ blocked"
  emit_deny "stdin redirect from secrets/ blocked (Risk Area #2: secrets).
WHY: redirecting a secret file into a command reads its plaintext into the session.
FIX: for inventory, use awk -F= on env files (key names only)."
  exit 0
fi

# 9. Risk Area #2 — find ... -exec on secrets/
if echo "$COMMAND" | grep -qiE 'find\s+.*secrets/.*-exec'; then
  log_violation secrets "find secrets/ -exec blocked"
  emit_deny "find secrets/ -exec blocked (Risk Area #2: secrets).
WHY: -exec runs an arbitrary reader over every secret file found.
FIX: for inventory, use awk -F= on env files (key names only)."
  exit 0
fi

# 10. Risk Area #2 — source / .  .env  files (plaintext token echo risk)
if echo "$COMMAND" | grep -qiE '(^|[;&|`(]|\bset\s+-a\s*&&)\s*(\.\s|source\s).*(secrets/|/\.env(\.|$|\s)|\.env\b)'; then
  log_violation secrets "source secrets/.env blocked — plaintext token exposure risk"
  emit_deny "source secrets/.env blocked (Risk Area #2: secrets).
WHY: sourcing an env file can echo tokens in plaintext into the session environment and transcript.
FIX: let server-side code read env vars at runtime; for inventory, use awk -F= on key names only."
  exit 0
fi

# 11. Risk Area #2 — Python/Node inline secret read (Bash matcher boundary)
if echo "$COMMAND" | grep -qiE '(python|python3|node)\s+(-c|-e)\s+["'"'"'].*(secrets/|/\.env|\.env\b)'; then
  log_violation secrets "Python/Node inline secret read blocked"
  emit_deny "Python/Node -c/-e reading secrets/.env blocked (Risk Area #2: secrets).
WHY: an inline one-liner bypasses the file-read guards and prints plaintext credentials.
FIX: read configuration through the app's own env handling (os.environ / process.env) in proper server-side code."
  exit 0
fi

# 11b. Risk Area #2 (project-declared paths) — hook-config.yml
# risk_areas.secrets.paths (P1-8: this field is now ENFORCED at runtime, closing
# the previously-aspirational config). Additive — the built-in secrets/ guards
# above always run first and are never weakened. The loader returns only safe
# literal path tokens (no regex/shell metacharacters), so the alternation built
# from them cannot inject a pattern. Covers the read/copy/archive/encrypt family
# plus curl/wget exfiltration for each declared path. hook_config.py sits next to
# this script; the project root (where .agent/hook-config.yml lives) is resolved
# the same way log_violation resolves it.
_HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)"
_PROJ_ROOT="${AGENT_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}}"
if [[ -n "$_PROJ_ROOT" && -n "$_HOOK_DIR" ]]; then
  # Secrets-path alternation ONLY (guard 11b): no config regex runs in this call, so the secrets
  # verdict below is settled before any T-4 risk-pattern evaluation (guard 15, last) can run
  # slowly or fail. Line 2, when present, says a data/deploy/payment extension is declared.
  _PY_OUT=$(_HD="$_HOOK_DIR" _PR="$_PROJ_ROOT" python3 - <<'PY' 2>/dev/null || true
import os, sys
# `python3 -` puts the working directory first on sys.path; drop it so a stray
# yaml.py / yaml/ in the repo cannot stand in for PyYAML.
try:
    _cwd = os.getcwd()
except OSError:  # deleted working directory
    _cwd = ""
sys.path[:] = [p for p in sys.path if p not in ("", ".", _cwd)]
sys.path.insert(0, os.environ.get("_HD", ""))
unparseable = False
toks = []
hook_config = None
try:
    import hook_config
    unparseable = hook_config.risk_areas_unparseable(os.environ.get("_PR", ""))
    if not unparseable:
        toks = hook_config.load_risk_area_secret_paths(os.environ.get("_PR", ""))
except Exception:
    toks = []
if unparseable:
    # '!' can never appear in a safe token, so this sentinel is unambiguous.
    print("!UNPARSEABLE")
else:
    # tokens are already a safe literal set (^[A-Za-z0-9._/\-]+$); escape the regex
    # dot so a config '.env.prod' matches literally, then join into an ERE group.
    print("|".join(t.replace(".", "[.]") for t in toks))
try:
    if hook_config.risk_config_declared(os.environ.get("_PR", "")):
        print("RISKCFG")
except Exception:
    pass
PY
)
  _EXTRA_SECRET_ALT=${_PY_OUT%%$'\n'*}
  _RISK_DECLARED=0
  [[ "$_PY_OUT" == *$'\nRISKCFG' ]] && _RISK_DECLARED=1
  _SECRET_READ_VERBS='cat|tac|nl|head|tail|less|more|awk|sed|grep|egrep|fgrep|rg|ag|bat|hexdump|xxd|od|strings|dd|fold|rev|tee|cp|mv|ln|md5sum|shasum|sha256sum|sha512sum|diff|cmp|gunzip|bunzip2|bzip2|bzcat|xz|xzcat|unxz|lzma|lz4cat|tar|unzip|7z|zip|gpg|openssl|age|rsync|scp|curl|wget|source|\.|'"$_SECRET_MORE_READERS"
  # P1-9: risk_areas declared but PyYAML absent -> the declared paths are unknown,
  # so deny anything the token match below could deny for SOME path: the same
  # unanchored verb match minus the path clause. That keeps fail-closed a strict
  # superset of the token path (incl. JSON-declared paths) and over-blocks
  # deliberately until PyYAML is installed.
  # Inline code and a here-string may span lines (python3 -c "<newline>open('p')<newline>"): look at
  # a copy with backslash-newline joined and newlines turned into blanks. Only the two interpreter
  # clauses use it; every other clause keeps its line-by-line match.
  _CMD_FLAT=$(hook_flatten_lines "$COMMAND")
  if [[ "$_EXTRA_SECRET_ALT" == "!UNPARSEABLE" ]]; then
    if echo "$COMMAND" | grep -qiE "($_SECRET_READ_VERBS)\s+" \
       || echo "$COMMAND" | grep -qiE "$_SECRET_CMD_START" \
       || echo "$_CMD_FLAT" | grep -qiE "$_SECRET_INLINE_CODE" \
       || echo "$_CMD_FLAT" | grep -qiE "$_SECRET_HERESTRING" \
       || echo "$COMMAND" | grep -qiE "\|.*xargs" \
       || echo "$COMMAND" | grep -qiE "(^|[^<])<>?\s*[\"']?[^ ;|&<>(]"; then
      log_violation secrets "risk_areas declared but unparseable (PyYAML missing)"
      emit_deny "Read/copy/upload command blocked: project secret paths cannot be checked (Risk Area #2: secrets).
WHY: .agent/hook-config.yml declares risk_areas, but PyYAML is not installed, so the declared secret paths are unknown and the guard fails closed.
FIX: install PyYAML (bash setup.sh --bootstrap asks first; or python3 -m pip install --user pyyaml), then retry."
      exit 0
    fi
    _EXTRA_SECRET_ALT=""
  fi
  if [[ -n "$_EXTRA_SECRET_ALT" ]]; then
    # P1-12: besides a reader verb followed by blank + path, a declared path is read through a
    # redirect (cat<p, `< p cat`, $(<p): no blank after any verb) and through inline interpreter
    # code (python3 -c "open('p')"), as guards 8 and 11 already catch for the built-in path.
    # The redirect operand is a word that holds the token, so `wc -c < README.md` stays allowed.
    if echo "$COMMAND" | grep -qiE "($_SECRET_READ_VERBS)\s+.*($_EXTRA_SECRET_ALT)" \
       || echo "$COMMAND" | grep -qiE "${_SECRET_CMD_START}.*($_EXTRA_SECRET_ALT)" \
       || echo "$COMMAND" | grep -qiE "(^|[^<])<>?\s*[\"']?[^ ;|&<>]*($_EXTRA_SECRET_ALT)" \
       || echo "$_CMD_FLAT" | grep -qiE "${_SECRET_INLINE_CODE}.*($_EXTRA_SECRET_ALT)" \
       || echo "$_CMD_FLAT" | grep -qiE "${_SECRET_HERESTRING}.*($_EXTRA_SECRET_ALT)" \
       || echo "$COMMAND" | grep -qiE "($_EXTRA_SECRET_ALT).*\|.*xargs"; then
      log_violation secrets "project secrets path access blocked"
      emit_deny "Access to a project-declared secret path blocked (Risk Area #2: secrets).
WHY: hook-config.yml risk_areas.secrets.paths marks this path as secret; reading/copying/uploading it exposes credentials.
FIX: read the value via environment variables in server-side code; for inventory, list key NAMES only (awk -F= on the env file)."
      exit 0
    fi
  fi
fi

# 12. Project-customizable risk area — `data/artifacts/ git add` (optional default).
# Override by editing this rule or adding to hook-config.yml: risk_areas.
if echo "$COMMAND" | grep -qE 'git\s+add\s+.*data/artifacts/'; then
  log_violation project-policy "data/artifacts/ git add blocked"
  emit_deny "data/artifacts/ git add blocked (project policy).
WHY: large binary artifacts bloat git history permanently and never diff meaningfully.
FIX: keep artifacts out of git (.gitignore) and use artifact/object storage; commit the code that generates them instead."
  exit 0
fi

# 13. Verification-gate bypass — `git commit/push --no-verify` (or `git commit -n`).
# These skip the repo's own pre-commit / pre-push hooks (gitleaks + sanitize),
# which is exactly how an unscanned secret or prior-project taint slips in. ASK
# (not deny): a gate bypass is reversible, and ask keeps a commit that merely
# mentions "-n" in its MESSAGE from being hard-blocked. `git push -n` is
# --dry-run, NOT no-verify, so push only matches the long `--no-verify` form.
#
# Match, on the message-stripped command, so the flag — not a -m "..." message
# that says "-n" — is what triggers:
#   - `--no-verify` after a `git commit`/`git push` (allowing global opts such as
#     `-c key=val` between `git` and the subcommand);
#   - any single-dash short-flag CLUSTER containing -n on commit — `-n`, `-nm`,
#     `-vn` (git parses `-nm` as `-n -m`). `(\s|^)-[a-z]*n[a-z]*(\s|$)` matches a
#     lowercase short cluster only, so a --long flag (`--amend`), a `-C<value>`
#     reuse arg, or an n-free cluster (`-am`) never false-positives;
#   - `core.hooksPath=` inline config, which disables hooks with no --no-verify.
_CMD_NG=$(printf '%s' "$COMMAND" | sed -E "s/'[^']*'//g; s/\"[^\"]*\"//g")
if echo "$_CMD_NG" | grep -qE 'git\s+([^ ;|&`]+\s+)*commit\b[^|;&]*(--no-verify|(\s|^)-[a-z]*n[a-z]*(\s|$))' \
   || echo "$_CMD_NG" | grep -qE 'git\s+([^ ;|&`]+\s+)*push\b[^|;&]*--no-verify' \
   || echo "$_CMD_NG" | grep -qE 'git\s+[^;|&]*\bcore\.hooksPath='; then
  log_violation verify-bypass "git --no-verify skips the commit/push gate" "ask"
  emit_ask "git --no-verify (or -n / -nm / core.hooksPath=) skips the repo's own pre-commit/pre-push gate.
WHY: verify-bypass guard — those hooks run gitleaks + sanitize; bypassing them is exactly how an unscanned secret or prior-project taint slips in.
FIX: commit through the normal path and fix the failing hook; confirm only if you truly intend to skip secret/taint scanning."
  exit 0
fi

# 14. Linter/gate config tampering via Bash — disabling a check to make code
# "pass" instead of fixing the code (the ECC-flagged anti-pattern). Matches a
# MUTATING shell op (sed -i / redirect / rm / mv / tee / truncate) whose TARGET
# is a known linter/formatter/gate config. ASK — config edits can be legitimate;
# the user confirms it is not a check being silently weakened. Reading a config
# (cat/grep) is not matched — and neither is a read that merely redirects its
# output ELSEWHERE (`cat .eslintrc.json > backup.txt`), because the redirect
# branch requires the config to be the redirect target. tsconfig/pyproject are
# intentionally out of scope (too broad, edited routinely) to avoid false positives.
_LINT_CFG='(\.eslintrc[a-zA-Z.]*|eslint\.config\.[a-zA-Z]+|\.prettierrc[a-zA-Z.]*|prettier\.config\.[a-zA-Z]+|\.?ruff\.toml|\.flake8|biome\.jsonc?|\.golangci\.ya?ml|\.pre-commit-config\.ya?ml|gitleaks\.toml)'
if echo "$COMMAND" | grep -qE "(sed\s+-i[^;|&]*|>>?\s*|\brm\s+[^;|&]*|\bmv\s+[^;|&]*|\btee\s+[^;|&]*|\btruncate\s+[^;|&]*)$_LINT_CFG"; then
  log_violation lint-tamper "linter/gate config modified via shell" "ask"
  emit_ask "This modifies a linter/formatter/gate config file.
WHY: gate-tamper guard — disabling a check to make code pass hides the defect instead of fixing it.
FIX: fix the flagged code itself; edit the config only when the rule change is the actual, reviewed intent. (Reading configs never asks.)"
  exit 0
fi

# 15. Project-declared risk-area paths (T-4) - hook-config.yml/json
# risk_areas.<data|deploy|payment>.pattern. EXTENSION-ONLY: this runs after every built-in
# guard above (secrets 11b included), so a built-in deny/ask is always settled first and a slow
# or broken config can never delay or suppress it; a config pattern can only ADD an `ask` (or an
# explicit `decision: deny`) for a command that modifies a matching path. hook_config bounds the
# whole evaluation by one process-wide deadline. Only projects that declare an area pay for this
# second python start (line 2 of the 11b call).
_RISK_RECORDS=""
# No verb pre-filter: any text-level filter must be a superset of what the tokenizer reads
# (`to\uch`, `s\ed`, `git -c 'x=;' add`, a line continuation all reach a writer), and a global
# pattern substitution over the command is super-linear on bash 3.2. A project that declared an
# area simply evaluates every Bash command; a project that declared none never starts python.
# The command travels in an env var, and exec caps ONE string near 128 KB — counted in BYTES, so
# the size test runs under LC_ALL=C (a UTF-8 shell counts characters: 50,000 Korean characters
# are 150 KB). A bigger command is cut by bytes and flagged, and hook_config then reports it as
# truncated (fail-closed), never as clean. The event itself goes over stdin, whatever its size,
# so its cwd always arrives.
_RISK_CUT=0
_RISK_ARG="$SCAN_CMD"
_rk_lc=${LC_ALL-__unset__}
LC_ALL=C
if (( ${#SCAN_CMD} > 100000 )); then
  _RISK_ARG=${SCAN_CMD:0:100000}
  _RISK_CUT=1
fi
if [[ "$_rk_lc" == __unset__ ]]; then unset LC_ALL; else LC_ALL="$_rk_lc"; fi
if [[ "${_RISK_DECLARED:-0}" == 1 && -n "${_HOOK_DIR:-}" && -n "${_PROJ_ROOT:-}" ]]; then
  # Belt and braces: hook_config has its own deadline; this outer bound covers a non-POSIX or
  # otherwise signal-less python. Where no timeout binary exists the in-process deadline stands.
  _RISK_TMO=()
  if command -v timeout >/dev/null 2>&1; then _RISK_TMO=(timeout 5); fi
  read -r -d '' _RISK_PY <<'PY' || true
import json, os, sys
try:
    _cwd = os.getcwd()
except OSError:
    _cwd = ""
sys.path[:] = [p for p in sys.path if p not in ("", ".", _cwd)]
sys.path.insert(0, os.environ.get("_HD", ""))
try:
    import hook_config
    try:
        ev = json.loads(sys.stdin.read() or "{}")
        ev_cwd = ev.get("cwd", "") if isinstance(ev, dict) else ""
    except Exception:
        ev_cwd = ""
    for line in hook_config.risk_command_report(os.environ.get("_PR", ""), os.environ.get("_CMD", ""),
                                                ev_cwd if isinstance(ev_cwd, str) else "",
                                                os.environ.get("_CUT") == "1"):
        print(line)
    print("END")
except Exception:
    pass
PY
  _RISK_RECORDS=$(printf '%s' "$INPUT" | _HD="$_HOOK_DIR" _PR="$_PROJ_ROOT" _CMD="$_RISK_ARG" _CUT="$_RISK_CUT" "${_RISK_TMO[@]}" python3 -c "$_RISK_PY" 2>/dev/null)
  # A python that did not run to the end (exec failure, crash, outer timeout) is reported, never
  # silent. Extension-only: the built-in verdicts above stand; pre-push / auto-ship, which read the
  # real changed-file list, are the backstop. Failing closed here would ask on EVERY command of a
  # declared project whenever the interpreter hiccups.
  case "$_RISK_RECORDS" in
    *END) ;;
    *) echo "hook_config: risk-area evaluation did not complete - project risk_areas not applied to this command (built-in guards unaffected)" >&2 ;;
  esac
fi
if [[ -n "${_RISK_RECORDS:-}" ]]; then
  # The strongest decision wins and the message names the area(s) that reached it, with only their
  # paths. Synthetic hits (truncated / unevaluated) arrive already capped at `ask`.
  _RISK_HIT_RANK=-1
  while IFS=$'\t' read -r _rk_kind _rk_a _rk_b _rk_c; do
    case "$_rk_kind" in
      WARN) echo "hook_config: $_rk_a" >&2 ;;
      HIT)
        case "$_rk_b" in deny) _rk_rank=2 ;; ask) _rk_rank=1 ;; *) _rk_rank=0 ;; esac
        if (( _rk_rank > _RISK_HIT_RANK )); then _RISK_HIT_RANK=$_rk_rank; fi
        ;;
    esac
  done <<< "$_RISK_RECORDS"
  _RISK_HIT_AREA="" _RISK_HIT_DEC="" _RISK_HIT_PATHS=""
  if (( _RISK_HIT_RANK >= 0 )); then
    case "$_RISK_HIT_RANK" in 2) _RISK_HIT_DEC=deny ;; 1) _RISK_HIT_DEC=ask ;; *) _RISK_HIT_DEC=advisory ;; esac
    while IFS=$'\t' read -r _rk_kind _rk_a _rk_b _rk_c; do
      if [[ "$_rk_kind" == HIT && "$_rk_b" == "$_RISK_HIT_DEC" ]]; then
        case ",$_RISK_HIT_AREA," in *",$_rk_a,"*) ;; *) _RISK_HIT_AREA="${_RISK_HIT_AREA:+$_RISK_HIT_AREA,}$_rk_a" ;; esac
        _RISK_HIT_PATHS="${_RISK_HIT_PATHS:+$_RISK_HIT_PATHS, }$_rk_c"
      fi
    done <<< "$_RISK_RECORDS"
  fi
  if [[ -n "$_RISK_HIT_AREA" ]]; then
    log_violation project-risk-area "project $_RISK_HIT_AREA path modified: ${_RISK_HIT_PATHS:0:200}" "$_RISK_HIT_DEC"
    _RISK_MSG="Command modifies a project-declared $_RISK_HIT_AREA path (Risk Area: $_RISK_HIT_AREA): ${_RISK_HIT_PATHS:0:200}
WHY: .agent/hook-config risk_areas ($_RISK_HIT_AREA) marks these paths as high-risk; automation must not change them without a human decision.
FIX: confirm only if this change is intended; otherwise leave the file to a reviewed change, or narrow the pattern in .agent/hook-config.yml."
    if [[ "$_RISK_HIT_DEC" == "deny" ]]; then emit_deny "$_RISK_MSG"; else emit_ask "$_RISK_MSG"; fi
    exit 0
  fi
fi

# 3a (ask half): held back from guard 3a so that every deny above (secrets, review gates, a project
# risk area declared deny) wins over it; only the allow path reaches here.
if [[ -n "$_DG_ASK" ]]; then
  log_violation "$_DG_GUARD" "$_DG_LOG" "ask"
  emit_ask "$_DG_BODY"
  exit 0
fi

exit 0
