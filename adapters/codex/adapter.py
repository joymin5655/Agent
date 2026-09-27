#!/usr/bin/env python3
"""Codex CLI envelope translator → canonical hook event JSON.

Reads one JSON object from stdin (newline-terminated or single message).
If it already matches the canonical shape, passes through unchanged.
Otherwise translates known Codex tool-call envelopes:

  Codex shell_call   →  PreToolUse + tool_name=Bash + tool_input.command
  Codex file_write   →  PreToolUse + tool_name=Write + tool_input.{file_path,content}
  Codex apply_patch  →  PreToolUse + tool_name=Edit + tool_input.{file_path,...}

Output: canonical event JSON to stdout, ready to pipe into a core hook.

`--run <hook-path>` mode (what adapter.sh uses) also RUNS the hook. When stdin
is a Codex *native* hook event (`hook_event_name` present — ~/.codex/hooks.json
or the plugin's hooks/codex-hooks.json), see run_native(): Codex continues the
tool call on any hook failure or unsupported `ask`, so PreToolUse failures are
converted to an explicit deny here (docs/ai-adapters.md § Codex decision mapping).
"""
from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import time

# PreToolUse only: ONE budget for all per-file runs of a hook, below the 30s
# `timeout` in hooks.json.template, so the adapter — not Codex — decides what a
# slow guard means (a Codex-side timeout continues the tool call: fail-open).
# Other events keep Codex's own (longer) timeout.
PRE_TOOL_TIMEOUT_S = float(os.environ.get("AGENT_CODEX_PRE_BUDGET_S", "25"))  # env: test seam
# A patch touching more files than this is denied outright (ask for smaller
# patches) instead of racing the time budget file by file.
MAX_PATCH_FILES = 100
# `*** Move to:` writes the whole source file to the destination; it is read
# from disk so the destination is checked with that content. Bigger -> deny.
MAX_MOVE_SOURCE_BYTES = 2_000_000

_PATCH_OPS = (
    ("*** Add File: ", "add"),
    ("*** Update File: ", "update"),
    ("*** Delete File: ", "delete"),
)


def is_canonical(obj: dict) -> bool:
    return "event" in obj and "tool_name" in obj and "tool_input" in obj


def translate_codex(obj: dict) -> dict:
    """Best-effort translation from Codex tool-call envelopes."""
    out = {
        "ai": "codex",
        "event": obj.get("event", "PreToolUse"),
        "session_id": obj.get("session_id", ""),
        "cwd": obj.get("cwd", ""),
    }

    t = obj.get("type", "")

    if t == "shell_call":
        args = obj.get("arguments", {})
        cmd = args.get("command", [])
        if isinstance(cmd, list):
            # Codex usually wraps in ["bash", "-lc", "<real-cmd>"]
            if len(cmd) >= 3 and cmd[0] in ("bash", "sh", "/bin/bash", "/bin/sh") and cmd[1] in ("-lc", "-c"):
                cmd_str = cmd[2]
            else:
                cmd_str = " ".join(cmd)
        else:
            cmd_str = str(cmd)
        out["tool_name"] = "Bash"
        out["tool_input"] = {"command": cmd_str}

    elif t == "file_write":
        out["tool_name"] = "Write"
        out["tool_input"] = {
            "file_path": obj.get("path", ""),
            "content": obj.get("content", ""),
        }

    elif t in ("apply_patch", "edit", "file_edit"):
        out["tool_name"] = "Edit"
        out["tool_input"] = {
            "file_path": obj.get("path", obj.get("file_path", "")),
            "old_string": obj.get("old_string", ""),
            "new_string": obj.get("new_string", ""),
        }

    else:
        # Unknown envelope — pass through as-is with `tool_name` falling back to type.
        out["tool_name"] = obj.get("tool_name", t or "Unknown")
        out["tool_input"] = obj.get("tool_input", obj.get("arguments", {}))

    return out


def is_native(obj: dict) -> bool:
    return "hook_event_name" in obj and "event" not in obj


