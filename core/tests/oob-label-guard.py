#!/usr/bin/env python3
"""Out-of-band label guard (X-2) — scan the model-visible text core/hooks emit.

A *measurement label* is a value that exists only to group or aggregate
observations: an experiment/holdout/cohort/variant/arm assignment, or the
sink-record fields a gate writes for aggregation (guard, gate_id, reproduce_test,
schema_version, sig_sha). Such a label must stay out-of-band (docs/hook-protocol.md
§ Out-of-band labels): in the jsonl sink, never in `additionalContext` or
`systemMessage`, because logging inside the model's context changes the behaviour
being measured. Ordinary guidance text is NOT in scope.

Method
  1. Emit sites: every place the key text `additionalContext` / `systemMessage`
     appears in a hook as something other than a read or a docstring — a dict
     literal key, a subscript store, a keyword argument, or inside a JSON string /
     f-string. A form that is none of those (computed key, key passed around as a
     value) cannot be followed and is reported UNRESOLVED.
  2. Text: the strings that can flow into the value — constants, f-strings,
     concatenations (joined, so "co" + "hort" is seen as "cohort"), name
     assignments, the return values of same-file helpers, and (one level) the
     arguments at the call sites of a wrapping function. Protocol constants
     (hookSpecificOutput, hookEventName, event names) are dropped.
  3. Anything left that cannot be followed (imported value, unknown call) makes the
     site UNRESOLVED, which FAILS — unless ALLOW names that function with a reason.

Usage: oob-label-guard.py [--root DIR]   (exit 1 on a label hit or an unresolved site)
"""
from __future__ import annotations

import argparse
import ast
import itertools
import os
import re
import sys

KEYS = ("additionalContext", "systemMessage")

# "file.py:function" -> why the text it emits cannot be followed and is still safe.
ALLOW = {}

PROTOCOL = {
    "hookSpecificOutput", "hookEventName", "additionalContext", "systemMessage",
    "PreToolUse", "PostToolUse", "PostToolUseFailure", "Stop", "SessionStart",
    "UserPromptSubmit", "SubagentStart", "SubagentStop",
}
NUMERIC_CALLS = {"int", "float", "len", "bool", "round", "abs", "sum", "min", "max",
                 "range", "time", "monotonic", "getpid", "isinstance", "hexdigest", "digest"}
TEXT_CALLS = {"str", "repr", "format", "sorted", "list", "tuple", "set", "dumps",
              "basename", "dirname", "join", "relpath", "abspath", "getattr", "next"}
STR_METHODS = {"join", "format", "strip", "lstrip", "rstrip", "replace", "lower",
               "upper", "title", "capitalize", "splitlines", "split", "get", "items",
               "values", "keys", "append", "encode", "decode", "removeprefix",
               "removesuffix", "ljust", "rjust", "center", "expandtabs"}
MAX_COMBOS = 32

_WORDS = [
    # assignment / identifier forms only — "experiment with X", "variant of the plan",
    # "an experimental flag" are ordinary prose.
    re.compile(r"(?i)\bhold-?out\b"),
    re.compile(r"\b(?:cohort|variant|arm|bucket)\s+(?:[A-Z]\b|\d+\b)"),
    re.compile(r"(?i)\b(?:experiment|cohort|variant|arm|bucket)[ _-]?(?:id|name|label|group)"
               r"\s*[=:]?\s*\S"),
    re.compile(r"(?i)\b(?:experiment|cohort|variant|arm|bucket)\s*[=:]\s*"
               r"(?:control|treatment|holdout|on|off|[A-Z]\b|\d+\b)"),
    re.compile(r"(?i)\b(?:control|treatment)[ -]group\b|\ba/b[ -]test\b"),
]
_FIELDS = [
    re.compile(r"(?<![\w-])(?:guard|gate_id|reproduce_test|schema_version|sig_sha)\s*=\s*\S"),
    re.compile(r"(?<![\w-])(?:gate_id|reproduce_test|schema_version|sig_sha)\s*:\s*\S"),
    re.compile(r'"(?:guard|gate_id|reproduce_test|schema_version|sig_sha)"\s*:'),
]


