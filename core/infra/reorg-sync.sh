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
# atomic (mkstemp temp + rename, permissions preserved); a file that cannot be
# written is reported and the sweep continues. Binary files, non-regular files
# (symlink/FIFO/socket/device), and the .git object store are skipped; the .git
# *file* (worktree pointer) is scanned. Exit 0 for a clean/dry report; exit 1 on
# a usage error or if any --apply write failed.
#
# Refused inputs (each a proven corruption/injection hazard, see guards below):
# relative --old/--new; --old of "/" or ""; --old/--new containing any line
# separator; promote-up moves (--old under --new, e.g. /old/sub -> /old).
#
# DOCUMENTED RESIDUALS (safe-miss-or-surfaced by design, NOT "never corrupts"):
#   * whitespace-as-boundary: a directory name containing whitespace — ASCII
#     space or Unicode whitespace (U+00A0, U+3000, ...) — splits at that char,
#     so OLD=/x/AB can hit the prefix of sibling `/x/AB<space>C` ("AB C").
#     Whitespace must stay a boundary or refs like `see /old/x.` / `run /old/x `
#     would all be missed; the dry-run report is the review gate before --apply.
#   * lossy key encoding: enc() folds '/', '.', '_' to '-', so a sibling
#     differing only in a folded char shares OLD's encoded key byte-for-byte and
#     its key-form refs rewrite together with the exact key (see the key-layer
#     note below).
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
# Normalize trailing slashes (6th panel MINOR): `--old /a/` is the same prefix as
# `/a`, but the raw form both broke matching (the literal `/a/` cannot be followed
# by the required boundary in `/a/x`) and tripped the promote-up guard's glob
# (`/a/` matches `/a/*` because `*` matches empty). Strip them once, up front, so
# every guard and matcher below sees one canonical spelling.
while [[ "$OLD" == */ && "$OLD" != "/" ]]; do OLD="${OLD%/}"; done
while [[ "$NEW" == */ && "$NEW" != "/" ]]; do NEW="${NEW%/}"; done
if [[ ! -d "$ROOT" ]]; then
  echo "reorg-sync: --root is not a directory: $ROOT" >&2
  exit 1
fi
# a bare "/" old-prefix would match everything — refuse the footgun.
if [[ "$OLD" == "/" || "$OLD" == "" ]]; then
  echo "reorg-sync: refusing a root ('/') or empty --old prefix (would match everything)" >&2
  exit 1
