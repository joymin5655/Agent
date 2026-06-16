#!/usr/bin/env python3
"""Additive, fail-safe loader for project-specific secret-scan extensions.

This module lets a project SPECIALIZE the generic secret-content-scan.py hook
WITHOUT forking the plugin. A consumer drops a `.agent/hook-config.yml` (or
`.agent/hook-config.json`) at its repo root carrying extra secret patterns,
extra exempt paths, and extra credential key names. The hook appends those to
its built-ins at runtime.

SECURITY MODEL — ADDITIVE ONLY (hard rule):
    The loader can ONLY return EXTRA patterns / exempts / key-names that the
    hook APPENDS to its hardcoded built-ins. There is intentionally NO mechanism
    to remove, disable, override, or relax a built-in pattern, nor to flip a
    decision from `deny` to `allow`. A malicious or careless config can only
    make the scan STRICTER, never weaker. Built-ins always remain and run first.

    BOUNDED EXEMPTS: exempt_paths is additive but cannot exempt the universe.
    An exempt fragment is dropped unless at least one of its alphanumeric
    segments is >= 3 chars. This rejects over-broad fragments like "/", ".",
    "..", "./", ".ts", ".js" (which, under substring matching, would skip
    scanning EVERY file and silently flip built-in `deny` into `allow`), while
    still allowing specific whitelists like ".env", "/src/", "secrets/".

FAIL-SAFE:
    The loader NEVER raises. Any problem — missing file, unreadable file, bad
    YAML/JSON, wrong top-level shape, non-list values, non-str entries,
    malformed pattern pairs — results in that bad input being silently dropped,
    degrading to empty extensions. A broken config therefore reduces the hook to
    its built-in behavior; it can never crash the hook or weaken it.

    CONFIG REGEX SAFETY (defense in depth): a config-supplied secret regex is
    validated by `re.compile` (SYNTAX only — note re.compile does NOT detect
    catastrophic backtracking), capped at 200 chars, and screened by a
    nested-quantifier heuristic (drops `(a+)+`, `(a*)*`, `(.+)+` style). Any
    config regex that survives those screens is still bounded AT RUNTIME by a 2s
    SIGALRM watchdog in secret-content-scan.py (where SIGALRM is available), so a
    catastrophic-backtracking config pattern is time-bounded, never hangs the
    session, and can never lose built-in detection. Built-in patterns are
    trusted and exempt from the config-only screens.

Config schema (top-level, or nested under `python_hooks:`):
    python_hooks:
      secret_patterns:                 # appended to built-in SECRET_PATTERNS
        - ["myco_secret_[A-Za-z0-9]{20,}", "MyCo internal token"]
      exempt_paths:                    # appended to built-in EXEMPT_PATHS
        - "vendor/fixtures/"
      credential_key_names:            # folded into one extra key-value pattern
        - "MYCO_SERVICE_TOKEN"

Both `.agent/hook-config.yml` (only if PyYAML importable) and
`.agent/hook-config.json` are read when present; their lists are concatenated.
"""
import json
import os
import re

# Defensive caps — bound config influence so a pathological config cannot
# explode scan cost or memory.
_MAX_PATTERNS = 100
_MAX_EXEMPTS = 100
_MAX_KEY_NAMES = 100

_EMPTY = {"secret_patterns": [], "exempt_paths": [], "credential_key_names": []}


def _empty():
    return {"secret_patterns": [], "exempt_paths": [], "credential_key_names": []}


def _coerce_str_list(value, limit):
    """Return up to `limit` str entries from `value` (a list); drop everything else."""
    out = []
    if not isinstance(value, list):
        return out
    for item in value:
        if isinstance(item, str) and item:
            out.append(item)
            if len(out) >= limit:
                break
    return out


def _coerce_exempt_list(value, limit):
    """Return up to `limit` exempt-path fragments from `value` (a list).

    Like `_coerce_str_list` but ALSO drops over-broad fragments that would
    exempt the universe. A fragment is kept only if at least one of its
    alphanumeric segments is >= 3 chars. This drops "/", ".", "..", "./",
    "/a/b/", ".ts", ".js" (a config can no longer whitelist everything via a
    substring match), while keeping ".env", "/src/", ".test.", "secrets/",
    "config/", etc. Exempt paths stay additive — bounded, never the universe.
    """
    out = []
    if not isinstance(value, list):
        return out
    for item in value:
        if not isinstance(item, str) or not item:
            continue
        segments = re.findall(r"[A-Za-z0-9]+", item)
        if not any(len(seg) >= 3 for seg in segments):
            # Over-broad fragment (no segment >= 3 chars) — would exempt too
            # much under substring matching. Drop it.
            continue
        out.append(item)
        if len(out) >= limit:
            break
    return out