class PatchError(ValueError):
    """apply_patch text the adapter cannot attribute to files unambiguously."""


def parse_apply_patch(text: str) -> list[dict]:
    """Split Codex patch text into per-file ops: {op, path, move_to, added, removed}.

    Scans every line (not only inside *** Begin/End Patch) so a heredoc-wrapped
    patch still yields its file ops; zero ops means the caller must fail closed.
    Markers count only at column 0. An indented marker is ambiguous — a hunk
    context line to one parser, a header to a lenient one — and mis-attributing
    the lines after it would check the wrong file, so it raises PatchError.
    """
    ops: list[dict] = []
    cur = None
    for line in text.splitlines():
        if line != line.lstrip() and line.lstrip().startswith("*** "):
            raise PatchError(f"indented patch marker {line.strip()[:60]!r}")
        header = next(((line[len(p):].strip(), op) for p, op in _PATCH_OPS if line.startswith(p)), None)
        if header:
            cur = {"op": header[1], "path": header[0], "move_to": "", "added": [], "removed": []}
            ops.append(cur)
        elif line.startswith("*** End Patch"):
            cur = None
        elif cur is None:
            continue
        elif line.startswith("*** Move to: "):
            cur["move_to"] = line[len("*** Move to: "):].strip()
        elif line.startswith("+"):
            cur["added"].append(line[1:])
        elif line.startswith("-"):
            cur["removed"].append(line[1:])
    return ops


def _abs(path: str, cwd: str) -> str:
    # normpath: path-prefix exemptions in core hooks (tests/, fixtures/) must
    # not be reachable through `tests/../src/x`.
    return os.path.normpath(path if os.path.isabs(path) or not cwd else os.path.join(cwd, path))


def _move_source(path: str) -> str:
    try:
        st = os.stat(path)
    except OSError:
        return ""  # nothing on disk to carry over; Codex's own apply will fail
    # A FIFO/device would block the read past Codex's timeout (= fail-open).
    if not stat.S_ISREG(st.st_mode):
        raise PatchError("move source is not a regular file")
    if st.st_size > MAX_MOVE_SOURCE_BYTES:
        raise PatchError(f"move source larger than {MAX_MOVE_SOURCE_BYTES} bytes")
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read(MAX_MOVE_SOURCE_BYTES + 1)
    except OSError:
        return ""


def translate_native(obj: dict) -> list[dict]:
    """Codex native hook stdin -> one or more canonical events.

    Native fields are kept (hooks such as circuit-breaker read tool_use_id);
    `ai`/`event` are added. apply_patch becomes one Write (Add File, and the
    destination of a Move) or Edit (Update/Delete File) per file, with absolute
    file_path like Claude's Write/Edit. Returns [] for an apply_patch with no
    recognizable file operation.
    """
    base = dict(obj, ai="codex", event=obj.get("hook_event_name", ""))
    tool = obj.get("tool_name", "")
    tool_input = obj.get("tool_input")
    if tool != "apply_patch":
        return [base]

    patch = tool_input.get("command", "") if isinstance(tool_input, dict) else str(tool_input or "")
    cwd = obj.get("cwd") or ""
    events = []
    ops = parse_apply_patch(patch if isinstance(patch, str) else "")
    touched = len(ops) + sum(1 for op in ops if op["move_to"])
    if touched > MAX_PATCH_FILES:
        raise PatchError(f"patch touches {touched} files (limit {MAX_PATCH_FILES}); split it")
    for op in ops:
        added = "".join(line + "\n" for line in op["added"])
        removed = "".join(line + "\n" for line in op["removed"])
        common = dict(base, codex_tool_name="apply_patch")
        if op["op"] == "add":
            events.append(dict(common, tool_name="Write",
                               tool_input={"file_path": _abs(op["path"], cwd), "content": added}))
            continue
        # old_string/new_string = the removed/added lines of all hunks, not an
        # exact-match block: enough for content and path guards, not for replay.
        events.append(dict(common, tool_name="Edit", tool_input={
            "file_path": _abs(op["path"], cwd), "old_string": removed, "new_string": added}))
        if op["move_to"]:
            # The destination receives the whole (edited) source file: check the
            # current source text plus the added lines (a superset of the result).
            src = _move_source(_abs(op["path"], cwd))
            events.append(dict(common, tool_name="Write", tool_input={
                "file_path": _abs(op["move_to"], cwd), "content": src + added}))
    return events


