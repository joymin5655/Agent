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
#   * `risk_areas.<area>.decision` — advisory | ask | deny (case-insensitive). A consumer's
#     effective decision is max(consumer floor, declared): it can only get STRONGER. `deny`
#     happens only when the config says so explicitly.
#   * `resources.<name>.triggers` — regexes that map a Bash command (or MCP tool name) to a
#     mutex resource name, consulted only when no built-in trigger matched.
#
# Config regexes are screened with the same boundary as `secret_patterns` (length cap, nested
# quantifier heuristic, syntax compile) PLUS a universe screen (a regex that matches the empty
# string would match every path). EVERY regex execution — the screen included — runs under a
# SIGALRM watchdog (CPython's regex engine polls signals) AND one PROCESS-WIDE deadline
# (`_TOTAL_BUDGET_S`) shared by screening and matching across every area and resource, so a
# catastrophic pattern, or a large honest config, can never hold a guard past that deadline.
# A pattern that overruns is ignored with a warning; once the deadline is spent the remaining
# config evaluation is skipped with ONE warning and the built-ins keep working.
#
# Inputs are never truncated silently: a file list or command larger than the analysis caps is
# reported as a fail-closed hit on every area that declares a pattern (see `_TRUNCATED_HIT`).
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
_MAX_PATH_ITEMS = 20000       # changed files examined per call (more => fail-closed hit)
_PATTERN_BUDGET_S = 0.25      # one regex execution (or one pattern over all paths)
_TOTAL_BUDGET_S = 1.5         # the whole process: screening + matching, all areas/resources
_RESOURCE_NAME = re.compile(r"^[a-z0-9][a-z0-9_.-]{0,63}$")
_TRUNCATED_PATHS = "(file list too large to evaluate fully)"
_TRUNCATED_COMMAND = "(command too large to analyse fully)"
_UNEVALUATED = "(risk-area config not fully evaluated: regex budget exhausted)"


class _MatchTimeout(Exception):
    pass


class _BudgetExhausted(Exception):
    pass


_budget = {"t0": None}


def _reset_budget():
    """Start a fresh process-wide deadline (called by every entry point)."""
    _budget["t0"] = None


def _remaining():
    import time
    if _budget["t0"] is None:
        _budget["t0"] = time.monotonic()
    return _TOTAL_BUDGET_S - (time.monotonic() - _budget["t0"])


_BUDGET_WARNING = ("regex budget (%.1fs) exhausted - remaining config patterns skipped, "
                   "built-in behaviour only" % _TOTAL_BUDGET_S)


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


def risk_config_declared(repo_root):
    """True when the project config declares anything for data/deploy/payment (or a yml that
    mentions risk_areas that cannot be parsed). A cheap gate so a guard starts the heavier
    evaluation only for projects that opted in. Never raises."""
    try:
        sink = []
        for doc in _config_docs(repo_root, "risk_areas", sink):
            risk = doc.get("risk_areas")
            if isinstance(risk, dict) and any(isinstance(risk.get(a), dict) for a in RISK_PATTERN_AREAS):
                return True
        return bool(sink)
    except Exception:
        return False


def _short(text):
    text = text if isinstance(text, str) else repr(text)
    text = re.sub(r"[\t\r\n]+", " ", text)
    return text if len(text) <= 40 else text[:37] + "..."


def _run_budgeted(fn, seconds):
    """Run fn() under a SIGALRM watchdog capped by the process-wide deadline. Raises
    _BudgetExhausted when no time is left, _MatchTimeout when fn overruns. Where signals are
    unavailable (non-POSIX, non-main thread) fn runs unguarded on length-capped inputs."""
    import signal
    import threading
    left = _remaining()
    if left <= 0:
        raise _BudgetExhausted()
    if not (hasattr(signal, "setitimer") and threading.current_thread() is threading.main_thread()):
        return fn()

    def _on_alarm(signum, frame):
        raise _MatchTimeout()

    previous = signal.signal(signal.SIGALRM, _on_alarm)
    signal.setitimer(signal.ITIMER_REAL, max(min(seconds, left), 0.001))
    try:
        return fn()
    except _MatchTimeout:
        if _remaining() <= 0:
            raise _BudgetExhausted()
        raise
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


