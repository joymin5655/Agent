#!/usr/bin/env python3
"""PostToolUse hook — Plan-mode approval flag.

When the AI uses ExitPlanMode (Claude Code) OR completes a Plan-class Agent
dispatch, write a /tmp flag so subsequent Write/Edit can be permitted by the
supervisor enforcer.

W-8 source-first: memory fragments are triggers, not evidence. An ExitPlanMode
plan that cites memory but carries no live-source evidence (file:line or
command output) does not get the flag; spec-gate then asks before edits.

Hook protocol: reads canonical event JSON from stdin, writes empty stdout (allow).
Side-effect: writes /tmp/agent-plan-approved with timestamp.
"""

import json
import os
import pathlib
import re
import stat
import sys
import time
from datetime import datetime

# Approval flag path. Overridable via AGENT_PLAN_FLAG so tests can exercise the
# gate against a throwaway path instead of clobbering the live session flag that
# spec-gate.py reads. Default is the shared /tmp location spec-gate expects.
PLAN_FLAG = pathlib.Path(os.environ.get("AGENT_PLAN_FLAG", "/tmp/agent-plan-approved"))

# Agent subagent_type values considered "plan-class"
PLAN_AGENT_TYPES = {"Plan", "plan", "Explore", "explore", "planner"}

# Description / prompt keyword heuristics (multilingual)
PLAN_DESCRIPTION_KEYWORDS = (
    "plan", "design", "architecture", "blueprint", "implementation",
    "구현 계획", "설계", "아키텍처", "구조",
)


# Memory-citation phrasing. Deliberately specific: bare "memory" (memory leak,
# memory usage, "read from memory instead of disk") must not match.
MEMORY_CITATION = re.compile(
    r"\b(per|from|according to|based on|as noted in)\s+(my\s+|the\s+)?"
    r"(memory|memories)\b(?!\s+(instead|pressure|usage|pool|leak|limit|footprint"
    r"|allocation|cache|only|rather|bandwidth|layout))"
    r"|\bmemory (says|notes that|states that|indicates that)\b"
    r"|(?:^|[.!?]\s+)(?:as )?I (?:recall|remember)\b"
    r"|\bMEMORY\.md\b|\bbrain_(get|search|neighbors)\b"
    r"|메모리에\s*(따르면|의하면|기록)|이전에 기록",
    re.IGNORECASE | re.MULTILINE,
)

SOURCE_EXTS = (
    "py|sh|bash|ts|tsx|js|jsx|mjs|md|yml|yaml|json|toml|sql|go|rs|java|rb|c|h"
    "|cpp|hpp|cs|swift|kt|php|html|css|ini|cfg"
)
# path:line — needs a path separator or a known source extension. URLs are
# stripped first so host:port / https://...:8080 never count as evidence.
FILE_LINE = re.compile(
    rf"(?<![\w./-])(?:[\w.-]+(?:/[\w.-]+)+|[\w-]+\.(?:{SOURCE_EXTS})):\d+\b"
)
URL = re.compile(r"\b\w+://\S+")
FENCE = re.compile(r"```[^\n]*\n(.*?)```", re.DOTALL)


def _has_command_output(plan: str) -> bool:
    """A fenced block with a `$ cmd` line followed by at least one output line."""
    for block in FENCE.findall(plan):
        lines = [ln.strip() for ln in block.splitlines() if ln.strip()]
        for idx, ln in enumerate(lines):
            if ln.startswith("$ ") and idx + 1 < len(lines) \
                    and not lines[idx + 1].startswith("$ "):
                return True
    return False


def has_live_evidence(plan: str) -> bool:
    return bool(FILE_LINE.search(URL.sub(" ", plan))) or _has_command_output(plan)


def memory_only_plan(plan: str) -> bool:
    return bool(MEMORY_CITATION.search(plan)) and not has_live_evidence(plan)


def flag_session(flag: pathlib.Path) -> str:
    try:
        m = re.search(r"session=(\S+)", flag.read_text(encoding="utf-8"))
    except OSError:
        return ""
    return m.group(1) if m else ""


