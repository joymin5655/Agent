#!/usr/bin/env bash
# critique.sh — send an anonymised draft to two external critics at once and vet the replies.
#
# usage: critique.sh <draft> [--purpose "<purpose and reader, one line>"] --out <dir>
# writes <dir>/findings.json (critics labelled A/B, identity-free), <dir>/labels.json
# (label -> role/company/status/elapsed), <dir>/status.txt; prints the status lines.
# exit: 0 at least one critic answered (read `result:` — both|one) | 2 usage/setup
#       4 no critic answered (`result: none`; the line says "approval needed" when a critic
#         ended in call-worker exit 3 and the other did too or failed, so the caller can ask
#         once and re-run; with one answer the status lines name a critic awaiting approval)
# --purpose may be omitted or empty: the prompt's purpose line then reads "명시 없음".
#
# Cost: each critic is a paid call-worker dispatch (roles advisor-writing-openai,
# advisor-writing-google). This script never sets the approval flag; call-worker's usage
# policy command (when the install configures one) decides per call, otherwise call-worker
# ends with exit 3 = approval needed and that critic is skipped. The caller asks the user
# once and re-runs with the flag set for that one call.
# Per-critic status: success | success-empty (answered, but no finding survived vetting) |
#   approval-needed | timeout | failed. labels.json also records the backend that really ran
#   and the fallback reason from the capture header, and status.txt shows a fallback.
# env seams (tests): WRITING_CRITIQUE_CALL_WORKER (path to a call-worker stand-in),
#                    WRITING_CRITIQUE_TIMEOUT_S (per-critic seconds, default 240)
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRAFT="" PURPOSE="" OUT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --purpose) PURPOSE="${2-}"; shift; [[ $# -gt 0 ]] && shift ;;
        --out) OUT="${2:?--out needs a folder}"; shift 2 ;;
        -h|--help) sed -n 2,22p "$0"; exit 0 ;;
        -*) echo "critique: unknown option $1" >&2; exit 2 ;;
        *) [[ -z "$DRAFT" ]] && DRAFT="$1" || { echo "critique: one draft only" >&2; exit 2; }; shift ;;
    esac
done
[[ -f "$DRAFT" && -n "$OUT" ]] || { echo "usage: critique.sh <draft> [--purpose \"...\"] --out <dir>" >&2; exit 2; }

CW="${WRITING_CRITIQUE_CALL_WORKER:-}"
if [[ -z "$CW" ]]; then
    ROOT="$(bash "$SKILL_DIR/../../scripts/harness-root.sh")" || exit 2
    CW="$ROOT/core/infra/call-worker.sh"
fi
[[ -f "$CW" ]] || { echo "critique: call-worker not found at $CW" >&2; exit 2; }

mkdir -p "$OUT"
python3 - "$SKILL_DIR" "$DRAFT" "$PURPOSE" "$OUT/prompt.md" <<'PY'
import sys
skill, draft, purpose, out = sys.argv[1:5]
tpl = open(f"{skill}/references/critic-prompt.md", encoding="utf-8").read()
rub = open(f"{skill}/references/rubric.md", encoding="utf-8").read()
body = open(draft, encoding="utf-8").read()
purpose = purpose.strip() or "(명시 없음 — 문서 자체로 판단한다)"
# one pass, so text inside the draft that looks like a placeholder is never expanded
import re
vals = {"PURPOSE": purpose, "RUBRIC": rub.strip(), "DRAFT": body.rstrip("\n")}
open(out, "w", encoding="utf-8").write(re.sub(r"\{\{(PURPOSE|RUBRIC|DRAFT)\}\}", lambda m: vals[m.group(1)], tpl))
PY

# random A/B: which company is which stays in labels.json only
if (( RANDOM % 2 )); then LA=openai LB=google; else LA=google LB=openai; fi
role_of() { echo "advisor-writing-$1"; }

run_critic() { # <label> <company>
    local label="$1" company="$2" t0 t1 rc=0
    t0=$(python3 -c 'import time;print(time.time())')
    AGENT_WORKER_TIMEOUT_S="${WRITING_CRITIQUE_TIMEOUT_S:-240}" \
        bash "$CW" "$(role_of "$company")" < "$OUT/prompt.md" > "$OUT/$label.path" 2> "$OUT/$label.err" || rc=$?
    t1=$(python3 -c 'import time;print(time.time())')
    echo "$rc" > "$OUT/$label.rc"
    python3 -c "print(round($t1-$t0,1))" > "$OUT/$label.sec"
}
run_critic A "$LA" &
run_critic B "$LB" &
wait