def _screen_regex(regex):
    """(ok, reason) for a config-supplied path/trigger regex. Raises _BudgetExhausted when the
    process-wide deadline is spent (the caller stops and warns once)."""
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
        # The empty-string probe is itself a regex execution: `(?:|){40}(?!)` backtracks
        # exponentially on "", so it runs under the same watchdog as real matching.
        universe = _run_budgeted(lambda: compiled.search("") is not None, _PATTERN_BUDGET_S)
    except _MatchTimeout:
        return False, "exceeded the %.2fs match budget while being checked" % _PATTERN_BUDGET_S
    except _BudgetExhausted:
        raise
    except Exception:
        return False, "invalid regex"
    if universe:
        return False, "matches the empty string (would match every path)"
    return True, ""


def _as_list(value):
    if isinstance(value, str):
        return [value]
    return value if isinstance(value, list) else []


def load_risk_area_patterns(repo_root):
    """Return {"areas": {area: {"patterns": [regex], "decision": str|None, "unevaluated": bool}},
    "warnings": [str]} for data/deploy/payment. Missing / malformed config degrades to empty.

    `decision` metadata is read from EVERY config file before any regex runs, so a spent regex
    budget can never lose a declared `deny` that lives in another file. When the budget runs out
    before every declared pattern of an area was screened, that area is `unevaluated`: consumers
    treat it like a truncated input (fail-closed), never as "no match". Never raises."""
    areas = dict((a, {"patterns": [], "decision": None, "unevaluated": False}) for a in RISK_PATTERN_AREAS)
    warnings = []
    try:
        blocks = []
        for doc in _config_docs(repo_root, "risk_areas", warnings):
            risk = doc.get("risk_areas")
            if isinstance(risk, dict):
                blocks.append(risk)
        for risk in blocks:
            for area in RISK_PATTERN_AREAS:
                block = risk.get(area)
                if not isinstance(block, dict):
                    continue
                decl = block.get("decision")
                if decl is None:
                    continue
                slot = areas[area]
                if isinstance(decl, str) and decl.strip().lower() in _DECISION_RANK:
                    decl = decl.strip().lower()
                    if slot["decision"] is None or _DECISION_RANK[decl] > _DECISION_RANK[slot["decision"]]:
                        slot["decision"] = decl
                else:
                    warnings.append("ignored risk_areas.%s.decision '%s': use advisory, ask or deny" % (area, _short(decl)))
        declared = []
        for risk in blocks:
            for area in RISK_PATTERN_AREAS:
                block = risk.get(area)
                if isinstance(block, dict):
                    declared.extend((area, raw) for raw in _as_list(block.get("pattern")) if raw not in ("", None))
        for index, (area, raw) in enumerate(declared):
            slot = areas[area]
            try:
                ok, reason = _screen_regex(raw)
            except _BudgetExhausted:
                warnings.append(_BUDGET_WARNING)
                for later_area, _later in declared[index:]:
                    areas[later_area]["unevaluated"] = True
                break
            if not ok:
                warnings.append("ignored risk_areas.%s.pattern '%s': %s" % (area, _short(raw), reason))
            elif raw not in slot["patterns"] and len(slot["patterns"]) < _MAX_AREA_PATTERNS:
                slot["patterns"].append(raw)
    except Exception:
        pass
    return {"areas": areas, "warnings": warnings}


def match_paths(patterns, paths, warnings=None):
    """(hits, complete): paths (order kept) matched by ANY of `patterns` via re.search.
    Each pattern runs under its own watchdog and the process-wide deadline; a pattern that
    overruns is ignored with a warning (the others still count). When the deadline is spent the
    rest is skipped with one warning and `complete` is False: the caller must treat the
    patterns it could not run as UNEVALUATED, not as "no match". Never raises."""
    hits = []
    seen = set()
    complete = True
    sink = warnings if warnings is not None else []
    bounded = [p[:_MAX_MATCH_TEXT] if isinstance(p, str) else "" for p in paths]
    try:
        for regex in patterns:
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
                sink.append("ignored pattern '%s': exceeded the %.2fs match budget" % (_short(regex), _PATTERN_BUDGET_S))
    except _BudgetExhausted:
        sink.append(_BUDGET_WARNING)
        complete = False
    except Exception:
        pass
    return [p for p in paths if p in seen], complete


