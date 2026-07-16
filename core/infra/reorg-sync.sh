#!/usr/bin/env bash
# reorg-sync.sh — sweep orphaned path references after a directory move (W-2).
#
# When a project tree moves (drive reorg, folder rename), absolute-path references
# left in config and metadata silently break: a git worktree's gitfile points at a
# gone .git, a crontab job runs a path that no longer exists, a shebang names a dead
# interpreter, a doc anchors to a moved file, and the path-keyed native-memory dir
# orphans. This tool takes the OLD and NEW path prefixes as arguments (nothing is
# hardcoded — it is repo-generic) and reports every such reference under a target
# tree, optionally rewriting them in place.
#
# Five reference classes are swept:
#   shebang            #!<old>/... interpreter lines
#   worktree-gitfile   `gitdir: <old>/...` lines in .git files
#   crontab            cron rows (5 schedule fields) whose command path is under <old>
#   anchor             any other textual reference to <old> (docs, config, rules)
#   native-memory-key  references to ~/.claude/projects/<encoded>/ where the path is
#                      encoded with / . _  ->  -  (the native-memory dir key); the OLD
#                      encoded key is rewritten to the NEW one, matching the harness's
#                      documented memory-key transform.
#
# Default is a DRY-RUN report (one `CLASS  file:line  <text>` row per hit, plus a
# per-class count summary). `--apply` performs LITERAL replacement anchored at a
# path-component boundary (re.escape'd literal + boundary lookarounds — no sed
# delimiter hazards, and no sibling bleed: `/old/prefixed-thing` is NOT a hit for
# `/old/prefix`). Encoded-key replacement is confined to lines carrying the
# documented consumer context (`claude/projects`) so ordinary kebab-case text is
# never touched. When NEW extends OLD (`/proj` -> `/proj_v2`), existing NEW
# occurrences are protected first, so re-running --apply is a no-op. Writes are
# atomic (temp + rename, permissions preserved); a file that cannot be written is
# reported and the sweep continues. Binary files and the .git object store are
# skipped; the .git *file* (worktree pointer) is scanned. Exit 0 for a clean/dry
# report; exit 1 on a usage error or if any --apply write failed.
#
# Usage:
#   bash core/infra/reorg-sync.sh --old <old-prefix> --new <new-prefix> \
#        --root <tree> [--apply]
#
# Env seams (for tests): none required — everything is an argument.
set -u

usage() {
  cat >&2 <<'EOF'
usage: reorg-sync.sh --old <old-prefix> --new <new-prefix> --root <tree> [--apply]
  --old    the path prefix that moved away (e.g. /mnt/old/project)
  --new    the path prefix it moved to     (e.g. /mnt/new/project)
  --root   the tree to sweep for references
  --apply  rewrite references in place (default: dry-run report only)
EOF
  exit 1
}

OLD="" NEW="" ROOT="" APPLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --old)   OLD="${2:-}"; shift 2 || usage ;;
    --new)   NEW="${2:-}"; shift 2 || usage ;;
    --root)  ROOT="${2:-}"; shift 2 || usage ;;
    --apply) APPLY=1; shift ;;
    -h|--help) usage ;;
    *) echo "reorg-sync: unknown argument: $1" >&2; usage ;;
  esac
done

[[ -n "$OLD" && -n "$NEW" && -n "$ROOT" ]] || usage
if [[ ! -d "$ROOT" ]]; then
  echo "reorg-sync: --root is not a directory: $ROOT" >&2
  exit 1
fi
# a bare "/" old-prefix would match everything — refuse the footgun.
if [[ "$OLD" == "/" || "$OLD" == "" ]]; then
  echo "reorg-sync: refusing a root ('/') or empty --old prefix (would match everything)" >&2
  exit 1
fi
# a newline inside either prefix would inject lines into swept files (a crontab
# reference file could gain a whole synthetic row) — refuse.
if [[ "$OLD" == *$'\n'* || "$NEW" == *$'\n'* ]]; then
  echo "reorg-sync: refusing --old/--new containing a newline (line-injection hazard)" >&2
  exit 1
fi