def label_hits(text):
    return [m.group(0) for rx in _WORDS + _FIELDS for m in rx.finditer(text)]


def _cat(parts):
    """Cartesian join of fragment alternatives (capped) so concatenations are
    checked as the text the model would actually read."""
    parts = [p if p else [""] for p in parts]
    out = []
    for combo in itertools.islice(itertools.product(*parts), MAX_COMBOS):
        out.append("".join(combo))
    return out


class Resolver:
    def __init__(self, tree):
        self.tree = tree
        self.parents = {}
        self.assigns = {}
        self.funcs = {}
        self.calls = {}
        for n in ast.walk(tree):
            for c in ast.iter_child_nodes(n):
                self.parents[id(c)] = n
            if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)):
                self.funcs.setdefault(n.name, n)
            elif isinstance(n, ast.Assign):
                for t in n.targets:
                    for nm in ast.walk(t):
                        if isinstance(nm, ast.Name):
                            self._add(nm.id, n.value, n)
            elif isinstance(n, ast.AugAssign) and isinstance(n.target, ast.Name):
                self._add(n.target.id, n.value, n)
            elif isinstance(n, ast.AnnAssign) and isinstance(n.target, ast.Name) and n.value:
                self._add(n.target.id, n.value, n)
            elif isinstance(n, ast.For):
                for nm in ast.walk(n.target):
                    if isinstance(nm, ast.Name):
                        self._add(nm.id, n.iter, n)
            elif isinstance(n, ast.comprehension):
                for nm in ast.walk(n.target):
                    if isinstance(nm, ast.Name):
                        self._add(nm.id, n.iter, n)
            elif isinstance(n, ast.Call):
                f = n.func
                key = f.id if isinstance(f, ast.Name) else (
                    f.attr if isinstance(f, ast.Attribute) else None)
                if key:
                    self.calls.setdefault(key, []).append(n)
                if isinstance(f, ast.Attribute) and f.attr in ("append", "extend", "insert") \
                        and isinstance(f.value, ast.Name) and n.args:
                    self._add(f.value.id, n.args[-1], n)

    def _add(self, name, value, node):
        self.assigns.setdefault((name, id(self.enclosing_fn(node))), []).append(value)

    def enclosing_fn(self, node):
        cur = self.parents.get(id(node))
        while cur is not None and not isinstance(cur, (ast.FunctionDef, ast.AsyncFunctionDef)):
            cur = self.parents.get(id(cur))
        return cur

    def params(self, fn):
        a = fn.args
        return [x.arg for x in list(a.posonlyargs) + list(a.args) + list(a.kwonlyargs)]

    def resolve(self, node, fn, seen, depth=0):
        """-> (candidate strings, opaque reasons)."""
        if node is None:
            return [], []
        if depth > 40:
            return [], ["too deep"]
        r = lambda n, f=fn: self.resolve(n, f, seen, depth + 1)  # noqa: E731
        if isinstance(node, ast.Constant):
            if isinstance(node.value, str) and node.value not in PROTOCOL:
                return [node.value], []
            return [], []
        if isinstance(node, ast.JoinedStr):
            parts, op = [], []
            for v in node.values:
                if isinstance(v, ast.FormattedValue):
                    # an interpolated value is a runtime datum (counts, paths, tool
                    # output): its literal fragments are still checked, but what it
                    # cannot follow is not an unresolved emit site.
                    s, _ = r(v.value)
                else:
                    s, o = r(v)
                    op += o
                parts.append(s)
            return _cat(parts), op
        if isinstance(node, ast.BinOp):
            ls, lo = r(node.left)
            rs, ro = r(node.right)
            if isinstance(node.op, (ast.Add, ast.Mod)) and ls and rs:
                return _cat([ls, rs]), lo + ro
            return ls + rs, lo + ro
        if isinstance(node, (ast.IfExp,)):
            a, ao = r(node.body)
            b, bo = r(node.orelse)
            return a + b, ao + bo
        if isinstance(node, ast.Name):
            return self._name(node, fn, seen, depth)
        if isinstance(node, ast.Call):
            return self._call(node, fn, seen, depth)
        if isinstance(node, ast.Attribute):
            s, o = r(node.value)
            if isinstance(node.value, ast.Name) and node.attr in ("sep", "linesep"):
                return [], []
            return s, o + [f"attribute .{node.attr}"]
        s, o = [], []
        for c in ast.iter_child_nodes(node):
            if isinstance(c, (ast.expr, ast.comprehension, ast.keyword)):
                cs, co = r(c)
                s += cs
                o += co
        return s, o

    def _name(self, node, fn, seen, depth):
        name = node.id
        if name in ("True", "False", "None"):
            return [], []
        key = (name, id(fn))
        if key in seen:
            return [], []
        seen = seen | {key}
        strs, opq = [], []
        found = False
        scopes = [id(fn)] + ([id(None)] if fn is not None else [])
        for sc in scopes:
            for v in self.assigns.get((name, sc), []):
                found = True
                s, o = self.resolve(v, self.enclosing_fn(v), seen, depth + 1)
                strs += s
                opq += o
            if found:
                break
        if fn is not None and name in self.params(fn):
            found = True
            callers = self.calls.get(fn.name, [])
            if not callers:
                opq.append(f"parameter {name} of {fn.name}() has no in-file caller")
            plist = self.params(fn)
            offset = 1 if plist and plist[0] in ("self", "cls") else 0
            for c in callers:
                arg = None
                if name in plist:
                    idx = plist.index(name) - offset
                    if 0 <= idx < len(c.args) and not isinstance(c.args[idx], ast.Starred):
                        arg = c.args[idx]
                for kw in c.keywords:
                    if kw.arg == name:
                        arg = kw.value
                if arg is None:
                    continue
                s, o = self.resolve(arg, self.enclosing_fn(c), seen, depth + 1)
                strs += s
                opq += o
        if not found:
            opq.append(f"name {name} (import/builtin/global)")
        return strs, opq

    def _call(self, node, fn, seen, depth):
        f = node.func
        name = f.id if isinstance(f, ast.Name) else (f.attr if isinstance(f, ast.Attribute) else None)
        args = list(node.args) + [k.value for k in node.keywords]

        def over(nodes):
            s, o = [], []
            for a in nodes:
                x, y = self.resolve(a, fn, seen, depth + 1)
                s += x
                o += y
            return s, o

        if name in NUMERIC_CALLS:
            return [], []
        if name in self.funcs and not (isinstance(f, ast.Attribute) and name in STR_METHODS):
            target = self.funcs[name]
            strs, opq = [], []
            for n in ast.walk(target):
                if isinstance(n, ast.Return) and n.value is not None \
                        and self.enclosing_fn(n) is target:
                    s, o = self.resolve(n.value, target, seen, depth + 1)
                    strs += s
                    opq += o
            return strs, opq
        if isinstance(f, ast.Attribute) and name in STR_METHODS:
            sv, ov = self.resolve(f.value, fn, seen, depth + 1)
            sa, oa = over(args)
            if name == "join" and sv and sa:
                return _cat([sa, sv]) + sa, ov + oa
            return sv + sa, ov + oa
        if name in TEXT_CALLS:
            return over(args)
        return [], [f"call {name or '<expr>'}()"]