# ---- Bash command -> repo-relative paths a command would MODIFY (pre-tool-guard) --------------
# A real (small) shell tokenizer: quotes, heredoc bodies and comments are DATA; operators, redirect
# operators and $(...)/`...` bodies are interpreted. It is a heuristic for "what would this change",
# not a sandbox: see docs/hook-config.md for the list of things it deliberately does not see.
_WRAPPERS = frozenset(["sudo", "doas", "env", "nohup", "time", "command", "exec", "nice",  # supply-chain-scan: allow-literal wrapper names skipped when parsing a command, not a spawn
                       "stdbuf", "xargs", "timeout", "gtimeout"])
_ALL_WRITERS = frozenset(["rm", "unlink", "touch", "truncate", "tee"])
_COPIERS = frozenset(["cp", "mv", "install", "ln"])
_VALUE_OPTS = {
    "touch": frozenset(["-r", "-d", "-t", "--date", "--reference"]),
    "truncate": frozenset(["-s", "-r", "--size", "--reference"]),
    "cp": frozenset(["-t", "--target-directory", "-S", "--suffix"]),
    "mv": frozenset(["-t", "--target-directory", "-S", "--suffix"]),
    "install": frozenset(["-t", "--target-directory", "-S", "--suffix", "-m", "--mode", "-o", "--owner",
                          "-g", "--group"]),
    "ln": frozenset(["-t", "--target-directory", "-S", "--suffix"]),
    "sed": frozenset(["-e", "-f", "-l", "--expression", "--file", "--line-length"]),
    "perl": frozenset(["-e", "-E", "-I"]),
    "git-restore": frozenset(["-s", "--source"]),
}
_SHELLS = frozenset(["sh", "bash", "zsh", "dash"])
_GIT_VALUE_GLOBALS = frozenset(["-c", "--git-dir", "--work-tree", "--namespace"])
_WRITE_REDIRECTS = frozenset([">", ">>", ">|", "&>", "&>>", "<>"])
_ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
_MAX_COMMAND_CHARS = 65536
_MAX_COMMANDS = 512
_MAX_COMMAND_PATHS = 2000
_MAX_SUBST_DEPTH = 4


def _match_paren(src, i):
    """Index of the ')' closing the '(' at src[i] (quote-aware, nesting-aware), else len(src)."""
    depth = 0
    n = len(src)
    while i < n:
        c = src[i]
        if c == "\\":
            i += 2
            continue
        if c == "'":
            j = src.find("'", i + 1)
            i = n if j < 0 else j + 1
            continue
        if c == '"':
            i += 1
            while i < n and src[i] != '"':
                i += 2 if src[i] == "\\" else 1
            i += 1
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return n


def _backtick_end(src, i):
    """Index of the backtick closing the one at src[i]: a backslash escapes the next character,
    so an escaped backtick nests instead of closing. len(src) when unterminated."""
    j = i + 1
    n = len(src)
    while j < n:
        if src[j] == "\\":
            j += 2
            continue
        if src[j] == "`":
            return j
        j += 1
    return n


def _unescape_backtick(body):
    """Body of a `...` substitution as the shell hands it to the inner command: `\\` followed by
    a backtick, a dollar sign or a backslash loses the backslash."""
    return re.sub(r"\\([`$\\])", r"\1", body)


def _expansion_span(src, i):
    """For a substitution starting at src[i] ('$(' or '$((' or a backtick), return
    (end_index, kind, inner): kind is "cmd", "arith" or "tick"; inner is the text to scan."""
    if src.startswith("$((", i):
        k = _match_paren(src, i + 1)
        if k > i + 3 and src[k - 1] == ")":
            return k, "arith", src[i + 3:k - 1]
        return k, "cmd", src[i + 2:k]
    if src.startswith("$(", i):
        k = _match_paren(src, i + 1)
        return k, "cmd", src[i + 2:k]
    k = _backtick_end(src, i)
    return k, "tick", _unescape_backtick(src[i + 1:k])


_MAX_ARITH_DEPTH = 8