# Per-session withheld markers live at <flag>.withheld.d/<session_id>, so a second
# withheld session cannot overwrite the first one's record. The single file
# <flag>.withheld (content = one session id) stays as the fallback slot: unsafe ids,
# an unusable marker dir, or a failed per-session write land there. Older plugin
# scopes still read it, so migration copies from it and never deletes it.
#
# /tmp is world-writable: every marker open is O_NOFOLLOW, the marker dir must be a
# real 0700-style dir we own, and files must be regular files we own.
SAFE_SID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}")
# A marker that sees no plan-gate event (withhold / Agent|Task / ExitPlanMode) for
# this long is pruned on the next withhold; every event for the session refreshes
# its mtime. 7d so a weekend or overnight pause does not re-open the Agent path.
STALE_SECONDS = 7 * 24 * 3600
_NOFOLLOW = os.O_NOFOLLOW | os.O_NONBLOCK | getattr(os, "O_CLOEXEC", 0)


def safe_sid(sid: str) -> bool:
    return bool(SAFE_SID.fullmatch(sid)) and ".." not in sid


def legacy_marker() -> pathlib.Path:
    return PLAN_FLAG.with_name(PLAN_FLAG.name + ".withheld")


def marker_dir() -> pathlib.Path:
    return PLAN_FLAG.with_name(PLAN_FLAG.name + ".withheld.d")


def _open_regular(name: str, flags: int, dir_fd: "int | None" = None) -> int:
    """Open without following symlinks; only a regular file we own is accepted.

    Writes additionally require a single link and truncate only AFTER validation, so a
    hard link planted at the legacy slot cannot get a victim-owned file truncated."""
    writing = bool(flags & (os.O_WRONLY | os.O_RDWR))
    fd = os.open(name, (flags & ~os.O_TRUNC) | _NOFOLLOW, 0o600, dir_fd=dir_fd)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid():
            raise OSError("not a regular file owned by this user")
        if writing and st.st_nlink != 1:
            raise OSError("marker file has extra hard links")
        if flags & os.O_TRUNC:
            os.ftruncate(fd, 0)
    except OSError:
        os.close(fd)
        raise
    return fd


def _read(name: str, dir_fd: "int | None" = None) -> "str | None":
    try:
        fd = _open_regular(name, os.O_RDONLY, dir_fd)
    except OSError:
        return None
    try:
        return os.read(fd, 4096).decode("utf-8", "replace").strip()
    except OSError:
        return None
    finally:
        os.close(fd)


def _write_verified(name: str, content: str, dir_fd: "int | None" = None) -> bool:
    """Write, then read back: a swallowed OSError must not look like success."""
    try:
        data = content.encode("utf-8")  # before open: an unencodable id must not truncate
        fd = _open_regular(name, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, dir_fd)
        try:
            os.write(fd, data)
        finally:
            os.close(fd)
    except (OSError, UnicodeError):
        return False
    return _read(name, dir_fd) == content


def open_marker_dir(create: bool) -> "tuple[int | None, str]":
    """fd of the marker dir, or (None, reason). reason '' = merely absent."""
    path = str(marker_dir())
    if create:
        try:
            os.mkdir(path, 0o700)
        except FileExistsError:
            pass
        except OSError as exc:
            return None, f"mkdir failed: {exc.strerror}"
    try:
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return None, ""
    except OSError as exc:
        return None, f"cannot open (symlink or not a directory?): {exc.strerror}"
    st = os.fstat(fd)
    if st.st_uid != os.geteuid():
        os.close(fd)
        return None, "owned by another user"
    if st.st_mode & 0o022:
        os.close(fd)
        return None, "group/world-writable"
    return fd, ""


def legacy_session() -> str:
    return _read(str(legacy_marker())) or ""


def is_withheld(sid: str) -> bool:
    """True if this session has a withheld marker (per-session or legacy)."""
    if not sid:
        return False
    if safe_sid(sid):
        dfd, _ = open_marker_dir(False)
        if dfd is not None:
            try:
                fd = _open_regular(sid, os.O_RDONLY, dfd)
            except OSError:
                fd = -1
            finally:
                os.close(dfd)
            if fd >= 0:
                try:
                    os.utime(fd)  # keep-alive: any plan-gate event for the session
                except OSError:
                    pass
                os.close(fd)
                return True
    return legacy_session() == sid


