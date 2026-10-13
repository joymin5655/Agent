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

T-4: the same two files also carry `risk_areas.data/deploy/payment.pattern` (+ `decision`) and
`resources.<name>.triggers`, read by pre-tool-guard, pre-push, auto-ship and r4-mutex-check
through the functions at the bottom of this module (`load_risk_area_patterns`,
`risk_command_report`, `match_paths`, `load_resource_triggers`, `resource_match`) and the CLI
(`python3 hook_config.py risk-paths|resource-match ...`). Same EXTENSION-ONLY rule: a config
pattern is unioned with the built-ins, a declared decision can only raise a consumer's floor.
"""
import json
import os
import re
import sys

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


# W1-6: a Mac python3 without PyYAML silently skipped hook-config.yml entirely
# (project-declared secret path protection failed OPEN, with no signal). Warn
# once per process on stderr — never stdout, which is the hook JSON channel.
_pyyaml_warned = False


def _warn_pyyaml_missing():
    global _pyyaml_warned
    if _pyyaml_warned:
        return
    _pyyaml_warned = True
    print(
        "hook_config: PyYAML not installed — hook-config.yml skipped "
        "(project path protection inactive); run: python3 -m pip install --user pyyaml",
        file=sys.stderr,
    )


def _read_yaml(path):
    """Parse a YAML file into a dict, or {} on any problem. Never raises."""
    try:
        import yaml  # optional dependency — absent => skip yml entirely
    except Exception:  # absent or broken install; JSON config still applies
        _warn_pyyaml_missing()
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


# Bounds for risk_areas.secrets.paths (P1-8). A project extends the secrets
# path list the Bash guard denies access to; bound the count/length and reject
# any token that isn't a plain path fragment (no regex/shell metacharacters), so
# a config value can only ADD literal paths — never inject a regex or a shell op.
_MAX_RISK_PATHS = 50
_MAX_RISK_PATH_LEN = 200
# A safe path token: letters, digits, and the handful of path punctuation chars.
# Deliberately excludes regex/shell metacharacters (| ( ) [ ] { } $ ` ; & etc.).
_SAFE_PATH_TOKEN = re.compile(r"^[A-Za-z0-9._/\-]+$")


def load_risk_area_secret_paths(repo_root: str) -> list:
    """Return project-declared secret PATH tokens from `risk_areas.secrets.paths`
    (P1-8 — the field the Bash guard now enforces at runtime, closing the
    previously-aspirational config).

    Each glob (`secrets/**`, `.env.production`, `config/keys/*.pem`) is reduced to
    its literal prefix (glob metacharacters stripped at the first `*`/`?`), so a
    token is always a plain substring the guard can match a command against. Tokens
    are bounded in count and length and MUST match `_SAFE_PATH_TOKEN` — anything
    carrying a regex/shell metacharacter is dropped, so the config can only add
    literal paths, never inject a pattern. Missing/malformed config -> []. Never raises.
    """
    try:
        if not repo_root or not isinstance(repo_root, str):
            return []
        base = os.path.join(repo_root, ".agent")
        docs = []
        yml_path = os.path.join(base, "hook-config.yml")
        json_path = os.path.join(base, "hook-config.json")
        if os.path.isfile(yml_path):
            docs.append(_read_yaml(yml_path))
        if os.path.isfile(json_path):
            docs.append(_read_json(json_path))

        tokens = []
        seen = set()
        for doc in docs:
            if not isinstance(doc, dict):
                continue
            risk = doc.get("risk_areas")
            if not isinstance(risk, dict):
                continue
            secrets = risk.get("secrets")
            if not isinstance(secrets, dict):
                continue
            raw = secrets.get("paths")
            if not isinstance(raw, list):
                continue
            for item in raw:
                if not isinstance(item, str):
                    continue
                # reduce glob to its literal prefix (up to the first * or ?).
                # Keep a directory glob's trailing slash ('vault/**' -> 'vault/')
                # so the substring match stays path-anchored — otherwise bare
                # 'vault' would also block 'myvault2/x', an over-block. A lone
                # trailing slash from '/**' at root is stripped to avoid an empty
                # or slash-only token.
                frag = re.split(r"[*?]", item, 1)[0].strip()
                if frag == "/" or not frag:
                    continue
                if len(frag) > _MAX_RISK_PATH_LEN:
                    continue
                if not _SAFE_PATH_TOKEN.match(frag):
                    continue
                # A meaningful path fragment: at least 2 chars AND at least one
                # alphanumeric. This drops a glob that reduces to bare punctuation
                # (e.g. '.*' -> '.'), which would otherwise match almost any
                # command and turn a config typo into a blanket block.
                if len(frag) < 2 or not re.search(r"[A-Za-z0-9]", frag):
                    continue
                if frag in seen:
                    continue
                seen.add(frag)
                tokens.append(frag)
                if len(tokens) >= _MAX_RISK_PATHS:
                    return tokens
        return tokens
    except Exception:
        return []


def risk_areas_unparseable(repo_root: str) -> bool:
    """True when `.agent/hook-config.yml` mentions `risk_areas` but PyYAML is
    unavailable (P1-9). `load_risk_area_secret_paths` then sees no tokens, so the
    Bash guard must fail CLOSED instead of silently allowing every path. A raw
    substring check (no parser) keeps projects that declare nothing unaffected.
    An unreadable yml under a missing parser counts as declared. Only a module
    exposing `safe_load` counts as PyYAML: a stray `yaml.py`/`yaml/` or a broken
    install is treated as absent. Never raises.
    """
    try:
        import yaml
        if callable(getattr(yaml, "safe_load", None)):
            return False
    except Exception:
        pass
    try:
        if not repo_root or not isinstance(repo_root, str):
            return False
        yml_path = os.path.join(repo_root, ".agent", "hook-config.yml")
        if not os.path.isfile(yml_path):
            return False
        with open(yml_path, "r", encoding="utf-8", errors="replace") as f:
            return "risk_areas" in f.read()
    except Exception:
        return True


# Bounds for session.completion_tests (P3-1). A project cannot make the Stop
# gate run an unbounded number of arbitrarily long commands.
_MAX_COMPLETION_TESTS = 20
_MAX_COMMAND_LEN = 500


def load_session_config(repo_root: str) -> dict:
    """Load the project's `session.*` config. Currently exposes one key:
    `completion_tests` — a bounded list of shell command strings the Stop gate
    (session-quality-gate.py) runs to verify completion.

    Returns {"completion_tests": [str, ...]}. Missing / empty / malformed config
    (no file, bad YAML/JSON, wrong shape, non-str / over-long entries) degrades
    to an empty list. NEVER raises.

    TRUST MODEL: these commands run in the PROJECT's own environment at the
    project's own trust level — the same as its `package.json` scripts, Makefile,
    or CI config. This loader BOUNDS count and length; it does not sandbox
    execution. An agent that could add a `completion_tests` entry could already
    run the same command directly, so this adds enforcement (can't claim done
    while tests fail), not new capability. Unset => the gate does nothing.
    """
    try:
        if not repo_root or not isinstance(repo_root, str):
            return {"completion_tests": []}

        base = os.path.join(repo_root, ".agent")
        docs = []
        yml_path = os.path.join(base, "hook-config.yml")
        json_path = os.path.join(base, "hook-config.json")
        if os.path.isfile(yml_path):
            docs.append(_read_yaml(yml_path))
        if os.path.isfile(json_path):
            docs.append(_read_json(json_path))

        cmds = []
        for doc in docs:
            if not isinstance(doc, dict):
                continue
            sess = doc.get("session")
            if not isinstance(sess, dict):
                continue
            raw = sess.get("completion_tests")
            if not isinstance(raw, list):
                continue
            for item in raw:
                if isinstance(item, str) and item.strip() and len(item) <= _MAX_COMMAND_LEN:
                    cmds.append(item)
                    if len(cmds) >= _MAX_COMPLETION_TESTS:
                        break
            if len(cmds) >= _MAX_COMPLETION_TESTS:
                break

        return {"completion_tests": cmds}
    except Exception:
        return {"completion_tests": []}


def log_origin() -> str:
    """Return the log-origin tag for JSONL writers (W1-4).

    Every existing security-violations.jsonl / model-routing.jsonl record
    carries session_id=main, so a block produced by a test battery is
    indistinguishable from a real-session block. AGENT_LOG_ORIGIN, when set
    and non-empty, is recorded verbatim as the "origin" field — test runners
    (core/tests/verify-all.sh) export AGENT_LOG_ORIGIN=test so every
    test-produced record is tagged "test". Default: "session".
    """
    origin = os.environ.get("AGENT_LOG_ORIGIN", "")
    return origin if origin else "session"


# ---------------------------------------------------------------------------
# T-4 (2)(3): EXTENSION-ONLY risk-area path patterns and mutex-resource triggers.
#
#   * `risk_areas.<data|deploy|payment>.pattern` — one regex or a list (Python `re` syntax,
#     applied with `search` to a repo-relative path). UNIONed with each consumer's built-in
#     patterns; there is no way to remove or narrow a built-in.
#   * `risk_areas.<area>.decision` — advisory | ask | deny. A consumer's effective decision is
#     max(consumer floor, declared): it can only get STRONGER. `deny` happens only when the
#     config says so explicitly.
#   * `resources.<name>.triggers` — regexes that map a Bash command (or MCP tool name) to a
#     mutex resource name, consulted only when no built-in trigger matched.
#
# Config regexes are screened with the same boundary as `secret_patterns` (length cap, nested
# quantifier heuristic, syntax compile) PLUS a universe screen (a regex that matches the empty
# string would match every path), then matched with bounded input and a SIGALRM watchdog —
# CPython's regex engine polls signals, so a catastrophic pattern is cut off and ignored, never
# hangs a guard. A bad entry is dropped with a warning; the built-ins keep working.
# ---------------------------------------------------------------------------
RISK_PATTERN_AREAS = ("data", "deploy", "payment")
_DECISION_RANK = {"advisory": 0, "ask": 1, "deny": 2}
# The weakest decision each consumer already gives a built-in hit. pre-push and the shell guard
# cannot prompt mid-push, so their floor is advisory; auto-ship already aborts on every area.
_CONSUMER_FLOOR = {"pre-tool-guard": "ask", "pre-push": "advisory", "auto-ship": "deny"}
_MAX_AREA_PATTERNS = 20
_MAX_RESOURCES = 20
_MAX_TRIGGERS = 20
_MAX_MATCH_TEXT = 1024        # chars of one path / command fed to a config regex
_MAX_MATCH_ITEMS = 2000       # paths examined per call
_PATTERN_BUDGET_S = 0.5       # per-pattern wall budget before it is ignored
_TOTAL_BUDGET_S = 2.0
_RESOURCE_NAME = re.compile(r"^[a-z0-9][a-z0-9_.-]{0,63}$")


class _MatchTimeout(Exception):
    pass


def effective_decision(consumer, declared):
    """max(consumer floor, declared). Never returns anything weaker than the floor."""
    floor = _CONSUMER_FLOOR.get(consumer, "advisory")
    if declared in _DECISION_RANK and _DECISION_RANK[declared] > _DECISION_RANK[floor]:
        return declared
    return floor


def _pyyaml_usable():
    """Same test as risk_areas_unparseable: only a module exposing safe_load is PyYAML."""
    try:
        import yaml
        return callable(getattr(yaml, "safe_load", None))
    except Exception:
        return False


def _config_docs(repo_root, key, warnings):
    """Parsed `.agent/hook-config.{yml,json}` mappings. When the yml declares `key` but PyYAML
    is unusable it is skipped with ONE warning (built-ins keep working); json still applies."""
    docs = []
    if not repo_root or not isinstance(repo_root, str):
        return docs
    base = os.path.join(repo_root, ".agent")
    yml_path = os.path.join(base, "hook-config.yml")
    json_path = os.path.join(base, "hook-config.json")
    if os.path.isfile(yml_path):
        if _pyyaml_usable():
            docs.append(_read_yaml(yml_path))
        else:
            try:
                with open(yml_path, "r", encoding="utf-8", errors="replace") as f:
                    declared = key in f.read()
            except Exception:
                declared = True
            if declared:
                warnings.append(
                    "PyYAML not installed - hook-config.yml %s extensions inactive "
                    "(built-in behaviour only); run: python3 -m pip install --user pyyaml" % key
                )
    if os.path.isfile(json_path):
        docs.append(_read_json(json_path))
    return [d for d in docs if isinstance(d, dict)]


def _short(text):
    text = text if isinstance(text, str) else repr(text)
    text = re.sub(r"[\t\r\n]+", " ", text)
    return text if len(text) <= 40 else text[:37] + "..."


def _screen_regex(regex):
    """(ok, reason) for a config-supplied path/trigger regex."""
    if not isinstance(regex, str) or not regex.strip():
        return False, "empty"
    if len(regex) > _MAX_REGEX_LEN:
        return False, "longer than %d chars" % _MAX_REGEX_LEN
    if _NESTED_QUANTIFIER.search(regex):
        return False, "nested quantifier (catastrophic backtracking risk)"
    try:
        compiled = re.compile(regex)
    except (re.error, RecursionError, Exception):
        return False, "invalid regex"
    try:
        if compiled.search("") is not None:
            return False, "matches the empty string (would match every path)"
    except Exception:
        return False, "invalid regex"
    return True, ""


def _as_list(value):
    if isinstance(value, str):
        return [value]
    return value if isinstance(value, list) else []


def load_risk_area_patterns(repo_root):
    """Return {"areas": {area: {"patterns": [regex], "decision": str|None}}, "warnings": [str]}
    for data/deploy/payment. Missing / malformed config degrades to empty. Never raises."""
    areas = dict((a, {"patterns": [], "decision": None}) for a in RISK_PATTERN_AREAS)
    warnings = []
    try:
        for doc in _config_docs(repo_root, "risk_areas", warnings):
            risk = doc.get("risk_areas")
            if not isinstance(risk, dict):
                continue
            for area in RISK_PATTERN_AREAS:
                block = risk.get(area)
                if not isinstance(block, dict):
                    continue
                slot = areas[area]
                for raw in _as_list(block.get("pattern")):
                    if raw == "" or raw is None:
                        continue  # an empty pattern means "no extension"
                    ok, reason = _screen_regex(raw)
                    if not ok:
                        warnings.append("ignored risk_areas.%s.pattern '%s': %s" % (area, _short(raw), reason))
                    elif raw not in slot["patterns"] and len(slot["patterns"]) < _MAX_AREA_PATTERNS:
                        slot["patterns"].append(raw)
                decl = block.get("decision")
                if decl is None:
                    continue
                if isinstance(decl, str) and decl.lower() in _DECISION_RANK:
                    decl = decl.lower()
                    if slot["decision"] is None or _DECISION_RANK[decl] > _DECISION_RANK[slot["decision"]]:
                        slot["decision"] = decl
                else:
                    warnings.append("ignored risk_areas.%s.decision '%s': use advisory, ask or deny" % (area, _short(decl)))
    except Exception:
        pass
    return {"areas": areas, "warnings": warnings}


def _run_budgeted(fn, seconds):
    """Run fn() under a SIGALRM budget (main thread, POSIX). Raises _MatchTimeout on overrun.
    Where signals are unavailable the inputs are still length-capped; fn runs unguarded."""
    import signal  # lazy: only paths that run a config regex pay for it
    import threading
    usable = hasattr(signal, "setitimer") and threading.current_thread() is threading.main_thread()
    if not usable:
        return fn()

    def _on_alarm(signum, frame):
        raise _MatchTimeout()

    previous = signal.signal(signal.SIGALRM, _on_alarm)
    signal.setitimer(signal.ITIMER_REAL, seconds)
    try:
        return fn()
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


def match_paths(patterns, paths, warnings=None):
    """Paths (order kept) matched by ANY of `patterns` via re.search. Each pattern runs under its
    own time budget; one that overruns (or is invalid) is ignored with a warning. Never raises."""
    import time
    hits = []
    seen = set()
    sink = warnings if warnings is not None else []
    started = time.monotonic()
    bounded = [p[:_MAX_MATCH_TEXT] if isinstance(p, str) else "" for p in paths[:_MAX_MATCH_ITEMS]]
    for regex in patterns:
        if time.monotonic() - started > _TOTAL_BUDGET_S:
            sink.append("regex budget exhausted - remaining config patterns skipped")
            break
        try:
            compiled = re.compile(regex)
        except Exception:
            continue

        def _scan():
            for original, text in zip(paths, bounded):
                if original not in seen and compiled.search(text):
                    seen.add(original)
                    hits.append(original)

        try:
            _run_budgeted(_scan, _PATTERN_BUDGET_S)
        except _MatchTimeout:
            sink.append("ignored pattern '%s': exceeded the %.1fs match budget" % (_short(regex), _PATTERN_BUDGET_S))
        except Exception:
            continue
    ordered = [p for p in paths[:_MAX_MATCH_ITEMS] if p in seen]
    return ordered


# ---- Bash command -> candidate paths a command would MODIFY (pre-tool-guard) -----------------
_WRAPPERS = frozenset(["sudo", "doas", "env", "nohup", "time", "command", "exec", "nice",  # supply-chain-scan: allow-literal wrapper names skipped when parsing a command, not a spawn
                       "stdbuf", "xargs", "timeout", "gtimeout"])
_MUTATORS = frozenset(["cp", "mv", "rm", "tee", "touch", "install", "ln", "truncate", "unlink"])
_SHELLS = frozenset(["sh", "bash", "zsh", "dash"])
_GIT_PATH_SUBCMDS = frozenset(["add", "rm", "mv"])
_GIT_VALUE_OPTS = frozenset(["-C", "-c", "--git-dir", "--work-tree", "--namespace"])
_SEGMENT_SPLIT = re.compile(r"\|\||&&|[;&|\n`()]")
_REDIRECT_TARGET = re.compile(r"(?<![<>&])>{1,2}(?!&)\s*['\"]?([^\s;&|<>'\"()`]+)")
_ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
_MAX_COMMAND_CHARS = 16384
_MAX_SEGMENTS = 64
_MAX_COMMAND_PATHS = 200


def _norm_path(path, root):
    path = path.strip().strip("\"'")
    while path.startswith("./"):
        path = path[2:]
    prefix = (root or "").rstrip("/") + "/"
    if root and path.startswith(prefix):
        path = path[len(prefix):]
    return path


def _segment_targets(tokens, out, depth):
    """Append the non-option arguments of the first path-modifying command in `tokens`."""
    n = len(tokens)
    i = 0
    after_option = False
    while i < n:
        tok = tokens[i]
        base = os.path.basename(tok)
        known = base in _MUTATORS or base in ("git", "sed", "perl", "dd") or base in _SHELLS
        if (_ASSIGNMENT.match(tok) or base in _WRAPPERS or tok.startswith("-")
                or (after_option and not known)):
            after_option = tok.startswith("-") or base in _WRAPPERS
            i += 1
            continue
        break
    if i >= n:
        return
    base = os.path.basename(tokens[i])
    start = None
    if base == "git":
        j = i + 1
        while j < n and tokens[j].startswith("-"):
            j += 2 if tokens[j] in _GIT_VALUE_OPTS else 1
        if j < n and tokens[j] in _GIT_PATH_SUBCMDS:
            start = j + 1
    elif base in _MUTATORS:
        start = i + 1
    elif base in ("sed", "perl"):
        if any(re.match(r"^-[A-Za-z]*i", t) or t == "--in-place" for t in tokens[i + 1:]):
            start = i + 1
    elif base == "dd":
        for t in tokens[i + 1:]:
            if t.startswith("of="):
                out.append(t[3:])
        return
    elif base in _SHELLS and depth < 2:
        for k in range(i + 1, n - 1):
            if tokens[k] == "-c":
                _command_targets(tokens[k + 1], out, depth + 1)
                break
        return
    if start is None:
        return
    for t in tokens[start:]:
        if t.startswith("-") or not t:
            continue
        out.append(t)


def _command_targets(command, out, depth):
    for seg in _SEGMENT_SPLIT.split(command)[:_MAX_SEGMENTS]:
        seg = seg.strip()
        if not seg:
            continue
        try:
            import shlex
            tokens = shlex.split(seg)
        except ValueError:
            tokens = seg.split()
        _segment_targets(tokens, out, depth)


def command_paths(command, root=""):
    """Best-effort list of repo-relative paths a Bash command would modify: arguments of
    `git add|rm|mv`, cp/mv/rm/tee/touch/install/ln/truncate/unlink, `sed|perl -i`, `dd of=`,
    redirect targets, and `sh -c '<cmd>'` bodies. `git add .`/`-A` expose no file names and are
    left to pre-push. A heuristic, not a parser: it can over-ask, never hides the built-ins."""
    if not isinstance(command, str) or not command:
        return []
    command = command[:_MAX_COMMAND_CHARS]
    found = []
    _command_targets(command, found, 0)
    found.extend(_REDIRECT_TARGET.findall(command))
    paths = []
    for raw in found:
        path = _norm_path(raw, root)
        if path and path not in paths and not path.startswith("/dev/"):
            paths.append(path)
        if len(paths) >= _MAX_COMMAND_PATHS:
            break
    return paths


def risk_command_report(repo_root, command):
    """Protocol lines for pre-tool-guard: `WARN\\t<text>` and `HIT\\t<area>\\t<decision>\\t<path>`.
    Silent (empty) for a command that modifies no path. Never raises."""
    try:
        paths = command_paths(command, repo_root)
        if not paths:
            return []
        cfg = load_risk_area_patterns(repo_root)
        warnings = list(cfg["warnings"])
        hit_lines = []
        for area in RISK_PATTERN_AREAS:
            slot = cfg["areas"][area]
            if not slot["patterns"]:
                continue
            decision = effective_decision("pre-tool-guard", slot["decision"])
            for path in match_paths(slot["patterns"], paths, warnings)[:5]:
                hit_lines.append("HIT\t%s\t%s\t%s" % (area, decision, re.sub(r"[\t\r\n]+", " ", path)))
        return ["WARN\t" + w for w in warnings] + hit_lines
    except Exception:
        return []


# ---- Resource mutex triggers (r4-mutex-check) ------------------------------------------------
def load_resource_triggers(repo_root):
    """Return {"resources": {name: [regex]}, "warnings": [str]} from `resources.<name>.triggers`.
    Names must match [a-z0-9][a-z0-9_.-]{0,63}. `auto_expire_minutes` is deliberately NOT read:
    an expiry shortens a lock's hold, which would weaken the mutex (gc owns lock expiry)."""
    resources = {}
    warnings = []
    try:
        for doc in _config_docs(repo_root, "resources", warnings):
            block = doc.get("resources")
            if not isinstance(block, dict):
                continue
            for name, spec in block.items():
                if not isinstance(name, str) or not _RESOURCE_NAME.match(name):
                    warnings.append("ignored resources.'%s': name must match [a-z0-9][a-z0-9_.-]*" % _short(name))
                    continue
                if not isinstance(spec, dict):
                    continue
                if name not in resources and len(resources) >= _MAX_RESOURCES:
                    continue
                bucket = resources.setdefault(name, [])
                for raw in _as_list(spec.get("triggers")):
                    ok, reason = _screen_regex(raw)
                    if not ok:
                        warnings.append("ignored resources.%s.triggers '%s': %s" % (name, _short(raw), reason))
                    elif raw not in bucket and len(bucket) < _MAX_TRIGGERS:
                        bucket.append(raw)
    except Exception:
        pass
    return {"resources": resources, "warnings": warnings}


