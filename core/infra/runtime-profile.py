#!/usr/bin/env python3
"""runtime-profile.py — detect which vendor runtimes are usable and recommend a main vendor.

Subcommands: detect [--json] | recommend [--json] | save [--main VENDOR].

Reads only local CLIs and files; never writes auth state, never touches the network. Only
three values are ever extracted: claude loggedIn + subscriptionType, and the codex JWT's
chatgpt_plan_type claim. Everything else (email, org, tokens) is left unread.
Antigravity authenticated="unknown" (agy installed, no token file) still counts as a usable
reviewer, by design: authentication cannot be verified locally.
Any failure degrades to "unknown"; the script never raises on detection.

Env seams: AGENT_PROFILE_FILE, CODEX_HOME, HOME, PATH.
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

TIMEOUT_S = 10
PLAN_RE = re.compile(r"^[a-z0-9_-]{1,32}$")
# runtime -> (binary, vendor); order = main-vendor preference
RUNTIMES = {
    "claude": ("claude", "anthropic"),
    "codex": ("codex", "openai"),
    "antigravity": ("agy", "google"),
}
VENDORS = ("anthropic", "openai", "google")
REVIEWER_ORDER = ("openai", "google", "anthropic")


def _plan(value: Any) -> str:
    if isinstance(value, str) and PLAN_RE.fullmatch(value.lower()):
        return value.lower()
    return "unknown"


def _run(cmd: list[str]) -> subprocess.CompletedProcess[str] | None:
    try:
        return subprocess.run(
            cmd, capture_output=True, text=True, timeout=TIMEOUT_S, check=False,
            stdin=subprocess.DEVNULL,
        )
    except (OSError, subprocess.SubprocessError):
        return None


def _detect_claude() -> tuple[Any, str]:
    proc = _run(["claude", "auth", "status", "--json"])
    if proc is None:
        return "unknown", "unknown"
    # Parsed regardless of exit code: a logged-out claude may exit 1 with loggedIn=false.
    try:
        data = json.loads(proc.stdout)
        logged_in = data.get("loggedIn")
        sub = data.get("subscriptionType")
    except (ValueError, AttributeError):
        return "unknown", "unknown"
    if logged_in is True:
        return True, _plan(sub)
    return (False if logged_in is False else "unknown"), "unknown"


def _codex_plan() -> str:
    home = os.environ.get("CODEX_HOME") or str(Path.home() / ".codex")
    try:
        auth = json.loads((Path(home) / "auth.json").read_text())
        token = auth["tokens"]["id_token"]
        seg = token.split(".")[1]
        payload = json.loads(base64.urlsafe_b64decode(seg + "=" * (-len(seg) % 4)))
        return _plan(payload["https://api.openai.com/auth"]["chatgpt_plan_type"])
    except (OSError, ValueError, KeyError, IndexError, TypeError, AttributeError):
        return "unknown"


def _detect_codex() -> tuple[Any, str]:
    proc = _run(["codex", "login", "status"])
    if proc is None:
        return "unknown", "unknown"
    if proc.returncode != 0:
        # Only an explicit "not logged in" is False; a crash or usage error stays unknown.
        if "not logged in" in (proc.stdout + proc.stderr).lower():
            return False, "unknown"
        return "unknown", "unknown"
    return True, _codex_plan()


def _detect_antigravity() -> tuple[Any, str]:
    # Existence-only: the token file is never opened, and agy is never run (quota).
    token = Path.home() / ".gemini" / "antigravity-cli" / "antigravity-oauth-token"
    return (True if token.exists() else "unknown"), "unknown"


_DETECTORS = {
    "claude": _detect_claude,
    "codex": _detect_codex,
    "antigravity": _detect_antigravity,
}


def detect() -> dict[str, dict[str, Any]]:
    out: dict[str, dict[str, Any]] = {}
    for name, (binary, _vendor) in RUNTIMES.items():
        if shutil.which(binary) is None:
            out[name] = {"installed": False, "authenticated": "unknown", "plan": "unknown"}
            continue
        try:
            auth, plan = _DETECTORS[name]()
        except Exception:  # noqa: BLE001 - detection must never raise
            auth, plan = "unknown", "unknown"
        out[name] = {"installed": True, "authenticated": auth, "plan": plan}
    return out


def recommend(det: dict[str, dict[str, Any]], main: str | None = None) -> dict[str, Any]:
    if main is None:
        main = "anthropic"
        for name, (_b, vendor) in RUNTIMES.items():
            if det[name]["authenticated"] is True:
                main = vendor
                break
    usable = {
        vendor for name, (_b, vendor) in RUNTIMES.items()
        if det[name]["installed"] and det[name]["authenticated"] is not False
    }
    reviewers = [v for v in REVIEWER_ORDER if v in usable and v != main]
    plans = {vendor: det[name]["plan"] for name, (_b, vendor) in RUNTIMES.items()}
    return {"main_vendor": main, "reviewers": reviewers, "plans": plans}


def _profile_path() -> Path:
    env = os.environ.get("AGENT_PROFILE_FILE")
    return Path(env) if env else Path.home() / ".agent" / "profile.json"


class ProfileRefusedError(Exception):
    pass


def _is_profile(path: Path) -> bool:
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return False
    return isinstance(data, dict) and "main_vendor" in data


def save(main: str | None) -> Path:
    path = _profile_path()
    if path.exists() and not _is_profile(path):
        raise ProfileRefusedError("refusing to overwrite a file that is not a runtime profile")
    rec = recommend(detect(), main)
    rec["detected_at"] = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".profile.")
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(rec, fh, indent=2)
            fh.write("\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise
    return path


def _fmt_detect(det: dict[str, dict[str, Any]]) -> str:
    return "\n".join(
        f"{n}: installed={d['installed']} authenticated={d['authenticated']} plan={d['plan']}"
        for n, d in det.items()
    )


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("detect", "recommend"):
        sub.add_parser(name).add_argument("--json", action="store_true")
    sp = sub.add_parser("save")
    sp.add_argument("--main")
    args = ap.parse_args(argv)

    if args.cmd == "detect":
        det = detect()
        print(json.dumps(det) if args.json else _fmt_detect(det))
    elif args.cmd == "recommend":
        rec = recommend(detect())
        if args.json:
            print(json.dumps(rec))
        else:
            print(f"main: {rec['main_vendor']}\nreviewers: {', '.join(rec['reviewers']) or '-'}")
    else:
        if args.main is not None and args.main not in VENDORS:
            print(f"error: --main must be one of {', '.join(VENDORS)}", file=sys.stderr)
            return 2
        try:
            print(f"profile saved: {save(args.main)}")
        except ProfileRefusedError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1
        except OSError as exc:
            # strerror only: the message must never echo file contents
            print(f"error: cannot save profile: {exc.strerror or type(exc).__name__}",
                  file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