def _run_hook(hook_path: str, event: dict, timeout: float | None = None) -> tuple[int, str, str]:
    cwd = event.get("cwd")
    try:
        proc = subprocess.run(
            [hook_path], input=json.dumps(event), capture_output=True, text=True, check=False,
            timeout=timeout, cwd=cwd if cwd and os.path.isdir(cwd) else None,
        )
    except subprocess.TimeoutExpired:
        return 124, "", f"hook timed out after {timeout}s"
    except OSError as exc:
        return 126, "", str(exc)
    return proc.returncode, proc.stdout, proc.stderr


def _parse_output(stdout: str):
    """Hook stdout -> dict | None (empty); raises ValueError/TypeError when unusable."""
    text = stdout.strip()
    if not text:
        return None
    try:
        out = json.loads(text)
    except json.JSONDecodeError:
        out = json.loads(text.splitlines()[-1])  # JSONDecodeError is a ValueError
    if not isinstance(out, dict):
        raise TypeError("hook output is not a JSON object")
    return out


def _deny(reason: str) -> dict:
    return {"hookSpecificOutput": {
        "hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason}}


def _pre_tool_use(hook_path: str, events: list[dict], deadline: float) -> dict | None:
    """Run the hook per event; deny > ask(->deny) > advisory > allow."""
    hook = os.path.basename(hook_path)
    if not events:
        return _deny(f"[agent/codex] {hook}: apply_patch has no recognizable file operation; "
                     "blocked fail-closed because the target files cannot be checked.")
    denied = asked = None
    contexts: list[str] = []
    for ev in events:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return _deny(f"[agent/codex] {hook}: {PRE_TOOL_TIMEOUT_S}s check budget used up before every "
                         "file was checked; blocked fail-closed. Split the patch.")
        rc, stdout, stderr = _run_hook(hook_path, ev, remaining)
        if rc != 0:
            detail = (stderr.strip() or f"exit {rc}")[-500:]
            if rc == 2 or 12 <= rc <= 16:
                return _deny(f"[agent/codex] blocked by {hook}: {detail}")
            return _deny(f"[agent/codex] {hook} failed ({detail}); blocked fail-closed because "
                         "Codex would otherwise run the tool unchecked.")
        try:
            out = _parse_output(stdout)
        except (ValueError, TypeError):
            return _deny(f"[agent/codex] {hook} returned unparseable output; blocked fail-closed.")
        spec = (out or {}).get("hookSpecificOutput") or {}
        decision = spec.get("permissionDecision")
        reason = str(spec.get("permissionDecisionReason", ""))
        if decision not in (None, "allow", "deny", "ask"):
            return _deny(f"[agent/codex] {hook} returned unknown decision {str(decision)[:40]!r}; "
                         "blocked fail-closed.")
        if decision == "deny":
            denied = reason if denied is None else denied
        elif decision == "ask":
            asked = reason if asked is None else asked
        elif spec.get("additionalContext"):
            contexts.append(str(spec["additionalContext"]))
    # Re-emitted in the documented minimal shape: an extra field Codex does not
    # support (continue, suppressOutput, ...) would make it skip the decision.
    if denied is not None:
        return _deny(denied or f"[agent/codex] blocked by {hook}")
    if asked is not None:
        reason = asked
        return _deny("[agent/codex] This action needs user approval, and Codex hooks cannot ask. "
                     "Ask the user to approve it explicitly, then have them run it or retry "
                     f"with their go-ahead.\n{reason}".rstrip())
    if contexts:
        return {"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                       "additionalContext": "\n".join(contexts)}}
    return None


def run_native(hook_path: str, obj: dict) -> int:
    if obj.get("hook_event_name") == "PreToolUse":
        # The budget starts before translation: reading a Move source counts too.
        deadline = time.monotonic() + PRE_TOOL_TIMEOUT_S
        try:
            if not os.access(hook_path, os.X_OK):
                out = _deny(f"[agent/codex] guard {os.path.basename(hook_path)} is missing or not "
                            "executable in the Agent checkout; blocked fail-closed (setup.sh --doctor).")
            else:
                out = _pre_tool_use(hook_path, translate_native(obj), deadline)
        except PatchError as exc:
            out = _deny(f"[agent/codex] apply_patch not checkable: {exc}; blocked fail-closed.")
        except Exception as exc:  # noqa: BLE001 — an adapter crash must not become Codex fail-open
            out = _deny(f"[agent/codex] adapter error ({type(exc).__name__}); blocked fail-closed.")
        if out:
            # ASCII-escaped: no locale can turn the decision into an encode error.
            json.dump(out, sys.stdout)
            sys.stdout.write("\n")
        return 0
    # Observation/lifecycle events never block on an adapter or hook failure:
    # every per-file event runs (registration hooks need all files); the first
    # non-empty output is forwarded, hook errors are dropped (warned on stderr).
    if not os.access(hook_path, os.X_OK):
        return 0
    try:
        events = translate_native(obj)
    except PatchError as exc:
        sys.stderr.write(f"[agent/codex] {os.path.basename(hook_path)} skipped: {exc}\n")
        return 0
    first = ""
    for ev in events:
        rc, stdout, stderr = _run_hook(hook_path, ev)
        if rc != 0:
            sys.stderr.write(f"[agent/codex] {os.path.basename(hook_path)} exit {rc}: {stderr.strip()[-300:]}\n")
        elif stdout.strip() and not first:
            first = stdout
    sys.stdout.write(first)
    return 0


def run(hook_path: str, raw: str) -> int:
    """adapter.sh entry: translate stdin, run the core hook, relay its result."""
    try:
        obj = json.loads(raw) if raw.strip() else None
    except json.JSONDecodeError:
        obj = None
    if not isinstance(obj, dict):
        # Undecodable stdin: a native PreToolUse is the only case that must not
        # pass. Codex always sends valid JSON, so this is a transport fault.
        if '"PreToolUse"' in raw or '"hook_event_name"' in raw:
            json.dump(_deny("[agent/codex] hook stdin was not valid JSON; blocked fail-closed."), sys.stdout)
            sys.stdout.write("\n")
        return 0
    if is_native(obj):
        return run_native(hook_path, obj)
    if not os.access(hook_path, os.X_OK):
        return 0  # legacy/canonical input: missing hook = silent pass, as before
    event = obj if is_canonical(obj) else translate_codex(obj)
    rc, stdout, stderr = _run_hook(hook_path, event)
    sys.stdout.write(stdout)
    sys.stderr.write(stderr)
    return rc


def main() -> int:
    try:
        raw = sys.stdin.buffer.read().decode("utf-8", errors="replace")
    except Exception:  # noqa: BLE001 — unreadable stdin: nothing to translate
        if sys.argv[1:2] == ["--run"]:  # may be a native PreToolUse: fail closed
            json.dump(_deny("[agent/codex] hook stdin unreadable; blocked fail-closed."), sys.stdout)
            sys.stdout.write("\n")
        return 0

    if len(sys.argv) >= 3 and sys.argv[1] == "--run":
        return run(sys.argv[2], raw)

    if not raw.strip():
        return 0

    try:
        obj = json.loads(raw)
    except json.JSONDecodeError:
        # Bad JSON — silently pass empty to upstream hook
        return 0

    if not isinstance(obj, dict):
        return 0

    if is_canonical(obj):
        out = obj
    else:
        out = translate_codex(obj)

    json.dump(out, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