def _scan_expansions(text, on_subst, overflow=None, depth=0):
    """Hand every command substitution inside `text` (an unquoted heredoc body or an arithmetic
    expression) to `on_subst`. $((...)) is arithmetic, not a command: only the substitutions
    nested inside it count. A backslash escapes the next character."""
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == "\\":
            i += 2
        elif text.startswith("$(", i) or c == "`":
            k, kind, inner = _expansion_span(text, i)
            if kind == "arith":
                if depth >= _MAX_ARITH_DEPTH:  # unbounded $((...)) nesting: stop, say so
                    if overflow is not None:
                        overflow()
                else:
                    _scan_expansions(inner, on_subst, overflow, depth + 1)
            else:
                on_subst(inner)
            i = k + 1
        else:
            i += 1


def _heredoc_substitutions(body, on_subst, overflow=None):
    """The $(...) and `...` spans of an unquoted heredoc body run when the shell expands it."""
    _scan_expansions(body, on_subst, overflow)


def _lex(src, on_subst, overflow=None):
    """Tokens: ("w", word) with quotes resolved, ("o", op) command separators, ("r", op)
    redirections. Heredoc bodies and comments are skipped; the bodies of $(...) and `...` are
    handed to `on_subst` and left as a placeholder inside the word."""
    toks = []
    buf = []
    inword = False
    heredocs = []
    pending_hd = [None]
    quoted = [False]  # did the word being built contain a quote or backslash?
    i = 0
    n = len(src)

    def flush():
        nonlocal buf, inword
        if inword:
            word = "".join(buf)
            toks.append(("w", word))
            if pending_hd[0] is not None:
                heredocs.append((word, pending_hd[0], quoted[0]))
                pending_hd[0] = None
            buf = []
            inword = False
            quoted[0] = False

    while i < n:
        c = src[i]
        if c == "\n":
            flush()
            toks.append(("o", "\n"))
            i += 1
            while heredocs:
                delim, strip, was_quoted = heredocs.pop(0)
                body = []
                while i < n:
                    j = src.find("\n", i)
                    line = src[i:] if j < 0 else src[i:j]
                    i = n if j < 0 else j + 1
                    if (line.lstrip("\t") if strip else line) == delim:
                        break
                    body.append(line)
                if not was_quoted:
                    # an unquoted heredoc is EXPANDED by the shell: its $(...) and `...` run
                    _heredoc_substitutions("\n".join(body), on_subst, overflow)
            continue
        if c in " \t":
            flush()
            i += 1
            continue
        if c == "\\":
            if i + 1 < n and src[i + 1] == "\n":
                i += 2
            elif i + 1 < n:
                buf.append(src[i + 1])
                inword = True
                quoted[0] = True
                i += 2
            else:
                i += 1
            continue
        if c == "'":
            j = src.find("'", i + 1)
            if j < 0:
                j = n
            buf.append(src[i + 1:j])
            inword = True
            quoted[0] = True
            i = j + 1
            continue
        if c == '"':
            quoted[0] = True
            j = i + 1
            seg = []
            while j < n and src[j] != '"':
                if src[j] == "\\" and j + 1 < n:
                    if src[j + 1] in '"\\$`':
                        seg.append(src[j + 1])
                    elif src[j + 1] != "\n":
                        seg.append(src[j:j + 2])
                    j += 2
                    continue
                if src.startswith("$(", j) or src[j] == "`":
                    k, kind, inner = _expansion_span(src, j)
                    if kind == "arith":
                        _scan_expansions(inner, on_subst, overflow)
                    else:
                        on_subst(inner)
                    seg.append("$(...)")
                    j = k + 1
                    continue
                seg.append(src[j])
                j += 1
            buf.append("".join(seg))
            inword = True
            i = j + 1
            continue
        if src.startswith("$(", i) or c == "`":
            k, kind, inner = _expansion_span(src, i)
            if kind == "arith":
                _scan_expansions(inner, on_subst, overflow)
            else:
                on_subst(inner)
            buf.append("$(...)")
            inword = True
            i = k + 1
            continue
        if c == "#" and not inword:
            while i < n and src[i] != "\n":
                i += 1
            continue
        if c in ";|&()":
            nxt = src[i + 1] if i + 1 < n else ""
            if c == "&" and nxt == ">":
                flush()
                op = "&>>" if src.startswith("&>>", i) else "&>"
                toks.append(("r", op))
                i += len(op)
                continue
            flush()
            if (c == "|" and nxt in "|&") or (c == "&" and nxt == "&") or (c == ";" and nxt == ";"):
                i += 2
            else:
                i += 1
            toks.append(("o", c))
            continue
        if c in "<>":
            if inword and "".join(buf).isdigit():
                buf = []
                inword = False  # a leading file descriptor number: N> / N<
            else:
                flush()
            if c == ">":
                op = ">>" if src.startswith(">>", i) else ">|" if src.startswith(">|", i) else ">&" if src.startswith(">&", i) else ">"
            else:
                op = ("<<<" if src.startswith("<<<", i) else "<<-" if src.startswith("<<-", i)
                      else "<<" if src.startswith("<<", i) else "<&" if src.startswith("<&", i)
                      else "<>" if src.startswith("<>", i) else "<")
            if op in ("<<", "<<-"):
                pending_hd[0] = (op == "<<-")
            toks.append(("r", op))
            i += len(op)
            continue
        buf.append(c)
        inword = True
        i += 1
    flush()
    return toks