def migrate_legacy() -> None:
    """Copy the legacy slot's session into the per-session dir; legacy file stays."""
    old = legacy_session()
    if not old or not safe_sid(old):
        return
    dfd, _ = open_marker_dir(True)
    if dfd is None:
        return
    try:
        try:
            os.stat(old, dir_fd=dfd, follow_symlinks=False)
        except FileNotFoundError:
            _write_verified(old, old, dfd)
        except OSError:
            pass
    finally:
        os.close(dfd)


def prune_stale(dfd: int, keep: str) -> "list[str]":
    """Drop owned regular marker files idle > STALE_SECONDS; never follows links."""
    cutoff = time.time() - STALE_SECONDS
    pruned: "list[str]" = []
    try:
        with os.scandir(dfd) as it:
            names = [e.name for e in it]
    except OSError:
        return pruned
    for name in names:
        if name == keep or not SAFE_SID.fullmatch(name):
            continue
        try:
            st = os.stat(name, dir_fd=dfd, follow_symlinks=False)
            if (not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid()
                    or st.st_mtime >= cutoff):
                continue
            again = os.stat(name, dir_fd=dfd, follow_symlinks=False)  # revived meanwhile?
            if again.st_mtime >= cutoff or (again.st_ino, again.st_dev) != (st.st_ino, st.st_dev):
                continue
            os.unlink(name, dir_fd=dfd)
            pruned.append(name)
        except OSError:
            pass
    return pruned


def set_withheld(sid: str) -> "tuple[str, list[str], str]":
    """Record the marker -> (where, pruned, problem); where = session|legacy|none."""
    migrate_legacy()
    problems = []
    if safe_sid(sid):
        dfd, why = open_marker_dir(True)
        if dfd is None:
            problems.append(f"marker dir unusable ({why or 'absent'})")
        else:
            try:
                if _write_verified(sid, sid, dfd):
                    return "session", prune_stale(dfd, sid), ""
                problems.append("per-session marker write failed")
            finally:
                os.close(dfd)
    else:
        problems.append("session id is not filename-safe")
    if _write_verified(str(legacy_marker()), sid):
        return "legacy", [], "; ".join(problems)
    return "none", [], "; ".join(problems)


def _restore_claim(claim: str, legacy: str, content: "str | None") -> None:
    """Put a claimed slot that is not ours back without losing it or clobbering a
    newer slot: link, else rename when the slot is still free (FS without hard
    links), else keep that session as a per-session marker."""
    try:
        os.link(claim, legacy)
        os.unlink(claim)
        return
    except OSError:
        pass
    if not os.path.lexists(legacy):
        try:
            os.rename(claim, legacy)
            return
        except OSError:
            pass
    if content and safe_sid(content):
        dfd, _ = open_marker_dir(True)
        if dfd is not None:
            try:
                if not _write_verified(content, content, dfd):
                    return  # keep the claim file rather than lose the record
            finally:
                os.close(dfd)
    try:
        os.unlink(claim)
    except OSError:
        pass


def _claim_remove_legacy(sid: str) -> None:
    """Delete the legacy slot only if it is still this session's: rename to a unique
    name first, so a concurrent writer cannot be deleted between check and unlink."""
    legacy = str(legacy_marker())
    claim = f"{legacy}.claim.{os.getpid()}.{os.urandom(4).hex()}"
    try:
        os.rename(legacy, claim)
    except OSError:
        return
    try:
        content = _read(claim)
        if content == sid:
            os.unlink(claim)
            return
        _restore_claim(claim, legacy, content)
    except OSError:
        pass


def clear_withheld(sid: str) -> None:
    """Drop only this session's marker; other sessions' markers stay."""
    if safe_sid(sid):
        dfd, _ = open_marker_dir(False)
        if dfd is not None:
            try:
                os.unlink(sid, dir_fd=dfd)
            except OSError:
                pass
            finally:
                os.close(dfd)
    if legacy_session() == sid:
        _claim_remove_legacy(sid)


