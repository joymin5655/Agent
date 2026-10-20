#!/usr/bin/env bash
# supervisor-goal-log.sh — append-only decision log for a /supervise run, plus the
# completion cross-check that prints an "Attention" section.
#
# Usage:
#   supervisor-goal-log.sh append    <slug> <phase> <decision> <why> <evidence> <result>
#   supervisor-goal-log.sh supersede <slug> <line> <phase> <decision> <why> <evidence> <result>
#   supervisor-goal-log.sh check     <slug> [--strict]
#
# The log is .agent/plans/<slug>/DECISIONS.tsv (AGENT_PLANS_DIR overrides the plans root), one
# row per decision, tab-separated, header first:
#
#   ts  phase  decision  why  evidence  result
#
#   phase     [A-Za-z0-9._-]+, e.g. `plan`, `wave-2`, `review`; `wave-<N>` ties a row to a wave
#   evidence  a POINTER, never prose: a commit SHA, a repo path, `path:line`, a PR ref.
#             Prose with spaces is rejected — the reader must be able to go and look.
#   result    pass | fail | pending | free text
#
# Rules:
#   * Append-only. A wrong row is never edited; `supersede` appends a new row whose result
#     starts with `supersedes:L<line>` (line = 1-based file line, header is line 1).
#   * Cells are neutralized for spreadsheet import: a cell starting with = + - @ gets a leading
#     apostrophe (CSV/formula injection); tabs and newlines inside a cell become spaces.
#   * Secret-shaped strings (API keys, tokens, private-key headers, `password=…`) are replaced
#     with [REDACTED] before anything is written.
#   * `check` cross-checks the log against the run record (goal state in SQLite, RECORD.md) and
#     prints "## Attention". Exit 0 always; `--strict` exits 1 when anything needs attention.
#     supervisor-goal.sh `complete` runs it (to stderr) before declaring a run complete.
#
# Idea credit: cursor/plugins pstack show-me-your-work (MIT) — a decision log whose evidence is a
# pointer and whose corrections supersede instead of rewrite. Rewritten here.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
export REPO_ROOT
export PLANS_ROOT="${AGENT_PLANS_DIR:-$REPO_ROOT/.agent/plans}"
export DB_FILE="$REPO_ROOT/.agent/locks/goal-state.db"

