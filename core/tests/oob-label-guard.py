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
     f-string — plus keys built by concatenation ("additional" + "Context"). A form
     that is none of those (the key text passed around as a bare value) is reported
     UNRESOLVED.
  2. Text: the strings that can flow into the value — constants, f-strings,
     concatenations (joined, so "co" + "hort" is seen as "cohort"), `.format` / `%`
     templates filled with their arguments, `json.dumps(dict)` rendered as the JSON
     it produces, name assignments, the return values of same-file functions (all
     same-named definitions), and one level of caller arguments or parameter
     defaults. Protocol constants (hookSpecificOutput, event names) are dropped.
  3. Anything left that cannot be followed makes the site UNRESOLVED, which FAILS:
     an imported name or unknown call, a parameter nobody in the file calls, a call
     through `*args` / `**kwargs` or on a receiver that may be the method's class,
     a state explosion past HARD_CAP in the concatenation of alternatives. ALLOW (file:function -> reason)
     is the only way to accept one.

Deliberate exemptions — not "unresolved", stated so the claim stays true:
  * A value interpolated into an f-string / `.format` / `%` is a runtime datum (counts,
    paths, tool output). Its literal fragments are still checked; what it cannot follow
    is ignored — EXCEPT (a) a name or attribute chain rooted at an imported, non-stdlib
    name (`f"{LBL}"` with `from labels import LBL`) and (b) a value placed right after a
    label word or sink field (`f"arm={arm}"`, `"cohort {}".format(assign())`,
    `f"guard={g()}"`), where the literal template already names the label and the
    value is the assignment: both are UNRESOLVED. "Right after" is wide on purpose: a
    label word, any run of separators (space, `= : #`, brackets, quotes, `. / \\ -`) and then a runtime value is
    UNRESOLVED wherever it sits — in prose (`bucket {x} is full`, `session cohort {x}`),
    in a path (`docs/arm/{x}`, `cohort_{x}.csv`), in a URL or in markdown (`[variant]({x})`).
    This is a deliberate false-positive budget: the guard is a fail-closed CI tripwire, a
    path or file name can carry a label as well as a sentence can (`cohort_treatment.csv`),
    and narrowing the rule (AG18 r0 tried) let `variant "{x}" selected`, `arm=/{x}` and
    `done.arm={x}` through. Remedy: reword so the noun and the value are apart
    (`f"{x} is full"`). Do not ALLOW it: ALLOW is per function and blinds all of it.
  * A key computed from a runtime or imported value (not from string constants) is
    invisible: nothing in the file says it will spell additionalContext.
  * Same-named definitions are unioned: an unrelated class's `build()` can be reported
    for another class's call site (conservative — it errs toward a false alarm).
  * Numbers render as their decimal text; `.N` truncation and `0N` padding specs are
    applied, other format specs only add spaces and are ignored.
  * Shell hooks: the guard follows `jq --arg` variables to their assignment lines
    and to same-file shell functions they call (3 levels; same-named definitions are
    merged, so look-alikes in heredoc text cannot hide a real definition; names may carry
    `:` and `.`: `lib::build`, `pkg.build`). A `name()` line is a definition only when a
    compound command follows (`{`, `(`, `if`, `for`, ...); a bare `flush()` is not. A line
    ending in an odd number of backslashes continues on the next one (`build() \\` then
    `{`) and is read joined; a continued line that still is no definition is unfollowable,
    not dropped. `name ( )` with inner spaces is a definition. Cost of the dotted-name
    rule: a Python `self.end()` in a heredoc, followed by an `if ...:` line, reads as a
    definition `self.end`, so a jq message that mentions `self.end` is UNRESOLVED
    (fail-closed; reword the message).
    A function whose body is not a `{ }` group (`f() ( ... )`, `f() if ...`) is not
    parsed, and calling it is UNRESOLVED. Output of external commands is runtime data.
  * Cost: each emit site has a work budget (WORK_CAP string joins and node visits);
    past it the site is UNRESOLVED instead of enumerating every alternative. A computed
    key (`{"additional" + "Context": ...}`, `d[k] = ...`) gets a fresh budget per probe,
    and a key the resolver gave up on (budget, depth, state explosion) is itself an
    UNRESOLVED site; a key that is merely a runtime value stays invisible, as above.