def write_flag(sid: str) -> None:
    # Same discipline as the withheld marker: no symlink follow, single link only,
    # truncate after validation (a planted link must not get a victim file rewritten).
    try:
        data = f"approved at {datetime.now().isoformat()} session={sid}".encode("utf-8")
        fd = _open_regular(str(PLAN_FLAG), os.O_WRONLY | os.O_CREAT | os.O_TRUNC)
        try:
            os.write(fd, data)
        finally:
            os.close(fd)
    except (OSError, UnicodeError):
        pass


def notice(message: str) -> None:
    sys.stdout.write(json.dumps({
        "hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": message}
    }))


def withhold(sid: str) -> None:
    """Memory-only plan: no flag for this session, and Agent path stays shut."""
    try:
        where, pruned, problem = set_withheld(sid) if sid else ("none", [], "")
    except Exception as exc:  # never let a recording failure pass silently
        where, pruned, problem = "none", [], f"internal error: {type(exc).__name__}"
    cleared = False
    if PLAN_FLAG.exists() and sid and flag_session(PLAN_FLAG) == sid:
        try:
            PLAN_FLAG.unlink()
        except OSError:
            pass
    if not PLAN_FLAG.exists():
        cleared = True
    base = (
        "plan-gate: plan cites memory without live-source evidence. Memory is a "
        "trigger, not proof - re-verify each factual claim against the source "
        "(file:line or command output) and re-submit the plan. "
    )
    if not sid:
        base += (
            "The event has no session_id, so no withheld marker was recorded and a "
            "plan-class Agent/Task dispatch may re-open the gate. "
        )
    elif where == "legacy":
        base += (
            f"Withheld marker fell back to the shared single-slot file ({problem}); "
            "another withheld session may overwrite it. "
        )
    elif where == "none":
        base += (
            f"Withheld marker not recorded ({problem}); plan-class Agent/Task "
            "dispatches in this session may re-open the gate. "
        )
    if pruned:
        base += f"Pruned {len(pruned)} withheld marker(s) idle for over 7 days. "
    if cleared:
        notice(base + "This session's approval flag is not set.")
    else:
        notice(
            base + "Could not clear the approval flag (it belongs to another session "
            "or is unowned/undeletable), so edits may still pass the spec-gate."
        )


def is_plan_agent(data: dict) -> bool:
    tool_input = data.get("tool_input")
    if not isinstance(tool_input, dict):
        return False

    subagent_type = tool_input.get("subagent_type", "")
    if subagent_type in PLAN_AGENT_TYPES:
        return True

    description = (tool_input.get("description") or "").lower()
    for keyword in PLAN_DESCRIPTION_KEYWORDS:
        if keyword in description:
            return True

    prompt = (tool_input.get("prompt") or "").lower()
    if "implementation plan" in prompt or "구현 계획" in prompt:
        return True

    return False


def run() -> None:
    try:
        data = json.loads(sys.stdin.read())
    except (json.JSONDecodeError, ValueError):
        return
    if not isinstance(data, dict):
        return

    tool_name = data.get("tool_name", "")
    sid = str(data.get("session_id") or "")
    tool_input = data.get("tool_input")
    if not isinstance(tool_input, dict):
        tool_input = {}

    # ExitPlanMode = user-approved plan in Claude Code → write flag
    if tool_name == "ExitPlanMode":
        plan = tool_input.get("plan")
        if isinstance(plan, str) and memory_only_plan(plan):
            withhold(sid)
            return
        if sid:
            clear_withheld(sid)
        write_flag(sid)
        return

    # Agent tool — check if it's plan-class (Task/Agent per Claude Code version)
    if tool_name not in ("Agent", "Task"):
        return

    # A memory-only plan was withheld in this session: a plan-class dispatch must
    # not re-open the gate until an ExitPlanMode with live evidence passes.
    if is_withheld(sid):
        return

    if is_plan_agent(data):
        write_flag(sid)


def main() -> None:
    try:
        run()
    except Exception:  # fail-open: a hook bug must never break the session
        return


if __name__ == "__main__":
    main()