fi
# absolute paths only (5th panel MAJOR): a relative OLD with no '/', '.', '_'
# (e.g. 'Project') is byte-identical to its own encoded key form, so the same
# token would match BOTH the path axis and the key axis — double-counted and
# rewritten to the dash form. '/'-leading OLD/NEW keeps the two axes disjoint
# (path form starts '/', key form starts '-'), and absolute-path references are
# this tool's declared scope anyway.
if [[ "$OLD" != /* || "$NEW" != /* ]]; then
  echo "reorg-sync: refusing a relative --old/--new — both must be absolute ('/'-leading) paths" >&2
  exit 1
fi
# promote-up (OLD is NEW plus one or more trailing components, /old/sub -> /old)
# is REFUSED (5th panel CRITICAL, user decision 2026-08-10): after one apply, a
# migrated ref (/old/sub/file -> /old/file) and a FRESH /old/sub ref are
# byte-identical at identical syntactic positions, so NO stateless text
# transform can be idempotent — a re-run eats one path component per pass
# (/old/sub/sub/file -> /old/sub/file -> /old/file), which is data corruption.
# A real drive reorg moves children individually (/old/sub/a -> /dest/a); run
# one sweep per child instead. The MIRROR shape is refused for the same reason
# (8th panel CRITICAL): when a proper suffix of OLD is a boundary-terminated
# prefix of NEW (/srv:/app -> /app, /a/b -> /b/c), pre-existing text ending in
# OLD's leading remainder followed by a written NEW is byte-identical to a
# fresh OLD ref, and each re-apply eats one LEADING component instead.
# Identity (--old X --new X) is NOT a promote-up (zero trailing components) and
# is accepted as a no-op sweep reporting 0.
# The promote-up TEST itself lives in the Python below, next to the boundary
# regexes it must agree with. It used to be a bash `[[ "$OLD" == "$NEW"/* ]]`
# glob, which hard-coded '/' as the only component separator while the matcher
# treated 19 characters as boundaries (7th panel CRITICAL) — so `--old /srv:cache
# --new /srv` walked straight past the guard and ate one component per apply,
# exactly the corruption this refusal exists to prevent. Re-spelling the boundary
# set here in shell would just re-create that drift; the check is derived from
# _BOUNDARY / _KEY_R instead.
# Line-separator guard lives in the Python below (5th panel MAJOR): bash's
# $'\n' test missed the other separators Python's splitlines() honors
# (\r \v \f \x1c-\x1e \x85 U+2028 U+2029), any of which would let --apply write
# a value that later reads back as EXTRA LINES (line injection + broken
# idempotency). The check must therefore use splitlines() itself.

# The whole sweep + apply is done in Python: portable, and str.replace is a safe
# literal substitution (no sed delimiter / regex-metachar corruption of paths).
OLD="$OLD" NEW="$NEW" ROOT="$ROOT" APPLY="$APPLY" python3 <<'PY'
import os, stat, sys, re, tempfile

old = os.environ["OLD"]
new = os.environ["NEW"]
root = os.environ["ROOT"]
apply = os.environ["APPLY"] == "1"

# Line-separator guard (5th panel MAJOR): the authoritative check uses
# splitlines() itself — the sweep below iterates text.splitlines(), so ANY
# character that function treats as a separator (\n \r \v \f \x1c-\x1e \x85
# U+2028 U+2029) inside OLD/NEW would inject lines into swept files on --apply
# and break idempotency (each re-apply re-splits and re-matches the fragments).
for name, val in (("--old", old), ("--new", new)):
    if val.splitlines() != [val]:
        sys.stderr.write(
            "reorg-sync: refusing %s containing a line separator "
            "(line-injection hazard: any splitlines() separator counts, not just \\n)\n" % name)
        sys.exit(1)

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
# LEFT boundary (2026-07-16 code-review fix; 5th panel MAJOR rework): a path
# match must also START at a path boundary, or OLD would match as the *tail* of
# a longer, unrelated absolute path — e.g. OLD=/proj/x wrongly hitting
# /other/tree/proj/x. The first version BLOCKLISTED body chars ([\w./~+@%-]),
# but a blocklist is always incomplete: a combining mark (U+0301 etc.) is not
# \w, so NFD text — macOS filenames are NFD-normalized — like /data/care<U+0301>/old/x
# let OLD=/old tail-match and corrupt the path. Same principle as _BOUNDARY:
# WHITELIST the boundary instead (double-negative lookbehind — the preceding
# char must be whitespace, a quote, or structural punctuation; string start is
# vacuously true). '/' is deliberately NOT in the whitelist: a preceding '/'
# means OLD is a sub-path of a different absolute path and stays blocked, along
# with every body char in any script, combining marks, and emoji. The ONE
# non-punctuation boundary is the two-char shebang sigil `#!` (6th panel MINOR:
# whitelisting bare '!' and '#' let OLD tail-match mid-path inside legal
# directory names like `/proj/dir!/old/x` and `/proj/c#/old/x` — a fixed-width
# `(?<=#!)` lookbehind keeps `#!/old/bin/python3` detected without opening that
# hole). Other chars the old blocklist happened to allow as boundaries ('*',
# '?', '&', a bare '#' comment sigil with no space, ...) now fail toward a
# dry-run-visible safe MISS — never sibling corruption.
_LEFT = r"""(?:(?<=\#\!)|(?<![^\s"'`:,;=|<>(){}\[\]]))"""
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
#
# The span pattern deliberately has NO _LEFT requirement (8th panel CRITICAL):
# a WRITTEN span's left neighbour is whatever the splice left there. When two
# OLD matches were textually adjacent (possible exactly when OLD ends in a
# boundary char — that is what let the second match pass _LEFT), the first
# splice puts NEW's LAST character on the second span's left, and when that is
# not a boundary char (almost every path ends in a letter/digit) a left-bounded
# rescan no longer recognizes the second span — so the OLD embedded in the NEW
# this tool itself wrote re-matched, eating text on every --apply. The RIGHT
# lookahead stays: a written NEW is always followed by the boundary the OLD
# match's _BOUNDARY lookahead verified (splices never consume it), so it prunes
# only spans nothing was written into ('/app' inside a fresh '/apple'). Cost of
# the missing left bound, unchanged in kind: more text counts as span, so a
# fresh OLD ref sitting inside/behind ANY literal-NEW text (boundary-led or
# not) is now a documented safe MISS instead of a rewrite.
new_span_pat = re.compile(re.escape(new) + _BOUNDARY)
# The native-memory key is enc(cwd) with '/', '.', '_' ALL folded to '-'. That
# fold is lossy: a deeper key (enc('/old/p/sub') = '-old-p-sub') and a
# dash/dot/underscore SIBLING (enc('/old/p-sub') = the same '-old-p-sub') are
# byte-identical, so '-' after old_key cannot be a safe deeper-component boundary
# — treating it as one corrupted an unrelated project's key (2026-07-16 workflow
# panel). We therefore rewrite ONLY the EXACT key (cwd == OLD): the key boundary
# is the path whitelist WITHOUT '-'. A deeper key is left alone (a safe miss: the
# orphaned dir just stays, as before this tool) and every sibling whose key
# ENCODES DIFFERENTLY is protected. Residual (5th panel, documented — not
# fixable here): enc() itself is non-injective, so a sibling differing from OLD
# only in a folded char ('/x/10_Ref' vs '/x/10-Ref') has the byte-identical key
# and its key-form refs WILL rewrite along with the exact key. That is a
# property of the harness memory-key transform, not of this tool; the dry-run
# report surfaces every key hit for review before --apply.
# The Unicode-\w-aware left whitelist blocks a longer key that merely ends with
# old_key. Idempotency uses the same protected-span guard as the path layer
# (new_key_span_pat), so a new_key that embeds old_key after a surviving delimiter
# cannot compound either. Unlike the path span pattern, the KEY span pattern
# KEEPS its left anchor: a written key span always sits immediately after
# `claude/projects/` (that is the only place the key splice fires), and key
# matches cannot be textually adjacent (_KEY_R requires a boundary after
# old_key, but a following key match would have to start with the letter 'c' of
# its own context) — so the adjacency flip that forced the path span pattern to
# drop _LEFT is not constructible here, and keeping the anchor avoids treating
# every '-a-b'-shaped word in prose as a protected span.
# The key match is ANCHORED to the consumer context (6th panel MINOR): the
# native-memory dir is always spelled `…claude/projects/<encoded-key>/…`, so the
# key literal must sit immediately after `claude/projects/`. The earlier form
# accepted any boundary (including a plain '/') anywhere on a line that merely
# MENTIONED claude/projects, so an unrelated path component that happened to
# equal the encoded key — `/backup/-old-x/f` for OLD=/old-x — was rewritten into
# a path that does not exist. A fixed-width lookbehind keeps the match span
# covering exactly the key.
_KEY_R = r"""(?=/|$|[\s"'`:,;=|<>(){}\[\]])"""
KEY_CTX = "claude/projects/"
_KEY_L = r"(?<=%s)" % re.escape(KEY_CTX)
key_pat = re.compile(_KEY_L + re.escape(old_key) + _KEY_R)
new_key_span_pat = re.compile(_KEY_L + re.escape(new_key) + _KEY_R)

# PROMOTE-UP REFUSAL (5th panel CRITICAL, user decision 2026-08-10; reworked
# after the 7th panel). When OLD is NEW plus one or more trailing components, a
# migrated ref (/old/sub/file -> /old/file) and a FRESH /old/sub ref become
# byte-identical at identical syntactic positions, so NO stateless text transform
# can be idempotent: each re-apply eats one component (/old/sub/sub/f ->
# /old/sub/f -> /old/f). That is data corruption, so the input is refused.
#
# The test is DERIVED from the same boundary regexes the matcher uses, not
# re-spelled. The previous version was a shell glob (`$OLD == $NEW/*`) that knew
# only '/', while the matcher accepts 19 boundary characters — so every non-'/'
# boundary bypassed the refusal and corrupted on re-apply (7th panel CRITICAL,
# reproduced on all 18 of them, e.g. `--old /srv:cache --new /srv`). Anchoring
# both to the same definition is the point: a future boundary change moves the
# guard with it instead of silently reopening the hole.
#
# Both arms require _o != _n first (8th panel MAJOR + MINOR family): the
# boundary regexes both carry a `$` alternative, so with a zero-length remainder
# `re.match(escape(_n) + _b, _o)` fires on IDENTITY — "'X' is 'X' plus trailing
# components", a self-refuting message. On the path axis that wrongly refused
# --old X --new X (contract 6b: identity is a no-op sweep, not a promote-up).
# On the KEY axis it was worse: enc() folds '/', '.', '_' all to '-', so any
# rename that changes ONLY those characters (/x/10_Reference -> /x/10-Reference)
# has old_key == new_key and was refused OUTRIGHT — the tool could not sweep a
# plain sibling rename at all. With the identity arm gone, both cases fall
# through to the sweep, where every match sits inside its own literal-NEW span
# and reports an honest 0 on that axis.
#
# The key arm IS independently reachable (8th panel disproved the previous
# enumeration claim here): enc() folds only '/', '.', '_', so a boundary char
# that enc() PRESERVES (':', ' ', '(', ...) can make old_key extend new_key while
# the path arm sees no prefix at all — `--old '/a.b:c' --new /a/b` gives
# old_key='-a-b:c', new_key='-a-b', a genuine key-axis promote-up (its key sweep
# would be non-idempotent) that only this arm catches. A key-only refusal test
# is now constructible and asserted in the battery.
for _axis, _o, _n, _b in (("--old/--new", old, new, _BOUNDARY),
                          ("the encoded native-memory key for --old/--new",
                           old_key, new_key, _KEY_R)):
    if _o == _n:
        continue
    if re.match(re.escape(_n) + _b, _o):
        sys.stderr.write(
            "reorg-sync: refusing promote-up on %s: '%s' is '%s' plus trailing "
            "components (separated by a path boundary). A migrated ref and a fresh "
            "ref become byte-identical, so re-apply corrupts data — no stateless "
            "rewrite can be idempotent. Sweep each moved child individually "
            "instead.\n" % (_axis, _o, _n))
        sys.exit(1)
    # SUFFIX-OVERLAP REFUSAL (8th panel CRITICAL family — the exact MIRROR of
    # promote-up, previously unguarded). When a PROPER suffix of OLD equals a
    # boundary-terminated prefix of NEW (fully contained: NEW a suffix of OLD,
    # /srv:/app -> /app; or partial: /a/b -> /b/c sharing '/b'), --apply writes
    # NEW where OLD's tail stood, and pre-existing text ending with OLD's
    # leading remainder followed by that written NEW is byte-identical to a
    # FRESH OLD reference. The residue guard cannot save it: the re-match STARTS
    # in pre-existing text and only STRADDLES the span, and suppressing
    # straddles instead would make every fresh ref of such a move sit inside a
    # span — a silent 0 where the tool can in fact never sweep. Same
    # undecidability as promote-up, so the same answer: refuse loudly. Each
    # re-apply otherwise eats one leading component per pass (reproduced on all
    # 18 non-'/' boundary chars; '/' is excluded from _LEFT so the pure-slash
    # spelling of the PARTIAL case cannot re-match, but the CONTAINED case
    # (/a/b -> /b) corrupts regardless). The k range excludes k == len(_o):
    # OLD == NEW[:len(OLD)] is the supported extends case (/proj ->
    # /proj/inner), protected by span containment, not refused.
    for _k in range(1, min(len(_o), len(_n) + 1)):
        if _o.endswith(_n[:_k]) and re.match(_b, _n[_k:]):
            sys.stderr.write(
                "reorg-sync: refusing suffix-overlap on %s: '%s' ends with "
                "'%s', which is '%s' up to a path boundary. After --apply, "
                "pre-existing text ending in the leading remainder followed by "
                "the written new value is byte-identical to a fresh reference, "
                "so re-apply corrupts data (one leading component per pass) — "
                "no stateless rewrite can be idempotent. Sweep with a more "
                "specific --old, or move through an intermediate name sharing "
                "no boundary-anchored affix with either side.\n"
                % (_axis, _o, _n[:_k], _n))
            sys.exit(1)

# _abuts() was folded into _in_residue() below (its `start == span end` case is
# now the `<= e` half of one rule); see that comment for the 6th-panel history.

def _new_spans(s):
    # Every already-migrated literal-NEW span on the line, from BOTH axes, found
    # with an OVERLAPPING scan. Two 7th-panel CRITICALs lived in what this
    # replaced:
    #
    # CROSS-AXIS (findings 3, 5, 7, 12): live_matches used to be called per axis
    # with only that axis's span pattern, so the path axis never saw the spans the
    # KEY splice had just written. new_key shares NEW's last character, so when
    # NEW ends in a boundary char, writing new_key flips the left boundary of the
    # component right after it — the exact flip _abuts exists to catch, arriving
    # through the other axis. A 2nd --apply then ate a live path reference.
    #
    # SELF-SIMILAR NEW (finding 10): finditer returns NON-overlapping matches, so
    # for NEW='/b (x)/b (x)' in '/b (x)/b (x)/b (x)/o/y' it reported only the span
    # at 0, missing the one at 6 whose end is exactly where '/o' starts — so the
    # residue guard did not fire and each --apply ate one component. Scanning
    # through a zero-width lookahead yields every START, overlapping included; the
    # consumed text is exactly the literal (the _LEFT/_BOUNDARY parts are
    # zero-width), so the end is start + len(literal).
    spans = []
    for pat, lit in ((new_span_pat, new), (new_key_span_pat, new_key)):
        for m in re.finditer("(?=" + pat.pattern + ")", s):
            spans.append((m.start(), m.start() + len(lit)))
    return spans

def _in_residue(m, spans):
    # True iff m is MIGRATION RESIDUE rather than a live reference: it starts
    # anywhere inside a literal-NEW span, or exactly where one ends.
    #
    # This used to be two weaker tests. FULL containment was required (not merely
    # "starts inside") because the "starts inside" form silently no-op'd every ref
    # of a PROMOTE-UP reorg — NEW a boundary-prefix of OLD, /old/sub -> /old —
    # where each OLD match begins at a NEW-span start (2026-07-16 workflow MAJOR).
    # That constraint is GONE: promote-up is now refused outright at startup, so
    # NEW can never be a boundary-prefix of OLD and that case cannot arise.
    #
    # Dropping it closes 7th-panel CRITICAL 9, where an OLD match started inside a
    # NEW span and OVERRAN it, so neither test fired: /old/sub -> '/B(1)/old'
    # rewrote '/B(1)/old/sub/sub/f' again on every pass, eating one component each
    # time (/B(1)/B(1)/old/sub/f, /B(1)/B(1)/B(1)/old/f, ...). Anything starting
    # inside text this tool just wrote is by construction part of that write.
    #
    # `<= e` (rather than `< e`) folds in the former _abuts case — a match
    # starting exactly where a NEW span ends. That is the boundary flip that
    # appears when NEW's last character is itself a boundary char
    # (`/backup (2026)`, `/srv:`): writing NEW makes the FOLLOWING component
    # matchable although it was not before, so a re-apply would eat it.
    #
    # Cost is the documented safe MISS, unchanged in kind: a genuinely fresh OLD
    # sitting immediately after (or inside) literal NEW text is left alone and
    # shows up in the dry-run, rather than being rewritten into corruption.
    return any(s <= m.start() <= e for s, e in spans)

def _ctx_manufactured(m, spans, ctx_len):
    # True iff the left CONTEXT this match depends on overlaps text --apply just
    # wrote. 7th panel family C (findings 4, 6, 8, 13): the key axis only matches
    # immediately after `claude/projects/`, but that gate is evaluated on the
    # POST-apply text — so when NEW itself contains `claude/projects`, the path
    # rewrite MANUFACTURES the context and the 2nd --apply performs a key rewrite
    # that had no live reference before it ran. `/old/-old` with
    # NEW=/n/claude/projects became `/n/claude/projects/-old`, and the next pass
    # rewrote the inert `-old` component into `-n-claude-projects`.
    #
    # The residue rule above cannot see this: the key match starts one character
    # PAST the NEW span (the '/' separates them), so it is neither inside nor
    # abutting. What is compromised is the LOOKBEHIND, not the match — hence the
    # separate test on the context window [start - ctx_len, start).
    a, b = m.start() - ctx_len, m.start()
    return any(a < e and s < b for s, e in spans)

def live_matches(pat, s, ctx_len=0):
    # The pat matches --apply will ACTUALLY rewrite: every match not contained in an
    # already-migrated literal-NEW span. This is the SINGLE SOURCE OF TRUTH that both
    # the dry-run report and --apply consume, so the reported per-class count equals
    # the substitutions performed exactly — no report/apply divergence (2026-07-16
    # workflow: the old report path used a bare .search that neither counted per-match
    # nor modelled the span guard, diverging from apply in both directions).
    spans = _new_spans(s)
    return [m for m in pat.finditer(s)
            if not _in_residue(m, spans)
            and not (ctx_len and _ctx_manufactured(m, spans, ctx_len))]

def splice(s, repls):
    # Positional splice (5th panel MAJOR): rewrite BOTH axes' live_matches in one
    # pass over the ORIGINAL string. The earlier flow ran key-sub then path-sub
    # SEQUENTIALLY, so the path layer re-matched against a key-mutated line: when
    # new_key ended in a boundary char (')' ':' ...) it could flip the left
    # boundary of a following path ref, making --apply do more (or less) than the
    # report said. Splicing by the positions live_matches computed on the original
    # line makes report == apply by construction. Overlapping replacements are
    # dropped by drop_overlaps() BEFORE both counting and splicing, so this loop
    # can assume disjoint, ascending spans.
    out, pos = [], 0
    for a, b, r in sorted(repls):
        out.append(s[pos:a]); out.append(r); pos = b
    out.append(s[pos:])
    return "".join(out)

def drop_overlaps(keep, drop):
    # 6th panel MINOR: the two axes were assumed disjoint (a path literal holds
    # '/', its enc() key image does not), but a pathological OLD built only from
    # boundary punctuation can produce key and path matches that share bytes —
    # and splicing both then deleted the overlapped region. Yield to the `keep`
    # axis and drop the colliding `drop` matches, before counting, so the report
    # still equals what apply performs.
    spans = [(m.start(), m.end()) for m in keep]
    return [m for m in drop
            if not any(m.start() < e and s < m.end() for s, e in spans)]

# the path axis is ONE mutually-exclusive class for a line's plain-path refs (the
# native-memory-key axis is counted independently, per-match, in the sweep below).
def path_axis_class(line):
    stripped = line.lstrip()
    if stripped.startswith("#!"):
        return "shebang"
    if stripped.startswith("gitdir:"):
        return "worktree-gitfile"
    # cron row: 5 schedule fields (num/*/,-/ ranges) or an @keyword schedule, then cmd
    if re.match(r"^\s*([\d*/,\-]+(\s+[\d*/,\-]+){4}|@[A-Za-z]+)\s+\S", line):
        return "crontab"
    return "anchor"

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
        # regular files only (5th panel MINOR): islink alone let a FIFO through,
        # and open(FIFO) blocks forever waiting for a writer — hanging the whole
        # sweep. lstat + S_ISREG skips symlinks, FIFOs, sockets, and devices.
        try:
            fst = os.lstat(fp)
        except OSError:
            continue
        if not stat.S_ISREG(fst.st_mode):
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
        out = []
        # ONE pass drives both the report and --apply from live_matches, so the
        # per-class counts can never diverge from the substitutions performed. The
        # native-memory-key axis (dash-form key) and the path axis (slash-form) are
        # disjoint and counted independently, PER MATCH — a line with N same-class
        # refs contributes N, and a ref the span guard skips contributes 0.
        for i, ln in enumerate(text.splitlines(keepends=True), 1):
            disp = ln.rstrip("\n").strip()[:120]
            kmatch = live_matches(key_pat, ln, len(KEY_CTX)) if KEY_CTX in ln else []
            pmatch = live_matches(path_pat, ln)
            if kmatch:
                pmatch = drop_overlaps(kmatch, pmatch)
            if kmatch:
                counts["native-memory-key"] += len(kmatch)
                file_hit = True
                report.append("%-17s %s:%d  %s" % ("native-memory-key", rel, i, disp))
            if pmatch:
                cls = path_axis_class(ln)
                counts[cls] += len(pmatch)
                file_hit = True
                report.append("%-17s %s:%d  %s" % (cls, rel, i, disp))
            if apply and (kmatch or pmatch):
                # both axes splice at their ORIGINAL-line positions in one pass —
                # never sequential re.sub over an already-mutated line (see splice).
                ln = splice(ln, [(m.start(), m.end(), new_key) for m in kmatch]
                              + [(m.start(), m.end(), new) for m in pmatch])
            out.append(ln)
        if apply and file_hit:
            updated = "".join(out)
            if updated != text:
                # atomic write: temp + rename, preserving the original mode
                # (a shebang target must stay executable). A file we cannot
                # rewrite is reported and the sweep continues. The temp name is
                # mkstemp-random (5th panel data-loss fix): the earlier FIXED
                # name fp+".reorg-sync-tmp" collided with any real file of that
                # name — the sweep would list it, then destroy it by using it
                # as the temp target for fp's rewrite.
                tmp = None
                try:
                    st = os.stat(fp)
                    fd, tmp = tempfile.mkstemp(dir=dirpath, prefix=".reorg-sync-", suffix=".tmp")
                    with os.fdopen(fd, "w", encoding="utf-8") as fh:
                        fh.write(updated)
                    os.chmod(tmp, st.st_mode & 0o7777)
                    os.replace(tmp, fp)
                    changed_files += 1
                except OSError as e:
                    failed.append("%s: %s" % (rel, e))
                    if tmp is not None:
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
