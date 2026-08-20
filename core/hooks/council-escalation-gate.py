#!/usr/bin/env python3
"""council-escalation-gate.py — deterministic council-review escalation gate.

Matcher: PreToolUse Task|Agent, code-reviewer dispatches only (namespace-agnostic:
`x:code-reviewer` resolves `code-reviewer`, same normalization
model-routing-advisor.py:98 and supervisor.py:367 already use).

Enforced by tool boundary, not prompt coercion — spec-gate's founding
principle, restated in the harness's own numbers: supervisor.py's docstring
cites ~98% ignore rate on advisory routing hints, so a council-scale diff
must not stay Claude-solo just because nobody read a suggestion.

Decision: core/infra/council-threshold.sh is the SSOT for "is this diff
council-scale" (line/file count OR a risk-area path). When it says yes (exit
10), a plain code-reviewer dispatch is denied with a pointer to
`/council-review --staged`. Every other case — non-dispatch tool, non-Task/Agent,
non-code-reviewer subagent, small diff — is silent (empty stdout, allow).

Escape-hatch state lives OUTSIDE any reviewed workspace (2026-08-21 security
fix, F2 — the same "grant-side state must live outside any workspace" rule
core/hooks/trust_tier.py:14-19 states for its own trust list): a
cloned/unpacked hostile repo can ship files, and git sets a FRESH mtime on
checkout, so anything this gate TRUSTS must not be readable from inside the
repo under review. Base dir: AGENT_COUNCIL_STATE_DIR or
~/.agent/state/council; keyed per-repo by a sha256(abs-path)[:12] subdir so
concurrent projects don't collide. Two escape hatches live there:

  1. The council-active FLAG — set by skills/council-review/SKILL.md step 0.5
     (via this file's own `--council-flag set` CLI) before its internal
     `code-reviewer` Agent dispatch, so the council's own dispatch is never
     blocked by the gate that sent the caller here. council_active() requires
     BOTH: the flag file is fresh (age <= AGENT_COUNCIL_ACTIVE_TTL_S, default
     300s — shortened from an earlier 1800s borrowed from a different
     mechanism's shape; this flag only has to cover one dispatch) AND its
     CONTENT equals the sha256 of the diff it was set for (diff_hash()) — a
     stale, forged, or diff-mismatched flag no longer bypasses anything. The
     skill clears the flag again at the end of its run (step 6) so it cannot
     silently un-gate a later, unrelated diff for the rest of its TTL.
  2. Same-diff-hash single-deny — a diff already denied once is allowed
     through on a retry within AGENT_COUNCIL_DENY_TTL_S (default 3600s;
     stderr warning, not a permission decision), so a caller that cannot
     actually run council-review (no worker CLI, offline, user declines the
     cost prompt) is not stuck in a permanent deny loop on the same diff.
     Ledger entries carry a timestamp and expire — an un-timestamped entry
     would otherwise be a forever-valid bypass token for that diff hash.

CLI (`--council-flag set|clear`): the only supported way to touch the flag —
the skill never writes the flag file directly, since "set" must write the
CURRENT diff hash, not an empty touch. Argv is checked before stdin is ever
read, so this never disturbs the normal stdin-JSON hook path; both verbs are
silent on stdout (errors go to stderr only), matching the hook protocol's
"every non-deny/ask path writes zero bytes to stdout" even though CLI
invocations aren't hook events.

Audit sink: firing/escape events are appended to the SAME
.agent/logs/security-violations.jsonl every other deny-class gate writes
(pre-tool-guard.sh's log_violation() shape) — kept IN the reviewed repo,
unlike the escape-hatch state above. The distinction is deliberate: state is
TRUSTED (read back to make an allow/deny decision), so a hostile repo must
not be able to plant or backdate it; the log is WRITE-ONLY (this gate never
reads it back), so a hostile repo forging or padding it can pollute
telemetry but cannot buy a bypass — and keeping it in-repo is what makes it
visible to core/infra/telemetry-digest.sh, which only counts sinks under
<repo>/.agent/logs/.

Fail-open: any exception, missing git repo, missing/broken threshold script,
or a threshold exit code other than 0/10 all resolve to silent allow — a
broken gate must never block a dispatch (docs/hook-protocol.md §3). A
threshold-script failure (including its 15s timeout) additionally writes one
stderr line and one "error" audit record, so a broken gate is distinguishable
from a genuinely small diff after the fact.

Seams: AGENT_COUNCIL_LINES / AGENT_COUNCIL_FILES (read by
council-threshold.sh, not this file), AGENT_COUNCIL_ACTIVE_TTL_S (default
300), AGENT_COUNCIL_DENY_TTL_S (default 3600), AGENT_COUNCIL_STATE_DIR
(default ~/.agent/state/council).
Registered in docs/gate-registry.md (GATE council-escalation).
"""

