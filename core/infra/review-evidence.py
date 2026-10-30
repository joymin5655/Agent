#!/usr/bin/env python3
"""review-evidence.py — review-evidence helpers shared by call-worker.sh and the commit gate.

  project-key [--root DIR]  per-project key: sha256(realpath(git toplevel))[:12], the same
                            key council-escalation-gate.py's state_dir() uses
  key --staged              sha256 over mode+blob of the STAGED risk-path files only (empty
                            line when none; exit 2 on any git failure, never a key); risk
                            paths are classified by `council-threshold.sh --classify`;
                            during a merge (MERGE_HEAD) a risk file whose staged state
                            equals a merged-in parent's that is contained in a remote
                            DEFAULT branch is dropped first (remote-tracking refs are local
                            state an agent could rewrite: a convenience for merging the
                            default branch in, not proof). Cherry-pick and rebase are NOT
                            covered. `check` applies the same reduction.
  check --staged [--merge-head SHA]...
                            commit gate (pre-merge-commit passes the merged heads
                            explicitly; the environment is never read for heads): exit 0 when no risk file is staged, or an
                            external-vendor (a known vendor that is none of the authors', see
                            author-vendor; not an advisor-* role) `complete` review row in
                            reviews.jsonl is bound to this exact key, or the user set
                            AGENT_REVIEW_OVERRIDE (>=10 chars; logged). Exit 1 otherwise,
                            exit 2 for an unknown AGENT_AUTHOR_VENDOR name.
                            The override is user-only by policy; agents must not set it.
  summary CAPTURE...        lane-status line for the council report; first line warns
                            "single-vendor review" when no external lane completed. Vendor
                            and role come from the reviews.jsonl row whose `capture` is that
                            file, else from backends.json / the capture frontmatter.
  author-vendor             every company whose model wrote the staged change, sorted and
                            comma-joined: the union of AGENT_AUTHOR_VENDOR (a comma list; it
                            only adds, and an unknown name exits 2), the branch prefix
                            (claude/ codex/ gemini/ agy/), the working-copy folder prefix
                            (claude- codex- gemini- agy-), every AI Co-Authored-By trailer of
                            merge-base(default branch)..HEAD (HEAD alone without a merge-base)
                            and the writing lanes call-worker.sh recorded in
                            <git dir>/agent-author-vendors. Only when all are empty: the saved
                            runtime profile's main vendor, else anthropic. A review by any of
                            them is not external; a reviews.jsonl row's own `author_vendor`
                            can only add to this set, never replace it.
"""
from __future__ import annotations

import getpass
import hashlib
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

# realpath, not abspath: consumer hooks reach this file as <link>/../infra/..., and a
# lexical ".." collapse would point THRESHOLD outside the framework copy.
HERE = os.path.dirname(os.path.realpath(__file__))
THRESHOLD = os.path.join(HERE, "council-threshold.sh")


def git_toplevel(path: str) -> str | None:
    try:
        out = subprocess.check_output(
            ["git", "-c", "core.fsmonitor=", "rev-parse", "--show-toplevel"],
            cwd=path, stderr=subprocess.DEVNULL, timeout=15,
        ).decode().strip()
    except (OSError, subprocess.SubprocessError):
        return None
    return out or None


def canonical_root(path: str) -> str:
    """git toplevel of `path`, realpath'd; realpath(path) outside a repo.
    Mirrors council-escalation-gate.canonical_root (parity is tested)."""
    return os.path.realpath(git_toplevel(path) or path)


def project_key(root: str | None = None) -> str:
    """Same order as the gate: the cwd's own repo wins; the env dirs are only a
    fallback when cwd is not inside a git repo. A linked worktree is its own
    toplevel, so review and commit must run in the same worktree."""
    start = root or os.getcwd()
    if not root and git_toplevel(start) is None:
        start = (
            os.environ.get("AGENT_PROJECT_DIR")
            or os.environ.get("CLAUDE_PROJECT_DIR")
            or start
        )
    return hashlib.sha256(canonical_root(start).encode()).hexdigest()[:12]