# The whole sweep + apply is done in Python: portable, and str.replace is a safe
# literal substitution (no sed delimiter / regex-metachar corruption of paths).
OLD="$OLD" NEW="$NEW" ROOT="$ROOT" APPLY="$APPLY" python3 <<'PY'
import os, sys, re

old = os.environ["OLD"]
new = os.environ["NEW"]
root = os.environ["ROOT"]
apply = os.environ["APPLY"] == "1"

def enc(p):
    # native-memory dir key: '/', '.', '_' -> '-'  (harness memory-key transform)
    return re.sub(r"[/._]", "-", p)

old_key, new_key = enc(old), enc(new)

# Boundary-anchored matchers (2026-07-15 adversarial-review fix — unbounded
# substring replacement corrupted sibling paths and broke idempotency;
# 2026-07-16 fix — the first attempt used an ASCII-only blocklist that still
# leaked CJK and punctuation siblings, live on this drive's Korean top-level
# folders).
#
# A filename component can hold almost any character (every Unicode letter and
# digit, '.', '-', '_', '+', '@', '~', '%', ...), so a blocklist of "continuation
# chars" is always incomplete. We instead WHITELIST the boundary: a PATH hit is a
# real reference only when the next char is '/', a line/string end, whitespace,
# or an unambiguous path DELIMITER (quote, structural punctuation). Anything else
# — any word char in any script, '.', '-', '+', '@', '~', '%' — is treated as a
# continuation (a sibling name) and skipped, failing toward a dry-run-visible
# MISS rather than silent sibling corruption. '/sub' continuation still matches.
# Residual (documented): a directory whose name is the moved prefix + a literal
# space + more (e.g. `/old/data 2024` when OLD=`/old/data`) is treated as the
# component `data` followed by text — the dry-run surfaces it before apply.
_BOUNDARY = r"""(?=/|$|[\s"'`:,;=|<>(){}\[\]])"""
# LEFT boundary (2026-07-16 code-review fix): a path match must also START at a
# path boundary, or OLD would match as the *tail* of a longer, unrelated
# absolute path — e.g. OLD=/proj/x wrongly hitting /other/tree/proj/x. Unlike
# the right side, a preceding '/' is NOT a boundary (it would mean OLD is a
# sub-path of a different absolute path); block it along with any path-body char
# (word chars in any script, '. - ~ + @ %'). Vacuously true at string start.
_LEFT = r"(?<![\w./~+@%\-])"
path_pat = re.compile(_LEFT + re.escape(old) + _BOUNDARY)
new_pat = re.compile(_LEFT + re.escape(new) + _BOUNDARY)
# The encoded key alphabet is '-' (into which only / . _ fold) plus every
# surviving component char — so chars like ~ + @ % and CJK punctuation
# (e.g. U+30FB '・') stay INSIDE a component yet are non-\w. A \w-based key
# boundary therefore leaked sibling keys ('-x-논문・백업', '-x-논문~백업') — the
# 2026-07-16 workflow panel confirmed this silently corrupted a different
# project's memory key. Fix: WHITELIST the key boundary the same way the path
# layer does, with the one difference that '-' IS a key boundary (it is the key's
# own component separator, so a deeper key '-x-논문-sub' must still rewrite).
# Left side: preceded by a boundary/delimiter, '/', or string start — never a
# component-body char (blocks a longer key that merely ends with old_key).
_KEY_R = r"""(?=[-/]|$|[\s"'`:,;=|<>(){}\[\]])"""
_KEY_L = r"""(?<![^\s"'`:,;=|<>(){}\[\]/])"""
key_pat = re.compile(_KEY_L + re.escape(old_key) + _KEY_R)
new_key_pat = re.compile(_KEY_L + re.escape(new_key) + _KEY_R)
KEY_CTX = "claude/projects"

# NUL can never occur in swept text (binary files are skipped on b"\x00"), so it
# is a safe protection nonce: when NEW itself still matches the OLD pattern (NEW
# extends OLD, e.g. /proj -> /proj/inner or /proj -> /proj_v2), mask existing
# *complete* NEW references before substituting so a re-run is a no-op instead of
# compounding. The mask is BOUNDARY-ANCHORED (repl_pat), NOT a blind substring:
# a blind text.replace(NEW, …) would also eat the NEW-shaped PREFIX of a genuine
# OLD reference like /proj/innerX, silently dropping a hit the dry-run reported
# (2026-07-16 workflow panel). Restoring the nonce afterward leaves protected
# references byte-identical.
NONCE = "\x00"

