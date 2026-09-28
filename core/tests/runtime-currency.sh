#!/usr/bin/env bash
# runtime-currency.sh — GATE: are the runtime specs this harness was built
# against still current?
#
# Reads docs/runtime-registry.json (the SSOT for "what CLI version / docs / hook
# surface we last verified") and checks, per runtime:
#
#   (F) freshness  — `measured_on` and every docs[].checked_on must be within
#                    AGENT_CURRENCY_MAX_AGE_DAYS (default: registry
#                    max_age_days_default, 45). Stale = WARN; with --strict = FAIL.
#                    A date after today is a typo, not "fresh" = FAIL always.
#                    Rationale: gate-registry.md flags a gate STALE when its
#                    assumption is unreviewed; a runtime spec is the same kind of
#                    assumption and rots at the same rate (see docs/runtime-registry.json).
#   (R) retired IDs — for runtimes carrying `retired_model_patterns`, no pin line
#                    in that runtime's `pin_files` may match a retired pattern.
#                    A pin line is any non-comment line that assigns/passes a
#                    model (`model = "…"`, `"model": "…"`, `model: …`, `--model …`).
#                    A denylist of known-dead IDs rots slower than an allowlist of
#                    live ones (same principle as codex-template-currency-test.sh).
#                    Retired pin = FAIL always.
#   (S) schema      — every runtime has kind/vendor/cli_version_measured/measured_on/
#                    pin_files; first-party runtimes also carry
#                    retired_model_patterns (may be empty). Missing = FAIL.
#
# Model IDs never appear in the registry (no-model-ids policy): it names the
# adapter files that own the pins and the patterns that must NOT be there.
#
# Usage:
#   bash core/tests/runtime-currency.sh            # WARN on stale, FAIL on retired/schema
#   bash core/tests/runtime-currency.sh --strict   # stale is FAIL too (monthly CI)
# Env:
#   AGENT_CURRENCY_REGISTRY      path to registry (default docs/runtime-registry.json)
#   AGENT_CURRENCY_MAX_AGE_DAYS  override the freshness window
#   AGENT_CURRENCY_TODAY         YYYY-MM-DD, pins "today" (tests)
#   AGENT_CURRENCY_REPO_ROOT     root that pin_files globs resolve against (tests)
# Exit: 0 pass (WARNs allowed unless --strict), 1 fail.
set -u

REPO_ROOT="${AGENT_CURRENCY_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
REGISTRY="${AGENT_CURRENCY_REGISTRY:-$REPO_ROOT/docs/runtime-registry.json}"
STRICT=0
[[ "${1:-}" == "--strict" ]] && STRICT=1

if ! command -v python3 >/dev/null 2>&1; then
  echo "runtime-currency: FAIL — python3 not on PATH (needed to parse the registry)"; exit 1
fi
if [[ ! -f "$REGISTRY" ]]; then
  echo "runtime-currency: FAIL — registry not found: $REGISTRY"; exit 1
fi

STRICT="$STRICT" REGISTRY="$REGISTRY" REPO_ROOT="$REPO_ROOT" python3 - <<'PY'
import datetime as _dt, glob, json, os, re, sys

strict = os.environ["STRICT"] == "1"
reg_path = os.environ["REGISTRY"]
root = os.environ["REPO_ROOT"]
today_s = os.environ.get("AGENT_CURRENCY_TODAY") or _dt.date.today().isoformat()
today = _dt.date.fromisoformat(today_s)

try:
    reg = json.load(open(reg_path, encoding="utf-8"))
except Exception as e:  # malformed registry is a hard fail, never a silent pass
    print(f"  FAIL [registry-parse] {reg_path}: {e}")
    sys.exit(1)

max_age = int(os.environ.get("AGENT_CURRENCY_MAX_AGE_DAYS") or reg.get("max_age_days_default", 45))
runtimes = reg.get("runtimes") or {}
ok = warn = fail = 0

