#!/usr/bin/env python3
"""Antigravity CLI (agy) native hook adapter -> canonical hook event protocol.

Usage: adapter.py <PreToolUse|PostToolUse|Stop>   (stdin = agy hook JSON)

agy sends no event name on stdin, so the event comes from argv (one command per
event in the plugin's hooks.json). One invocation runs the WHOLE core-hook chain
for that event and aggregates the result itself: agy's combine order for several
hooks on one event is undocumented (w5-design D2).

agy decision facts this file is built around (measured on agy 1.2.12, see
.agent/plans/runtime-currency-2026-09/w5-design.md M1-M8):
  * PreToolUse stdout `{}` is a DENY. `{"decision":"allow"}` behaved like `ask` in
    headless and did not bypass the write_file permission; its grant semantics are
    unmeasured, so it is never emitted. Pass-through is `{"decision":"ask"}` (D1)
    -- never `{}`, never allow.
  * `ask` only defers to agy's own permission handling (a matching allow rule or an
    Always-Allow cache satisfies it without a prompt). A core-hook `ask` demanded a
    human, so it is emitted as `force_ask` (agy's documented always-prompt verb; its
    headless behavior is unmeasured). Bare `ask` is kept for the no-objection case.
  * A crash/timeout/garbage from the hook is not known to be fail-closed, so every
    PreToolUse failure is turned into an explicit deny here.
  * PostToolUse and Stop hooks cannot block; their failures are warned on stderr.

Canonical hook contract: docs/hook-protocol.md. The core-hook chains below mirror
adapters/codex/hooks.json.template; core/tests/antigravity-adapter-test.sh fails
if the two drift apart.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time

FRAMEWORK_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HOOKS_DIR = os.path.join(FRAMEWORK_ROOT, "core", "hooks")

# One budget for the whole PreToolUse/PostToolUse/Stop chain, below the 30s
# `timeout` in hooks.json.template, so the adapter -- not agy -- decides what a
# slow guard means.
def _budget() -> float:
    try:
        value = float(os.environ.get("AGENT_ANTIGRAVITY_BUDGET_S", "25"))  # env: test seam
    except ValueError:
        return 25.0
    return value if 0 < value < float("inf") else 25.0  # also rejects nan, inf, <= 0


BUDGET_S = _budget()
# The Stop chain shares BUDGET_S, but the two closing hooks each keep a reserved
# slice so a slow completion gate cannot starve them (brain capture, lock release).
STOP_RESERVE_FRACTION = {"brain-capture.py": 0.2, "session-close.sh": 0.2}
# multi_replace_file_content with more chunks than this is denied outright
# instead of racing the time budget chunk by chunk.
MAX_CHUNKS = 100
# A Stop marker older than this belongs to a conversation that died mid-continue;
# it must not silence the gate for a later resumption.
STOP_MARKER_TTL_S = 6 * 3600
_CONVERSATION_ID_RE = re.compile(r"^[A-Za-z0-9-]{1,64}$")
# Never handed to core hooks: they have no use for a model API key.
_SCRUBBED_ENV = ("GEMINI_API_KEY", "GOOGLE_API_KEY")

_BASH_PRE = ["pre-tool-guard.sh", "loop-write-guard.py", "r4-mutex-check.sh"]
_FILE_PRE = ["check-hardcoding.py", "secret-content-scan.py", "r4-file-mutex-check.sh",
             "tdd-guard.py", "spec-gate.py", "loop-write-guard.py", "r4-mutex-check.sh"]
_FILE_POST = ["r4-file-mutex-register.sh"]
# Keyed by canonical event, then canonical tool. The Codex template is the
# reference; the drift test compares these sets against it.
CHAINS: dict[str, dict[str, list[str]]] = {
    "PreToolUse": {"Bash": _BASH_PRE, "Write": _FILE_PRE, "Edit": _FILE_PRE},
    "PostToolUse": {"Bash": ["circuit-breaker.py", "verify-observer.py"],
                    "Write": _FILE_POST, "Edit": _FILE_POST},
    "Stop": {"": ["session-quality-gate.py", "brain-capture.py", "session-close.sh"]},
}
EVENTS = tuple(CHAINS)


class Untranslatable(ValueError):
    """agy tool arguments the adapter cannot map to a checkable canonical event."""


def _abs(path: str, base: str) -> str:
    # normpath: path-prefix exemptions in core hooks (tests/, fixtures/) must
    # not be reachable through `tests/../src/x`.
    return os.path.normpath(path if os.path.isabs(path) or not base else os.path.join(base, path))


def _text(args: dict, key: str, tool: str) -> str:
    value = args.get(key)
    if not isinstance(value, str):
        raise Untranslatable(f"{tool} argument {key!r} is missing or not a string; "
                             "the agy tool schema is unverified for this shape")
    return value


def _workspace(obj: dict) -> str:
    roots = obj.get("workspacePaths")
    if isinstance(roots, list) and roots and isinstance(roots[0], str):
        return roots[0]
    return ""


def translate(obj: dict, event: str) -> list[dict] | None:
    """agy hook stdin -> canonical events; None for a tool the chains do not cover.

    cwd comes from the tool call (`Cwd`) or the workspace, never from this process:
    agy starts hooks inside the plugin directory, which is not the user's project.
    """
    call = obj.get("toolCall")
    if not isinstance(call, dict):
        raise Untranslatable("toolCall is missing")
    name, args = call.get("name"), call.get("args")
    if not isinstance(args, dict):
        raise Untranslatable("toolCall.args is missing")
    workspace = _workspace(obj)

    session = obj.get("conversationId")
    transcript = obj.get("transcriptPath")
    step = obj.get("stepIdx")
    base = {
        "ai": "antigravity",
        "event": event,
        "hook_event_name": event,
        "session_id": session if isinstance(session, str) else "",
        "cwd": workspace,
        "transcript_path": os.path.expanduser(transcript) if isinstance(transcript, str) else "",
    }
    if event == "PostToolUse":
        error = obj.get("error")
        if error not in (None, "", False):
            base["event"] = base["hook_event_name"] = "PostToolUseFailure"
            base["error"] = error if isinstance(error, str) else json.dumps(error)
    if isinstance(session, str) and isinstance(step, int) and not isinstance(step, bool):
        base["tool_use_id"] = f"{session}:{step}"  # lets circuit-breaker dedup a re-fired step

    def make(tool: str, tool_input: dict, cwd: str = "") -> dict:
        return dict(base, tool_name=tool, tool_input=tool_input, cwd=cwd or base["cwd"])

    if name == "run_command":
        cwd = args.get("Cwd")
        return [make("Bash", {"command": _text(args, "CommandLine", name)},
                     cwd if isinstance(cwd, str) and os.path.isabs(cwd) else "")]
    if name == "send_command_input":
        # Feeds a live shell started by run_command; the text is a command in all but name.
        # The arg keys are inferred from the agy binary, never seen in a live call, so a
        # missing key is a deny (fail-closed) rather than an unguarded pass.
        text = args.get("Input")
        if text in (None, "") and args.get("Terminate") is True:
            return None  # carries nothing to guard: it only ends the process
        cwd = args.get("Cwd")
        return [make("Bash", {"command": _text(args, "Input", name)},
                     cwd if isinstance(cwd, str) and os.path.isabs(cwd) else "")]
    if name == "write_to_file":
        return [make("Write", {"file_path": _abs(_text(args, "TargetFile", name), workspace),
                               "content": _text(args, "CodeContent", name)})]
    if name == "replace_file_content":
        return [make("Edit", {"file_path": _abs(_text(args, "TargetFile", name), workspace),
                              "old_string": _text(args, "TargetContent", name),
                              "new_string": _text(args, "ReplacementContent", name)})]
    if name == "multi_replace_file_content":
        target = _abs(_text(args, "TargetFile", name), workspace)
        chunks = args.get("ReplacementChunks")
        if not isinstance(chunks, list) or not chunks:
            raise Untranslatable(f"{name} has no ReplacementChunks list")
        if len(chunks) > MAX_CHUNKS:
            raise Untranslatable(f"{name} has {len(chunks)} chunks (limit {MAX_CHUNKS}); split it")
        events = []
        for chunk in chunks:
            if not isinstance(chunk, dict):
                raise Untranslatable(f"{name} chunk is not an object; the agy chunk schema is unverified")
            events.append(make("Edit", {"file_path": target,
                                        "old_string": _text(chunk, "TargetContent", name),
                                        "new_string": _text(chunk, "ReplacementContent", name)}))
        return events
    return None


def _run_hook(hook_path: str, event: dict, timeout: float) -> tuple[int, str, str]:
    cwd = event.get("cwd")
    env = {k: v for k, v in os.environ.items() if k not in _SCRUBBED_ENV}
    try:
        proc = subprocess.run(
            [hook_path], input=json.dumps(event), capture_output=True, text=True, check=False,
            timeout=timeout, cwd=cwd if cwd and os.path.isdir(cwd) else None, env=env,
        )
    except subprocess.TimeoutExpired:
        return 124, "", f"hook timed out after {timeout:.1f}s"
    except OSError as exc:
        return 126, "", str(exc)
    return proc.returncode, proc.stdout, proc.stderr


def _parse_output(stdout: str) -> dict | None:
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
    return {"decision": "deny", "reason": reason}


def _hook_path(name: str) -> str:
    return os.path.join(HOOKS_DIR, name)


def pre_tool_use(events: list[dict], chain: list[str], deadline: float) -> dict:
    """Run every chain hook on every event; deny > ask > advisory > pass-through."""
    asked = None
    contexts: list[str] = []
    for ev in events:
        for hook in chain:
            path = _hook_path(hook)
            if not os.access(path, os.X_OK):
                return _deny(f"[agent/antigravity] guard {hook} is missing or not executable in the "
                             "Agent checkout; blocked fail-closed (setup.sh --doctor).")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return _deny(f"[agent/antigravity] {BUDGET_S}s check budget used up before {hook} "
                             "ran; blocked fail-closed.")
            rc, stdout, stderr = _run_hook(path, ev, remaining)
            if rc != 0:
                detail = (stderr.strip() or f"exit {rc}")[-500:]
                if rc == 2 or 12 <= rc <= 16:
                    return _deny(f"[agent/antigravity] blocked by {hook}: {detail}")
                return _deny(f"[agent/antigravity] {hook} failed ({detail}); blocked fail-closed "
                             "because the tool would otherwise run unchecked.")
            try:
                out = _parse_output(stdout)
            except (ValueError, TypeError):
                return _deny(f"[agent/antigravity] {hook} returned unparseable output; blocked fail-closed.")
            spec = (out or {}).get("hookSpecificOutput") or {}
            if not isinstance(spec, dict):
                return _deny(f"[agent/antigravity] {hook} returned a malformed decision; blocked fail-closed.")
            decision = spec.get("permissionDecision")
            reason = str(spec.get("permissionDecisionReason", ""))
            if decision not in (None, "allow", "deny", "ask"):
                return _deny(f"[agent/antigravity] {hook} returned unknown decision "
                             f"{str(decision)[:40]!r}; blocked fail-closed.")
            if decision == "deny":
                return _deny(reason or f"[agent/antigravity] blocked by {hook}")
            if decision == "ask":
                asked = reason if asked is None else asked
            elif spec.get("additionalContext"):
                contexts.append(str(spec["additionalContext"]))
    if asked is not None:
        # force_ask: a plain `ask` would let the user's permissions.allow rules or an
        # Always-Allow cache satisfy a guard that demanded a human.
        return {"decision": "force_ask", "reason": asked}
    if contexts:
        return {"decision": "ask", "reason": "\n".join(contexts)}
    # The pass-through: agy applies its own permission rules. Never `{}` (agy
    # reads that as deny) and never `allow` (grant semantics unmeasured).
    return {"decision": "ask"}


def _run_pre(obj: dict) -> dict:
    deadline = time.monotonic() + BUDGET_S
    events = translate(obj, "PreToolUse")
    if events is None:
        name = (obj.get("toolCall") or {}).get("name")
        sys.stderr.write(f"[agent/antigravity] no guard chain for tool {str(name)[:60]!r}; passed through.\n")
        return {"decision": "ask"}
    return pre_tool_use(events, CHAINS["PreToolUse"][events[0]["tool_name"]], deadline)


def _run_observers(events: list[dict], chain: list[str],
                   reserve: dict[str, float] | None = None) -> list[tuple[str, int, str, str]]:
    """Run every hook on every event (registration hooks need all of them).

    `reserve` maps a hook name to a fraction of BUDGET_S kept back for it: a hook
    earlier in the chain may not use that slice, so it cannot starve the later one.
    """
    deadline = time.monotonic() + BUDGET_S
    results = []
    for ev in events:
        for i, hook in enumerate(chain):
            path = _hook_path(hook)
            if not os.access(path, os.X_OK):
                sys.stderr.write(f"[agent/antigravity] {hook} missing or not executable; skipped.\n")
                continue
            held = sum(reserve.get(h, 0.0) for h in chain[i + 1:]) * BUDGET_S if reserve else 0.0
            remaining = deadline - time.monotonic() - held
            if remaining <= 0:
                sys.stderr.write(f"[agent/antigravity] budget used up before {hook}; skipped.\n")
                continue
            rc, stdout, stderr = _run_hook(path, ev, remaining)
            if rc != 0:
                sys.stderr.write(f"[agent/antigravity] {hook} exit {rc}: {stderr.strip()[-300:]}\n")
            results.append((hook, rc, stdout, stderr))
    return results


def _run_post(obj: dict) -> None:
    # Hook stdout is discarded: core hooks print plain additionalContext JSON that
    # agy would not understand, and PostToolUse must answer `{}` regardless. So these
    # are observers: circuit-breaker's "change your approach" context never reaches the
    # model here (only its state file and r4 register's side effect are effective);
    # relaying PostToolUse context to agy is unmeasured.
    try:
        events = translate(obj, "PostToolUse")
    except Untranslatable as exc:
        sys.stderr.write(f"[agent/antigravity] PostToolUse skipped: {exc}\n")
        return
    if events:
        _run_observers(events, CHAINS["PostToolUse"][events[0]["tool_name"]])


def _state_dir() -> str:
    return os.environ.get("AGENT_STATE_DIR") or os.path.join(os.path.expanduser("~"), ".agent", "state")


def _marker_active(marker: str) -> bool:
    try:
        return time.time() - os.stat(marker).st_mtime < STOP_MARKER_TTL_S
    except OSError:
        return False


def _remove(path: str) -> None:
    try:
        os.remove(path)
    except OSError:
        pass


def _run_stop(obj: dict) -> dict:
    stop = {"decision": "stop"}
    conversation = obj.get("conversationId")
    if not isinstance(conversation, str) or not _CONVERSATION_ID_RE.match(conversation):
        sys.stderr.write("[agent/antigravity] Stop without a valid conversationId; nothing run.\n")
        return stop
    marker = os.path.join(_state_dir(), "antigravity-stop", conversation)
    active = _marker_active(marker)
    transcript = obj.get("transcriptPath")
    event = {
        "ai": "antigravity", "event": "Stop", "hook_event_name": "Stop", "session_id": conversation,
        "cwd": _workspace(obj),
        "transcript_path": os.path.expanduser(transcript) if isinstance(transcript, str) else "",
        "stop_hook_active": active,
    }
    block_reason = None
    for hook, rc, stdout, _ in _run_observers([event], CHAINS["Stop"][""], STOP_RESERVE_FRACTION):
        if rc == 124:
            # A killed gate looks like a clean pass; say that its verdict is missing.
            sys.stderr.write(f"[agent/antigravity] {hook} did not finish inside its time slice; "
                             "its verdict was NOT applied (completion tests longer than the Stop "
                             "budget cannot gate on agy).\n")
        if rc != 0 or block_reason is not None:
            continue
        try:
            out = _parse_output(stdout)
        except (ValueError, TypeError):
            continue
        if out and out.get("decision") == "block":
            block_reason = str(out.get("reason", "")) or f"[agent/antigravity] {hook} blocked the stop"
    if block_reason is not None and not active:
        try:
            os.makedirs(os.path.dirname(marker), mode=0o700, exist_ok=True)
            with open(marker, "w", encoding="utf-8"):
                pass
        except OSError:
            # Without the marker the next Stop would block again forever.
            sys.stderr.write("[agent/antigravity] could not write the Stop loop marker; stopping.\n")
            return stop
        return {"decision": "continue", "reason": block_reason}
    _remove(marker)
    return stop


def _emit(out: dict) -> None:
    # ASCII-escaped: no locale can turn the decision into an encode error.
    json.dump(out, sys.stdout)
    sys.stdout.write("\n")


def run(event: str, raw: str) -> int:
    if os.environ.get("AGENT_ANTIGRAVITY_WORKER") == "1":
        # A review worker needs neither exec nor write; the OS sandbox is the
        # primary control, this is the second one (w5-design D5).
        if event == "PreToolUse":
            _emit(_deny("review worker: tools are disabled"))
        elif event == "Stop":
            _emit({"decision": "stop"})
        else:
            _emit({})
        return 0
    try:
        obj = json.loads(raw) if raw.strip() else None
    except json.JSONDecodeError:
        obj = None
    if not isinstance(obj, dict):
        if event == "PreToolUse":
            _emit(_deny("[agent/antigravity] hook stdin was not valid JSON; blocked fail-closed."))
        else:
            sys.stderr.write(f"[agent/antigravity] {event} stdin was not valid JSON; ignored.\n")
            _emit({"decision": "stop"} if event == "Stop" else {})
        return 0
    try:
        if event == "PreToolUse":
            _emit(_run_pre(obj))
        elif event == "PostToolUse":
            _run_post(obj)
            _emit({})
        else:
            _emit(_run_stop(obj))
    except Untranslatable as exc:
        _emit(_deny(f"[agent/antigravity] {exc}; blocked fail-closed."))
    except Exception as exc:  # noqa: BLE001 -- an adapter crash must not become fail-open
        sys.stderr.write(f"[agent/antigravity] adapter error in {event}: {type(exc).__name__}: {exc}\n")
        if event == "PreToolUse":
            _emit(_deny(f"[agent/antigravity] adapter error ({type(exc).__name__}); blocked fail-closed."))
        else:
            _emit({"decision": "stop"} if event == "Stop" else {})
    return 0


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in EVENTS:
        sys.stderr.write(f"usage: adapter.py <{'|'.join(EVENTS)}>\n")
        return 2
    event = sys.argv[1]
    try:
        raw = sys.stdin.buffer.read().decode("utf-8", errors="replace")
    except Exception:  # noqa: BLE001 -- unreadable stdin
        raw = ""
    return run(event, raw)


if __name__ == "__main__":
    sys.exit(main())