python3 - "$SKILL_DIR" "$DRAFT" "$OUT" "$LA" "$LB" <<'PY'
import json, re, subprocess, sys
skill, draft, out, la, lb = sys.argv[1:6]
findings, labels, lines, ok = {}, {}, [], 0


def header(path):
    """backend / fallback_reason from the capture's front matter ('' when absent)."""
    try:
        head = open(path, encoding="utf-8", errors="replace").read(4000)
    except OSError:
        return "", ""
    m = re.match(r"---\n(.*?)\n---", head, re.S)
    vals = dict(re.findall(r"^(\w+):[ \t]*(.*)$", m.group(1), re.M)) if m else {}
    return vals.get("backend", "").strip(), vals.get("fallback_reason", "").strip()


for label, company in (("A", la), ("B", lb)):
    rc = int(open(f"{out}/{label}.rc").read().strip())
    sec = float(open(f"{out}/{label}.sec").read().strip())
    entry = {"status": "", "verdict": "", "findings": [], "dropped": {"total": 0, "reasons": {}}}
    backend = fallback = ""
    if rc == 3:
        entry["status"] = "approval-needed"
    elif rc == 124:
        entry["status"] = "timeout"
    elif rc != 0:
        entry["status"] = "failed"
    else:
        got = [l.strip() for l in open(f"{out}/{label}.path").read().splitlines() if l.strip()]
        path = got[-1] if got else ""
        if path:
            backend, fallback = header(path)
        if not path:
            entry["status"] = "failed"
        else:
            p = subprocess.run([sys.executable, f"{skill}/scripts/parse_findings.py", path,
                                "--draft", draft, "--label", label], capture_output=True, text=True)
            try:
                r = json.loads(p.stdout)
            except ValueError:
                r = {"ok": False}
            if r.get("ok"):
                empty = r["verdict"] == "revise" and not r["findings"]
                entry.update(status="success-empty" if empty else "success", verdict=r["verdict"],
                             findings=r["findings"], dropped=r["dropped"])
                ok += 1
            else:
                entry["status"] = "failed"
    findings[label] = entry
    labels[label] = {"role": f"advisor-writing-{company}", "company": company,
                     "status": entry["status"], "elapsed_s": sec,
                     "backend": backend, "fallback_reason": fallback}
    n, d = len(entry["findings"]), entry["dropped"]["total"]
    line = f"{label}: {entry['status']}"
    if entry["status"] == "success":
        line += f" ({n} findings, {d} dropped)"
    elif entry["status"] == "success-empty":
        line += f" (verdict revise, but 0 usable findings after vetting, {d} dropped)"
    if fallback:
        line += f" [fell back to {backend or 'another backend'}: {fallback}]"
    lines.append(line)
need = [label for label, e in findings.items() if e["status"] == "approval-needed"]
result = {2: "both", 1: "one", 0: "none"}[ok]
if result == "none" and len(need) == 2:
    lines.append("result: none (approval needed: both critics)")
    lines.append("approval needed for both critics: ask the user once, then re-run this command with the approval flag set for that one call; until then external review has not happened")
elif result == "none" and need:
    lines.append(f"result: none (approval needed: critic {need[0]}; the other failed)")
    lines.append(f"approval needed for critic {need[0]}: ask the user once, then re-run this command with the approval flag set for that one call (both critics run again); until then external review has not happened")
elif result == "none":
    lines.append("result: none")
    lines.append("external review unavailable: proceed without it and say so; do not substitute a Claude-only critique")
else:
    lines.append(f"result: {result}")
if result == "one":
    lines.append("only one critic answered: use that critic's findings alone and say so")
    if need:
        lines.append(f"critic {need[0]} needs approval: to add it, ask the user and re-run this command with the approval flag set for that one call (both critics run again)")
json.dump(findings, open(f"{out}/findings.json", "w"), ensure_ascii=False, indent=2)
json.dump(labels, open(f"{out}/labels.json", "w"), ensure_ascii=False, indent=2)
open(f"{out}/status.txt", "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
sys.exit(0 if ok else 4)
PY