Usage: oob-label-guard.py [--root DIR]   (exit 1 on a label hit or an unresolved site)
"""
from __future__ import annotations

import argparse
import ast
import itertools
import json
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
SAFE_MODULES = {"os", "sys", "json", "time", "re", "stat", "hashlib", "datetime", "pathlib",
                "tempfile", "fcntl", "shutil", "subprocess", "itertools", "contextlib",
                "string", "textwrap", "typing", "collections", "functools"}
NUMERIC_CALLS = {"int", "float", "len", "bool", "round", "abs", "sum", "range", "time",
                 "monotonic", "getpid", "isinstance", "hexdigest", "digest"}
TEXT_CALLS = {"str", "repr", "format", "sorted", "list", "tuple", "set", "basename",
              "dirname", "join", "relpath", "abspath", "getattr", "next", "min", "max"}
STR_METHODS = {"join", "strip", "lstrip", "rstrip", "replace", "lower", "upper", "title",
               "capitalize", "splitlines", "split", "get", "items", "values", "keys",
               "append", "encode", "decode", "removeprefix", "removesuffix", "ljust",
               "rjust", "center", "expandtabs"}
MAX_COMBOS = 64      # candidates kept verbatim before compressing to hits + tail
TAIL = 48            # chars kept after compression; label patterns are shorter
HARD_CAP = 4096      # distinct compressed tails before a site is called unresolved
WORK_CAP = 250000     # string joins + node visits per emit site before it is called unresolved
KEY_GAVE_UP = "computed key not followed: the resolver gave up on it (budget or depth)"
BUDGET_MSG = "work budget exceeded (%d steps): too many alternatives to enumerate" % WORK_CAP


def _gave_up(opq):
    """True when the resolver stopped short (budget, depth, state explosion) instead of
    meeting an ordinary runtime value."""
    return any(o == BUDGET_MSG or o == "too deep" or o.startswith("combinatorial") for o in opq)

_WORDS = [
    # assignment / identifier forms only — "experiment with X", "variant of the plan",
    # "an experimental flag", "bucket names must be lowercase" are ordinary prose.
    re.compile(r"(?i)\bhold-?out\b"),
    re.compile(r"\b(?:cohort|variant|arm|bucket)\s+(?:[A-Z]\b|\d+\b)"),
    re.compile(r"(?i)\b(?:experiment|cohort|variant|arm|bucket)[_-](?:id|name|label|group)\b"),
    re.compile(r"(?i)\b(?:experiment|cohort|variant|arm|bucket)[ _-]?(?:id|name|label|group)"
               r"\s*[=:]\s*\S"),
    re.compile(r"(?i)\b(?:experiment|cohort|variant|arm|bucket)\s*[=:]\s*"
               r"(?:control|treatment|holdout|on|off|[A-Z]\b|\d+\b)"),
    re.compile(r"(?i)\b(?:control|treatment)[ -]group\b|\ba/b[ -]test\b"),
]
_Q = r"""(?:\\?["'])"""        # a quote, plain or backslash-escaped (nested dumps / repr)
_FIELDS = [
    re.compile(r"(?<![\w-])(?:guard|gate_id|reproduce_test|schema_version|sig_sha)\s*=\s*\S"),
    re.compile(r"(?<![\w-])(?:gate_id|reproduce_test|schema_version|sig_sha)\s*:\s*\S"),
    re.compile(_Q + r"(?:guard|gate_id|reproduce_test|schema_version|sig_sha)" + _Q + r"\s*:"),
]


def label_hits(text):
    return [m.group(0) for rx in _WORDS + _FIELDS for m in rx.finditer(text)]


SENT = "\ufffc"      # stands in for an interpolated value the guard cannot follow
# separators allowed between a label word and the value: spaces, = : # brackets,
# quotes, slashes, dots, dashes — "arm=[{x}]", 'arm="{x}"', "cohort #{x}", "variant/{x}"
_SEP = r"""[\s=:#\[\]()<>'"`./\\-]*"""  # separator class
_RUNTIME = re.compile(
    r"(?i)\b(?:experiment|cohort|variant|arm|bucket)[ _-]?(?:id|name|label|group)?" + _SEP
    + SENT + r"|(?<![\w-])(?:guard|gate_id|reproduce_test|schema_version|sig_sha)\s*[=:]"
    + _SEP + SENT)


def runtime_hits(text):
    if SENT not in text:                       # every runtime form needs the sentinel
        return []
    return [m.group(0).replace(SENT, "{…}") for m in _RUNTIME.finditer(text)]


_FMT_TOKEN = re.compile(
    r"\{\{|\}\}|\{([A-Za-z_]\w*|\d*)((?:\.\w+|\[[^\]]*\])*)(?:![rsa])?"
    r"(?::((?:[^{}]|\{[^{}]*\})*))?\}")
_PCT_TOKEN = re.compile(r"%%|%(?:\((\w+)\))?[-#0 +]*(\d*)(?:\.(\d+))?([sdifrxXcgeE])")
_SPEC = re.compile(r"^(?:.?[<>^=])?[+\- ]?#?(0?)(\d*),?(?:\.(\d+))?([a-zA-Z%]?)$")


def _apply_spec(val, spec):
    """Effect of a format spec on a candidate string: `.N` truncates text,
    `0N` zero-pads a number; width/alignment/sign only add spaces."""
    m = _SPEC.match(spec or "")
    if not m:
        return val
    zero, width, prec, kind = m.groups()
    if prec and kind in ("", "s"):
        return val[:int(prec)]
    if zero and width and val.isdigit():
        return val.zfill(int(width))
    return val


def _compress(text):
    hits = (label_hits(text) + ([m.group(0) for m in _RUNTIME.finditer(text)]
                                if SENT in text else []) if len(text) > TAIL else [])
    return ("\n".join(hits) + "\n" if hits else "") + text[-TAIL:]


class Resolver:
    def __init__(self, tree):
        self.tree = tree
        self.parents = {}
        self.assigns = {}
        self.funcs = {}
        self.calls = {}
        self.imported = {}
        self.dict_sets = {}
        self.work = 0
        for n in ast.walk(tree):
            for c in ast.iter_child_nodes(n):
                self.parents[id(c)] = n
        for n in ast.walk(tree):
            if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)):
                self.funcs.setdefault(n.name, []).append(n)
            elif isinstance(n, ast.Import):
                for a in n.names:
                    self.imported[(a.asname or a.name).split(".")[0]] = a.name.split(".")[0]
            elif isinstance(n, ast.ImportFrom):
                root = ("." * n.level + (n.module or "")).split(".")[0] or "."
                for a in n.names:
                    self.imported[a.asname or a.name] = root
            elif isinstance(n, ast.Assign):
                for t in n.targets:
                    if isinstance(t, ast.Subscript) and isinstance(t.value, ast.Name):
                        self.dict_sets.setdefault((t.value.id, id(self.enclosing_fn(n))),
                                                  []).append((t.slice, n.value))
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
                if isinstance(f, ast.Attribute) and isinstance(f.value, ast.Name):
                    dkey = (f.value.id, id(self.enclosing_fn(n)))
                    if f.attr == "update":
                        for kw in n.keywords:
                            if kw.arg:
                                self.dict_sets.setdefault(dkey, []).append(
                                    (ast.Constant(kw.arg), kw.value))
                        for a in n.args:
                            if isinstance(a, ast.Dict):
                                self.dict_sets.setdefault(dkey, []).extend(zip(a.keys, a.values))
                    elif f.attr == "setdefault" and len(n.args) >= 2:
                        self.dict_sets.setdefault(dkey, []).append((n.args[0], n.args[1]))
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

    def enclosing_class(self, fn):
        p = self.parents.get(id(fn))
        return p if isinstance(p, ast.ClassDef) else None

    def params(self, fn):
        a = fn.args
        return [x.arg for x in list(a.posonlyargs) + list(a.args) + list(a.kwonlyargs)]

    def default_of(self, fn, name):
        a = fn.args
        pos = list(a.posonlyargs) + list(a.args)
        if a.defaults:
            tail = pos[len(pos) - len(a.defaults):]
            for p, d in zip(tail, a.defaults):
                if p.arg == name:
                    return d
        for p, d in zip(a.kwonlyargs, a.kw_defaults):
            if p.arg == name and d is not None:
                return d
        return None

    def spend(self, n):
        """Charge n steps to the site being resolved; True once the budget is gone."""
        self.work += n
        return self.work > WORK_CAP

    def cat(self, parts, opq):
        """Join fragment alternatives so a label split across fragments is seen.

        Past MAX_COMBOS the candidates are compressed to "label hits found so far +
        the last TAIL characters": every later match that starts in the tail is still
        found (label patterns are far shorter than TAIL) and every earlier match is
        kept verbatim, so nothing is dropped. Only a state explosion beyond
        HARD_CAP distinct tails is reported as unresolved."""
        cur = [""]
        for part in parts:
            part = part or [""]
            if self.spend(len(cur) * len(part)):
                opq.append(BUDGET_MSG)
                return cur
            nxt = dict.fromkeys(a + b for a in cur for b in part)
            if len(nxt) > MAX_COMBOS:
                if self.spend(4 * len(nxt)):
                    opq.append(BUDGET_MSG)
                    return cur
                nxt = dict.fromkeys(_compress(x) for x in nxt)
            if len(nxt) > HARD_CAP:
                opq.append("combinatorial expansion beyond %d distinct tails" % HARD_CAP)
                return list(itertools.islice(nxt, HARD_CAP))     # stop at the first overflow
            cur = list(nxt)
        return cur

    def resolve(self, node, fn, seen, depth=0):
        """-> (candidate strings, opaque reasons)."""
        if node is None:
            return [], []
        if depth > 40:
            return [], ["too deep"]
        if self.spend(1):
            return [], [BUDGET_MSG]
        r = lambda n, f=fn: self.resolve(n, f, seen, depth + 1)  # noqa: E731
        if isinstance(node, ast.Constant):
            if isinstance(node.value, str) and node.value not in PROTOCOL:
                return [node.value], []
            if isinstance(node.value, (int, float)) and not isinstance(node.value, bool):
                return [str(node.value)], []
            return [], []
        if isinstance(node, ast.JoinedStr):
            parts, op = [], []
            for v in node.values:
                if isinstance(v, ast.FormattedValue):
                    # an interpolated value is a runtime datum: its literal fragments
                    # are still checked, what it cannot follow is ignored — except an
                    # imported non-stdlib name, which may be a constant defined elsewhere.
                    if self._is_dictlike(v.value, fn):
                        s, _ = self._render(v.value, fn, seen, depth + 1, "repr")
                    else:
                        s, vo = r(v.value)
                        if not s or vo:
                            s = s + [SENT]        # a value the guard cannot see
                    spec = "".join(c.value for c in (v.format_spec.values if v.format_spec else [])
                                   if isinstance(c, ast.Constant) and isinstance(c.value, str))
                    if spec:
                        s = [_apply_spec(val, spec) for val in s]
                    base = v.value
                    while isinstance(base, (ast.Attribute, ast.Subscript)):
                        base = base.value
                    if isinstance(base, ast.Name) and base.id in self.imported \
                            and self.imported[base.id] not in SAFE_MODULES:
                        op.append("imported name %s interpolated" % base.id)
                else:
                    s, o = r(v)
                    op += o
                parts.append(s)
            return self.cat(parts, op), op
        if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Mult):
            for text_node, num in ((node.left, node.right), (node.right, node.left)):
                if isinstance(num, ast.Constant) and isinstance(num.value, int) \
                        and not isinstance(num.value, bool) and 0 <= num.value <= 256 \
                        and not (isinstance(text_node, ast.Constant)
                                 and not isinstance(text_node.value, str)):
                    ts, to = r(text_node)
                    if ts:
                        return [t * num.value for t in ts if len(t) * num.value <= 8192], to
        if isinstance(node, ast.BinOp):
            ls, lo = r(node.left)
            if isinstance(node.op, ast.Mod) and ls:
                return self._percent(node, ls, lo, fn, seen, depth)
            rs, ro = r(node.right)
            op = lo + ro
            if isinstance(node.op, ast.Add) and ls and rs:
                return self.cat([ls, rs], op), op
            return ls + rs, op
        if isinstance(node, ast.IfExp):
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
            return s, o + ["attribute .%s" % node.attr]
        s, o = [], []
        for c in ast.iter_child_nodes(node):
            if isinstance(c, (ast.expr, ast.comprehension, ast.keyword)):
                cs, co = r(c)
                s += cs
                o += co
        return s, o

    def _is_dictlike(self, node, fn):
        return isinstance(node, ast.Dict) or (
            isinstance(node, ast.Name) and bool(self._dict_pairs(node, fn)))

    def _dict_pairs(self, node, fn):
        """(key-node, value-node) pairs of a dict literal or of a Name holding one
        (literal assignments plus `d[k] = v` stores); [] when it is not a dict."""
        if isinstance(node, ast.Dict):
            return list(zip(node.keys, node.values))
        if not isinstance(node, ast.Name):
            return []
        name = node.id
        pairs, found = [], False
        for sc in [id(fn)] + ([id(None)] if fn is not None else []):
            for v in self.assigns.get((name, sc), []):
                if isinstance(v, ast.Dict):
                    found = True
                    pairs += list(zip(v.keys, v.values))
            if found:
                break
        pairs += self.dict_sets.get((name, id(fn)), []) + self.dict_sets.get((name, id(None)), [])
        return pairs if (found or pairs) else []

    def _cands(self, node, fn, seen, depth):
        """One template argument -> candidate list; runtime data (empty) -> ['']."""
        if self._is_dictlike(node, fn):
            return self._render(node, fn, seen, depth + 1, "repr")[0] or [""]
        s, o = self.resolve(node, fn, seen, depth + 1)
        return s + [SENT] if (not s or o) else s

    def _kw_from(self, node, fn, seen, depth):
        """Mapping name -> candidates from a dict literal / dict variable."""
        out = {}
        for k, v in self._dict_pairs(node, fn):
            if isinstance(k, ast.Constant) and isinstance(k.value, str):
                out[k.value] = self._cands(v, fn, seen, depth)
        return out

    def _template(self, tmpls, kind, pos, kw, op):
        """Fill str.format ('format') or %-style ('percent') templates; pos is a
        list of candidate lists, kw a name -> candidate-list map."""
        out = []
        for t in tmpls:
            parts, last, auto = [], 0, 0
            if kind == "format":
                for m in _FMT_TOKEN.finditer(t):
                    parts.append([t[last:m.start()]])
                    last = m.end()
                    if m.group(0) in ("{{", "}}"):
                        parts.append([m.group(0)[0]])
                        continue
                    key, spec = m.group(1), m.group(3) or ""
                    if key == "":
                        key, auto = str(auto), auto + 1
                    if "{" in spec:          # nested {} in the spec consume arguments too
                        auto += spec.count("{")
                        spec = ""
                    vals = pos[int(key)] if key.isdigit() and int(key) < len(pos) \
                        else kw.get(key, [""])
                    parts.append([_apply_spec(val, spec) for val in vals])
            else:
                for m in _PCT_TOKEN.finditer(t):
                    parts.append([t[last:m.start()]])
                    last = m.end()
                    if m.group(0) == "%%":
                        parts.append(["%"])
                        continue
                    name, prec, conv = m.group(1), m.group(3), m.group(4)
                    if name:
                        vals = kw.get(name, [""])
                    else:
                        vals = pos[auto] if auto < len(pos) else [""]
                        auto += 1
                    if prec and conv in ("s", "r"):
                        vals = [val[:int(prec)] for val in vals]
                    parts.append(vals)
            parts.append([t[last:]])
            out += self.cat(parts, op)
        return out

    def _percent(self, node, tmpls, lopq, fn, seen, depth):
        right = node.right
        pos, kw = [], {}
        if isinstance(right, ast.Tuple):
            pos = [self._cands(e, fn, seen, depth) for e in right.elts]
        elif self._is_dictlike(right, fn):
            kw = self._kw_from(right, fn, seen, depth)
        else:
            pos = [self._cands(right, fn, seen, depth)]
        return self._template(tmpls, "percent", pos, kw, lopq), lopq

    def _render(self, node, fn, seen, depth, style="json"):
        """(candidate text, opaque reasons) of str()/json.dumps() applied to node."""
        quote = json.dumps if style == "json" else repr
        if depth > 40:
            return ["0"], ["too deep"]
        if isinstance(node, ast.Constant):
            return [quote(node.value)], []
        if isinstance(node, (ast.Dict, ast.List, ast.Tuple, ast.Set)) \
                or (isinstance(node, ast.Name) and self._dict_pairs(node, fn)):
            if isinstance(node, ast.Name):
                key = ("render", node.id, id(fn))
                if key in seen:
                    return ["{}"], ["cyclic structure"]
                seen = seen | {key}
            op, parts = [], []
            if isinstance(node, (ast.Dict, ast.Name)):
                pairs = self._dict_pairs(node, fn)
                parts.append(["{"])
                for i, (k, v) in enumerate(pairs):
                    if i:
                        parts.append([", "])
                    if k is None:
                        op.append("dict ** unpacking")
                        continue
                    kt, ko = self._render(k, fn, seen, depth + 1, style)
                    vt, vo = self._render(v, fn, seen, depth + 1, style)
                    parts += [kt, [": "], vt]
                    op += ko + vo
                parts.append(["}"])
            else:
                o_, c_ = ("[", "]") if isinstance(node, ast.List) else ("(", ")")
                parts.append([o_])
                for i, e in enumerate(node.elts):
                    if i:
                        parts.append([", "])
                    et, eo = self._render(e, fn, seen, depth + 1, style)
                    parts.append(et)
                    op += eo
                parts.append([c_])
            return self.cat(parts, op), op
        s, op = self.resolve(node, fn, seen, depth + 1)
        return [quote(x) for x in s] or ["0"], op

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
        for sc in [id(fn)] + ([id(None)] if fn is not None else []):
            for v in self.assigns.get((name, sc), []):
                found = True
                s, o = self.resolve(v, self.enclosing_fn(v), seen, depth + 1)
                strs += s
                opq += o
            if found:
                break
        if fn is not None and name in self.params(fn):
            found = True
            s, o = self._param(fn, name, seen, depth)
            strs += s
            opq += o
        if not found:
            opq.append("name %s (import/builtin/global)" % name)
        return strs, opq

    def _param(self, fn, name, seen, depth):
        """Values of parameter `name`: caller arguments, else the default."""
        strs, opq = [], []
        plist = self.params(fn)
        cls = self.enclosing_class(fn)
        offset = 1 if cls is not None and plist and plist[0] in ("self", "cls") else 0
        callers = []
        for c in self.calls.get(fn.name, []):
            f = c.func
            if isinstance(f, ast.Name):
                callers.append(c)
            elif isinstance(f, ast.Attribute) and cls is not None:
                recv = f.value
                if isinstance(recv, ast.Name) and recv.id in ("self", "cls", cls.name):
                    callers.append(c)
                else:
                    opq.append("ambiguous receiver for .%s()" % fn.name)
        if not callers:
            opq.append("parameter %s of %s() has no in-file caller" % (name, fn.name))
        for c in callers:
            if any(isinstance(a, ast.Starred) for a in c.args) \
                    or any(k.arg is None for k in c.keywords):
                opq.append("%s() called with */** unpacking" % fn.name)
                continue
            arg = None
            idx = plist.index(name) - offset
            if 0 <= idx < len(c.args):
                arg = c.args[idx]
            for kw in c.keywords:
                if kw.arg == name:
                    arg = kw.value
            if arg is None:
                arg = self.default_of(fn, name)
                if arg is None:
                    continue
                s, o = self.resolve(arg, fn, seen, depth + 1)
            else:
                s, o = self.resolve(arg, self.enclosing_fn(c), seen, depth + 1)
            strs += s
            opq += o
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
        if name == "dumps" and node.args:
            return self._render(node.args[0], fn, seen, depth + 1)
        if name in ("str", "repr") and node.args and self._is_dictlike(node.args[0], fn):
            return self._render(node.args[0], fn, seen, depth + 1, "repr")
        if name in self.funcs and not (isinstance(f, ast.Attribute) and name in STR_METHODS):
            strs, opq = [], []
            for target in self.funcs[name]:
                for n in ast.walk(target):
                    if isinstance(n, ast.Return) and n.value is not None \
                            and self.enclosing_fn(n) is target:
                        s, o = self.resolve(n.value, target, seen, depth + 1)
                        strs += s
                        opq += o
            return strs, opq
        if isinstance(f, ast.Attribute) and name == "format":
            tm, to = self.resolve(f.value, fn, seen, depth + 1)
            if tm:
                pos = [self._cands(a, fn, seen, depth) for a in node.args]
                kw = {k.arg: self._cands(k.value, fn, seen, depth) for k in node.keywords if k.arg}
                for k in node.keywords:
                    if k.arg is None:
                        kw.update(self._kw_from(k.value, fn, seen, depth))
                return self._template(tm, "format", pos, kw, to), to
            return over(args)
        if isinstance(f, ast.Attribute) and name == "join":
            sv, ov = self.resolve(f.value, fn, seen, depth + 1)
            seq = node.args[0] if node.args else None
            if isinstance(seq, (ast.List, ast.Tuple, ast.Set)) and seq.elts and sv:
                parts, op = [], list(ov)
                for i, e in enumerate(seq.elts):
                    es, eo = self.resolve(e, fn, seen, depth + 1)
                    if i:
                        parts.append(sv)
                    parts.append(es)
                    op += eo
                return self.cat(parts, op), op
            sa, oa = over(args)
            if sv and sa:
                op = ov + oa
                return self.cat([sa, sv], op) + sa, op
            return sv + sa, ov + oa
        if isinstance(f, ast.Attribute) and name in STR_METHODS:
            sv, ov = self.resolve(f.value, fn, seen, depth + 1)
            sa, oa = over(args)
            return sv + sa, ov + oa
        if name in TEXT_CALLS:
            return over(args)
        return [], ["call %s()" % (name or "<expr>")]


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
            return _store_value(parent, parents), "subscript"
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


