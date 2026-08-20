#!/usr/bin/env bash
# completion-gate.sh — P1 grounded-completion-gate: the blocking CONSUMER for
# completion-verify.py's verdict.
#
# Why a separate consumer instead of making completion-verify.py itself block:
# docs/scoring-convention.md "Consuming a verdict" — a producer's verdict is
# advisory by design; whether/how to enforce it is a consumer decision. This is
# the FIRST blocking consumer of that verdict (docs/gate-registry.md `completion-gate`
# row). Literature motivation: agent false-success claims are 45-76% of failures
# (arXiv 2606.09863) and independent verification cuts that to ~3%; but LLM-judge-
# only blocking overtrusts itself (arXiv 2406.07791, 2410.21819) — so the hard
# gate here is DETERMINISTIC evidence (completion-verify.py --require-evidence
# --diff-base), and the judge (skills/verify-completion) stays an advisory layer
# on top, never the sole blocker.
#
# Modes (AGENT_VERIFY_BLOCKING):
#   off     — immediate exit 0. No canary, no verify run, no log line. (Matches
#             the off-mode contract every gate in this repo shares — spec-gate.py.)
#   dryrun  — (default) canary + verify + log, but NEVER blocks: exit 0 regardless
#             of verdict. Observation phase, same as every other gate's default.
#   block   — canary + verify + log; exit 1 on a REFUTED verdict, refutations
#             printed verbatim to stderr.
#
# Decision order:
#   [0] Liveness canary — BEFORE trusting any verdict on the real claim, prove
#       the verifier can actually REFUTE an obviously-false claim (a cited file
#       that does not exist + a test command that cannot run), AND that BOTH
#       sub-checks fired (the file-existence refutation AND the test-failure
#       refutation are both present in the canary's own refutations — a
#       PARTIAL death, e.g. a regressed `_run()` that always returns success,
#       can still leave the file-check refuting and the overall verdict
#       REFUTED while the test-check is silently broken; checking only the
#       top-level verdict would miss exactly that). If either sub-check is
#       missing, or the verdict/exit code themselves are wrong — a crash, a
#       stubbed/neutralized binary, any outcome other than REFUTED/exit 1 with
#       both refutations present — this gate FAILS CLOSED: exit 2. A dead gate
#       must never present a "clean" verdict as though the check ran (the
#       `infra-as-verdict` failure mode, evals/failure-modes.yaml).
#   [1] Resolve the claim path (see "Claim path resolution" below), then run
#       `completion-verify.py --require-evidence --diff-base <base>` against
#       it — unless the claim file does not exist, in which case skip the
#       verifier call and synthesize a distinct "claim file missing" verdict.
#   [2] Append the verdict (+ gate metadata: ts/slug/wave/mode/claim/reproduce/
#       diff_base_used/verifier_stderr) to the sink in EVERY reachable mode
#       (dryrun included) — a dryrun gate that logs nothing cannot be measured
#       before it is trusted to block.
#   [3] Decide:
#         - the claim carries NO deterministically-checkable evidence at all
#           (files + tests + assertions all cite zero items) AND neither the
#           `evidence` nor the `trajectory` dimension actually FAILED ->
#           needs_semantic: print guidance to dispatch /verify-completion's
#           semantic pass and exit 0. NEVER hard-block here — a claim that is
#           true but not mechanically checkable (a design/UX claim, say) is
#           not a false claim, and the deterministic layer has nothing to
#           refute it with. Critically, this is NOT the same test as "core
#           citations are zero": a claim can cite zero files/tests/assertions
#           and STILL carry a real REFUTED verdict from `--require-evidence`
#           (code changed, nothing cited as evidence) or `--diff-base` (a
#           scope/trajectory violation) — those are real, checkable defects,
#           and needs_semantic must never downgrade them to advisory.
#         - block mode + REFUTED (any reason, including "claim file missing")
#           -> print refutations verbatim, exit 1.
#         - otherwise -> exit 0.
#
# Env:
#   AGENT_VERIFY_BLOCKING         off | dryrun (default) | block
#   AGENT_COMPLETION_GATE_SINK    sink path, relative to repo root or an
#                                 absolute path confined to repo-root/system-temp
#                                 (default .agent/logs/completion-gate.jsonl;
#                                 an empty/escaping override falls back to the
#                                 default, mirrors core/hooks/spec-gate.py
#                                 resolve_sink)
#   AGENT_COMPLETION_VERIFY_BIN   override the completion-verify.py path (test
#                                 seam for the canary death case). Honored
#                                 ONLY when AGENT_REPRODUCE_TEST=1 is ALSO set —
#                                 a production block-mode run always uses the
#                                 hardcoded in-repo path, so this cannot become
#                                 an arbitrary-binary injection point on a real
#                                 gating run (security review response).
#   AGENT_COMPLETION_DIFF_BASE    ref for the --diff-base trajectory audit
#                                 (default: first of origin/main, origin/master,
#                                 main, master, HEAD~1 that resolves; omitted
#                                 entirely — not a fabricated ref — if none do)
#   AGENT_REPRODUCE_TEST=1        marks the logged record reproduce:true, and
#                                 (see above) is the ONLY thing that activates
#                                 the AGENT_COMPLETION_VERIFY_BIN test seam
#
# Claim path resolution: an explicit claim-path arg wins outright; otherwise
# the wave-suffixed `.agent/claims/<slug>-w<wave-i>.yml` is tried first, then
# the repo-wide convention `.agent/claims/<slug>.yml`
# (skills/verify-completion/SKILL.md, docs/scoring-convention.md). If NEITHER
# exists, the gate still runs (still blocks in block mode) but reports a
# distinct "claim file missing" refutation instead of completion-verify.py's
# generic parse-error text — the two are different defects (nothing was
# written to check, vs. something was written and it's wrong).
#
# Concurrency: the JSONL sink is appended with a plain `>>` — concurrent
# gate invocations writing the same sink can interleave partial lines under
# heavy parallel wave execution (no file locking). Accepted for now; not a
# correctness issue for a single wave's own record, only for reading the sink
# concurrently with a write in flight.
#
# Usage: bash core/infra/completion-gate.sh <slug> <wave-i> [claim-path]
#   claim-path defaults to .agent/claims/<slug>-w<wave-i>.yml, falling back to
#   .agent/claims/<slug>.yml when the wave-suffixed file does not exist.
set -u