import hashlib
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone

FRAMEWORK_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
THRESHOLD_SCRIPT = os.path.join(FRAMEWORK_ROOT, "core", "infra", "council-threshold.sh")

DISPATCH_TOOLS = {"Task", "Agent"}
ACTIVE_TTL_S = int(os.environ.get("AGENT_COUNCIL_ACTIVE_TTL_S", "300") or 300)
DENY_TTL_S = int(os.environ.get("AGENT_COUNCIL_DENY_TTL_S", "3600") or 3600)
DENY_LOG_CAP = 50

DENY_REASON = (
    "council-escalation: this diff is council-scale (line/file threshold or a "
    "risk-area path) — a plain solo code-reviewer dispatch is blocked. Run "
    "`/council-review --staged` for a multi-vendor review instead, or "
    "re-issue this exact dispatch once more (the same-diff single-deny "
    "escape lets an identical retry through, once, with a warning) if "
    "council-review genuinely cannot run right now."
)


def canonical_root(path):
    """Collapse every spelling of one repository to a single string, so the
    `--council-flag set` CLI and the hook that reads that flag agree on
    state_dir()'s key. Two spellings diverge in practice: a session whose cwd
    is a SUBDIRECTORY of the repo, and a checkout reached through a symlink
    (macOS `/tmp` and `/var` are symlinks). Resolving to the git top-level and
    then realpath'ing collapses both. Falls back to realpath(path) outside a
    repo."""
    try:
        out = subprocess.check_output(
            ["git", "-c", "core.fsmonitor=", "rev-parse", "--show-toplevel"],
            cwd=path, stderr=subprocess.DEVNULL, timeout=15,
        ).decode().strip()
        if out:
            return os.path.realpath(out)
    except Exception:
        pass
    return os.path.realpath(path)


def repo_root(event=None):
    """Resolve the active project root. Priority: the PreToolUse event's own
    'cwd' (the session's real working directory when this hook fired) ->
    AGENT_PROJECT_DIR/CLAUDE_PROJECT_DIR -> the hook process's own cwd, which
    is not guaranteed to match the event's cwd. Mirrors session-quality-gate.py's
    resolve_root() idiom (F8) — a session started outside a repo, or whose
    event cwd differs from the hook process's cwd, must not key state (or run
    git) against the wrong root. The winner is canonicalized (F13) so the CLI
    and the hook cannot key the same repo two different ways."""
    cwd = event.get("cwd") if isinstance(event, dict) else None
    if isinstance(cwd, str) and cwd.strip():
        return canonical_root(cwd)
    env_root = os.environ.get("AGENT_PROJECT_DIR") or os.environ.get("CLAUDE_PROJECT_DIR")
    if env_root:
        return canonical_root(env_root)
    return canonical_root(os.getcwd())


def state_dir(root):
    """Escape-hatch state root — OUTSIDE any reviewed workspace (F2). Keyed
    per-repo so concurrent projects never collide."""
    base = os.environ.get("AGENT_COUNCIL_STATE_DIR") or os.path.join(
        os.path.expanduser("~"), ".agent", "state", "council"
    )
    key = hashlib.sha256(os.path.realpath(root).encode()).hexdigest()[:12]
    return os.path.join(base, key)


def flag_path(root):
    return os.path.join(state_dir(root), "active")