def _store_value(sub, parents):
    asg = parents.get(id(sub))
    while asg is not None and not isinstance(asg, (ast.Assign, ast.AugAssign, ast.AnnAssign)):
        asg = parents.get(id(asg))
    return asg.value if asg is not None else None


def scan_python(path, rel):
    try:
        tree = ast.parse(open(path, encoding="utf-8").read())
    except (SyntaxError, OSError) as exc:
        # a file the guard cannot read is a blind spot, never a pass
        return [(1, "parse", [], ["cannot parse: %s" % exc], None)]
    rs = Resolver(tree)
    sites = []

    def add(lineno, kind, value, anchor):
        fn = rs.enclosing_fn(anchor)
        rs.work = 0                            # the budget is per emit site
        strs, opq = rs.resolve(value, fn, frozenset())
        sites.append((lineno, kind, strs, opq, fn))

    def probe(node):
        """Texts a computed key can spell, and whether the resolver gave up on it. Each
        probe gets a fresh budget: one expensive key must not blind the next."""
        rs.work = 0
        strs, opq = rs.resolve(node, rs.enclosing_fn(node), frozenset())
        return strs, _gave_up(opq)

    for n in ast.walk(tree):
        if isinstance(n, ast.Constant) and isinstance(n.value, str) \
                and any(k in n.value for k in KEYS):
            value, kind = _site_value(n, rs.parents)
            if kind in ("doc", "read"):
                continue
            if kind == "other":
                sites.append((n.lineno, kind, [], ["key not in a followable form"],
                              rs.enclosing_fn(n)))
                continue
            add(n.lineno, kind, value, n)
        elif isinstance(n, ast.keyword) and n.arg in KEYS:
            add(n.value.lineno, "keyword", n.value, n.value)
        elif isinstance(n, ast.Dict):
            # keys built from string constants: {"additional" + "Context": ...}
            for k, v in zip(n.keys, n.values):
                if k is None or isinstance(k, ast.Constant):
                    continue
                texts, gave_up = probe(k)
                if any(c in KEYS for c in texts):
                    add(k.lineno, "dict", v, n)
                elif gave_up:
                    sites.append((k.lineno, "key", [], [KEY_GAVE_UP], rs.enclosing_fn(n)))
        elif isinstance(n, ast.Subscript) and isinstance(n.ctx, ast.Store) \
                and not isinstance(n.slice, ast.Constant):
            texts, gave_up = probe(n.slice)
            if any(c in KEYS for c in texts):
                add(n.lineno, "subscript", _store_value(n, rs.parents), n)
            elif gave_up:
                sites.append((n.lineno, "key", [], [KEY_GAVE_UP], rs.enclosing_fn(n)))
    return sites