class EvidenceError(Exception):
    pass


def _git(top: str, *args: str) -> bytes:
    env = dict(os.environ, GIT_LITERAL_PATHSPECS="1")
    proc = subprocess.run(
        ["git", "-c", "core.fsmonitor=", *args],
        cwd=top, capture_output=True, env=env, check=False,
    )
    if proc.returncode != 0:
        raise EvidenceError(f"git {args[0]} failed: {proc.stderr.decode(errors='replace').strip()}")
    return proc.stdout


def staged_entries(top: str) -> dict[str, tuple[str, str]]:
    """path -> (mode, blob) of the staged diff only; a deletion is ("000000", "deleted")."""
    # --no-abbrev: --raw abbreviates blob ids, and the abbreviation grows with the
    # object count, so a key computed at review time could differ at commit time.
    raw = _git(top, "diff", "--staged", "--raw", "-z", "--no-renames", "--no-abbrev",
               "--no-ext-diff", "--no-textconv").split(b"\0")
    entries: dict[str, tuple[str, str]] = {}
    i = 0
    while i + 1 < len(raw) and raw[i]:
        meta = raw[i].decode().lstrip(":").split()  # old-mode new-mode old-blob new-blob status
        path = raw[i + 1].decode(errors="surrogateescape")
        status = meta[4][0]
        entries[path] = ("000000", "deleted") if status == "D" else (meta[1], meta[3])
        i += 2
    return entries


def classify_risk(top: str, paths: list[str]) -> set[str]:
    if not paths:
        return set()
    proc = subprocess.run(
        ["bash", THRESHOLD, "--classify"], cwd=top, check=False, capture_output=True,
        input=b"".join(p.encode(errors="surrogateescape") + b"\0" for p in paths),
    )
    if proc.returncode != 0:
        raise EvidenceError("council-threshold --classify failed")
    return {x.decode(errors="surrogateescape") for x in proc.stdout.split(b"\0") if x}


def _default_branch_refs(top: str) -> list[str]:
    """Remote default-branch refs: the target of refs/remotes/<remote>/HEAD per remote,
    else refs/remotes/<remote>/main or /master when that HEAD is unset."""
    refs: list[str] = []
    for remote in _git(top, "remote").decode().split():
        try:
            target = _git(top, "symbolic-ref", "-q",
                          f"refs/remotes/{remote}/HEAD").decode().strip()
        except EvidenceError:
            target = ""
        if target:
            refs.append(target)
            continue
        refs += [f"refs/remotes/{remote}/{b}" for b in ("main", "master")]
    return refs


def _published(top: str, sha: str) -> bool:
    """True when a remote default branch contains sha. Remote-tracking refs are local
    state an agent could rewrite, so this is a convenience for merging the default branch
    in, not proof of review. An unknown sha counts as unpublished."""
    for ref in _default_branch_refs(top):
        try:
            out = _git(top, "for-each-ref", "--contains", sha, ref, "--count=1",
                       "--format=%(refname)")
        except EvidenceError:
            continue
        if out.decode().strip() == ref:
            return True
    return False


def drop_merge_reviewed(top: str, entries: dict[str, tuple[str, str]], risky: set[str],
                        extra_parents: tuple[str, ...] = ()) -> set[str]:
    """During a merge a risk file whose staged state equals its state in a merged-in
    parent that a remote DEFAULT branch contains is not re-gated (see _published for the
    trust limit). Parents come from the MERGE_HEAD file, plus `extra_parents` that the
    pre-merge-commit hook passes explicitly (git writes no MERGE_HEAD while it runs); the
    environment is never consulted, so a command-line `GITHEAD_x=...` cannot inject one.
    One `git diff --cached <parent>` per qualifying sha lists the paths that DIFFER from it
    (content, mode or presence, so an equal deletion drops too); an octopus keeps only
    paths that differ from every qualifying parent. HEAD is not a reference: a file equal
    to HEAD is not in the staged diff at all. Cherry-pick and rebase are not covered (git
    runs no pre-commit for them either)."""
    if not risky:
        return risky
    mh = _git(top, "rev-parse", "--git-path", "MERGE_HEAD").decode().strip()
    mh = mh if os.path.isabs(mh) else os.path.join(top, mh)
    parents: list[str] = list(extra_parents)
    try:
        with open(mh, encoding="ascii") as f:
            parents += [ln.strip() for ln in f if ln.strip()]
    except OSError:
        pass
    remaining = set(risky)
    for sha in parents:
        if not _published(top, sha):
            continue
        out = _git(top, "diff", "--cached", "--name-only", "-z", "--no-renames",
                   "--no-ext-diff", "--no-textconv", sha, "--")
        differing = {x.decode(errors="surrogateescape") for x in out.split(b"\0") if x}
        remaining &= differing
    return remaining


