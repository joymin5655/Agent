#!/usr/bin/env python3
"""log_run.py — append one metadata-only line per writing-critique run.

usage: log_run.py --draft FILE --kind general|user-voiced --labels labels.json \
         --findings findings.json [--decisions decisions.json] [--drift drift.json]
decisions.json: [{"id": "A1", "decision": "accept|reject", "reason": "R1..R5 (reject only)"}]
drift.json:     the drift_check.py output of the FINAL text.

Log: $WRITING_CRITIQUE_LOG, else ${AGENT_LOGS_DIR:-~/.agent/logs}/writing-critique.jsonl.
Whitelisted fields only: time, doc hash (sha256[:12]) / length / kind, per-critic company,
status, seconds and finding counts, accept/reject counts and reason codes, drift summary.
No document text, quotes or suggestions are ever written.
"""
import argparse
import datetime
import hashlib
import json
import os
import sys

REASONS = {"R1", "R2", "R3", "R4", "R5"}


def counts(items, key):
    out = {}
    for it in items:
        out[it[key]] = out.get(it[key], 0) + 1
    return out


def log_path():
    p = os.environ.get("WRITING_CRITIQUE_LOG")
    if p:
        return p
    base = os.environ.get("AGENT_LOGS_DIR") or os.path.expanduser("~/.agent/logs")
    return os.path.join(base, "writing-critique.jsonl")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--draft", required=True)
    ap.add_argument("--kind", choices=["general", "user-voiced"], required=True)
    ap.add_argument("--labels", required=True)
    ap.add_argument("--findings", required=True)
    ap.add_argument("--decisions")
    ap.add_argument("--drift")
    a = ap.parse_args()

    text = open(a.draft, encoding="utf-8").read()
    labels = json.load(open(a.labels, encoding="utf-8"))
    findings = json.load(open(a.findings, encoding="utf-8"))
    decisions = json.load(open(a.decisions, encoding="utf-8")) if a.decisions else []
    by_id = {}
    for d in decisions:
        if d.get("decision") not in ("accept", "reject"):
            sys.exit("log_run: decision must be accept|reject")
        if d["decision"] == "reject" and d.get("reason") not in REASONS:
            sys.exit("log_run: a rejection needs reason R1..R5")
        by_id[d["id"]] = d

    critics, reasons = [], {}
    for label, meta in sorted(labels.items()):
        fl = findings.get(label, {}).get("findings", [])
        acc = sum(1 for f in fl if by_id.get(f["id"], {}).get("decision") == "accept")
        rej = [by_id[f["id"]] for f in fl if by_id.get(f["id"], {}).get("decision") == "reject"]
        for r in rej:
            reasons[r["reason"]] = reasons.get(r["reason"], 0) + 1
        critics.append({
            "company": meta["company"], "status": meta["status"], "elapsed_s": meta["elapsed_s"],
            "backend": meta.get("backend", ""), "fallback": bool(meta.get("fallback_reason")),
            "findings": len(fl), "by_severity": counts(fl, "severity"), "by_category": counts(fl, "category"),
            "dropped": findings.get(label, {}).get("dropped", {}).get("total", 0),
            "accepted": acc, "rejected": len(rej),
            "undecided": len(fl) - acc - len(rej)})
    rec = {
        "ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "doc": {"sha": hashlib.sha256(text.encode("utf-8")).hexdigest()[:12], "chars": len(text), "kind": a.kind},
        "critics": critics,
        "accepted": sum(c["accepted"] for c in critics),
        "rejected": sum(c["rejected"] for c in critics),
        "reject_reasons": reasons,
    }
    if a.drift:
        d = json.load(open(a.drift, encoding="utf-8"))
        rec["drift"] = {"passed": bool(d.get("ok")), "mismatches": len(d.get("mismatches", [])),
                        "kinds": d.get("summary", {})}
    p = log_path()
    os.makedirs(os.path.dirname(p) or ".", exist_ok=True)
    with open(p, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
    print(f"log_run: appended to {p}")


if __name__ == "__main__":
    main()