_JQ_ARG = re.compile(r'--arg\s+\w+\s+"\$\{?(\w+)')
_SH_NAME = r"[A-Za-z_][\w:.-]*"           # lib::build  pkg.build  my-fn
_SH_FUNC = re.compile(
    r"^\s*(?:function\s+(" + _SH_NAME + r")\s*(?:\(\s*\))?|(" + _SH_NAME
    + r")\s*\(\s*\))\s*(.*)$")
# What may follow `name()`: a compound command. A bare `flush()` line (a Python call inside
# a heredoc, say) is no definition at all.
_SH_BODY = re.compile(r"\{|\(|(?:if|for|while|until|case|select)\b|\[\[")
_HEREDOC = re.compile(r"(?<!<)<<(?!<)-?\s*([\"']?)(\w+)\1")


class _Joined(str):
    """A logical line made of several physical lines (backslash continuation)."""


_CONT = re.compile(r"(\\+)$")


def _logical_lines(lines):
    """[(first line number, text)] with `\\`-continued lines joined, as bash reads them:
    a line ending in an ODD number of backslashes continues on the next one (the pair
    disappears), so `build() \\` + `{` is the definition `build() {`. A line that is, or
    ends in, a comment does not continue. A continuation that runs into EOF keeps its
    backslash; the definition parser treats that as unfollowable."""
    out, i = [], 0
    while i < len(lines):
        no, text, joined = i + 1, lines[i], False
        i += 1
        while True:
            m = _CONT.search(text)
            commentish = text.lstrip().startswith("#") or re.search(r"\s#", text)
            if not m or len(m.group(1)) % 2 == 0 or commentish or i >= len(lines):
                break
            text = text[:-1] + lines[i]
            joined = True
            i += 1
        out.append((no, _Joined(text) if joined else text))
    return out