def _site_value(node, parents):
    """(value-node-or-None, kind) for a Constant that mentions an emit key."""
    parent = parents.get(id(node))
    if isinstance(parent, ast.Expr):
        return None, "doc"
    if isinstance(parent, ast.Dict):
        for k, v in zip(parent.keys, parent.values):
            if k is node:
                return v, "dict"
        return None, "other"
    if isinstance(parent, ast.Subscript) and parent.slice is node:
        if isinstance(parent.ctx, ast.Store):
            asg = parents.get(id(parent))
            while asg is not None and not isinstance(asg, (ast.Assign, ast.AugAssign)):
                asg = parents.get(id(asg))
            return (asg.value if asg is not None else None), "subscript"
        return None, "read"
    if isinstance(parent, ast.keyword):
        return parent.value, "keyword"
    if isinstance(parent, ast.Compare):
        return None, "read"
    if isinstance(parent, ast.Call) and isinstance(parent.func, ast.Attribute) \
            and parent.func.attr in ("get", "pop", "setdefault") and parent.args \
            and parent.args[0] is node:
        if parent.func.attr == "setdefault" and len(parent.args) > 1:
            return parent.args[1], "setdefault"
        return None, "read"
    if isinstance(parent, ast.JoinedStr):
        return parent, "json"
    if isinstance(node.value, str) and node.value not in KEYS:
        return node, "json"          # the key is embedded in a longer string
    return None, "other"