def sub_protected(pat, repl, repl_pat, text):
    if not pat.search(repl):
        return pat.sub(lambda m: repl, text)
    text = repl_pat.sub(lambda m: NONCE, text)
    text = pat.sub(lambda m: repl, text)
    return text.replace(NONCE, repl)

# classify a single line's hit for reporting. Order matters: most specific first.
def classify(line):
    stripped = line.lstrip()
    has_path = path_pat.search(line) is not None
    if stripped.startswith("#!") and has_path:
        return "shebang"
    if stripped.startswith("gitdir:") and has_path:
        return "worktree-gitfile"
    # cron row: 5 schedule fields (num/*/,-/ ranges) or an @keyword schedule,
    # then a command that includes <old>
    if has_path and re.match(r"^\s*([\d*/,\-]+(\s+[\d*/,\-]+){4}|@[A-Za-z]+)\s+\S", line):
        return "crontab"
    if KEY_CTX in line and key_pat.search(line):
        return "native-memory-key"
    if has_path:
        return "anchor"
    return None

counts = {"shebang": 0, "worktree-gitfile": 0, "crontab": 0, "anchor": 0, "native-memory-key": 0}
changed_files = 0
failed = []
report = []

for dirpath, dirnames, filenames in os.walk(root):
    # skip the git object store, but NOT a .git *file* (worktree pointer) — that is
    # a regular file, handled below.
    if os.path.basename(dirpath) == ".git":
        dirnames[:] = []
        continue
    for fn in filenames:
        fp = os.path.join(dirpath, fn)
        if os.path.islink(fp):
            continue
        try:
            with open(fp, "rb") as fh:
                raw = fh.read()
        except OSError:
            continue
        if b"\x00" in raw:  # binary — skip
            continue
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            continue
        if old not in text and old_key not in text:
            continue
        rel = os.path.relpath(fp, root)
        file_hit = False
        for i, line in enumerate(text.splitlines(), 1):
            cls = classify(line)
            if cls:
                counts[cls] += 1
                file_hit = True
                report.append("%-17s %s:%d  %s" % (cls, rel, i, line.strip()[:120]))
        if apply and file_hit:
            # native-memory key first (more specific, and only on lines that
            # carry the consumer context), then the plain path everywhere.
            out = []
            for ln in text.splitlines(keepends=True):
                if KEY_CTX in ln and key_pat.search(ln):
                    ln = sub_protected(key_pat, new_key, new_key_pat, ln)
                out.append(ln)
            updated = sub_protected(path_pat, new, new_pat, "".join(out))
            if updated != text:
                # atomic write: temp + rename, preserving the original mode
                # (a shebang target must stay executable). A file we cannot
                # rewrite is reported and the sweep continues.
                tmp = fp + ".reorg-sync-tmp"
                try:
                    st = os.stat(fp)
                    with open(tmp, "w", encoding="utf-8") as fh:
                        fh.write(updated)
                    os.chmod(tmp, st.st_mode & 0o7777)
                    os.replace(tmp, fp)
                    changed_files += 1
                except OSError as e:
                    failed.append("%s: %s" % (rel, e))
                    try:
                        os.unlink(tmp)
                    except OSError:
                        pass

mode = "APPLY" if apply else "DRY-RUN"
print("reorg-sync [%s]  old=%s  new=%s  root=%s" % (mode, old, new, root))
for line in report:
    print("  " + line)
total = sum(counts.values())
print("summary: %d reference(s) across %d class(es) — %s" % (
    total,
    sum(1 for v in counts.values() if v > 0),
    ", ".join("%s=%d" % (k, counts[k]) for k in counts),
))
if apply:
    print("applied: rewrote %d file(s)" % changed_files)
    if failed:
        for f in failed:
            sys.stderr.write("apply-FAILED %s\n" % f)
        print("applied-with-errors: %d file(s) could not be rewritten" % len(failed))
        sys.exit(1)
else:
    print("dry-run: no files changed (re-run with --apply to rewrite)")
PY