MODE="${AGENT_VERIFY_BLOCKING:-dryrun}"
if [[ "$MODE" == "off" ]]; then
  exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# AGENT_COMPLETION_VERIFY_BIN is honored ONLY under AGENT_REPRODUCE_TEST=1 —
# a production block-mode run always uses the hardcoded in-repo verifier, so
# this seam cannot become an arbitrary-binary injection point on a real gate
# (Major security-review finding: the seam was unconditionally honored before).
VERIFY_PY="$REPO_ROOT/core/infra/completion-verify.py"
if [[ "${AGENT_REPRODUCE_TEST:-0}" == "1" && -n "${AGENT_COMPLETION_VERIFY_BIN:-}" ]]; then
  VERIFY_PY="$AGENT_COMPLETION_VERIFY_BIN"
fi

SINK_RELATIVE="${AGENT_COMPLETION_GATE_SINK:-.agent/logs/completion-gate.jsonl}"

SLUG="${1:-}"
WAVE="${2:-}"
EXPLICIT_CLAIM="${3:-}"
if [[ -z "$SLUG" || -z "$WAVE" ]]; then
  echo "usage: completion-gate.sh <slug> <wave-i> [claim-path]" >&2
  exit 2
fi

# Claim path resolution (see header): explicit arg wins outright; otherwise
# wave-suffixed first, then the repo-wide `.agent/claims/<slug>.yml` convention.
WAVE_CLAIM="$REPO_ROOT/.agent/claims/${SLUG}-w${WAVE}.yml"
SLUG_CLAIM="$REPO_ROOT/.agent/claims/${SLUG}.yml"
if [[ -n "$EXPLICIT_CLAIM" ]]; then
  CLAIM="$EXPLICIT_CLAIM"
elif [[ -f "$WAVE_CLAIM" ]]; then
  CLAIM="$WAVE_CLAIM"
elif [[ -f "$SLUG_CLAIM" ]]; then
  CLAIM="$SLUG_CLAIM"
else
  CLAIM="$WAVE_CLAIM"   # neither exists; keep this as the canonical "expected" path for messaging below
fi

# ---------------------------------------------------------------------------
# resolve_sink — mirrors core/hooks/spec-gate.py resolve_sink: confine the
# (possibly overridden) sink path to repo-root or system-temp; an empty or
# escaping override falls back to the in-repo default rather than writing
# somewhere arbitrary.
# ---------------------------------------------------------------------------
resolve_sink() {
  local root="$1" default="$1/.agent/logs/completion-gate.jsonl"
  if [[ -z "$SINK_RELATIVE" ]]; then
    printf '%s' "$default"
    return
  fi
  python3 - "$root" "$SINK_RELATIVE" "$default" <<'PY'
import os, sys, tempfile
root, rel, default = sys.argv[1], sys.argv[2], sys.argv[3]
path = os.path.realpath(rel if os.path.isabs(rel) else os.path.join(root, rel))
for allowed in (os.path.realpath(root), os.path.realpath(tempfile.gettempdir())):
    if path == allowed or path.startswith(allowed + os.sep):
        print(path)
        sys.exit(0)
print(default)
PY
}