if [[ $# -lt 2 ]]; then
  sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  exit 2
fi

exec python3 -I - "$@" <<'PY'
import datetime, os, re, sqlite3, subprocess, sys

HEADER = ["ts", "phase", "decision", "why", "evidence", "result"]
SLUG_RE = re.compile(r"^[A-Za-z0-9._-]+$")
PHASE_RE = re.compile(r"^[A-Za-z0-9._-]+$")
POINTER_RE = re.compile(r"^[A-Za-z0-9._/@:#+~=,%-]{1,200}$")
SHA_RE = re.compile(r"^[0-9a-f]{7,40}$")
SECRETS = [
    re.compile(r"sk-[A-Za-z0-9_-]{16,}"),
    re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}"),
    re.compile(r"github_pat_[A-Za-z0-9_]{20,}"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}"),
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{16,}"),
    re.compile(r"(?i)\b(api[_-]?key|token|secret|passwd|password)\b\s*[=:]\s*\S+"),
]
PLANS_ROOT = os.environ["PLANS_ROOT"]
REPO_ROOT = os.environ["REPO_ROOT"]
DB_FILE = os.environ["DB_FILE"]


def die(msg, code=2):
    print("supervisor-goal-log: " + msg, file=sys.stderr)
    sys.exit(code)


def clean(cell):
    cell = re.sub(r"[\t\r\n]+", " ", cell).strip()
    for pat in SECRETS:
        cell = pat.sub("[REDACTED]", cell)
    cell = cell[:500]
    if cell[:1] in ("=", "+", "-", "@"):
        cell = "'" + cell
    return cell


def log_path(slug):
    if not SLUG_RE.match(slug) or slug == "..":
        die("invalid slug: " + slug)
    return os.path.join(PLANS_ROOT, slug, "DECISIONS.tsv")


def read_rows(path):
    """Return [(line_no, [cells])] for data rows; header is line 1."""
    rows = []
    with open(path, encoding="utf-8") as fh:
        for n, line in enumerate(fh, start=1):
            if n == 1:
                continue
            rows.append((n, line.rstrip("\n").split("\t")))
    return rows


def superseded_set(rows):
    out = {}
    for n, cells in rows:
        if len(cells) >= 6:
            m = re.match(r"^supersedes:L(\d+)\b", cells[5])
            if m:
                out[int(m.group(1))] = n
    return out


def append_row(slug, phase, decision, why, evidence, result):
    if not PHASE_RE.match(phase):
        die("phase must match [A-Za-z0-9._-]+: " + phase)
    if not POINTER_RE.match(evidence):
        die("evidence must be a pointer (commit SHA, path, path:line), not prose: " + evidence[:60])
    if not decision.strip():
        die("decision must not be empty")
    path = log_path(slug)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    row = "\t".join([ts] + [clean(c) for c in (phase, decision, why, evidence, result)]) + "\n"
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        if os.fstat(fd).st_size == 0:
            row = "\t".join(HEADER) + "\n" + row
        os.write(fd, row.encode("utf-8"))
    finally:
        os.close(fd)


def pointer_state(evidence):
    ev = evidence.lstrip("'")
    if ev in ("", "none", "n/a"):
        return "none"
    if SHA_RE.match(ev):
        r = subprocess.run(["git", "-C", REPO_ROOT, "cat-file", "-e", ev + "^{commit}"],
                           capture_output=True)
        return "ok" if r.returncode == 0 else "missing"
    target = re.split(r"[:#]", ev, maxsplit=1)[0]
    if "/" in target or "." in target:
        for base in (REPO_ROOT, PLANS_ROOT):
            if os.path.exists(os.path.join(base, target)):
                return "ok"
        return "missing"
    return "ok"  # opaque ref (e.g. pr-123): nothing local to resolve


def check(slug, strict):
    path = log_path(slug)
    items = []
    rows = []
    if not os.path.isfile(path):
        items.append("no decision log (DECISIONS.tsv): this run's decisions were not recorded")
    else:
        rows = read_rows(path)
        sup = superseded_set(rows)
        lines = {n for n, _ in rows}
        for target, by in sup.items():
            if target not in lines:
                items.append(f"L{by}: supersedes L{target}, which does not exist")
        effective = []
        for n, cells in rows:
            if len(cells) != 6:
                items.append(f"L{n}: malformed row ({len(cells)} cells, want 6)")
                continue
            if n in sup:
                continue
            effective.append((n, cells))
            _, phase, decision, _, evidence, result = cells
            res = re.sub(r"^supersedes:L\d+\s*", "", result).strip().lower()
            label = f"L{n} [{phase}] {decision[:60]}"
            if res in ("", "pending"):
                items.append(f"{label}: still pending")
            elif res.startswith("fail"):
                items.append(f"{label}: recorded as failed and never superseded")
            st = pointer_state(evidence)
            if st == "none":
                items.append(f"{label}: no evidence pointer")
            elif st == "missing":
                items.append(f"{label}: evidence pointer not found: {evidence.lstrip(chr(39))}")
        rows = effective

    # run record: goal state + RECORD.md
    completed = []
    open_agents = []
    if os.path.isfile(DB_FILE):
        try:
            con = sqlite3.connect("file:" + DB_FILE + "?mode=ro", uri=True)
            r = con.execute("SELECT waves_completed FROM supervisor_goals WHERE plan_slug = ?",
                            (slug,)).fetchone()
            if r:
                import json
                completed = [int(w) for w in json.loads(r[0])]
            try:
                open_agents = con.execute(
                    "SELECT agent_id, status FROM supervisor_agents WHERE plan_slug = ? AND status != 'done'",
                    (slug,)).fetchall()
            except sqlite3.Error:
                pass
            con.close()
        except sqlite3.Error:
            pass
    logged_waves = set()
    for _, cells in rows:
        m = re.match(r"^wave-(\d+)$", cells[1])
        if m:
            logged_waves.add(int(m.group(1)))
    for w in completed:
        if w not in logged_waves:
            items.append(f"wave {w} is recorded complete but has no decision row (phase wave-{w})")
    for agent, status in open_agents:
        items.append(f"agent {agent} is still {status} in the goal state")
    rec = os.path.join(PLANS_ROOT, slug, "RECORD.md") if SLUG_RE.match(slug) else ""
    if rec and not os.path.isfile(rec):
        items.append("RECORD.md missing: no execution record to cross-check against")
    elif rec:
        with open(rec, encoding="utf-8", errors="replace") as fh:
            if "<fill" in fh.read():
                items.append("RECORD.md still has unfilled <fill ...> slots")

    print("## Attention")
    if items:
        for it in items:
            print("- " + it)
    else:
        print("- none")
    if strict and items:
        sys.exit(1)


cmd = sys.argv[1]
args = sys.argv[2:]
if cmd == "append":
    if len(args) != 6:
        die("usage: append <slug> <phase> <decision> <why> <evidence> <result>")
    append_row(*args)
elif cmd == "supersede":
    if len(args) != 7:
        die("usage: supersede <slug> <line> <phase> <decision> <why> <evidence> <result>")
    slug, line, phase, decision, why, evidence, result = args
    if not line.isdigit() or int(line) < 2:
        die("line must be a data-row line number (>= 2)")
    path = log_path(slug)
    if not os.path.isfile(path):
        die("no decision log for " + slug, 3)
    rows = read_rows(path)
    if int(line) not in {n for n, _ in rows}:
        die(f"line {line} is not a row of {path}", 3)
    if int(line) in superseded_set(rows):
        die(f"line {line} is already superseded", 3)
    append_row(slug, phase, decision, why, evidence, f"supersedes:L{line} {result}".strip())
elif cmd == "check":
    strict = "--strict" in args
    pos = [a for a in args if a != "--strict"]
    if len(pos) != 1:
        die("usage: check <slug> [--strict]")
    check(pos[0], strict)
else:
    die("unknown command: " + cmd)
PY
