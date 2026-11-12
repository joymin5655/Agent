#!/usr/bin/env python3
"""Local before/after skill-routing check for a PR that changes skills.

Exports the merge-base of --base and --head, and head, into temp trees (the working tree and
index are never touched; only committed revisions are seen), runs `claude plugin eval` on each
tree for every changed skill that has eval cases, then compares the results with compare.py.
It calls a model, so CI never runs it. Advisory only.

Exit 0: no regression (or no target). Exit 1: REGRESSION found. Exit 2: bad input or an
infrastructure failure.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "compare", Path(__file__).resolve().parent / "compare.py"
)
assert _spec is not None and _spec.loader is not None
compare = importlib.util.module_from_spec(_spec)
sys.modules["compare"] = compare  # dataclasses resolve their module through sys.modules
_spec.loader.exec_module(compare)

EVAL_DIR = "evals/plugin"


class Infra(Exception):
    pass


def git(top: str | None, *args: str) -> str:
    cmd = ["git"] + (["-C", top] if top else []) + list(args)
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if proc.returncode != 0:
        raise Infra(f"git {' '.join(args)} failed: {proc.stderr.strip()}")
    return proc.stdout


def resolve(top: str, rev: str) -> str:
    return git(top, "rev-parse", "--verify", f"{rev}^{{commit}}").strip()


def changed_skills(top: str, base: str, head: str) -> list[str]:
    names: set[str] = set()
    out = git(top, "-c", "core.quotepath=false", "diff", "--name-only", base, head, "--",
              "skills", "extras/skills")
    for path in out.splitlines():
        parts = path.split("/")
        if "skills" in parts and parts.index("skills") + 1 < len(parts) - 1:
            names.add(parts[parts.index("skills") + 1])
    return sorted(names)


def skill_exists(top: str, rev: str, name: str) -> bool:
    out = git(top, "ls-tree", "--name-only", rev, "--", f"skills/{name}", f"extras/skills/{name}")
    return bool(out.strip())


def case_names(top: str, rev: str) -> list[str]:
    return git(top, "ls-tree", "--name-only", f"{rev}:{EVAL_DIR}").splitlines()


def eval_command(claude: str, model: str, runs: int, cost: float, skill: str, json_path: Path
                 ) -> list[str]:
    return [
        claude, "plugin", "eval", ".", "--eval-dir", EVAL_DIR, "--trust-plugin", "--no-publish",
        "-j", "4", "--model", model, "--runs", str(runs), "--max-cost-usd", f"{cost:g}",
        "--case", f"{skill}-*", "--json", str(json_path),
    ]


def export_tree(top: str, rev: str, dest: Path, paths: tuple[str, ...] = ()) -> None:
    dest.mkdir(parents=True)
    archive = subprocess.run(["git", "-C", top, "archive", rev, *paths], capture_output=True,
                             check=False)
    if archive.returncode != 0:
        raise Infra(f"git archive {rev} failed: {archive.stderr.decode(errors='replace').strip()}")
    untar = subprocess.run(["tar", "-x", "-C", str(dest)], input=archive.stdout,
                           capture_output=True, check=False)
    if untar.returncode != 0:
        raise Infra(f"tar extract failed: {untar.stderr.decode(errors='replace').strip()}")


def pin_cases(tree: Path, source: Path) -> None:
    target = tree / EVAL_DIR
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(source, target)
    shutil.rmtree(target / "results", ignore_errors=True)


def check_result(json_path: Path, label: str) -> None:
    if not json_path.is_file():
        raise Infra(f"eval for {label} wrote no result JSON")
    try:
        doc = json.loads(json_path.read_text(encoding="utf-8"))
    except ValueError as exc:
        raise Infra(f"eval for {label} wrote unreadable JSON") from exc
    if not isinstance(doc, dict) or not doc.get("cases"):
        raise Infra(f"eval for {label} produced no cases (does --case match anything?)")


def run_evals(args: argparse.Namespace, top: str, base: str, head: str, cases_rev: str,
              skills: list[str], claude: str) -> int:
    work = Path(tempfile.mkdtemp(prefix="regress-trees-"))
    try:
        out_dir = Path(args.out_dir) if args.out_dir else Path(
            tempfile.mkdtemp(prefix="regress-out-"))
        out_dir.mkdir(parents=True, exist_ok=True)
        print(f"out dir: {out_dir}")
        case_src = work / "cases"
        export_tree(top, cases_rev, case_src, (EVAL_DIR,))
        source = case_src / EVAL_DIR
        trees = {"base": base, "head": head}
        for side, rev in trees.items():
            export_tree(top, rev, work / side)
            pin_cases(work / side, source)
        partial = False
        for side in trees:
            for skill in skills:
                json_path = out_dir / f"{side}-{skill}.json"
                json_path.unlink(missing_ok=True)
                cmd = eval_command(claude, args.model, args.runs, args.max_cost_usd, skill,
                                   json_path)
                print(f"running [{side}] {skill} ...", flush=True)
                proc = subprocess.run(cmd, cwd=work / side, check=False)
                if proc.returncode not in (0, 1, 2):
                    raise Infra(f"eval for {side}/{skill} exited {proc.returncode}")
                check_result(json_path, f"{side}/{skill}")
                partial = partial or proc.returncode == 2
        base_json = [str(out_dir / f"base-{s}.json") for s in skills]
        head_json = [str(out_dir / f"head-{s}.json") for s in skills]
        try:
            rows, cmp_partial = compare.compare(base_json, head_json)
        except compare.BadInput as exc:
            raise Infra(str(exc)) from exc
        partial = partial or cmp_partial
        summary = compare.summarize(rows)
        regression = summary["REGRESSION"] > 0
        md = compare.render_markdown(rows, summary, partial)
        print(md, end="")
        (out_dir / "compare.md").write_text(md, encoding="utf-8")
        (out_dir / "compare.json").write_text(
            json.dumps({"summary": summary, "rows": rows, "regression": regression,
                        "partial": partial}, indent=2) + "\n", encoding="utf-8")
        return 1 if regression else 0
    finally:
        if args.keep:
            print(f"kept trees: {work}")
        else:
            shutil.rmtree(work, ignore_errors=True)


def plan_or_run(args: argparse.Namespace) -> int:
    if args.runs < 3:
        raise Infra("--runs must be at least 3 (the NOISE/REGRESSION thresholds assume 3 runs)")
    top = git(None, "rev-parse", "--show-toplevel").strip()
    base_tip = resolve(top, args.base)
    head = resolve(top, args.head)
    cases_rev = resolve(top, args.cases_from) if args.cases_from else head
    base = git(top, "merge-base", base_tip, head).strip()
    print(f"base {args.base} → merge-base {base[:10]}, head {args.head} ({head[:10]}), "
          f"cases from {cases_rev[:10]}")
    wanted = sorted(set(args.skill)) or changed_skills(top, base, head)
    if not wanted:
        print(f"no target: no skill changed between {args.base} and {args.head}")
        return 0
    have = case_names(top, cases_rev)
    skills = []
    for name in wanted:
        if not skill_exists(top, head, name):
            print(f"skipped: no skill named {name}")
        # ponytail: cases match by the `NAME-` prefix, so a skill named as another skill's prefix
        # shares its cases - upgrade: a skill field in the case front matter
        elif any(c.startswith(f"{name}-") for c in have):
            skills.append(name)
        else:
            print(f"skipped: no eval cases for {name}")
    if not skills:
        print("no target: none of the changed skills has eval cases")
        return 0
    claude = os.environ.get("REGRESS_CLAUDE_BIN", "claude")
    print(f"skills: {', '.join(skills)}")
    print(f"cost note: {2 * len(skills)} eval calls (base and head per skill), "
          f"each capped at ${args.max_cost_usd:g}")
    if args.plan:
        out = args.out_dir or "<new temp dir>"
        print(f"out dir: {out}")
        for side in ("base", "head"):
            for skill in skills:
                cmd = eval_command(claude, args.model, args.runs, args.max_cost_usd, skill,
                                   Path(out) / f"{side}-{skill}.json")
                print(f"[{side}] cd <{side} tree> && {shlex.join(cmd)}")
        return 0
    return run_evals(args, top, base, head, cases_rev, skills, claude)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--base", default="origin/main",
                    help="base revision; its merge-base with --head is the baseline "
                    "(default: %(default)s)")
    ap.add_argument("--head", default="HEAD")
    ap.add_argument("--cases-from", help="revision whose evals/plugin is used (default: head)")
    ap.add_argument("--skill", action="append", default=[], help="skill to check (repeatable)")
    ap.add_argument("--runs", type=int, default=3, help="runs per case, minimum 3")
    ap.add_argument("--model", default="sonnet")
    ap.add_argument("--max-cost-usd", type=float, default=6.0, help="ceiling per eval call")
    ap.add_argument("--out-dir", help="result directory (default: a new temp dir)")
    ap.add_argument("--plan", action="store_true", help="print the plan, call no model")
    ap.add_argument("--keep", action="store_true", help="keep the exported temp trees")
    args = ap.parse_args(argv)
    try:
        return plan_or_run(args)
    except (Infra, OSError) as exc:
        print(f"infrastructure failure: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
