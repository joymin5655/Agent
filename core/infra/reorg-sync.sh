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
# substring replacement corrupted sibling paths and broke idempotency).
#
# A PATH hit must end at a path-component boundary: the next char may not be a
# path-word char. Blocks sibling bleed (/old/prefixed-thing, /old/prefix_v2,
# /old/prefix.txt) while '/sub' continuation still matches.
path_pat = re.compile(re.escape(old) + r"(?![A-Za-z0-9._\-])")
# An ENCODED-KEY hit must be a standalone key token: not embedded in a longer
# alphanumeric run on either side. '-' continuation stays legal — a deeper cwd's
# key ('-old-prefix-sub') must still rewrite — but '-old-prefix2' (a sibling
# project's key) and 'kebab-old-prefix' (ordinary kebab text) must not. The key
# layer additionally only ever runs on lines carrying the documented consumer
# context, KEY_CTX.
key_pat = re.compile(r"(?<![A-Za-z0-9])" + re.escape(old_key) + r"(?![A-Za-z0-9])")
KEY_CTX = "claude/projects"

# NUL can never occur in swept text (binary files are skipped on b"\x00"), so it
# is a safe protection nonce: when NEW itself still matches the pattern (NEW
# extends OLD, e.g. /proj -> /proj_v2), mask existing NEW occurrences before
# substituting so a re-run is a no-op instead of compounding (_v2_v2).
NONCE = "\x00"

def sub_protected(pat, repl, text):
    if pat.search(repl):
        text = text.replace(repl, NONCE)
        text = pat.sub(lambda m: repl, text)
        return text.replace(NONCE, repl)
    return pat.sub(lambda m: repl, text)

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
                    ln = sub_protected(key_pat, new_key, ln)
                out.append(ln)
            updated = sub_protected(path_pat, new, "".join(out))
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