def _split_commands(toks):
    """[(words, redirects)] — redirects are (op, target-word)."""
    cmds = []
    words = []
    reds = []
    pending = None
    for kind, val in toks:
        if kind == "w":
            if pending is not None:
                reds.append((pending, val))
                pending = None
            else:
                words.append(val)
        elif kind == "r":
            pending = val
        else:
            pending = None
            if words or reds:
                cmds.append((words, reds))
                words = []
                reds = []
    if words or reds:
        cmds.append((words, reds))
    return cmds


def _operands(args, value_opts):
    """Non-option arguments, skipping the values of `value_opts` and honouring `--`."""
    out = []
    i = 0
    n = len(args)
    while i < n:
        a = args[i]
        if a == "--":
            out.extend(args[i + 1:])
            break
        if a.startswith("-") and a != "-":
            if a in value_opts:
                i += 2
                continue
            i += 1
            continue
        out.append(a)
        i += 1
    return out


def _opt_value(args, names):
    """Value of the first `-t DIR` / `--target-directory[=]DIR` style option, else None."""
    for i, a in enumerate(args):
        if a in names and i + 1 < len(args):
            return args[i + 1]
        for nm in names:
            if nm.startswith("--") and a.startswith(nm + "="):
                return a[len(nm) + 1:]
    return None


def _command_words(words):
    """Index of the command word after wrappers, env assignments and their options."""
    i = 0
    n = len(words)
    after_option = False
    known = _COPIERS | _ALL_WRITERS | _SHELLS | frozenset(["git", "sed", "perl", "dd", "eval"])
    while i < n:
        tok = words[i]
        base = os.path.basename(tok)
        if (_ASSIGNMENT.match(tok) or base in _WRAPPERS or tok.startswith("-")
                or (after_option and base not in known)):
            after_option = tok.startswith("-") or base in _WRAPPERS
            i += 1
            continue
        break
    return i


def _add(out, state, path, base):
    if len(out) >= _MAX_COMMAND_PATHS:
        state["truncated"] = True
        return
    out.append((path, base))


def _command_targets(command, base, depth, out, state):
    if depth > _MAX_SUBST_DEPTH:
        state["truncated"] = True
        return
    def sub(body):
        try:
            _command_targets(body, base, depth + 1, out, state)
        except Exception:  # RecursionError and friends: keep what was found, flag the rest
            state["truncated"] = True

    def overflow():
        state["truncated"] = True

    toks = _lex(command, sub, overflow)
    for words, reds in _split_commands(toks):
        state["commands"] += 1
        if state["commands"] > _MAX_COMMANDS:
            state["truncated"] = True
            return
        for op, target in reds:
            if op in _WRITE_REDIRECTS or (op == ">&" and not (target.isdigit() or target == "-")):
                _add(out, state, target, base)
        _word_targets(words, base, depth, out, state)