# Hard length cap on a single config regex (chars). Anything longer is dropped
# before it can reach scan — bounds both compile cost and worst-case backtracking.
_MAX_REGEX_LEN = 200

# Nested-quantifier heuristic for catastrophic backtracking. Matches a group
# `(...)` or char-class `[...]` that itself contains a quantifier (`+`/`*`),
# immediately followed by another quantifier — i.e. `(a+)+`, `(a*)*`, `(.+)+`
# style. Config patterns matching this are dropped (built-ins are exempt).
_NESTED_QUANTIFIER = re.compile(r"(\([^)]*[+*][^)]*\)|\[[^\]]*\])\s*[*+]")


def _coerce_pattern_list(value, limit):
    """Return up to `limit` [regex, label] pairs from `value`.

    Each accepted entry is a 2-element list/tuple of non-empty strings. A config
    regex is dropped (never raised) when it: fails to compile (syntax), exceeds
    `_MAX_REGEX_LEN` chars, OR matches the nested-quantifier heuristic indicating
    catastrophic backtracking. Built-in patterns are trusted and NOT subject to
    these config-only screens.
    """
    out = []
    if not isinstance(value, list):
        return out
    for item in value:
        if not isinstance(item, (list, tuple)) or len(item) != 2:
            continue
        regex, label = item[0], item[1]
        if not isinstance(regex, str) or not isinstance(label, str):
            continue
        if not regex or not label:
            continue
        if len(regex) > _MAX_REGEX_LEN:
            # Over-long config regex — drop before it reaches scan.
            continue
        if _NESTED_QUANTIFIER.search(regex):
            # Nested-quantifier (catastrophic-backtracking) heuristic — drop.
            continue
        try:
            re.compile(regex)
        except (re.error, RecursionError, Exception):
            # Drop any regex that fails to compile — never let it reach scan.
            continue
        out.append([regex, label])
        if len(out) >= limit:
            break
    return out


def _read_yaml(path):
    """Parse a YAML file into a dict, or {} on any problem. Never raises."""
    try:
        import yaml  # optional dependency — absent => skip yml entirely
    except ImportError:
        return {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _read_json(path):
    """Parse a JSON file into a dict, or {} on any problem. Never raises."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _section(doc):
    """Pull the config mapping: prefer `python_hooks` sub-mapping, else top level."""
    if not isinstance(doc, dict):
        return {}
    nested = doc.get("python_hooks")
    if isinstance(nested, dict):
        return nested
    return doc


def load_extensions(repo_root: str) -> dict:
    """Load additive secret-scan extensions for `repo_root`.

    Returns a dict with three list keys — "secret_patterns" (list of
    [regex, label] pairs), "exempt_paths" (list of str), "credential_key_names"
    (list of str). Missing / empty / malformed config degrades to empty lists.
    NEVER raises.
    """
    try:
        if not repo_root or not isinstance(repo_root, str):
            return _empty()

        base = os.path.join(repo_root, ".agent")
        sources = []
        yml_path = os.path.join(base, "hook-config.yml")
        json_path = os.path.join(base, "hook-config.json")
        if os.path.isfile(yml_path):
            sources.append(_section(_read_yaml(yml_path)))
        if os.path.isfile(json_path):
            sources.append(_section(_read_json(json_path)))

        if not sources:
            return _empty()

        patterns = []
        exempts = []
        key_names = []
        for sect in sources:
            if not isinstance(sect, dict):
                continue
            patterns.extend(sect.get("secret_patterns", []) or [])
            exempts.extend(sect.get("exempt_paths", []) or [])
            key_names.extend(sect.get("credential_key_names", []) or [])

        return {
            "secret_patterns": _coerce_pattern_list(patterns, _MAX_PATTERNS),
            "exempt_paths": _coerce_exempt_list(exempts, _MAX_EXEMPTS),
            "credential_key_names": _coerce_str_list(key_names, _MAX_KEY_NAMES),
        }
    except Exception:
        # Absolute fail-safe — any unexpected failure degrades to built-ins only.
        return _empty()
