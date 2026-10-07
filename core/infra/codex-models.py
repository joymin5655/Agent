#!/usr/bin/env python3
"""codex-models.py — keep the codex tier profiles on a model the account can run.

Truth source: codex's self-refreshed catalog ($CODEX_HOME/models_cache.json).
Reading it is free; applying a change is gated by a paid `codex exec` probe,
because a catalog entry marked "list" can still be rejected for the account.

  check [--json]                 exit 0 match, 10 change suggested, 2 no catalog
  apply [--tier top|low] [--yes] probe candidates, rewrite the profile's model line
  upgrade-for <id>               successor of a retired/unsupported model (exit 1: none)

Tier -> family comes from $AGENT_CODEX_TIERS_FILE (default ~/.agent/codex-tiers.json),
shape-validated so no free text reaches an argv. Seams: CODEX_HOME, AGENT_CODEX_TIERS_FILE,
AGENT_STATE_DIR, AGENT_CODEX_PROBE_FAIL_TTL_DAYS (failed probes are remembered, default 30 days).
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile

DEFAULT_TIERS = {"top": "sol", "low": "luna"}
PROFILE_FOR_TIER = {"top": "deep.config.toml", "low": "quick.config.toml"}
FAMILY_RE = re.compile(r"^[a-z]+$")
ID_RE = re.compile(r"^[A-Za-z0-9._-]+$")
MODEL_LINE_RE = re.compile(r"""^(\s*model\s*=\s*)(["'])([^"']+)\2""")
EFFORT_LINE_RE = re.compile(r"""^\s*model_reasoning_effort\s*=\s*["']([^"']+)["']""")
REJECTED_RE = re.compile(
    r"model.*(not supported|retired|not found|invalid|does not exist)"
    r'|"status"\s*:\s*(400|404)\b',
    re.IGNORECASE,
)
PROBE_OK, PROBE_REJECTED, PROBE_INCONCLUSIVE = "ok", "rejected", "inconclusive"


def probe_timeout_s() -> int:
    try:
        return int(os.environ.get("AGENT_CODEX_PROBE_TIMEOUT_S", "120"))
    except ValueError:
        return 120


class ToolError(Exception):
    """A user-facing failure; main() prints it and exits with .code."""

    def __init__(self, message: str, code: int = 2) -> None:
        super().__init__(message)
        self.code = code


def codex_home() -> pathlib.Path:
    return pathlib.Path(os.environ.get("CODEX_HOME") or pathlib.Path.home() / ".codex")


def load_catalog() -> list[dict]:
    path = codex_home() / "models_cache.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        models = data["models"]
        if not isinstance(models, list):
            raise TypeError("models is not a list")
    except (OSError, ValueError, KeyError, TypeError) as exc:
        raise ToolError(f"codex catalog unreadable ({path}): {exc}") from exc
    return [m for m in models if isinstance(m, dict) and isinstance(m.get("slug"), str)]


def failed_state_path() -> pathlib.Path:
    state = os.environ.get("AGENT_STATE_DIR")
    base = pathlib.Path(state) if state else pathlib.Path.home() / ".agent" / "state"
    return base / "codex-probe-failed.json"


def load_failed() -> dict[str, str]:
    """Models whose probe failed, {slug: ISO date}; unreadable state counts as empty."""
    try:
        data = json.loads(failed_state_path().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict):
        return {}
    return {k: v for k, v in data.items() if isinstance(k, str) and isinstance(v, str)}


def save_failed(failed: dict[str, str]) -> None:
    path = failed_state_path()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(failed, indent=1), encoding="utf-8")
    except OSError:
        pass  # memory is an optimisation; losing it only brings the nag back


def recently_failed() -> set[str]:
    """Slugs excluded from resolution: a failed probe younger than the TTL.

    The TTL lets an account upgrade be picked up later instead of never.
    """
    try:
        ttl = int(os.environ.get("AGENT_CODEX_PROBE_FAIL_TTL_DAYS", "30"))
    except ValueError:
        ttl = 30
    today = datetime.datetime.now().astimezone().date()
    out = set()
    for slug, day in load_failed().items():
        try:
            age = (today - datetime.date.fromisoformat(day)).days
        except ValueError:
            continue
        if age < ttl:
            out.add(slug)
    return out


def supports_effort(model: dict, effort: str | None) -> bool:
    """False only when the catalog lists reasoning levels and effort is not among them."""
    levels = model.get("supported_reasoning_levels")
    if not effort or not isinstance(levels, list) or not levels:
        return True
    names = {x.get("effort") if isinstance(x, dict) else x for x in levels}
    return effort in names


def candidates(models: list[dict], family: str, effort: str | None = None) -> list[str]:
    """Listed, non-retiring, not-recently-failed models of a family, best first.

    Slugs end up in argv and in a rewritten TOML line, so only plain IDs pass.
    """
    skip = recently_failed()
    pool = [
        m for m in models
        if ID_RE.fullmatch(m["slug"]) and not m["slug"].startswith("-")
        and m.get("visibility") == "list"
        and not m.get("upgrade")
        and m["slug"] not in skip
        and m["slug"].endswith("-" + family)
        and supports_effort(m, effort)
    ]
    pool.sort(key=lambda m: m.get("priority") if isinstance(m.get("priority"), (int, float)) else 10**6)
    return [m["slug"] for m in pool]


def resolve(models: list[dict], family: str, effort: str | None = None) -> str | None:
    found = candidates(models, family, effort)
    return found[0] if found else None


def load_tiers() -> dict[str, str]:
    env = os.environ.get("AGENT_CODEX_TIERS_FILE")
    path = pathlib.Path(env) if env else pathlib.Path.home() / ".agent" / "codex-tiers.json"
    tiers = dict(DEFAULT_TIERS)
    if not path.is_file():
        return tiers
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(raw, dict):
            raise TypeError("top level is not an object")
    except (OSError, ValueError, TypeError) as exc:
        raise ToolError(f"tiers file unreadable ({path}): {exc}") from exc
    for tier in PROFILE_FOR_TIER:
        if tier not in raw:
            continue
        val = raw[tier]
        if not isinstance(val, str) or not FAMILY_RE.fullmatch(val):
            raise ToolError(f"tiers file {path}: '{tier}' must match ^[a-z]+$")
        tiers[tier] = val
    return tiers


def current_pin(profile: pathlib.Path) -> str | None:
    for line in profile.read_text(encoding="utf-8").splitlines():
        if line.lstrip().startswith("#"):
            continue
        m = MODEL_LINE_RE.match(line)
        if m:
            return m.group(3)
    return None


def profile_effort(profile: pathlib.Path) -> str | None:
    for line in profile.read_text(encoding="utf-8").splitlines():
        if line.lstrip().startswith("#"):
            continue
        m = EFFORT_LINE_RE.match(line)
        if m:
            return m.group(1)
    return None


def plan(tiers: dict[str, str], models: list[dict], only: str | None = None) -> list[dict]:
    rows = []
    for tier, profile_name in PROFILE_FOR_TIER.items():
        if only and tier != only:
            continue
        profile = codex_home() / profile_name
        if not profile.is_file():
            continue
        current = current_pin(profile)
        effort = profile_effort(profile)
        resolved = resolve(models, tiers[tier], effort)
        row = {
            "tier": tier,
            "family": tiers[tier],
            "profile": str(profile),
            "current": current,
            "effort": effort,
            "resolved": resolved,
            "change": bool(current and resolved and resolved != current),
        }
        if current is None:
            row["note"] = "no model line"
        rows.append(row)
    return rows


def cmd_check(args: argparse.Namespace) -> int:
    rows = plan(load_tiers(), load_catalog())
    if args.json:
        print(json.dumps({"tiers": rows}))
    else:
        for r in rows:
            if r.get("note"):
                print(f"{r['tier']}: {r['note']} in {r['profile']} (not managed)")
                continue
            mark = "->" if r["change"] else "=="
            print(f"{r['tier']}: {r['current']} {mark} {r['resolved']}")
    return 10 if any(r["change"] for r in rows) else 0


def probe(model: str) -> str:
    """OK / REJECTED (the account cannot use this model) / INCONCLUSIVE (anything else).

    Only a rejection is evidence about the model; a timeout, a missing binary or a
    usage limit says nothing about it and must not be remembered against it.
    """
    cmd = ["codex", "exec", "--skip-git-repo-check", "-s", "read-only", "-m", model,
           "-c", "model_reasoning_effort=low", "Reply with exactly: OK"]
    with tempfile.TemporaryDirectory() as cwd:
        try:
            proc = subprocess.run(cmd, cwd=cwd, stdin=subprocess.DEVNULL, capture_output=True,
                                  text=True, timeout=probe_timeout_s(), check=False)
        except (OSError, subprocess.TimeoutExpired):
            return PROBE_INCONCLUSIVE
    lines = (proc.stdout + "\n" + proc.stderr).splitlines()
    if proc.returncode == 0 and "OK" in lines:
        return PROBE_OK
    if proc.returncode != 0 and any(
        ln.startswith("ERROR:") and REJECTED_RE.search(ln) for ln in lines
    ):
        return PROBE_REJECTED
    return PROBE_INCONCLUSIVE


def backup(profile: pathlib.Path) -> pathlib.Path:
    stamp = datetime.datetime.now().astimezone().date().isoformat()
    dest = profile.with_name(f"{profile.name}.bak-{stamp}")
    n = 1
    while dest.exists():
        n += 1
        dest = profile.with_name(f"{profile.name}.bak-{stamp}-{n}")
    dest.write_bytes(profile.read_bytes())
    return dest


def rewrite_model(profile: pathlib.Path, new: str) -> None:
    lines = profile.read_text(encoding="utf-8").splitlines(keepends=True)
    for i, line in enumerate(lines):
        if line.lstrip().startswith("#"):
            continue
        m = MODEL_LINE_RE.match(line)
        if m:
            lines[i] = f"{m.group(1)}{m.group(2)}{new}{m.group(2)}" + line[m.end():]
            break
    else:
        raise ToolError(f"{profile}: no model line to rewrite", 1)
    profile.write_text("".join(lines), encoding="utf-8")


def cmd_apply(args: argparse.Namespace) -> int:
    tiers = load_tiers()
    models = load_catalog()
    todo = [r for r in plan(tiers, models, args.tier) if r["change"]]
    if not todo:
        print("codex profiles already match the catalog")
        return 0
    if not args.yes:
        if not sys.stdin.isatty():
            print("apply runs paid codex probes; pass --yes (no TTY to ask on)", file=sys.stderr)
            return 3
        reply = input(f"probe and update {', '.join(r['tier'] for r in todo)}? [y/N] ")
        if reply.strip().lower() not in ("y", "yes"):
            return 3
    any_failed = False
    for row in todo:
        profile = pathlib.Path(row["profile"])
        for model in candidates(models, row["family"], row["effort"]):
            if model == row["current"]:
                print(f"{row['tier']}: {model} stays (best candidate that passed or is pinned)")
                break
            verdict = probe(model)
            if verdict == PROBE_OK:
                failed = load_failed()
                if failed.pop(model, None) is not None:
                    save_failed(failed)
                bak = backup(profile)
                rewrite_model(profile, model)
                print(f"{row['tier']}: {row['current']} -> {model} (backup {bak.name})")
                break
            if verdict == PROBE_INCONCLUSIVE:
                print(f"{row['tier']}: probe of {model} was inconclusive (timeout, missing codex "
                      "or a limit); nothing changed, not remembered. Retry later.", file=sys.stderr)
                return 1
            failed = load_failed()
            failed[model] = datetime.datetime.now().astimezone().date().isoformat()
            save_failed(failed)
            print(f"{row['tier']}: probe rejected {model}", file=sys.stderr)
        else:
            print(f"{row['tier']}: no candidate passed the probe; profile unchanged", file=sys.stderr)
            any_failed = True
    return 1 if any_failed else 0


def cmd_upgrade_for(args: argparse.Namespace) -> int:
    if not ID_RE.fullmatch(args.model) or args.model.startswith("-"):
        print("model id has an invalid shape", file=sys.stderr)
        return 2
    models = load_catalog()
    skip = recently_failed()
    for m in models:
        up = m.get("upgrade")
        if m["slug"] == args.model and isinstance(up, dict):
            target = up.get("model")
            if isinstance(target, str) and ID_RE.fullmatch(target) and not target.startswith("-") \
                    and target not in skip:
                print(target)
                return 0
    family = args.model.rsplit("-", 1)[-1]
    if FAMILY_RE.fullmatch(family):
        for slug in candidates(models, family):
            if slug != args.model:
                print(slug)
                return 0
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("check")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_check)
    p = sub.add_parser("apply")
    p.add_argument("--tier", choices=sorted(PROFILE_FOR_TIER))
    p.add_argument("--yes", action="store_true")
    p.set_defaults(fn=cmd_apply)
    p = sub.add_parser("upgrade-for")
    p.add_argument("model")
    p.set_defaults(fn=cmd_upgrade_for)
    args = parser.parse_args()
    try:
        return args.fn(args)
    except ToolError as exc:
        print(f"codex-models: {exc}", file=sys.stderr)
        return exc.code
    except OSError as exc:
        print(f"codex-models: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
