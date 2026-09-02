#!/usr/bin/env python3
"""top-edit-advisor.py — accumulation-time reminder for the TOP-lane policy.

Matcher: PostToolUse Write|Edit|MultiEdit.

A 2026-09-02 transcript audit measured the session TOP model doing 511 direct
main-loop Edit/Write calls across 26 sessions (17 sessions with 10+ edits, one
as high as 65) — the docs/model-routing.md TOP-lane rule is that multi-file
implementation gets dispatched at workhorse tier (a `model` override on the
Agent/Task call) while the top model keeps design/synthesis/judgment. A
single warning had already fired and kept being ignored well past its first
occurrence, so this hook repeats the advisory every +THRESHOLD measured
main-loop edits instead of warning once and going silent.

This is the accumulation-time layer, complementing two hooks that only see
Task/Agent dispatches and so cannot see this leak (no dispatch ever happens
at all): model-routing-observer.py (PostToolUse Task/Agent, post-hoc
measurement) and model-routing-advisor.py (PreToolUse Task/Agent,
dispatch-time advisory). Those two only fire when a dispatch is attempted;
this hook fires on the top model's own direct Edit/Write/MultiEdit calls,
which is exactly the case those two structurally cannot observe.

Implementation ported from ~/.claude/hooks/top-edit-advisor.py (2026-09-02
hardening). Subagent Edit/Write calls also route through this same
PostToolUse matcher, so a naive per-invocation counter would over-count.
Only at multiples of THRESHOLD does it scan the session transcript (stdin
JSON's `transcript_path`) and count Edit/Write/MultiEdit/NotebookEdit
tool_use entries inside non-sidechain assistant messages whose `model` field
names a TOP-tier family, bounding scan cost to once per THRESHOLD
invocations. No TOP model observed in the transcript -> silent, WITHOUT
caching that verdict: the session model can switch mid-session (a
permanently cached not-TOP verdict was measured wrong for session
40781277), and the next re-scan only happens at the next THRESHOLD multiple
anyway, so the cost stays bounded even without caching. Re-warn only once
measured edits have grown by at least THRESHOLD since the last warning.

Advisory only: never sets permissionDecision, never blocks, always exits 0.
Registered in docs/gate-registry.md (GATE top-edit-advisor).

Env seams:
  AGENT_TOP_EDIT_STATE_DIR  per-session counter/warn state (default
                            ~/.agent/state/top-edit)
  AGENT_TOP_EDIT_THRESHOLD  edits between (re-)warnings (default 15; any
                            non-positive-int value falls back to 15)
"""
import json
import os
import sys
import time

# Keep in sync with session-tier-observer.py's TIER_MAP (can't import it
# directly — a hyphenated filename isn't a valid Python module name).
TOP_FAMILIES = ("fable", "opus")


def _threshold():
    raw = os.environ.get("AGENT_TOP_EDIT_THRESHOLD", "")
    try:
        n = int(raw)
        return n if n > 0 else 15
    except Exception:
        return 15


THRESHOLD = _threshold()
STATE_DIR = os.path.expanduser(
    os.environ.get("AGENT_TOP_EDIT_STATE_DIR") or "~/.agent/state/top-edit"
)

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

sid = data.get("session_id") or "unknown"
transcript = data.get("transcript_path") or ""

try:
    os.makedirs(STATE_DIR, exist_ok=True)
except Exception:
    sys.exit(0)

count_file = os.path.join(STATE_DIR, f"top-edit-{sid}.count")
warned_file = os.path.join(STATE_DIR, f"top-edit-{sid}.warned")  # main_edits at last warning

try:
    count = int(open(count_file).read().strip()) + 1
except Exception:
    count = 1
try:
    open(count_file, "w").write(str(count))
except Exception:
    pass

if count < THRESHOLD or count % THRESHOLD != 0:
    sys.exit(0)

# Opportunistic 7-day GC of stale per-session state files — gated to the same
# THRESHOLD-multiple path as the transcript scan below, so an os.listdir over
# STATE_DIR (shared across all sessions) doesn't run on every single call.
now = time.time()
try:
    for name in os.listdir(STATE_DIR):
        p = os.path.join(STATE_DIR, name)
        if name.startswith("top-edit-") and now - os.path.getmtime(p) > 7 * 86400:
            os.unlink(p)
except Exception:
    pass

if not os.path.exists(transcript):
    sys.exit(0)

# Measured main-loop (TOP, non-sidechain) Edit/Write/MultiEdit/NotebookEdit count.
main_edits = 0
is_top = False
try:
    for line in open(transcript, errors="replace"):
        if '"tool_use"' not in line and '"model"' not in line:
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        if o.get("isSidechain"):
            continue
        m = o.get("message")
        if not isinstance(m, dict) or m.get("role") != "assistant":
            continue
        model = m.get("model") or ""
        if any(fam in model for fam in TOP_FAMILIES):
            is_top = True
            for c in m.get("content") or []:
                if isinstance(c, dict) and c.get("type") == "tool_use" \
                        and c.get("name") in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
                    main_edits += 1
except Exception:
    sys.exit(0)

if not is_top:
    sys.exit(0)  # not cached — the session can switch to a TOP model later

if main_edits < THRESHOLD:
    sys.exit(0)  # subagent inflation guard — re-measure at the next multiple

try:
    last_warned = int(open(warned_file).read().strip())
except Exception:
    last_warned = 0
if main_edits < last_warned + THRESHOLD:
    sys.exit(0)  # fewer than THRESHOLD new edits since the last warning

try:
    open(warned_file, "w").write(str(main_edits))
except Exception:
    pass
print(json.dumps({
    "systemMessage": (
        f"⚠ TOP-model main loop has made {main_edits} direct edits this session"
        + (f" (previous warning at {last_warned})" if last_warned else "")
        + " — TOP-lane policy: dispatch multi-file implementation at workhorse "
        "tier (model override on the Agent call); the top model keeps "
        "design/synthesis/judgment. (docs/model-routing.md)"
    )
}, ensure_ascii=False))
sys.exit(0)