def deny_state_path(root):
    return os.path.join(state_dir(root), "denied.json")


def council_active(root, hash_fn):
    """True iff the council-active flag is fresh AND its content equals the
    diff hash `hash_fn()` computes for the CURRENT diff (F2's diff-binding
    fix) — a stale, forged, or diff-mismatched flag no longer bypasses the
    gate. `hash_fn` is called lazily, only once the flag is confirmed to
    exist and be fresh, so a dispatch with no active flag pays no extra
    git-diff cost."""
    try:
        age = time.time() - os.path.getmtime(flag_path(root))
    except Exception:
        return False
    if age > ACTIVE_TTL_S:
        return False
    try:
        with open(flag_path(root), encoding="utf-8") as f:
            content = f.read().strip()
    except Exception:
        return False
    h = hash_fn()
    return bool(h) and content == h


def threshold_escalates(root):
    """Run council-threshold.sh --staged in root. True iff it exits 10.
    Fail-open on any exception (including the 15s timeout), but write one
    stderr line and one audit record first (F7) — the diffs most likely to
    time out are exactly the council-scale ones this gate exists for, and a
    silent fail-open makes "gate broke" indistinguishable from "small diff"."""
    try:
        proc = subprocess.run(
            ["bash", THRESHOLD_SCRIPT, "--staged"],
            cwd=root,
            capture_output=True,
            text=True,
            timeout=15,
        )
    except Exception as exc:
        print(
            f"[council-escalation-gate] council-threshold.sh failed "
            f"({type(exc).__name__}) — failing open (allow)",
            file=sys.stderr,
        )
        log_event(root, "error", f"threshold script error: {type(exc).__name__}")
        return False
    return proc.returncode == 10


def diff_hash(root):
    """Hash the same diff council-threshold.sh judged (staged, falling back
    to HEAD~1..HEAD when staging is empty — same fallback the script uses),
    so the loop-safety dedup key and the flag-binding check both track the
    actual diff, not just its line/file summary. Returns None on any git
    failure (F9) — a distinct sentinel, NOT sha256(b"") — so two unrelated
    failures can never collide into "already denied", and callers skip both
    ledger read and write when this is None."""
    try:
        staged = subprocess.check_output(
            ["git", "-c", "core.fsmonitor=", "diff", "--no-ext-diff", "--no-textconv", "--staged"],
            cwd=root, stderr=subprocess.DEVNULL, timeout=15,
        )
        content = staged if staged.strip() else subprocess.check_output(
            ["git", "-c", "core.fsmonitor=", "diff", "--no-ext-diff", "--no-textconv", "HEAD~1..HEAD"],
            cwd=root, stderr=subprocess.DEVNULL, timeout=15,
        )
    except Exception:
        return None
    return hashlib.sha256(content).hexdigest()[:16]


def _load_deny_entries(root):
    """Load the deny ledger, dropping any entry older than DENY_TTL_S (F3).
    Malformed/legacy shapes degrade to empty rather than raising."""
    try:
        with open(deny_state_path(root), encoding="utf-8") as f:
            data = json.load(f)
        entries = data.get("entries")
        if not isinstance(entries, list):
            return []
        now = time.time()
        fresh = []
        for e in entries:
            if not isinstance(e, dict):
                continue
            h, ts = e.get("hash"), e.get("ts")
            if not isinstance(h, str) or not isinstance(ts, (int, float)):
                continue
            if now - ts <= DENY_TTL_S:
                fresh.append({"hash": h, "ts": ts})
        return fresh
    except Exception:
        return []


def already_denied(root, h):
    if not h:
        return False
    return any(e["hash"] == h for e in _load_deny_entries(root))


def record_denied(root, h):
    if not h:
        return  # F9: an unhashable diff is never recorded (nor read back)
    path = deny_state_path(root)
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        entries = _load_deny_entries(root)  # already TTL-pruned
        entries.append({"hash": h, "ts": time.time()})
        entries = entries[-DENY_LOG_CAP:]
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"entries": entries}, f)
        os.replace(tmp, path)  # atomic — mirrors supervisor.py's save_state
    except Exception:
        pass