def scan_python(path, rel):
    try:
        tree = ast.parse(open(path, encoding="utf-8").read())
    except (SyntaxError, OSError):
        return []
    rs = Resolver(tree)
    sites = []
    for n in ast.walk(tree):
        if not (isinstance(n, ast.Constant) and isinstance(n.value, str)
                and any(k in n.value for k in KEYS)):
            continue
        value, kind = _site_value(n, rs.parents)
        if kind in ("doc", "read"):
            continue
        fn = rs.enclosing_fn(n)
        if kind == "other":
            sites.append((n.lineno, kind, [], ["key not in a followable form"], fn))
            continue
        strs, opq = rs.resolve(value, fn, frozenset())
        sites.append((n.lineno, kind, strs, opq, fn))
    # keyword names (dict(additionalContext=...)) are ast.keyword.arg, not Constants
    for n in ast.walk(tree):
        if isinstance(n, ast.keyword) and n.arg in KEYS:
            fn = rs.enclosing_fn(n.value)
            strs, opq = rs.resolve(n.value, fn, frozenset())
            sites.append((n.value.lineno, "keyword", strs, opq, fn))
    return sites


_JQ_ARG = re.compile(r'--arg\s+\w+\s+"\$\{?(\w+)')


def scan_shell(path, rel):
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        return []
    code = [(i + 1, ln) for i, ln in enumerate(lines) if not ln.lstrip().startswith("#")]
    sites = []
    for i, (lineno, ln) in enumerate(code):
        if not any(k in ln for k in KEYS):
            continue
        window = " ".join(t for _, t in code[max(0, i - 4): i + 1])
        names = set(_JQ_ARG.findall(window))
        strs = [ln]
        for name in names:
            assign = re.compile(r"\b" + re.escape(name) + r"\w*(?:\[[^\]]*\])?\+?=")
            strs += [t for _, t in code if assign.search(t) or re.search(
                r"\b" + re.escape(name) + r"_PARTS\b", t)]
        opq = [] if names else ["no jq --arg variable feeds the key"]
        sites.append((lineno, "jq", strs, opq, None))
    return sites


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=os.path.join(os.path.dirname(__file__), "..", ".."))
    root = os.path.abspath(ap.parse_args().root)
    hooks = os.path.join(root, "core", "hooks")
    total = bad = allowed = 0
    unresolved = []
    for name in sorted(os.listdir(hooks)):
        path = os.path.join(hooks, name)
        if name.endswith(".py"):
            sites = scan_python(path, name)
        elif name.endswith(".sh"):
            sites = scan_shell(path, name)
        else:
            continue
        for lineno, kind, strs, opq, fn in sites:
            total += 1
            rel = "core/hooks/%s:%d" % (name, lineno)
            if opq:
                key = "%s:%s" % (name, fn.name if fn is not None else "<module>")
                if key in ALLOW:
                    allowed += 1
                else:
                    unresolved.append("%s (%s): %s" % (rel, kind, "; ".join(sorted(set(opq)))))
            for text in list(strs) + ["\n".join(strs)]:
                for hit in label_hits(text):
                    bad += 1
                    print("LABEL %s (%s): %r" % (rel, kind, hit))
    print("sites=%d unresolved=%d allowed=%d label_hits=%d"
          % (total, len(unresolved), allowed, bad))
    for u in unresolved:
        print("UNRESOLVED " + u)
    return 1 if (bad or unresolved) else 0


if __name__ == "__main__":
    sys.exit(main())
