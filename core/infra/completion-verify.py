#!/usr/bin/env python3
"""completion-verify.py — independent completion-claim verifier (P3-5).

Re-checks a completion CLAIM in a SEPARATE context (the deterministic layer of
the hooks-mastery builder-validator pattern) and emits a shared-convention
verdict JSON. It structures the "테스트 통과 ≠ 실제 동작 / passing tests ≠ actually
working" lesson: a claim is CONFIRMED only when every cited file exists (and
contains its declared substring), every cited test exits 0, and every cited
assertion exits 0.

Refute-by-default: anything unverifiable — a malformed claim, an empty claim, a
missing file, a spawn error — resolves to REFUTED, never a crash and never a
silent pass. This is the deterministic seed of the LLM-output-quality eval
harness; the semantic layer on top is skills/verify-completion/SKILL.md, which
emits the same verdict schema.

Usage:
  completion-verify.py [--root DIR] [--require-evidence] [--diff-base REF] <claim-file>
    <claim-file>        YAML (.yml/.yaml, when PyYAML is importable) or JSON (.json)
    --root DIR          project root the claim's paths/commands resolve against
                         (default: CWD)
    --require-evidence  opt-in: refute a claim that changed code (uncommitted diff
                         vs HEAD) but cites zero tests/assertions — false-success
                         literature (arXiv 2606.09863) puts "done, trust me" claims
                         at 45-76% of agent failures; this closes the "code changed,
                         nothing cited" gap. New `evidence` dimension.
    --diff-base REF      opt-in: audit the trajectory — every ADDED (`+`) line in
                         `git diff REF` — for skip/xfail/only markers and for a
                         changed code file outside the claim's declared files/scope.
                         New `trajectory` dimension.
  Exit 0 iff CONFIRMED; exit 1 otherwise — usable as a CI / wave GATE.
  completion-verify.py --check-command CMD
                         print the deny-list reason and exit 1 when CMD is denied, else
                         exit 0 (used by supervisor-goal-audit.sh before it runs a check).

Cited commands are screened by a static deny list (_DENY_RULES) before they run. A denied
command is neither run nor counted as passed or failed: it is listed under the verdict's
top-level `denied` key and refutes the claim ("denied (not run)").

Decision coverage (advisory, dryrun): when `.agent/plans/<slug>/spec.md` has a
`## Decisions` section, each `- D<n>:` not listed in the claim's optional
`decisions: [{id, evidence}]` (non-empty evidence) is reported under the
top-level `advisories` key. <slug> = claim `slug`, else the claim file name minus
extension and `-w<N>`. Never affects verdict, score, dimensions, or exit code.

Both flags are opt-in and additive: omitted, verify() behaves exactly as before
(same dimensions, same output) — see docs/scoring-convention.md "additive" rule.

See docs/scoring-convention.md for the verdict schema and its relation to the
supervisor-goal-audit 25-point scorer.
"""
import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys

SCHEMA_VERSION = "1.0.0"

# Bounds — a claim can never make the verifier do unbounded work.
_MAX_FILES = 50
_MAX_TESTS = 20
_MAX_ASSERTIONS = 20
_MAX_CMD_LEN = 500
# Cap the bytes read for a `contains` check so a claim citing a huge regular file
# can't slurp it whole and OOM the verifier. 5 MB is generous for source; a needle
# past it does not match (refute-by-default's safe direction — a false REFUTED, not
# a crash or a false CONFIRMED).
_MAX_CONTAINS_BYTES = 5_000_000


# Static deny list for commands a claim (or a plan's audit check) asks us to run. It screens
# the text only — a shell can spell any of these a thousand ways — so it is a guard against
# the plain forms, not a sandbox. The command is split into simple commands and only the command
# position is judged, so a dangerous word inside a quoted argument (`grep -c 'rm -rf' f`) is
# not a command. Keep it short; add a rule only with a test.
_SEPARATORS = ";&|()`\n"
_WRAPPERS = {"sudo", "doas", "env", "xargs", "command", "exec", "nice", "nohup", "timeout",
             "time", "stdbuf", "ionice"}