# ---------------------------------------------------------------------------
# [0] liveness canary — an obviously-false claim the verifier MUST refute.
# ---------------------------------------------------------------------------
CANARY_DIR="$(mktemp -d)"
cleanup() { rm -rf "$CANARY_DIR"; }
trap cleanup EXIT

CANARY_CLAIM="$CANARY_DIR/canary.json"
cat > "$CANARY_CLAIM" <<'EOF'
{ "claim": { "summary": "completion-gate liveness canary — must REFUTE",
    "files": [ { "path": "this/file/does-not-exist/completion-gate-canary.txt" } ],
    "tests": [ "bash /this/path/does/not/exist/completion-gate-canary.sh" ] } }
EOF

CANARY_OUT="$(python3 "$VERIFY_PY" --root "$CANARY_DIR" "$CANARY_CLAIM" 2>/dev/null)"
CANARY_RC=$?
# Check BOTH sub-checks independently, not just the top-level verdict — a
# PARTIAL death (e.g. a regressed _run() that always returns success) can
# still leave the file-existence refutation firing while the test-failure
# refutation silently never fires, and the overall verdict would still read
# REFUTED. Only trusting the top-level verdict would miss exactly that.
read -r CANARY_VERDICT CANARY_HAS_FILE_CHECK CANARY_HAS_TEST_CHECK <<<"$(printf '%s' "$CANARY_OUT" | python3 -c '
import sys, json
d = sys.stdin.read().strip()
try:
    j = json.loads(d) if d else {}
except Exception:
    j = {}
refs = j.get("refutations", []) or []
has_file = any("does not exist" in r for r in refs)
has_test = any("test did not pass" in r for r in refs)
print("%s %d %d" % (j.get("verdict", ""), 1 if has_file else 0, 1 if has_test else 0))
' 2>/dev/null)"

if [[ "$CANARY_RC" -ne 1 || "$CANARY_VERDICT" != "REFUTED" || "$CANARY_HAS_FILE_CHECK" != "1" || "$CANARY_HAS_TEST_CHECK" != "1" ]]; then
  echo "completion-gate: LIVENESS CANARY FAILED — completion-verify.py did not fully REFUTE an obviously-false claim (rc=$CANARY_RC verdict=${CANARY_VERDICT:-<none>} file-check=${CANARY_HAS_FILE_CHECK:-0} test-check=${CANARY_HAS_TEST_CHECK:-0})." >&2
  [[ "${CANARY_HAS_FILE_CHECK:-0}" != "1" ]] && echo "completion-gate:   the FILE-EXISTENCE check did not fire." >&2
  [[ "${CANARY_HAS_TEST_CHECK:-0}" != "1" ]] && echo "completion-gate:   the TEST-FAILURE check did not fire (a regressed _run() that always succeeds would look exactly like this)." >&2
  echo "completion-gate: refusing to trust ANY verdict from this verifier. Fix $VERIFY_PY (or unset AGENT_COMPLETION_VERIFY_BIN if it is overridden)." >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# [1] run completion-verify.py against the REAL claim — unless the claim file
#     does not exist at all, in which case skip the call and synthesize a
#     distinct "claim file missing" verdict (a different defect than "the
#     verifier ran and REFUTED", and clearer than completion-verify.py's own
#     generic parse-error text).
# ---------------------------------------------------------------------------
DIFF_BASE="${AGENT_COMPLETION_DIFF_BASE:-}"
if [[ -z "$DIFF_BASE" ]]; then
  for cand in origin/main origin/master main master HEAD~1; do
    if git -C "$REPO_ROOT" rev-parse --verify -q "$cand" >/dev/null 2>&1; then
      DIFF_BASE="$cand"
      break
    fi
  done
fi

VERIFIER_STDERR=""
if [[ ! -f "$CLAIM" ]]; then
  if [[ -n "$EXPLICIT_CLAIM" ]]; then
    VERDICT_JSON="$(python3 -c 'import json,sys; print(json.dumps({
    "verdict": "REFUTED", "score": 0.0, "target": sys.argv[1],
    "dimensions": {}, "refutations": ["claim file missing: %s (explicit path)" % sys.argv[1]],
    "schema_version": "1.0.0"}))' "$EXPLICIT_CLAIM")"
  else
    VERDICT_JSON="$(python3 -c 'import json,sys; print(json.dumps({
    "verdict": "REFUTED", "score": 0.0, "target": sys.argv[1],
    "dimensions": {}, "refutations": [
        "claim file missing: tried %s (wave-suffixed) and %s (repo convention .agent/claims/<slug>.yml) — neither exists" % (sys.argv[1], sys.argv[2])
    ], "schema_version": "1.0.0"}))' "$WAVE_CLAIM" "$SLUG_CLAIM")"
  fi