def risky_staged(top: str, extra_parents: tuple[str, ...] = ()
                 ) -> tuple[dict[str, tuple[str, str]], set[str]]:
    """Staged entries plus the risk subset that still needs an external review. The single
    reduction behind both the review-time key and the commit-time check."""
    entries = staged_entries(top)
    return entries, drop_merge_reviewed(top, entries, classify_risk(top, list(entries)),
                                        extra_parents)


def diff_key_staged(extra_parents: tuple[str, ...] = ()) -> str:
    top = git_toplevel(os.getcwd())
    if top is None:
        raise EvidenceError("not inside a git repository")
    entries, risky = risky_staged(top, extra_parents)
    if not risky:
        return ""
    lines = sorted(f"{p}\0{entries[p][0]}\0{entries[p][1]}" for p in risky)
    return hashlib.sha256("\n".join(lines).encode(errors="surrogateescape")).hexdigest()


OVERRIDE_MIN = 10
OVERRIDE_MAX = 300
SINGLE_VENDOR = "single-vendor review — not a council (no external lane returned)"
VENDORS = ("anthropic", "openai", "google")  # runtime-profile.py VENDORS; call-worker.sh KNOWN_VENDORS
# A branch `claude/fix-x` or a working-copy folder `claude-fix-x` names the tool that works there.
PREFIX_VENDOR = {"claude": "anthropic", "codex": "openai", "gemini": "google", "agy": "google"}
TRAILER_RE = re.compile(r"^co-authored-by:\s*(.+)$", re.IGNORECASE | re.MULTILINE)
TRAILER_VENDOR = (
    ("anthropic", re.compile(r"\b(claude|anthropic)\b", re.IGNORECASE)),
    ("openai", re.compile(r"\b(codex|openai|chatgpt|gpt)\b", re.IGNORECASE)),
    ("google", re.compile(r"\b(gemini|antigravity|google)\b", re.IGNORECASE)),
)
# call-worker.sh appends the vendor of every writing lane (a role without "readonly": true)
# that ran from this worktree to <git dir>/AUTHOR_FILE, one "<vendor>\t<branch>" (or
# "<vendor>\t@<HEAD commit>") line per run. Every line counts on every branch; the second
# field only tells the person who clears the file which run a line came from.
AUTHOR_FILE = "agent-author-vendors"


class AuthorVendorError(Exception):
    pass


def _norm(value: object) -> str:
    return str(value or "").strip().lower()


def _vendor_tokens(value: object) -> list[str]:
    """A vendor list as written by call-worker.sh / AGENT_AUTHOR_VENDOR: comma or space separated."""
    return [t for t in re.split(r"[\s,]+", _norm(value)) if t]


def _known(tokens: list[str]) -> set[str]:
    return {t for t in tokens if t in VENDORS}


def _prefix_vendor(name: str, sep: str) -> str:
    head, found, _ = name.partition(sep)
    return PREFIX_VENDOR.get(head.lower(), "") if found else ""