def log_event(root, decision, reason):
    """Append one firing/escape/error record to the shared deny-gate sink
    (see module docstring "Audit sink" for why this stays IN the repo while
    the escape-hatch state above does not). Never raises; silent on stdout."""
    try:
        log_dir = os.path.join(root, ".agent", "logs")
        os.makedirs(log_dir, exist_ok=True)
        rec = {
            "ts": datetime.now(timezone.utc).isoformat(),
            "guard": "council-escalation",
            "hook": "council-escalation-gate.py",
            "reason": reason,
            "session_id": os.environ.get("AGENT_SESSION_ID", "main"),
            "decision": decision,
            "schema_version": "2.0.0",
        }
        with open(os.path.join(log_dir, "security-violations.jsonl"), "a", encoding="utf-8") as f:
            f.write(json.dumps(rec) + "\n")
    except Exception:
        pass


def emit_deny():
    out = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": DENY_REASON,
        }
    }
    sys.stdout.write(json.dumps(out))


def council_flag_cli(args):
    """`--council-flag set|clear` — the only supported way to touch the
    council-active flag (the skill never writes it directly): "set" must
    write the CURRENT diff hash as the flag's content so council_active()'s
    diff-binding check has something real to compare against; a bare touch
    would not carry that binding. Both verbs are silent on stdout; problems
    go to stderr only."""
    if not args or args[0] not in ("set", "clear"):
        print("usage: council-escalation-gate.py --council-flag set|clear", file=sys.stderr)
        return
    root = repo_root(None)
    flag = flag_path(root)
    if args[0] == "clear":
        try:
            os.remove(flag)
        except FileNotFoundError:
            pass
        except Exception as exc:
            print(f"[council-escalation-gate] --council-flag clear failed: {exc}", file=sys.stderr)
        return
    h = diff_hash(root)
    if not h:
        print(
            "[council-escalation-gate] --council-flag set: could not compute a "
            "diff hash (not a git repo, or git failed) — flag NOT set",
            file=sys.stderr,
        )
        return
    try:
        os.makedirs(state_dir(root), exist_ok=True)
        tmp = flag + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(h)
        os.replace(tmp, flag)
    except Exception as exc:
        print(f"[council-escalation-gate] --council-flag set failed: {exc}", file=sys.stderr)


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "--council-flag":
        council_flag_cli(sys.argv[2:])
        return

    try:
        event = json.loads(sys.stdin.read())
    except Exception:
        return
    if event.get("tool_name") not in DISPATCH_TOOLS:
        return
    tool_input = event.get("tool_input") or {}
    subagent_type = tool_input.get("subagent_type", "")
    if not isinstance(subagent_type, str) or not subagent_type.strip():
        return

    bare = subagent_type.rsplit(":", 1)[-1]
    if bare != "code-reviewer":
        return

    root = repo_root(event)

    _hash_cache = {}

    def current_hash():
        if "v" not in _hash_cache:
            _hash_cache["v"] = diff_hash(root)
        return _hash_cache["v"]

    # Escape 1: council-review's own internal code-reviewer dispatch.
    if council_active(root, current_hash):
        log_event(root, "allow", "council-active flag escape")
        return

    if not threshold_escalates(root):
        return

    h = current_hash()

    # Escape 2: this exact diff was already denied once (within
    # AGENT_COUNCIL_DENY_TTL_S) — let the retry through rather than deny
    # forever (loop-safety valve).
    if h and already_denied(root, h):
        print(
            "[council-escalation-gate] this council-scale diff was already "
            "denied once — allowing the solo code-reviewer dispatch through "
            "this time (loop-safety escape; run /council-review --staged "
            "when you can).",
            file=sys.stderr,
        )
        log_event(root, "allow", "same-diff-hash escape (already denied once)")
        return

    record_denied(root, h)
    log_event(root, "deny", "council-scale diff — plain code-reviewer dispatch denied")
    emit_deny()


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # fail-open: a gate bug must never block a dispatch
    sys.exit(0)