def report(kind, label, msg=""):
    global ok, warn, fail
    if kind == "ok": ok += 1
    elif kind == "WARN": warn += 1
    else: fail += 1
    print(f"  {kind:<4} [{label}]{(' ' + msg) if msg else ''}")

def age_days(s):
    try:
        return (today - _dt.date.fromisoformat(s)).days
    except Exception:
        return None

PIN_LINE = re.compile(r'(^|[\s"\'{,])(model"?\s*[=:]|--model\b)', re.I)
COMMENT = re.compile(r'^\s*(#|//|\*|<!--)')

if not runtimes:
    report("FAIL", "registry-empty", "no runtimes declared")

print(f"=== (S) schema ===")
for rid, rt in runtimes.items():
    required = ["kind", "vendor", "cli_version_measured", "measured_on", "pin_files"]
    missing = [k for k in required if k not in rt]
    if rt.get("kind") == "first-party" and "retired_model_patterns" not in rt:
        missing.append("retired_model_patterns")
    if missing:
        report("FAIL", f"{rid}-schema", "missing " + ", ".join(missing))
    else:
        report("ok", f"{rid}-schema")

print(f"=== (F) freshness (window {max_age}d, today {today_s}) ===")
for rid, rt in runtimes.items():
    stamps = [("measured_on", rt.get("measured_on"))] + [
        (f"docs[{i}]", d.get("checked_on")) for i, d in enumerate(rt.get("docs") or [])
    ]
    for label, s in stamps:
        a = age_days(s or "")
        if a is None:
            report("FAIL", f"{rid}-{label}-date", f"unparseable date {s!r}")
        elif a < 0:
            report("FAIL", f"{rid}-{label}-future", f"{s} is {-a}d after today (typo?)")
        elif a > max_age:
            report("FAIL" if strict else "WARN", f"{rid}-{label}-stale", f"{a}d old (> {max_age}d)")
        else:
            report("ok", f"{rid}-{label}-fresh", f"{a}d")

print(f"=== (R) retired model IDs on pin lines ===")
for rid, rt in runtimes.items():
    pats = [re.compile(p) for p in (rt.get("retired_model_patterns") or [])]
    if not pats:
        report("ok", f"{rid}-retired-skip", "no denylist (gateway / not surveyed)")
        continue
    files = []
    for g in rt.get("pin_files") or []:
        files.extend(sorted(glob.glob(os.path.join(root, g))))
    if not files:
        report("FAIL", f"{rid}-pin-files-missing", "none of pin_files exist: " + ", ".join(rt.get("pin_files") or []))
        continue
    hit = False
    for f in files:
        try:
            lines = open(f, encoding="utf-8", errors="replace").read().splitlines()
        except Exception as e:
            report("FAIL", f"{rid}-pin-read", f"{f}: {e}"); hit = True; continue
        for n, line in enumerate(lines, 1):
            if COMMENT.match(line) or not PIN_LINE.search(line):
                continue
            for p in pats:
                if p.search(line):
                    rel = os.path.relpath(f, root)
                    report("FAIL", f"{rid}-retired-pin", f"{rel}:{n}: {line.strip()[:100]}  (matches /{p.pattern}/)")
                    hit = True
    if not hit:
        report("ok", f"{rid}-no-retired-pins", f"{len(files)} file(s) scanned")

print()
print(f"=== Results: {ok} ok, {warn} warn, {fail} failed{' (strict)' if strict else ''} ===")
if fail:
    print("runtime-currency: FAIL — re-survey the runtime (docs/runtime-registry.json) or fix the pin; see .agent/plans/runtime-currency-2026-09/plan.md W1/W2.")
    sys.exit(1)
if warn:
    print("runtime-currency: PASS with WARN — a runtime spec is past its review window; re-check its docs and bump checked_on/measured_on.")
sys.exit(0)
PY
