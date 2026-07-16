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
# Idempotency without masking. When NEW contains OLD — as a prefix
# (/proj -> /proj/inner) OR after a delimiter that _LEFT does not block
# (/a -> /a:/a, where ':' passes _LEFT) — a naive re-apply re-matches the OLD
# embedded in the NEW that apply just wrote, compounding unboundedly. Two earlier
# attempts failed: a NUL-nonce mask corrupted a mid-path sibling (masking a span to
# one char flipped the next component's left-neighbor to a boundary), and a
# leading-only negative lookahead protected only the OUTERMOST OLD, missing the copy
# of OLD that NEW itself reintroduces after a delimiter (2nd workflow panel,
# /a:/a:/a…). Correct fix: compute the boundary-anchored literal NEW spans
# POSITIONALLY on the original buffer, then refuse to rewrite any OLD that falls
# inside one. No text is mutated during the scan, so no neighbour's boundary is ever
# disturbed, and EVERY embedded OLD (prefix or post-delimiter) is covered. The cost
# is the same documented safe MISS of a fresh ref that coincidentally sits inside a
# literal-NEW-shaped span — never corruption.
new_span_pat = re.compile(_LEFT + re.escape(new) + _BOUNDARY)
# The native-memory key is enc(cwd) with '/', '.', '_' ALL folded to '-'. That
# fold is lossy: a deeper key (enc('/old/p/sub') = '-old-p-sub') and a
# dash/dot/underscore SIBLING (enc('/old/p-sub') = the same '-old-p-sub') are
# byte-identical, so '-' after old_key cannot be a safe deeper-component boundary
# — treating it as one corrupted an unrelated project's key (2026-07-16 workflow
# panel). We therefore rewrite ONLY the EXACT key (cwd == OLD): the key boundary
# is the path whitelist WITHOUT '-'. A deeper key is left alone (a safe miss: the
# orphaned dir just stays, as before this tool) and every sibling is protected.
# The Unicode-\w-aware left whitelist blocks a longer key that merely ends with
# old_key. Idempotency uses the same protected-span guard as the path layer
# (new_key_span_pat), so a new_key that embeds old_key after a surviving delimiter
# cannot compound either.
_KEY_R = r"""(?=/|$|[\s"'`:,;=|<>(){}\[\]])"""
_KEY_L = r"""(?<![^\s"'`:,;=|<>(){}\[\]/])"""
key_pat = re.compile(_KEY_L + re.escape(old_key) + _KEY_R)
new_key_span_pat = re.compile(_KEY_L + re.escape(new_key) + _KEY_R)
KEY_CTX = "claude/projects"

def sub_outside(pat, span_pat, repl, text):
    # Rewrite every pat match to repl EXCEPT one that sits inside a boundary-anchored
    # literal-repl (already-migrated NEW / new_key) span. Spans are positional on the
    # original buffer — the scan never mutates text, so adjacent boundaries are intact.
    spans = [(m.start(), m.end()) for m in span_pat.finditer(text)]
    if not spans:
        return pat.sub(lambda m: repl, text)
    def _r(m):
        p = m.start()
        for s, e in spans:
            if s <= p < e:
                return m.group(0)
        return repl
    return pat.sub(_r, text)

# classify a single line's reference hits for reporting. A line can carry BOTH a
# native-memory-key ref AND a co-resident plain-path ref, and --apply rewrites both,
# so classification is NON-exclusive across those two axes (2026-07-16 workflow
# MINOR: a key+path line was undercounted as one native-memory-key hit while --apply
# made two substitutions — report/apply divergence). The path axis
# (shebang/worktree-gitfile/crontab/anchor) is one mutually-exclusive class for the
# single path ref; native-memory-key is tallied independently.
def classify(line):
    hits = []
    if KEY_CTX in line and key_pat.search(line):
        hits.append("native-memory-key")
    if path_pat.search(line) is not None:
        stripped = line.lstrip()
        if stripped.startswith("#!"):
            hits.append("shebang")
        elif stripped.startswith("gitdir:"):
            hits.append("worktree-gitfile")
        # cron row: 5 schedule fields (num/*/,-/ ranges) or an @keyword schedule,
        # then a command that includes <old>
        elif re.match(r"^\s*([\d*/,\-]+(\s+[\d*/,\-]+){4}|@[A-Za-z]+)\s+\S", line):
            hits.append("crontab")
        else:
            hits.append("anchor")
    return hits

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
            for cls in classify(line):
                counts[cls] += 1
                file_hit = True
                report.append("%-17s %s:%d  %s" % (cls, rel, i, line.strip()[:120]))
        if apply and file_hit:
            # native-memory key first (more specific, and only on lines that
            # carry the consumer context), then the plain path everywhere. Both use
            # the protected-span guard so a re-apply is a no-op (never compounds).
            out = []
            for ln in text.splitlines(keepends=True):
                if KEY_CTX in ln and key_pat.search(ln):
                    ln = sub_outside(key_pat, new_key_span_pat, new_key, ln)
                out.append(ln)
            updated = sub_outside(path_pat, new_span_pat, new, "".join(out))
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