def _braces(line):
    """Net `{` minus `}` of a shell line; escaped, ${...} and quoted braces do not count."""
    t = re.sub(r"\\.", "", line)                       # \{ \} are literal
    t = re.sub(r"\$\{[^}]*\}", "", t)                   # ${...} expansions
    t = re.sub(r"\"[^\"]*\"|'[^']*'", "", t)             # quoted text
    return t.count("{") - t.count("}")


def _next_line(code, i):
    """Index of the next non-blank line after i, or None."""
    j = i + 1
    while j < len(code) and not code[j][1].strip():
        j += 1
    return j if j < len(code) else None


def _shell_functions(code):
    """name -> (body lines, followable). A `{ }` body is brace-counted outside
    quotes, escapes and heredoc bodies, so a `}` printed by the function does not end
    it early. Same-named definitions are merged, never replaced, so a look-alike
    `build()` in heredoc text cannot hide the real one. A `name()` line counts as a
    definition only when a compound command follows it (`{`, `(`, `if`, `for`, `while`,
    `until`, `case`, `select`, `[[`), here or on the next non-blank line: a bare call such
    as a Python `flush()` inside a heredoc defines nothing. A definition whose body is
    not a `{ }` group (`( ... )`, `if`, ...) is not parsed: it is marked unfollowable,
    which fails any site that calls it."""
    funcs = {}
    for i, (_, ln) in enumerate(code):
        # No heredoc skipping at this level: a `<<` is not always a heredoc ($((1<<2)),
        # let, quoted text) and a wrong guess would swallow every later definition.
        # A look-alike inside a real heredoc only adds text or an empty body to the merge.
        m = _SH_FUNC.match(ln)
        if not m:
            continue
        name = m.group(1) or m.group(2)
        tail = m.group(3).strip()
        if tail.startswith("#"):               # `build() # note` — the comment is not the body
            tail = ""
        rest, j = None, i + 1
        # A joined line that still is not a definition is not dropped: it is unfollowable.
        unsure = isinstance(ln, _Joined) or tail == "\\"
        if tail == "":
            nl = _next_line(code, i)
            if nl is None or not _SH_BODY.match(code[nl][1].strip()):
                if unsure:
                    tail = "\\"
                else:
                    continue                   # not followed by a compound command: no definition
            else:
                tail, j = code[nl][1].strip(), nl + 1
        elif not _SH_BODY.match(tail) and not unsure:
            continue
        if tail.startswith("{"):
            rest = tail[1:]
        if rest is None:                       # body is not a { } group
            body, ok = [], False
        else:
            body = [rest]
            depth = 1 + _braces(rest)
            tag = None
            while depth > 0 and j < len(code):
                nxt = code[j][1]
                body.append(nxt)
                j += 1
                if tag is not None:
                    if nxt.strip() == tag:
                        tag = None
                    continue
                depth += _braces(nxt)
                hd2 = _HEREDOC.search(nxt)
                if hd2:
                    tag = hd2.group(2)
            ok = depth <= 0
        old_body, old_ok = funcs.get(name, ([], True))
        funcs[name] = (old_body + body, old_ok and ok)
    return funcs


def scan_shell(path, rel):
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        return []
    code = [(no, ln) for no, ln in _logical_lines(lines) if not ln.lstrip().startswith("#")]
    funcs = _shell_functions(code)
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
        done, unterminated = set(), []
        for _ in range(3):                      # follow same-file functions, 3 levels
            blob = "\n".join(strs)
            new = [f for f in funcs if f not in done
                   and re.search(r"(?<![\w-])" + re.escape(f) + r"(?![\w-])", blob)]
            if not new:
                break
            for f in new:
                done.add(f)
                strs += funcs[f][0]
                if not funcs[f][1]:
                    unterminated.append(f)
        opq = [] if names else ["no jq --arg variable feeds the key"]
        opq += ["cannot follow shell function %s() (no { } body or no closing brace)" % f
                for f in unterminated]
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
            rt = sorted({h for text in list(strs) + ["\n".join(strs)] for h in runtime_hits(text)})
            if rt:
                opq = list(opq) + ["label word followed by a runtime value: " + ", ".join(
                    repr(h) for h in rt)]
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