def _word_targets(words, base, depth, out, state):
    i = _command_words(words)
    if i >= len(words):
        return
    cmd = os.path.basename(words[i])
    args = words[i + 1:]
    if cmd == "git":
        j = 0
        while j < len(args) and args[j].startswith("-"):
            a = args[j]
            if a == "-C" and j + 1 < len(args):
                base = os.path.join(base, os.path.expanduser(args[j + 1]))
                j += 2
            elif a in _GIT_VALUE_GLOBALS:
                j += 2
            else:
                j += 1
        if j >= len(args):
            return
        sub, rest = args[j], args[j + 1:]
        if sub in ("add", "rm", "mv"):
            for p in _operands(rest, frozenset()):
                _add(out, state, p, base)
        elif sub == "restore":
            for p in _operands(rest, _VALUE_OPTS["git-restore"]):
                _add(out, state, p, base)
        elif sub == "checkout" and "--" in rest:
            for p in rest[rest.index("--") + 1:]:
                _add(out, state, p, base)
    elif cmd in _ALL_WRITERS:
        for p in _operands(args, _VALUE_OPTS.get(cmd, frozenset())):
            _add(out, state, p, base)
    elif cmd in _COPIERS:
        ops = _operands(args, _VALUE_OPTS[cmd])
        target_dir = _opt_value(args, ("-t", "--target-directory"))
        if target_dir is not None:
            dests, sources = [target_dir], ops
        elif len(ops) >= 2:
            dests, sources = [ops[-1]], ops[:-1]
        else:
            return
        for d in dests:
            _add(out, state, d, base)
            full = os.path.join(base, os.path.expanduser(d))
            if d.endswith("/") or os.path.isdir(full):
                for s in sources:
                    _add(out, state, os.path.join(d, os.path.basename(s.rstrip("/"))), base)
        if cmd == "mv":
            for s in sources:
                _add(out, state, s, base)
    elif cmd in ("sed", "perl"):
        in_place = any(a == "--in-place" or a.startswith("--in-place=")
                       or (a.startswith("-") and not a.startswith("--") and re.match(r"^-[A-Za-z]*i", a))
                       for a in args)
        if not in_place:
            return
        ops = _operands(args, _VALUE_OPTS[cmd])
        has_script_opt = any(a in _VALUE_OPTS[cmd] or a.startswith(("--expression=", "--file="))
                             or (a.startswith(("-e", "-f")) and len(a) > 2 and not a.startswith("--"))
                             for a in args)
        if not has_script_opt and ops:
            ops = ops[1:]  # the first operand is the script (sed) / script file (perl)
        for p in ops:
            _add(out, state, p, base)
    elif cmd == "dd":
        for a in args:
            if a.startswith("of="):
                _add(out, state, a[3:], base)
    elif cmd in _SHELLS:
        for k in range(len(args) - 1):
            if args[k] == "-c":
                _command_targets(args[k + 1], base, depth + 1, out, state)
                break
    elif cmd == "eval" and args:
        _command_targets(" ".join(args), base, depth + 1, out, state)


def _relative_to_root(path, base, root_norm, root_real):
    p = os.path.expanduser(path)
    if not os.path.isabs(p):
        p = os.path.join(base, p)
    p = os.path.normpath(p)
    for r in (root_norm, root_real):
        if p == r:
            return ""
        if p.startswith(r + os.sep):
            return p[len(r) + 1:]
    real = os.path.realpath(p)
    if real.startswith(root_real + os.sep):
        return real[len(root_real) + 1:]
    return None


def command_paths(command, root="", cwd=""):
    """(paths, truncated): repo-relative paths a Bash command would modify. Relative operands are
    resolved against `cwd` (the event's working directory; default: this process's), `git -C` is
    honoured, `..` is normalised and paths outside `root` are ignored. `truncated` is True when
    the command exceeded an analysis cap (size, simple-command count, path count): the caller must
    treat that as "unknown", not "clean"."""
    if not isinstance(command, str) or not command or not root:
        return [], False
    state = {"truncated": False, "commands": 0}
    if len(command) > _MAX_COMMAND_CHARS:
        command = command[:_MAX_COMMAND_CHARS]
        state["truncated"] = True
    try:
        base = cwd if (isinstance(cwd, str) and os.path.isabs(cwd)) else os.getcwd()
    except OSError:
        base = root
    found = []
    try:
        _command_targets(command, base, 0, found, state)
    except Exception:
        # An extraction failure (e.g. RecursionError) is a truncation, not a clean command: the
        # hits found so far are kept and the caller fails closed for the rest.
        state["truncated"] = True
    root_norm = os.path.normpath(os.path.abspath(root))
    root_real = os.path.realpath(root)
    paths = []
    for raw, b in found:
        try:
            rel = _relative_to_root(raw, b, root_norm, root_real)
        except Exception:  # e.g. a NUL byte: skip this operand, keep the rest
            continue
        if rel and rel not in paths:
            paths.append(rel)
    return paths, state["truncated"]


