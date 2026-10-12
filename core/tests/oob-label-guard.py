#!/usr/bin/env python3
"""Out-of-band label guard (X-2) — scan the model-visible text core/hooks emit.

A *measurement label* is a value that exists only to group or aggregate
observations: an experiment/holdout/cohort/variant/arm assignment, or the
sink-record fields a gate writes for aggregation (guard, gate_id, reproduce_test,
schema_version, sig_sha). Such a label must stay out-of-band (docs/hook-protocol.md
§ Out-of-band labels): in the jsonl sink, never in `additionalContext`,
`systemMessage` or a system prompt, because logging inside the model's context
changes the behaviour being measured. Ordinary guidance text is NOT in scope.

Method: collect every string that can reach an `additionalContext` /
`systemMessage` value (Python hooks via ast, following name assignments in the
same file; shell hooks via the `jq --arg` variable they feed), then match the
label vocabulary below. A site whose text cannot be resolved is listed as
UNRESOLVED so a refactor cannot turn the guard silently blind.

Usage: oob-label-guard.py [--root DIR]    (exit 1 on any label hit or unresolvable site)
"""
from __future__ import annotations

import argparse
import ast
import os
import re
import sys

KEYS = ("additionalContext", "systemMessage")

_WORDS = re.compile(
    r"(?i)\b(?:hold-?out|cohort|variant|experiment(?:al)?|control[ -]group"
    r"|treatment[ -]group|a/b[ -]test|(?:arm|bucket|cohort|variant|experiment)[ _-]?id)\b"
)
_FIELDS = re.compile(
    r"(?<![\w-])(?:guard|gate_id|reproduce_test|schema_version|sig_sha|cohort|variant|arm)"
    r"\s*[=:]\s*\S"
)


def label_hits(text):
    return [m.group(0) for rx in (_WORDS, _FIELDS) for m in rx.finditer(text)]


def _strings(node, assigns, seen, depth=0):
    """Every string constant that can flow into `node` (best effort)."""
    out = []
    if node is None or depth > 6:
        return out
    if isinstance(node, ast.Constant):
        if isinstance(node.value, str):
            out.append(node.value)
    elif isinstance(node, ast.Name):
        if node.id not in seen:
            seen.add(node.id)
            for value in assigns.get(node.id, []):
                out += _strings(value, assigns, seen, depth + 1)
    else:
        for child in ast.iter_child_nodes(node):
            out += _strings(child, assigns, seen, depth + 1)
    return out


def _fn_strings(fn):
    """Fallback for text that arrives as a parameter or call result: every
    non-docstring string constant in the enclosing function."""
    skip = set()
    for n in ast.walk(fn):
        if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Module)) and n.body:
            first = n.body[0]
            if isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant):
                skip.add(id(first.value))
    return [n.value for n in ast.walk(fn)
            if isinstance(n, ast.Constant) and isinstance(n.value, str) and id(n) not in skip]


def scan_python(path):
    try:
        tree = ast.parse(open(path, encoding="utf-8").read())
    except (SyntaxError, OSError):
        return []
    assigns = {}
    for n in ast.walk(tree):
        if isinstance(n, ast.Assign):
            for t in n.targets:
                if isinstance(t, ast.Name):
                    assigns.setdefault(t.id, []).append(n.value)
        elif isinstance(n, ast.AugAssign) and isinstance(n.target, ast.Name):
            assigns.setdefault(n.target.id, []).append(n.value)
    sites = []
    parents = {}
    for n in ast.walk(tree):
        for c in ast.iter_child_nodes(n):
            parents[id(c)] = n
    for n in ast.walk(tree):
        if not isinstance(n, ast.Dict):
            continue
        for k, v in zip(n.keys, n.values):
            if isinstance(k, ast.Constant) and k.value in KEYS:
                strs = _strings(v, assigns, set())
                if not strs:
                    fn = parents.get(id(n))
                    while fn is not None and not isinstance(
                            fn, (ast.FunctionDef, ast.AsyncFunctionDef)):
                        fn = parents.get(id(fn))
                    strs = _fn_strings(fn) if fn is not None else []
                sites.append((n.lineno, k.value, strs))
    return sites


_JQ_ARG = re.compile(r'--arg\s+\w+\s+"\$\{?(\w+)')


def scan_shell(path):
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        return []
    code = [(i + 1, ln) for i, ln in enumerate(lines) if not ln.lstrip().startswith("#")]
    sites = []
    for i, (lineno, ln) in enumerate(code):
        if not any(k in ln for k in KEYS):
            continue
        # the jq call spans a few lines: its --arg variables feed the key
        window = " ".join(t for _, t in code[max(0, i - 4): i + 1])
        names = set(_JQ_ARG.findall(window))
        strs = []
        for name in names:
            assign = re.compile(r"\b" + re.escape(name) + r"\w*(?:\[[^\]]*\])?\+?=")
            strs += [t for _, t in code if assign.search(t) or re.search(
                r"\b" + re.escape(name) + r"_PARTS\b", t)]
        sites.append((lineno, "jq", strs))
    return sites


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.path.join(os.path.dirname(__file__), "..", ".."))
    root = os.path.abspath(ap.parse_args().root)
    hooks = os.path.join(root, "core", "hooks")
    total = bad = 0
    unresolved = []
    for name in sorted(os.listdir(hooks)):
        path = os.path.join(hooks, name)
        if name.endswith(".py"):
            sites = scan_python(path)
        elif name.endswith(".sh"):
            sites = scan_shell(path)
        else:
            continue
        for lineno, key, strs in sites:
            total += 1
            rel = "core/hooks/%s:%d" % (name, lineno)
            if not strs:
                unresolved.append(rel)
            for hit in label_hits("\n".join(strs)):
                bad += 1
                print("LABEL %s (%s): %r" % (rel, key, hit))
    print("sites=%d unresolved=%d label_hits=%d" % (total, len(unresolved), bad))
    for rel in unresolved:
        print("UNRESOLVED %s" % rel)
    return 1 if (bad or unresolved) else 0


if __name__ == "__main__":
    sys.exit(main())