def _env_vendors() -> set[str]:
    """AGENT_AUTHOR_VENDOR as a set. An unknown name is an error, never ignored: a typo would
    otherwise drop a company from the authors and let it count as its own outside reviewer."""
    tokens = _vendor_tokens(os.environ.get("AGENT_AUTHOR_VENDOR"))
    unknown = sorted(set(tokens) - set(VENDORS))
    if unknown:
        raise AuthorVendorError(f"AGENT_AUTHOR_VENDOR names unknown vendor(s) {', '.join(unknown)} "
                                f"(known: {', '.join(VENDORS)})")
    return set(tokens)


def _trailer_vendors(message: str) -> set[str]:
    """Every AI company named by a Co-Authored-By trailer of one commit message."""
    found: set[str] = set()
    for who in TRAILER_RE.findall(message):
        found |= {vendor for vendor, pattern in TRAILER_VENDOR if pattern.search(who)}
    return found


def _merge_base(top: str) -> str:
    """merge-base of HEAD with the default branch (remote default first, then a local main /
    master); "" when none can be found."""
    try:
        refs = _default_branch_refs(top)
    except EvidenceError:
        refs = []
    for ref in refs + ["refs/heads/main", "refs/heads/master"]:
        try:
            _git(top, "rev-parse", "--verify", "-q", f"{ref}^{{commit}}")
            return _git(top, "merge-base", ref, "HEAD").decode().strip()
        except EvidenceError:
            continue
    return ""


def _change_messages(top: str) -> list[str]:
    """Messages of the commits this branch adds: merge-base(default branch, HEAD)..HEAD; HEAD
    alone when no merge-base is found; none before the first commit."""
    try:
        _git(top, "rev-parse", "--verify", "-q", "HEAD^{commit}")
    except EvidenceError:  # no commit yet
        return []
    base = _merge_base(top)
    revs = [f"{base}..HEAD"] if base else ["-1", "HEAD"]
    try:
        out = _git(top, "log", "--format=%B%x00", *revs, "--")
    except EvidenceError:
        return []
    return [m for m in out.decode(errors="replace").split("\0") if m.strip()]