else
  VERIFY_ARGS=(--root "$REPO_ROOT" --require-evidence)
  [[ -n "$DIFF_BASE" ]] && VERIFY_ARGS+=(--diff-base "$DIFF_BASE")
  VERIFY_ARGS+=("$CLAIM")

  STDERR_TMP="$(mktemp)"
  VERDICT_JSON="$(python3 "$VERIFY_PY" "${VERIFY_ARGS[@]}" 2>"$STDERR_TMP")"
  VERIFIER_STDERR="$(head -c 2000 "$STDERR_TMP" 2>/dev/null || true)"
  rm -f "$STDERR_TMP"
fi

# ---------------------------------------------------------------------------
# [2] append verdict + gate metadata to the sink — every reachable mode.
# ---------------------------------------------------------------------------
SINK="$(resolve_sink "$REPO_ROOT")"
mkdir -p "$(dirname "$SINK")" 2>/dev/null || true

REPRODUCE="false"
[[ "${AGENT_REPRODUCE_TEST:-0}" == "1" ]] && REPRODUCE="true"

RECORD="$(python3 - "$VERDICT_JSON" "$SLUG" "$WAVE" "$MODE" "$REPRODUCE" "$CLAIM" "${DIFF_BASE:-}" "$VERIFIER_STDERR" <<'PY'
import json, sys
from datetime import datetime, timezone

verdict_raw, slug, wave, mode, reproduce, claim_path, diff_base, stderr = sys.argv[1:9]
try:
    if not verdict_raw.strip():
        raise ValueError("verifier produced no output")
    verdict = json.loads(verdict_raw)
    if not isinstance(verdict, dict):
        raise ValueError("verdict root is not a mapping")
except Exception as e:
    # Minor 6: an empty/unparseable verifier call must never silently become an
    # unexplained REFUTED — the refutation names exactly what went wrong.
    verdict = {
        "verdict": "REFUTED", "score": 0.0, "target": claim_path,
        "dimensions": {}, "refutations": ["gate: verifier output did not parse/empty: %s" % e],
        "schema_version": "1.0.0",
    }

rec = {
    "ts": datetime.now(timezone.utc).isoformat(),
    "slug": slug,
    "wave": wave,
    "mode": mode,
    "claim": claim_path,
    "reproduce": reproduce == "true",
    "diff_base_used": diff_base if diff_base else None,
    "verifier_stderr": stderr[:2000] if stderr else None,
}
rec.update(verdict)
print(json.dumps(rec, ensure_ascii=False))
PY
)"

if [[ -n "$RECORD" ]]; then
  printf '%s\n' "$RECORD" >> "$SINK" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# [3] decide.
# ---------------------------------------------------------------------------
# semantic_eligible distinguishes "the claim structurally cites nothing AND
# no deterministic check actually failed" (needs_semantic, never a hard
# block) from every other REFUTED case, INCLUDING a REFUTED that ALSO has
# core_total==0 — e.g. `--require-evidence` refuting an empty claim whose
# code diff DID change something (Blocker 1: the naive "core_total==0" test
# alone would have downgraded that real refutation to advisory). A mode's
# dimension only counts as "failed" when it is PRESENT and passed<total, so
# an absent or fully-passing evidence/trajectory dimension does not block
# needs_semantic.
read -r GATE_VERDICT CORE_TOTAL SEMANTIC_ELIGIBLE <<<"$(printf '%s' "$RECORD" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
dims = d.get("dimensions", {}) or {}
core = sum((dims.get(k, {}) or {}).get("total", 0) for k in ("files", "tests", "assertions"))

def dim_failed(name):
    dd = dims.get(name) or {}
    total = dd.get("total", 0)
    passed = dd.get("passed", 0)
    return total > 0 and passed < total

eligible = bool(dims) and core == 0 and not dim_failed("evidence") and not dim_failed("trajectory")
print("%s %d %d" % (d.get("verdict", "REFUTED"), core, 1 if eligible else 0))
')"

if [[ ! "$CORE_TOTAL" =~ ^[0-9]+$ ]]; then CORE_TOTAL=0; fi
if [[ ! "$SEMANTIC_ELIGIBLE" =~ ^[0-9]+$ ]]; then SEMANTIC_ELIGIBLE=0; fi

if [[ "$SEMANTIC_ELIGIBLE" -eq 1 ]]; then
  echo "completion-gate: '$CLAIM' cites no deterministically-checkable evidence (no files/tests/assertions) — dispatch /verify-completion for an independent semantic pass before accepting this claim as done." >&2
  exit 0
fi

if [[ "$MODE" == "block" && "$GATE_VERDICT" == "REFUTED" ]]; then
  echo "completion-gate: REFUTED — $CLAIM" >&2
  printf '%s' "$RECORD" | python3 -c '
import sys, json
d = json.load(sys.stdin)
for r in d.get("refutations", []):
    print("  - %s" % r)
' >&2
  exit 1
fi

exit 0