_RESERVED = {"if", "then", "elif", "else", "do", "while", "until", "!", "{", "("}
_SHELLS = {"sh", "bash", "zsh", "dash", "ksh"}
# After a wrapper the options and their arguments are not modelled; the rest of the words are
# scanned forward for the first name the screen knows, and judged from there.
_TARGETS = {"rm", "git", "gh", "tee", "dd", "find", "eval", "curl", "wget"} | _SHELLS
_FIND_EXEC = {"-exec", "-execdir", "-ok", "-okdir"}
_DEV_OK = re.compile(r"/dev/(?:null|stdout|stderr)$|/dev/fd/")
_GIT_ARG_OPTS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"}
_ASSIGN = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")


def _subst_in(text):
    """Return the bodies of the `$( )` and backtick substitutions in `text`."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c == "\\":
            i += 2
        elif c == "$" and text.startswith("(", i + 1):
            depth, j = 1, i + 2
            while j < n and depth:
                depth += (text[j] == "(") - (text[j] == ")")
                j += 1
            out.append(text[i + 2:j - 1 if depth == 0 else j])
            i = j
        elif c == "`":
            j = text.find("`", i + 1)
            j = n if j < 0 else j
            out.append(text[i + 1:j])
            i = j + 1
        else:
            i += 1
    return out


def _split_commands(cmd):
    """Split `cmd` into ([(prev_op, words, redirect_targets)] simple commands, [substitution
    bodies to screen again]). Quotes are removed from word values; separators inside quotes do
    not split; heredoc bodies are not commands. A `$( )`/backtick inside double quotes or an
    unquoted heredoc body is returned for a second look (the shell runs it)."""
    cmd = cmd.replace("\\\n", "")
    out, words, redirs, subs, heredocs = [], [], [], [], []
    prev, cur, have, quote, qstart, i, n = "", "", False, None, 0, 0, len(cmd)
    want_redir = False

    def flush():
        nonlocal cur, have, want_redir
        if have:
            (redirs if want_redir else words).append(cur)
            want_redir = False
        cur, have = "", False

    def end(op):
        nonlocal words, redirs, prev, want_redir
        flush()
        want_redir = False
        if words or redirs:
            out.append((prev, words, redirs))
        words, redirs, prev = [], [], op

    while i < n:
        c = cmd[i]
        if quote:
            if c == quote:
                if quote == '"':
                    subs.extend(_subst_in(cmd[qstart:i]))
                quote = None
            elif c == "\\" and quote == '"' and i + 1 < n:
                i += 1
                cur += cmd[i]
            else:
                cur += c
        elif c in "'\"":
            quote, have, qstart = c, True, i + 1
        elif c == "\\" and i + 1 < n:
            i += 1
            cur, have = cur + cmd[i], True
        elif c == "&" and i + 1 < n and cmd[i + 1] == ">":
            i += 1  # `&>file`
            flush()
            want_redir = True
        elif c == "&" and cmd[i - 1:i] == ">":
            pass  # the `&` of `2>&1`: not a separator
        elif c in _SEPARATORS:
            if c in "&|" and i + 1 < n and cmd[i + 1] == c:
                i += 1
                c += c
            end(c)
            if c == "\n" and heredocs:
                pos = i + 1
                for delim, quoted, tabs in heredocs:
                    body = []
                    while pos < n:
                        e = cmd.find("\n", pos)
                        e = n if e < 0 else e
                        line, pos = cmd[pos:e], e + 1
                        if (line.lstrip("\t") if tabs else line) == delim:
                            break
                        body.append(line)
                    if not quoted:
                        subs.extend(_subst_in("\n".join(body)))
                heredocs.clear()
                i = pos - 1
        elif c == "<" and cmd.startswith("<<", i) and not cmd.startswith("<<<", i):
            j = i + 2
            tabs = j < n and cmd[j] == "-"
            j += tabs
            while j < n and cmd[j] in " \t":
                j += 1
            q = cmd[j] if j < n and cmd[j] in "'\"" else None
            if q:
                k = cmd.find(q, j + 1)
                k = n if k < 0 else k
                delim, j = cmd[j + 1:k], k + 1
            else:
                k = j
                while k < n and cmd[k] not in " \t\n" + _SEPARATORS + "<>":
                    k += 1
                delim, j = cmd[j:k], k
            flush()
            heredocs.append((delim.replace("\\", ""), q is not None or "\\" in delim, tabs))
            i = j - 1
        elif c == ">":
            if have and cur.isdigit():
                cur, have = "", False  # the fd of `2>`
            else:
                flush()
            if i + 1 < n and cmd[i + 1] == ">":
                i += 1
            want_redir = True
        elif c in " \t":
            flush()
        else:
            cur, have = cur + c, True
        i += 1
    end("")
    return out, subs


def _command_words(words):
    """Drop leading VAR=value words, shell reserved words and wrappers (sudo, xargs, env,
    timeout...), returning the real command and its arguments. After a wrapper the rest of the
    words are scanned for the first name the screen judges (rm, git, a shell...); none found
    means nothing to judge."""
    i = 0
    while i < len(words):
        base = os.path.basename(words[i])
        if _ASSIGN.match(words[i]) or words[i] in _RESERVED:
            i += 1
        elif base in _WRAPPERS:
            i += 1
            while i < len(words) and os.path.basename(words[i]) not in _TARGETS:
                i += 1
        else:
            break
    return words[i:]


def _screen_simple(words, redirs, prev_words):
    """Return the deny reason for one simple command, or None."""
    for t in redirs:
        if t.startswith("/dev/") and not _DEV_OK.match(t):
            return "write to a device path"
    words = _command_words(words)
    if not words:
        return None
    name, args = os.path.basename(words[0]), words[1:]
    if name == "rm":
        for a in args:
            if a == "--":
                break
            if a == "--recursive" or (a.startswith("-") and not a.startswith("--") and set(a) & set("rR")):
                return "recursive delete (rm)"
    elif name == "git":
        j = 0
        while j < len(args) and args[j].startswith("-"):
            j += 2 if args[j] in _GIT_ARG_OPTS else 1
        sub, rest = (args[j], args[j + 1:]) if j < len(args) else ("", [])
        if sub == "push":
            dry = False
            for a in rest:
                if a in ("--dry-run", "-n"):
                    dry = True
                elif a == "--no-dry-run":
                    dry = False
            if not dry:
                return "git push"
        if sub == "reset" and "--hard" in rest:
            return "git reset --hard"
    elif name == "gh":
        j = 0
        while j < len(args) and args[j].startswith("-"):
            j += 2 if args[j] in ("-R", "--repo") else 1
        if args[j:j + 2] == ["pr", "merge"]:
            return "gh pr merge"
    elif name == "tee":
        if any(a.startswith("/dev/") and not _DEV_OK.match(a) for a in args):
            return "write to a device path"
    elif name == "dd":
        if any(a.startswith("of=/dev/") and not _DEV_OK.match(a[3:]) for a in args):
            return "write to a device path"
    elif name == "eval":
        return denied_reason(" ".join(args))
    elif name == "find":
        for k, a in enumerate(args):
            if a in _FIND_EXEC:
                sub = []
                for b in args[k + 1:]:
                    if b in (";", "+"):
                        break
                    sub.append(b)
                why = _screen_simple(sub, [], None)
                if why:
                    return why
    elif name in _SHELLS:
        for k, a in enumerate(args):
            if a.startswith("-") and not a.startswith("--") and "c" in a:
                if k + 1 < len(args):
                    why = denied_reason(args[k + 1])
                    if why:
                        return why
                break
        if prev_words:
            pw = _command_words(prev_words)
            if pw and os.path.basename(pw[0]) in ("curl", "wget"):
                return "download piped to a shell"
    return None


def denied_reason(cmd):
    """Return why `cmd` is on the deny list, or None when it may run."""
    if not isinstance(cmd, str):
        return None
    prev_words = None
    simple, subs = _split_commands(cmd)
    for op, words, redirs in simple:
        why = _screen_simple(words, redirs, prev_words if op == "|" else None)
        if why:
            return why
        prev_words = words
    for body in subs:
        why = denied_reason(body)
        if why:
            return why
    return None


def _parse_timeout(raw):
    """Per-command wall-clock bound (seconds); degrade to 60 on any bad value so
    a typo like '2m' can never crash the verifier."""
    try:
        v = int(raw)
    except (TypeError, ValueError):
        return 60
    return v if v > 0 else 60


CMD_TIMEOUT = _parse_timeout(os.environ.get("AGENT_VERIFY_CMD_TIMEOUT", "60"))


def load_claim(path):
    """Parse the claim file (JSON always; YAML when PyYAML is importable) and
    return its inner `claim` mapping. Raises on unparseable / ill-shaped input;
    the caller turns a raise into a REFUTED verdict rather than crashing."""
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    if path.endswith((".yml", ".yaml")):
        try:
            import yaml  # optional dependency, same policy as hook_config
        except ImportError:
            raise ValueError("claim is YAML but PyYAML is not importable")
        doc = yaml.safe_load(text)
    else:
        doc = json.loads(text)
    if not isinstance(doc, dict):
        raise ValueError("claim root is not a mapping")
    claim = doc.get("claim", doc)  # a bare top-level mapping is accepted too
    if not isinstance(claim, dict):
        raise ValueError("`claim` is not a mapping")
    return claim


def _run(cmd, root):
    """Run a claim command; return True iff it exits 0. Never raises — a spawn
    error, timeout, or signal all count as failure. `start_new_session=True`
    isolates the command's process group so a teardown idiom that signals its
    group (`kill 0`, `trap 'kill 0' EXIT`) reaches only the command, never this
    verifier.

    Output is discarded to DEVNULL, not captured: only the exit code decides the
    verdict, and capturing a chatty command's stdout would let it accumulate
    unboundedly in the verifier's memory (a timeout bounds time, not memory) and
    OOM-kill the gate before it can refute."""
    if not isinstance(cmd, str) or not cmd.strip() or len(cmd) > _MAX_CMD_LEN:
        return False
    try:
        r = subprocess.run(
            cmd, shell=True, cwd=root or None,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=CMD_TIMEOUT, start_new_session=True,
        )
        return r.returncode == 0
    except Exception:
        return False


def _label(cmd):
    return cmd if isinstance(cmd, str) else repr(cmd)


# --- --require-evidence: code-file extension heuristic --------------------
# Inclusion list (not exclusion) on purpose: an unrecognized extension does
# NOT count as "code changed", so a doc-only or config-only diff never
# triggers the evidence requirement (refute-by-default's safe direction here
# is under-triggering the opt-in check, not over-triggering it on a file
# class this heuristic doesn't recognize).
_CODE_EXT_RE = re.compile(
    r"\.(py|js|jsx|mjs|cjs|ts|tsx|go|rb|java|kt|swift|c|cc|cpp|h|hpp|rs|php|"
    r"sh|bash|zsh|sql|vue|scala|cs)$",
    re.IGNORECASE,
)


def _git_diff_names(root):
    """Uncommitted changed file paths (staged + unstaged), best-effort. Tries
    `git diff --name-only HEAD` first (the common case); a repo with no HEAD
    yet (fresh init, no commits) falls back to the union of unstaged +
    staged. git absent / not a repo / any error -> empty list, never a raise
    — this is an opt-in heuristic, not a gate that should crash the verifier."""
    def _try(args):
        try:
            r = subprocess.run(
                ["git"] + args, cwd=root or None,
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                timeout=CMD_TIMEOUT, text=True,
            )
            if r.returncode == 0:
                return [ln for ln in r.stdout.splitlines() if ln.strip()]
        except Exception:
            pass
        return None

    names = _try(["diff", "--name-only", "HEAD"])
    if names is None:
        unstaged = _try(["diff", "--name-only"]) or []
        staged = _try(["diff", "--name-only", "--cached"]) or []
        names = list(dict.fromkeys(unstaged + staged))
    return names


# --- --diff-base: trajectory audit -----------------------------------------
# Skip/xfail/only markers a trajectory diff must catch on ADDED lines only —
# a pre-existing (context) skip line must NOT trigger this (that would refute
# every claim touching a file that already had an unrelated skip elsewhere).
_TRAJECTORY_SKIP_PATTERNS = [
    (re.compile(r"@pytest\.mark\.skip"), "pytest skip marker"),
    (re.compile(r"@pytest\.mark\.xfail"), "pytest xfail marker"),
    (re.compile(r"@unittest\.skip\b"), "unittest skip decorator"),
    (re.compile(r"\bskipIf\("), "unittest skipIf"),
    (re.compile(r"\bskipUnless\("), "unittest skipUnless"),
    (re.compile(r"\bit\.only\("), "it.only("),
    (re.compile(r"\btest\.skip\b"), "test.skip"),
    (re.compile(r"\bdescribe\.only\("), "describe.only("),
    (re.compile(r"\bxit\("), "xit("),
    (re.compile(r"\bxdescribe\("), "xdescribe("),
    (re.compile(r"\bjest\.mock\("), "broad jest.mock("),
]

# Lockfiles / build artifacts exempt from the scope check. Lockfile patterns
# stay unanchored ((^|/)) — a lockfile is a lockfile no matter how deep it is
# nested (a workspace can carry one per package). dist/build/.agent/
# node_modules are REPO-ROOT anchored (^...) on purpose: 'src/dist/real.py' is
# a real source file that happens to live under a directory named 'dist', NOT
# a build artifact, and must NOT ride the exemption — the review's Major
# finding was exactly that the comment already claimed this anchoring while
# the pattern (^|/) still matched mid-path. Root-anchoring is deliberately
# narrower than "any directory named dist/build anywhere" for that reason.
_DIFF_SCOPE_EXEMPT = [
    re.compile(r"(^|/)package-lock\.json$"),
    re.compile(r"(^|/)yarn\.lock$"),
    re.compile(r"(^|/)pnpm-lock\.yaml$"),
    re.compile(r"(^|/)Gemfile\.lock$"),
    re.compile(r"\.lock$"),
    re.compile(r"^dist/"),
    re.compile(r"^build/"),
    re.compile(r"^\.agent/"),
    re.compile(r"^node_modules/"),
]


def _git_diff_trajectory(root, base):
    """Run `git diff <base> --unified=0` and return (changed_files, added).
    added is a list of (file, text) for every '+' line (never '+++' headers,
    never context/removed lines). Returns (None, None) on any git failure
    (bad ref, not a repo, spawn error) — the caller fails the trajectory
    dimension closed rather than silently skipping it (infra-as-verdict is a
    named failure mode: an infra failure must not become a trusted pass)."""
    try:
        r = subprocess.run(
            ["git", "diff", base, "--unified=0"], cwd=root or None,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=CMD_TIMEOUT, text=True, errors="replace",
        )
    except Exception:
        return None, None
    if r.returncode != 0:
        return None, None

    changed_files = set()
    added = []
    current_file = None
    for line in r.stdout.splitlines():
        if line.startswith("diff --git "):
            current_file = None
        elif line.startswith("+++ "):
            path = line[4:]
            if path.startswith("b/"):
                path = path[2:]
            if path != "/dev/null":
                current_file = path
                changed_files.add(path)
        elif line.startswith("+") and not line.startswith("+++"):
            if current_file:
                added.append((current_file, line[1:]))
    return sorted(changed_files), added


def _claimed_scope(claim):
    """Paths/globs the claim declares in scope: every `files[].path` plus an
    optional `scope` list of glob patterns. Returns (paths:set, globs:list)."""
    paths = set()
    raw = claim.get("files")
    if isinstance(raw, list):
        for item in raw:
            if isinstance(item, str):
                paths.add(item)
            elif isinstance(item, dict):
                p = item.get("path")
                if isinstance(p, str):
                    paths.add(p)
    globs = []
    scope = claim.get("scope")
    if isinstance(scope, list):
        globs = [s for s in scope if isinstance(s, str)]
    return paths, globs


# --- decision coverage (advisory, dryrun) -----------------------------------
# A spec's `## Decisions` bullets (`- D<n>: ...`) vs the claim's optional
# `decisions: [{id, evidence}]`. Reported ONLY under the top-level `advisories`
# key: never a refutation, never a verdict/score/exit change.
_SLUG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
_DECISION_RE = re.compile(r"^[-*]\s+(?:\*\*)?(D\d+)\b")  # top-level bullets only
_DECISIONS_HEAD_RE = re.compile(r"^##\s+Decisions\b", re.IGNORECASE)
_WAVE_SUFFIX_RE = re.compile(r"-w\d+$")


def _slug_ok(slug):
    return bool(_SLUG_RE.match(slug)) and ".." not in slug


def _spec_lines(root, slug):
    """Lines of `.agent/plans/<slug>/spec.md`, or None when unreadable."""
    if not _slug_ok(slug):
        return None
    path = os.path.join(root or "", ".agent", "plans", slug, "spec.md")
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read(_MAX_CONTAINS_BYTES).splitlines()
    except OSError:
        return None


def _find_spec(claim, claim_path, root):
    """Spec lines for the claim: its `slug` field verbatim (no trimming — a slug
    that is not a plain name is rejected, never normalized into a match), else
    the claim file stem, falling back to the stem minus a `-w<N>` wave suffix
    only when the exact stem has no spec."""
    slug = claim.get("slug")
    if isinstance(slug, str) and slug:
        return _spec_lines(root, slug)
    if not claim_path:
        return None
    stem = os.path.splitext(os.path.basename(claim_path))[0]
    lines = _spec_lines(root, stem)
    if lines is None and _WAVE_SUFFIX_RE.search(stem):
        lines = _spec_lines(root, _WAVE_SUFFIX_RE.sub("", stem))
    return lines


def _spec_decision_ids(lines):
    """D-IDs from top-level bullets under the `## Decisions` heading, skipping
    fenced blocks; [] when the section or any D-ID bullet is absent (`- none ...`
    yields no IDs)."""
    ids, in_section, in_fence = [], False, False
    for line in lines:
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
        elif in_fence:
            continue
        elif line.startswith("## "):
            in_section = bool(_DECISIONS_HEAD_RE.match(line))
        elif in_section:
            m = _DECISION_RE.match(line)
            if m and m.group(1) not in ids:
                ids.append(m.group(1))
    return ids


def _decision_advisories(claim, root, claim_path):
    lines = _find_spec(claim, claim_path, root)
    spec_ids = _spec_decision_ids(lines) if lines else []
    if not spec_ids:
        return []
    raw = claim.get("decisions")
    if raw is None:
        covered = set()
    elif not isinstance(raw, list):
        return ["`decisions` must be a list of {id, evidence} (dryrun, ignored)"]
    else:
        covered = {
            d["id"] for d in raw
            if isinstance(d, dict) and isinstance(d.get("id"), str)
            and isinstance(d.get("evidence"), str) and d["evidence"].strip()
        }
    return ["decision %s not covered by claim (dryrun)" % i for i in spec_ids if i not in covered]


def verify(claim, root, require_evidence=False, diff_base=None, claim_path=None):
    """Deterministically check the claim against `root`; return a verdict dict.
    Refute-by-default: any unmet cited fact appends a refutation, and a claim is
    CONFIRMED only when there is something to verify and nothing was refuted."""
    refutations = []
    dims = {
        "files": {"passed": 0, "total": 0},
        "tests": {"passed": 0, "total": 0},
        "assertions": {"passed": 0, "total": 0},
    }

    def _section(name, cap, kind):
        # Normalize a claim section to a bounded list. A present-but-wrong-type
        # section (`"tests": "false"`) is REFUTED, not silently dropped — else a
        # malformed section would let the rest of the claim CONFIRM. Exceeding the
        # cap is itself a refutation so padding can't hide a failing item past the
        # bound; the verdict can never be CONFIRMED by volume.
        raw = claim.get(name)
        if raw is None:
            return []
        if not isinstance(raw, list):
            refutations.append("`%s` must be a list" % name)
            return []
        if len(raw) > cap:
            refutations.append(
                "claim declares %d %s — exceeds the %d cap; the excess is not verified"
                % (len(raw), kind, cap)
            )
        return raw[:cap]

    for item in _section("files", _MAX_FILES, "files"):
        if isinstance(item, str):
            path, contains = item, None
        elif isinstance(item, dict):
            path, contains = item.get("path"), item.get("contains")
        else:
            path, contains = None, None
        dims["files"]["total"] += 1
        if not isinstance(path, str) or not path:
            refutations.append("files: an entry declares no `path`")
            continue
        full = os.path.join(root, path) if root else path
        if not os.path.isfile(full):
            refutations.append("file does not exist: %s" % path)
            continue
        if contains:
            try:
                with open(full, "r", encoding="utf-8", errors="replace") as fh:
                    body = fh.read(_MAX_CONTAINS_BYTES)
            except OSError:
                body = ""
            if str(contains) not in body:
                refutations.append("file %s lacks claimed content: %r" % (path, contains))
                continue
        dims["files"]["passed"] += 1

    denied = []

    def _run_cited(dim, cmd, fail_msg):
        dims[dim]["total"] += 1
        try:
            why = denied_reason(cmd)
        except Exception:
            why = "deny-list screen failed; command not run"
        if why:
            denied.append({"cmd": _label(cmd)[:_MAX_CMD_LEN], "reason": why})
            refutations.append("%s denied (not run): %s [%s]" % (dim[:-1], _label(cmd), why))
        elif _run(cmd, root):
            dims[dim]["passed"] += 1
        else:
            refutations.append("%s: %s" % (fail_msg, _label(cmd)))

    for cmd in _section("tests", _MAX_TESTS, "tests"):
        _run_cited("tests", cmd, "test did not pass")

    for cmd in _section("assertions", _MAX_ASSERTIONS, "assertions"):
        _run_cited("assertions", cmd, "assertion did not hold")

    # --- opt-in: --require-evidence ---
    # code changed (uncommitted, vs HEAD) but the claim cites zero runnable
    # evidence (tests + assertions) -> refuted. A doc/config-only diff, or a
    # claim that DOES cite tests/assertions, always passes this dimension.
    if require_evidence:
        code_changed = [f for f in _git_diff_names(root) if _CODE_EXT_RE.search(f)]
        cited_evidence = dims["tests"]["total"] + dims["assertions"]["total"]
        if code_changed and cited_evidence == 0:
            refutations.append(
                "code changed but claim cites no runnable evidence (tests/assertions): %s"
                % ", ".join(code_changed[:5])
            )
            dims["evidence"] = {"passed": 0, "total": 1}
        else:
            dims["evidence"] = {"passed": 1, "total": 1}

    # --- opt-in: --diff-base <ref> ---
    # trajectory audit: every ADDED line in `git diff <ref>` for a skip/xfail/
    # only/broad-mock marker, and every changed CODE file outside the claim's
    # declared files/scope. A failed diff computation (bad ref, not a repo)
    # fails this dimension closed rather than silently skipping it.
    if diff_base:
        changed_files, added = _git_diff_trajectory(root, diff_base)
        if changed_files is None:
            refutations.append("could not compute trajectory diff against %s" % diff_base)
            dims["trajectory"] = {"passed": 0, "total": 1}
        else:
            traj_ok = True
            for fpath, text in added:
                for pat, label in _TRAJECTORY_SKIP_PATTERNS:
                    if pat.search(text):
                        refutations.append("trajectory: added %s in %s" % (label, fpath))
                        traj_ok = False
            claimed_paths, claimed_globs = _claimed_scope(claim)
            for fpath in changed_files:
                if any(pat.search(fpath) for pat in _DIFF_SCOPE_EXEMPT):
                    continue
                if not _CODE_EXT_RE.search(fpath):
                    continue  # scope check is code-files-only, like --require-evidence
                if fpath in claimed_paths or any(fnmatch.fnmatch(fpath, g) for g in claimed_globs):
                    continue
                refutations.append("changed outside claimed scope: %s" % fpath)
                traj_ok = False
            dims["trajectory"] = {"passed": 1 if traj_ok else 0, "total": 1}

    # "nothing to verify" is scoped to the CORE dimensions only (files/tests/
    # assertions) — evidence/trajectory are opt-in audits, not citable facts,
    # so their presence must never let an empty claim slip past this refutation.
    core_total = dims["files"]["total"] + dims["tests"]["total"] + dims["assertions"]["total"]
    if core_total == 0:
        refutations.append("nothing to verify — the claim cites no files, tests, or assertions")

    total = sum(d["total"] for d in dims.values())
    passed = sum(d["passed"] for d in dims.values())
    score = round(passed / total, 4) if total else 0.0
    confirmed = total > 0 and not refutations
    verdict = {
        "verdict": "CONFIRMED" if confirmed else "REFUTED",
        "score": score,
        "target": str(claim.get("summary") or claim.get("slug") or "(unnamed claim)")[:200],
        "dimensions": dims,
        "refutations": refutations[:50],
        "schema_version": SCHEMA_VERSION,
    }
    if denied:
        verdict["denied"] = denied[:50]
    advisories = _decision_advisories(claim, root, claim_path)
    if advisories:
        verdict["advisories"] = advisories[:50]
    return verdict


def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="completion-verify.py",
        description="Independent completion-claim verifier (P3-5).",
    )
    ap.add_argument("claim", nargs="?", help="path to a JSON/YAML completion claim")
    ap.add_argument("--check-command", default=None, metavar="CMD",
                    help="exit 1 (printing the reason) when CMD is on the deny list, else 0")
    ap.add_argument("--root", default=None,
                    help="project root the claim resolves against (default: CWD)")
    ap.add_argument("--require-evidence", action="store_true",
                    help="opt-in: refute a claim that changed code but cites no tests/assertions")
    ap.add_argument("--diff-base", default=None, metavar="REF",
                    help="opt-in: audit `git diff REF` added lines for skip markers + scope")
    args = ap.parse_args(argv)
    if args.check_command is not None:
        try:
            why = denied_reason(args.check_command)
        except Exception:
            why = "deny-list screen failed"
        if why:
            print("denied: %s" % why)
        return 1 if why else 0
    if not args.claim:
        ap.error("a claim file is required")
    root = args.root or os.getcwd()

    try:
        claim = load_claim(args.claim)
    except Exception as e:  # refute-by-default: unverifiable => REFUTED, no crash
        verdict = {
            "verdict": "REFUTED", "score": 0.0,
            "target": os.path.basename(args.claim),
            "dimensions": {}, "refutations": ["unverifiable claim: %s" % e],
            "schema_version": SCHEMA_VERSION,
        }
        print(json.dumps(verdict, ensure_ascii=False))
        return 1

    verdict = verify(claim, root, require_evidence=args.require_evidence,
                     diff_base=args.diff_base, claim_path=args.claim)
    print(json.dumps(verdict, ensure_ascii=False))
    return 0 if verdict["verdict"] == "CONFIRMED" else 1


if __name__ == "__main__":
    sys.exit(main())