def _recorded_vendors(top: str) -> set[str]:
    """Vendors call-worker.sh recorded for writing lanes run from this worktree, on any
    branch. A line is "<vendor>\\t<branch>", "<vendor>\\t@<commit>" (detached HEAD) or a bare
    "<vendor>"; only the vendor field is read. Binding a line to its branch would let a
    `git switch -c` or `git branch -m` carry the uncommitted change away from the record of
    who wrote it, so every line counts until a person clears the file."""
    try:
        git_dir = _git(top, "rev-parse", "--absolute-git-dir").decode().strip()
        with open(os.path.join(git_dir, AUTHOR_FILE), encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except (EvidenceError, OSError):
        return set()
    found: set[str] = set()
    for line in lines:
        found |= _known(_vendor_tokens(line.partition("\t")[0]))
    return found


def _profile_vendor() -> str:
    """main_vendor of the runtime profile `runtime-profile.py save` wrote; "" when absent."""
    path = os.environ.get("AGENT_PROFILE_FILE") or os.path.join(
        os.path.expanduser("~"), ".agent", "profile.json")
    try:
        with open(path, encoding="utf-8") as f:
            main = _norm(json.load(f).get("main_vendor"))
    except (OSError, ValueError, AttributeError):
        return ""
    return main if main in VENDORS else ""


def author_vendors() -> list[str]:
    """Every company whose model wrote the staged change, sorted: a review by any of them is
    not an external one. The union of AGENT_AUTHOR_VENDOR (it only adds, never overrides), the
    branch prefix, the working-copy folder prefix, every AI Co-Authored-By trailer of the
    commits this branch adds (_change_messages) and every writing lane call-worker.sh recorded
    in this worktree (AUTHOR_FILE). Only when all of them are empty: the runtime profile's
    main vendor, else anthropic, which is what the gate assumed before the author was
    tracked. Raises AuthorVendorError for an unknown AGENT_AUTHOR_VENDOR name."""
    found = _env_vendors()
    top = git_toplevel(os.getcwd())
    if top:
        try:
            branch = _git(top, "symbolic-ref", "--short", "-q", "HEAD").decode().strip()
        except EvidenceError:  # detached HEAD
            branch = ""
        found |= {v for v in (_prefix_vendor(branch, "/"),
                              _prefix_vendor(os.path.basename(top), "-")) if v}
        for message in _change_messages(top):
            found |= _trailer_vendors(message)
        found |= _recorded_vendors(top)
    if not found:
        found.add(_profile_vendor() or "anthropic")
    return sorted(found)


def row_authors(row: dict) -> set[str]:
    """The known vendors in a reviews.jsonl row's author_vendor (a comma list or null)."""
    return _known(_vendor_tokens(row.get("author_vendor")))


def is_external(vendor: object, authors: set[str]) -> bool:
    """External = a known vendor that is none of the authors' companies."""
    v = _norm(vendor)
    return v in VENDORS and v not in authors


def row_is_external_complete(row: dict, authors: set[str]) -> bool:
    """A complete, non-advisor lane whose vendor wrote none of the work. The row's own
    author_vendor can only add authors (narrow what counts), never remove the commit-time ones."""
    return (row.get("status") == "complete"
            and not str(row.get("role") or "").startswith("advisor")
            and is_external(row.get("vendor"), authors | row_authors(row)))


def workers_dir() -> str:
    return os.environ.get("AGENT_WORKERS_DIR") or os.path.join(
        os.path.expanduser("~"), ".agent", "workers", project_key())


def index_rows() -> list[dict]:
    try:
        with open(os.path.join(workers_dir(), "reviews.jsonl"), encoding="utf-8",
                  errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return []
    rows = []
    for line in lines:
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict):
            rows.append(row)
    return rows


def has_external_complete(key: str, authors: set[str] | None = None) -> bool:
    """Raises AuthorVendorError (unknown AGENT_AUTHOR_VENDOR name) when authors is None."""
    if authors is None:
        authors = set(author_vendors())
    return any(row.get("diff_key") == key and row_is_external_complete(row, authors)
               for row in index_rows())


def log_override(key: str | None, reason: str) -> None:
    logs = os.environ.get("AGENT_LOGS_DIR") or os.path.join(
        os.path.expanduser("~"), ".agent", "logs")
    try:
        user = getpass.getuser()
    except (KeyError, OSError, ImportError):
        user = "unknown"
    row = {"ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "project_key": project_key(), "diff_key": key, "reason": reason[:OVERRIDE_MAX],
           "user": user}
    os.makedirs(logs, exist_ok=True)
    with open(os.path.join(logs, "review-override.jsonl"), "a", encoding="utf-8") as f:
        f.write(json.dumps(row) + "\n")


def try_override(key: str | None) -> bool:
    """User-only escape: a logged reason of >= OVERRIDE_MIN chars. It also covers a key
    that cannot be computed, so a broken git state never leaves --no-verify as the
    only way out."""
    reason = (os.environ.get("AGENT_REVIEW_OVERRIDE") or "").strip()
    if len(reason) < OVERRIDE_MIN:
        return False
    try:
        log_override(key, reason)
    except OSError as exc:
        print(f"review-evidence: override log write failed ({exc})", file=sys.stderr)
        return False
    print("review-evidence: AGENT_REVIEW_OVERRIDE accepted — override recorded in "
          "review-override.jsonl", file=sys.stderr)
    return True


def check_staged(extra_parents: tuple[str, ...] = ()) -> int:
    try:
        key = diff_key_staged(extra_parents)
    except (EvidenceError, OSError, IndexError, UnicodeDecodeError) as exc:
        if try_override(None):
            return 0
        print(f"review-evidence: cannot compute the staged review key ({exc}) — "
              "failing closed (AGENT_REVIEW_OVERRIDE still applies)", file=sys.stderr)
        return 1
    if not key:
        return 0
    try:
        authors = set(author_vendors())
    except AuthorVendorError as exc:
        print(f"review-evidence: {exc} — fix or unset it; the gate cannot tell who wrote this "
              "change", file=sys.stderr)
        return 2
    if has_external_complete(key, authors):
        return 0
    if try_override(key):
        return 0
    top = git_toplevel(os.getcwd()) or os.getcwd()
    try:
        files = sorted(risky_staged(top, extra_parents)[1])
    except EvidenceError:
        files = []
    print("review-evidence: risk-area files are staged and no external-vendor review "
          f"(status complete, by a company other than the authors '{','.join(sorted(authors))}') "
          "is bound to this staged content:", file=sys.stderr)
    for path in files:
        print(f"  - {path}", file=sys.stderr)
    print("  Run `/council-review --staged` (re-run it after editing any risk file), or, "
          "only when every external lane is down and the user agrees:\n"
          '    AGENT_REVIEW_OVERRIDE="<reason, >=10 chars>" git commit ...\n'
          "  The override is user-only; agents must not set it. It is logged.",
          file=sys.stderr)
    return 1


def read_frontmatter(path: str) -> dict[str, str]:
    fm: dict[str, str] = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            if f.readline().strip() != "---":
                return fm
            for line in f:
                if line.strip() == "---":
                    break
                k, sep, v = line.partition(":")
                if sep:
                    fm[k.strip()] = v.strip()
    except OSError:
        pass
    return fm


def backend_vendors() -> dict[str, str]:
    path = os.environ.get("AGENT_BACKENDS_FILE") or os.path.join(HERE, "backends.json")
    try:
        with open(path, encoding="utf-8") as f:
            backends = json.load(f).get("backends", {})
        return {n: b.get("vendor") or "" for n, b in backends.items() if isinstance(b, dict)}
    except (OSError, ValueError, AttributeError):
        return {}


def summary(captures: list[str]) -> int:
    vendors = backend_vendors()
    try:
        authors = set(author_vendors())
    except AuthorVendorError as exc:
        print(f"review-evidence: {exc}", file=sys.stderr)
        return 2
    by_capture = {os.path.realpath(str(r["capture"])): r for r in index_rows()
                  if r.get("capture")}
    parts: list[str] = []
    external_complete = 0
    for cap in captures:
        fm = read_frontmatter(cap)
        backend = fm.get("backend", "?")
        status = fm.get("status", "unknown")
        vendor = vendors.get(backend) or ("anthropic" if backend == "claude" else "")
        role = fm.get("role", "")
        lane = {"status": status, "vendor": vendor, "role": role}
        row = by_capture.get(os.path.realpath(cap))
        if row is not None:  # the index row is what the commit gate trusts
            lane["role"] = str(row.get("role") or role)
            lane["status"] = str(row.get("status") or status)
            if "vendor" in row:
                lane["vendor"] = str(row["vendor"] or "")
            lane["author_vendor"] = row.get("author_vendor")
        if row_is_external_complete(lane, authors):
            external_complete += 1
        good = lane["status"] == "complete"
        parts.append(f"{backend} {'✓' if good else '✗'} ({lane['status']})")
    if not external_complete:
        print(SINGLE_VENDOR)
    print("Lane status: " + " | ".join(parts))
    return 0


def main(argv: list[str]) -> int:
    if argv[:1] == ["project-key"]:
        root = argv[2] if argv[1:2] == ["--root"] and len(argv) > 2 else None
        print(project_key(root))
        return 0
    if argv == ["key", "--staged"]:
        try:
            print(diff_key_staged())
        except EvidenceError as exc:
            print(f"review-evidence: {exc}", file=sys.stderr)
            return 2
        return 0
    if argv[:2] == ["check", "--staged"]:
        rest = argv[2:]
        heads = tuple(rest[1::2])
        if (len(rest) % 2 or any(a != "--merge-head" for a in rest[0::2])
                or not all(re.fullmatch(r"[0-9a-f]{40,64}", h) for h in heads)):
            print(__doc__, file=sys.stderr)
            return 2
        return check_staged(heads)
    if argv[:1] == ["summary"]:
        return summary(argv[1:])
    if argv == ["author-vendor"]:
        try:
            print(",".join(author_vendors()))
        except AuthorVendorError as exc:
            print(f"review-evidence: {exc}", file=sys.stderr)
            return 2
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