def resource_match(repo_root, tool_name, command):
    """(resource_name, warnings): first configured resource whose trigger matches the Bash
    command (tool_name == "Bash") or the MCP tool name; ("", warnings) otherwise. Never raises."""
    cfg = load_resource_triggers(repo_root)
    warnings = list(cfg["warnings"])
    text = command if tool_name == "Bash" else tool_name
    try:
        for name, triggers in cfg["resources"].items():
            if triggers and match_paths(triggers, [text or ""], warnings):
                return name, warnings
    except Exception:
        pass
    return "", warnings


def _cli(argv):
    """python3 hook_config.py risk-paths <root> <consumer>       (paths on stdin)
       python3 hook_config.py resource-match <root> <tool_name>  (Bash command on stdin)
    Warnings go to stderr as `hook_config: ...`; the result goes to stdout. Always exits 0 so a
    broken config can never fail a gate on its own."""
    try:
        mode = argv[1]
        root = argv[2]
        if mode == "risk-paths":
            consumer = argv[3]
            paths = [p for p in sys.stdin.read().splitlines() if p][:_MAX_MATCH_ITEMS]
            cfg = load_risk_area_patterns(root)
            warnings = list(cfg["warnings"])
            for area in RISK_PATTERN_AREAS:
                print("AREA\t%s\t%s" % (area, effective_decision(consumer, cfg["areas"][area]["decision"])))
            for area in RISK_PATTERN_AREAS:
                pats = cfg["areas"][area]["patterns"]
                for path in (match_paths(pats, paths, warnings) if pats else []):
                    print("HIT\t%s\t%s" % (area, re.sub(r"[\t\r\n]+", " ", path)))
        elif mode == "resource-match":
            tool = argv[3]
            command = sys.stdin.read() if tool == "Bash" else ""
            name, warnings = resource_match(root, tool, command)
            if name:
                print(name)
        else:
            return 0
        for w in dict.fromkeys(warnings):
            print("hook_config: " + w, file=sys.stderr)
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(_cli(sys.argv))
