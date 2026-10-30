#!/usr/bin/env python3
"""report.py — aggregate writing-critique.jsonl over the last N days.

usage: report.py [--days 30] [--log FILE] [--json]
Per critic company: runs, success rate, findings, accept rate (accepted / decided),
category distribution. Outcomes are counted apart: success, success-empty (answered, nothing
usable left), approval-needed (not a failure, so left out of the success-rate base), timeout,
failed, and fallback (another backend served the call). Overall: runs, drift pass rate, reject-reason counts.
"""
import argparse
import datetime
import json
import os
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=30)
    ap.add_argument("--log")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    path = a.log or os.environ.get("WRITING_CRITIQUE_LOG") or os.path.join(
        os.environ.get("AGENT_LOGS_DIR") or os.path.expanduser("~/.agent/logs"), "writing-critique.jsonl")
    cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=a.days)
    recs = []
    if os.path.isfile(path):
        for ln in open(path, encoding="utf-8"):
            try:
                r = json.loads(ln)
                ts = datetime.datetime.strptime(r["ts"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
            except (ValueError, KeyError):
                continue
            if ts >= cutoff:
                recs.append(r)
    per, reasons, drift_n, drift_pass = {}, {}, 0, 0
    for r in recs:
        for k, v in r.get("reject_reasons", {}).items():
            reasons[k] = reasons.get(k, 0) + v
        if "drift" in r:
            drift_n += 1
            drift_pass += 1 if r["drift"]["passed"] else 0
        for c in r.get("critics", []):
            p = per.setdefault(c["company"], {"runs": 0, "success": 0, "success_empty": 0, "approval_needed": 0,
                                              "timeout": 0, "failed": 0, "fallback": 0, "findings": 0,
                                              "accepted": 0, "rejected": 0, "by_category": {}})
            p["runs"] += 1
            key = {"success": "success", "success-empty": "success_empty", "approval-needed": "approval_needed",
                   "timeout": "timeout"}.get(c["status"], "failed")
            p[key] += 1
            p["fallback"] += 1 if c.get("fallback") else 0
            p["findings"] += c["findings"]
            p["accepted"] += c["accepted"]
            p["rejected"] += c["rejected"]
            for k, v in c.get("by_category", {}).items():
                p["by_category"][k] = p["by_category"].get(k, 0) + v
    for p in per.values():
        tried = p["runs"] - p["approval_needed"]
        p["success_rate"] = round((p["success"] + p["success_empty"]) / tried, 2) if tried else None
        d = p["accepted"] + p["rejected"]
        p["accept_rate"] = round(p["accepted"] / d, 2) if d else None
    out = {"days": a.days, "runs": len(recs), "critics": per, "reject_reasons": reasons,
           "drift_pass_rate": round(drift_pass / drift_n, 2) if drift_n else None}
    if a.json:
        print(json.dumps(out, ensure_ascii=False, indent=2))
        return 0
    print(f"writing-critique, last {a.days} days: {len(recs)} run(s)")
    print(f"{'critic':<10}{'runs':>5}{'success':>9}{'empty':>6}{'appr':>5}{'fail':>5}{'fallbk':>7}{'findings':>9}{'accept':>8}  categories")
    for name, p in sorted(per.items()):
        cats = " ".join(f"{k}:{v}" for k, v in sorted(p["by_category"].items()))
        sr = "-" if p["success_rate"] is None else f"{p['success_rate']:.0%}"
        ar = "-" if p["accept_rate"] is None else f"{p['accept_rate']:.0%}"
        fail = p["failed"] + p["timeout"]
        print(f"{name:<10}{p['runs']:>5}{sr:>9}{p['success_empty']:>6}{p['approval_needed']:>5}{fail:>5}"
              f"{p['fallback']:>7}{p['findings']:>9}{ar:>8}  {cats}")
    print("reject reasons: " + (" ".join(f"{k}:{v}" for k, v in sorted(reasons.items())) or "-"))
    print("drift check pass rate: " + ("-" if out["drift_pass_rate"] is None else f"{out['drift_pass_rate']:.0%}"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
