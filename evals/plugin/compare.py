#!/usr/bin/env python3
"""Compare two sets of `claude plugin eval --json` results for skill-routing regressions.

Only the `with` arm is read. For each case and routing grader (`tool_used` on `Skill`) it
counts passing runs on the base and head side and assigns a verdict. Advisory only: it never
calls a model. See evals/plugin/README.md "Regression check".

Exit 0: no regression. Exit 1: at least one REGRESSION. Exit 2: unreadable or unrecognized input.
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

VERDICTS = (
    "REGRESSION",
    "NOISE",
    "UNDETERMINED",
    "IMPROVED",
    "UNCHANGED",
    "ONLY-IN-BASE",
    "ONLY-IN-HEAD",
)
NOISE_NOTE = (
    "NOISE = a fires case lost one run out of a few; within run-to-run variance, "
    "re-run to confirm before acting."
)


class BadInput(Exception):
    pass


@dataclass
class Counts:
    passed: int
    total: int
    errors: int

    def show(self) -> str:
        text = f"{self.passed}/{self.total}"
        return f"{text} ({self.errors} err)" if self.errors else text


@dataclass
class GraderStat:
    kind: str  # "fires", "quiet" or "info"
    counts: Counts


@dataclass
class CaseData:
    graders: dict[str, GraderStat] = field(default_factory=dict)


def _shape_error(path: str) -> BadInput:
    return BadInput(f"unrecognized result shape: {path}")


def _classify(grader: dict[str, Any]) -> str:
    cfg = grader.get("config")
    cfg = cfg if isinstance(cfg, dict) else {}
    if grader.get("type") != "tool_used":
        return "info"
    cap = cfg.get("max")
    return "quiet" if isinstance(cap, int) and not isinstance(cap, bool) and cap == 0 else "fires"


def _case_data(case: dict[str, Any], path: str) -> CaseData:
    defs = case.get("graders")
    arms = case.get("arms")
    runs = arms.get("with") if isinstance(arms, dict) else None
    if not isinstance(defs, list) or not isinstance(runs, list):
        raise _shape_error(path)
    data = CaseData()
    for gdef in defs:
        if not isinstance(gdef, dict) or not isinstance(gdef.get("name"), str):
            raise _shape_error(path)
        name = gdef["name"]
        if name in data.graders:
            raise BadInput(f"duplicate grader {name} in case {case.get('name')} ({path})")
        passed = total = errors = 0
        for run in runs:
            if not isinstance(run, dict):
                raise _shape_error(path)
            total += 1
            if run.get("error") is not None:
                errors += 1
            for rg in run.get("graders") or []:
                if isinstance(rg, dict) and rg.get("name") == name and rg.get("passed") is True:
                    passed += 1
        data.graders[name] = GraderStat(_classify(gdef), Counts(passed, total, errors))
    return data


def load_side(paths: list[str]) -> tuple[dict[str, CaseData], bool]:
    merged: dict[str, CaseData] = {}
    partial = False
    for path in paths:
        try:
            doc = json.loads(Path(path).read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise _shape_error(path) from exc
        if not isinstance(doc, dict) or doc.get("schemaVersion") != 1:
            raise _shape_error(path)
        cases = doc.get("cases")
        if not isinstance(cases, list):
            raise _shape_error(path)
        partial = partial or doc.get("partial") is True
        for case in cases:
            if not isinstance(case, dict) or not isinstance(case.get("name"), str):
                raise _shape_error(path)
            if case["name"] in merged:
                raise BadInput(f"duplicate case on one side: {case['name']} ({path})")
            merged[case["name"]] = _case_data(case, path)
    return merged, partial


def _verdict(kind: str, base: Counts, head: Counts) -> str:
    if base.errors or head.errors or base.total != head.total or base.total == 0:
        return "UNDETERMINED"
    if kind == "fires":
        delta = head.passed - base.passed
        if delta <= -2:
            return "REGRESSION"
        if delta == -1:
            return "NOISE"
        return "IMPROVED" if delta >= 1 else "UNCHANGED"
    false_base = base.total - base.passed
    false_head = head.total - head.passed
    if false_head > false_base:
        return "REGRESSION"
    return "IMPROVED" if false_head < false_base else "UNCHANGED"


def build_rows(base: dict[str, CaseData], head: dict[str, CaseData]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for name in sorted(set(base) | set(head)):
        if name not in head or name not in base:
            only = "ONLY-IN-BASE" if name in base else "ONLY-IN-HEAD"
            rows.append(
                {"case": name, "grader": "*", "kind": "case", "base": "-", "head": "-",
                 "verdict": only}
            )
            continue
        for gname in sorted(set(base[name].graders) | set(head[name].graders)):
            b = base[name].graders.get(gname)
            h = head[name].graders.get(gname)
            kind = h.kind if h is not None else (b.kind if b is not None else "info")
            kind_differs = b is not None and h is not None and b.kind != h.kind
            row: dict[str, Any] = {
                "case": name, "grader": gname, "kind": kind,
                "base": b.counts.show() if b else "-",
                "head": h.counts.show() if h else "-",
                "verdict": "",
            }
            if kind_differs or ((b is None or h is None) and kind != "info"):
                row["verdict"] = "UNDETERMINED"
            elif kind == "info":
                row["verdict"] = "info"
            else:
                assert b is not None and h is not None
                row["verdict"] = _verdict(kind, b.counts, h.counts)
            rows.append(row)
    return rows


def summarize(rows: list[dict[str, Any]]) -> dict[str, int]:
    summary = {v: 0 for v in VERDICTS}
    for row in rows:
        if row["verdict"] in summary:
            summary[row["verdict"]] += 1
    return summary


def render_markdown(rows: list[dict[str, Any]], summary: dict[str, int], partial: bool) -> str:
    parts = ", ".join(f"{summary[v]} {v}" for v in VERDICTS if summary[v])
    lines = [f"Skill routing comparison: {parts or 'nothing to compare'}"]
    if partial:
        lines.append("PARTIAL: at least one input run hit its cost ceiling; counts are incomplete.")
    lines += ["", "| case | grader | base | head | verdict |", "|---|---|---|---|---|"]
    for r in rows:
        lines.append(f"| {r['case']} | {r['grader']} | {r['base']} | {r['head']} | {r['verdict']} |")
    lines += ["", NOISE_NOTE]
    return "\n".join(lines) + "\n"


def compare(base_paths: list[str], head_paths: list[str]) -> tuple[list[dict[str, Any]], bool]:
    base, base_partial = load_side(base_paths)
    head, head_partial = load_side(head_paths)
    routing = any(
        g.kind != "info" for side in (base, head) for c in side.values() for g in c.graders.values()
    )
    if not routing:
        raise BadInput("no routing graders found (no tool_used grader in any case)")
    return build_rows(base, head), base_partial or head_partial


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--base", nargs="+", required=True, metavar="JSON")
    ap.add_argument("--head", nargs="+", required=True, metavar="JSON")
    ap.add_argument("--json-out", metavar="FILE")
    ap.add_argument("--md-out", metavar="FILE")
    args = ap.parse_args(argv)
    try:
        rows, partial = compare(args.base, args.head)
    except BadInput as exc:
        print(str(exc), file=sys.stderr)
        return 2
    summary = summarize(rows)
    regression = summary["REGRESSION"] > 0
    md = render_markdown(rows, summary, partial)
    sys.stdout.write(md)
    if args.md_out:
        Path(args.md_out).write_text(md, encoding="utf-8")
    if args.json_out:
        payload = {"summary": summary, "rows": rows, "regression": regression, "partial": partial}
        Path(args.json_out).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return 1 if regression else 0


if __name__ == "__main__":
    sys.exit(main())