def risk_command_report(repo_root, command, cwd="", cut=False):
    """Protocol lines for pre-tool-guard: `WARN\\t<text>` and `HIT\\t<area>\\t<decision>\\t<path>`.
    Silent (empty) for a command that modifies no path. A command over an analysis cap, or an area
    whose patterns the regex budget could not evaluate, is a synthetic fail-closed HIT whose
    decision is capped at `ask`: `deny` is reserved for a REAL path match. Never raises."""
    try:
        _reset_budget()
        paths, truncated = command_paths(command, repo_root, cwd)
        truncated = truncated or bool(cut)  # the caller cut the command before handing it over
        if not paths and not truncated:
            return []
        cfg = load_risk_area_patterns(repo_root)
        warnings = list(cfg["warnings"])
        declared = [a for a in RISK_PATTERN_AREAS if cfg["areas"][a]["patterns"] or cfg["areas"][a]["unevaluated"]]
        if truncated and declared:
            warnings.append("command exceeds the analysis caps and was truncated - treated as touching every declared risk area")
        hit_lines = []
        for area in declared:
            slot = cfg["areas"][area]
            decision = effective_decision("pre-tool-guard", slot["decision"])
            synthetic = []
            if truncated:
                synthetic.append(_TRUNCATED_COMMAND)
            if slot["unevaluated"]:
                synthetic.append(_UNEVALUATED)
            hits, complete = match_paths(slot["patterns"], paths, warnings) if slot["patterns"] else ([], True)
            if not complete:
                synthetic.append(_UNEVALUATED)
            for text in dict.fromkeys(synthetic):
                hit_lines.append("HIT\t%s\task\t%s" % (area, text))
            for path in hits[:5]:
                hit_lines.append("HIT\t%s\t%s\t%s" % (area, decision, re.sub(r"[\t\r\n]+", " ", path)))
        return ["WARN\t" + w for w in dict.fromkeys(warnings)] + hit_lines
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
    except _BudgetExhausted:
        warnings.append(_BUDGET_WARNING)
    except Exception:
        pass
    return {"resources": resources, "warnings": warnings}


def resource_match(repo_root, tool_name, command):
    """(resource_name, warnings): first configured resource whose trigger matches the Bash
    command (tool_name == "Bash") or the MCP tool name; ("", warnings) otherwise. Never raises."""
    _reset_budget()
    cfg = load_resource_triggers(repo_root)
    warnings = list(cfg["warnings"])
    text = command if tool_name == "Bash" else tool_name
    try:
        for name, triggers in cfg["resources"].items():
            if triggers and match_paths(triggers, [text or ""], warnings)[0]:
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
        _reset_budget()
        if mode == "risk-paths":
            consumer = argv[3]
            lines = [p for p in sys.stdin.read().splitlines() if p]
            truncated = len(lines) > _MAX_PATH_ITEMS
            paths = lines[:_MAX_PATH_ITEMS]
            cfg = load_risk_area_patterns(root)
            warnings = list(cfg["warnings"])
            declared = [a for a in RISK_PATTERN_AREAS if cfg["areas"][a]["patterns"] or cfg["areas"][a]["unevaluated"]]
            if truncated and declared:
                warnings.append("file list has %d entries and was truncated to the first %d - treated as touching every declared risk area" % (len(lines), _MAX_PATH_ITEMS))
            for area in RISK_PATTERN_AREAS:
                print("AREA\t%s\t%s" % (area, effective_decision(consumer, cfg["areas"][area]["decision"])))
            for area in RISK_PATTERN_AREAS:
                slot = cfg["areas"][area]
                if area not in declared:
                    continue
                synthetic = []
                if truncated:
                    synthetic.append(_TRUNCATED_PATHS)
                if slot["unevaluated"]:
                    synthetic.append(_UNEVALUATED)
                hits, complete = match_paths(slot["patterns"], paths, warnings) if slot["patterns"] else ([], True)
                if not complete:
                    synthetic.append(_UNEVALUATED)
                for text in dict.fromkeys(synthetic):
                    print("HIT\t%s\t%s" % (area, text))
                for path in hits:
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
