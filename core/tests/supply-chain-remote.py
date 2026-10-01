#!/usr/bin/env python3
"""supply-chain-remote.py — remote-code classes 5-7 for supply-chain-scan.sh.

Reads "<kind>\\t<path>" lines on stdin and prints one hit per line in the
scanner's report format. Kinds:
  P  auto-loaded prose (class 5 only, with the host allowlist tolerance)
  C  auto-fired hook code (classes 5, 6 text form, 7)
  M  code-wiring manifest JSON (classes 5, 6 text + JSON form, 7)

Class 5  fetch-and-execute: a fetch (curl/wget) piped into, substituted into,
         or eval'd by an interpreter. Always a hit in C/M. In P a segment is
         tolerated only when it names at least one URL and every URL host in
         that segment is allowlisted (segments split on ; && ||, so an
         allowlisted URL elsewhere on the line cannot vouch for a URL-less
         fetch). Also matched on a whitespace-flattened copy of P files, so a
         pipe soft-wrapped across lines cannot evade.
Class 6  unpinned remote runner: npx/npm exec with --yes or --package, and
         bunx/pnpm dlx/yarn dlx/uvx/pipx run, with a package that is not
         pinned to an exact version. A range
         (^2.1.0, ~1, 2) or a dist-tag (latest, next) is not a pin.
Class 7  off-allowlist URL host in C/M. IP literals (dotted, decimal, hex,
         IPv6), localhost and single-label names count as hosts; only known
         documentation placeholders are skipped. Userinfo
         (https://allowed@evil) is reported whole and never matches.

Allowlist: $SUPPLY_CHAIN_ALLOWLIST, else core/tests/supply-chain-allowlist.txt.
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ALLOWLIST = os.environ.get("SUPPLY_CHAIN_ALLOWLIST") or os.path.join(HERE, "supply-chain-allowlist.txt")

FETCH = r"(?:curl|wget)\b"
INTERP = (r"(?:sudo\s+)?(?:env\s+)?(?:/\S*/)?"
          r"(?:(?:ba|z|da|k)?sh|python[0-9.]*|node|perl|ruby)\b")
EXEC = re.compile("|".join([
    FETCH + r"[^|;&\n]*\|\s*" + INTERP,                         # curl … | sh
    INTERP + r"\s+<\(\s*" + FETCH,                              # bash <(curl …)
    r"(?:eval|source|\.)\s+[\"']?(?:\$\(|<\()\s*" + FETCH,      # eval "$(curl …)"
    INTERP + r"\s+-c\s+[\"']?\$\(\s*" + FETCH,                  # bash -c "$(curl …)"
]), re.IGNORECASE)
SEGMENT_SPLIT = re.compile(r";|&&|\|\|")
URL = re.compile(r"https?://([^/?#\s\"'`<>()]+)", re.IGNORECASE)
PLACEHOLDER_HOSTS = {"host", "hostname", "example", "domain", "server", "your-host"}
EXACT_VERSION = re.compile(r"^v?\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$")
RUNNER = re.compile(r"\b(npx|bunx|uvx|pnpm\s+dlx|yarn\s+dlx|npm\s+exec|pipx\s+run)\s+([^\n\"'`;|&]*)", re.IGNORECASE)
VALUE_FLAGS = {"--package", "-p", "--from", "--spec", "--with", "--python"}


def load_allowlist():
    hosts = set()
    try:
        with open(ALLOWLIST, encoding="utf-8") as fh:
            for line in fh:
                h = line.split("#", 1)[0].strip().lower()
                if h:
                    hosts.add(h)
    except OSError:
        pass
    return hosts


def url_hosts(text):
    out = []
    for auth in URL.findall(text):
        a = auth.lower()
        if "@" in a:                      # userinfo: never an allowlisted host
            out.append(a)
            continue
        if a.startswith("["):             # IPv6 literal, keep brackets
            out.append(a.split("]", 1)[0] + "]")
            continue
        h = a.rsplit(":", 1)[0] if re.search(r":\d*$", a) else a
        h = h.rstrip(".")
        if h and ("." in h or h not in PLACEHOLDER_HOSTS):
            out.append(h)
    return out


def exec_segments(text):
    return [s for s in SEGMENT_SPLIT.split(text) if EXEC.search(s)]


def prose_segment_bad(seg, allowed):
    hosts = url_hosts(seg)
    return not hosts or any(h not in allowed for h in hosts)


def runner_package(runner, rest):
    """First package token after a runner (honoring --package/--from values)."""
    toks = rest.split()
    i = 0
    while i < len(toks):
        t = toks[i]
        if t == "--":
            i += 1
            continue
        if t.startswith("-"):
            name, _, val = t.partition("=")
            if name in VALUE_FLAGS:
                return val if val else (toks[i + 1] if i + 1 < len(toks) else "")
            i += 1
            continue
        return t
    return ""


def pinned(runner, pkg):
    runner = runner.split()[0].lower()
    if not pkg:
        return True                       # nothing to run (e.g. a flag-only probe)
    if runner in ("uvx", "pipx"):
        m = re.match(r"^[A-Za-z0-9_.\-\[\],]+(?:==|@)(.+)$", pkg)
        return bool(m and EXACT_VERSION.match(m.group(1)))
    bare = pkg.split("/", 1)[1] if pkg.startswith("@") and "/" in pkg else pkg
    if "@" not in bare:
        return False
    return bool(EXACT_VERSION.match(bare.rsplit("@", 1)[1]))


def fetches_silently(runner, rest):
    """npx / npm exec only fetch without a prompt when told to (--yes or an
    explicit --package); bare `npx tsc` runs a local bin, and in a
    non-interactive hook an uninstalled package fails instead of downloading.
    The dlx runners, bunx, uvx and pipx run always fetch."""
    r = runner.split()[0].lower()
    if r in ("npx", "npm"):
        toks = rest.split()
        return any(t in ("-y", "--yes") or t.split("=", 1)[0] in ("--package", "-p") for t in toks)
    return True


def runner_hits(text):
    hits = []
    for m in RUNNER.finditer(text):
        runner, rest = m.group(1), m.group(2)
        if not fetches_silently(runner, rest):
            continue
        pkg = runner_package(runner, rest)
        if not pinned(runner, pkg):
            hits.append(f"{runner} {pkg}".strip())
    return hits


def json_commands(obj):
    """Yield 'cmd arg arg …' strings for every {command, args} object."""
    if isinstance(obj, dict):
        cmd, args = obj.get("command"), obj.get("args")
        if isinstance(cmd, str):
            parts = [os.path.basename(cmd.split()[0])] + cmd.split()[1:] if cmd.strip() else []
            if isinstance(args, list):
                parts += [a for a in args if isinstance(a, str)]
            if parts:
                yield " ".join(parts)
        for v in obj.values():
            yield from json_commands(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from json_commands(v)


def scan(kind, path, allowed):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        return []
    hits = []
    lines = text.splitlines()
    if kind == "P":
        line_hit = False
        for n, line in enumerate(lines, 1):
            if any(prose_segment_bad(s, allowed) for s in exec_segments(line)):
                hits.append(f"{path}:{n}:{line.strip()}")
                line_hit = True
        if not line_hit:
            flat = re.sub(r"\s+", " ", text)
            bad = [s for s in exec_segments(flat) if prose_segment_bad(s, allowed)]
            if bad:
                hits.append(f"{path} (wrapped): {bad[0].strip()[:160]}")
        return hits
    for n, line in enumerate(lines, 1):           # C and M: class 5, no tolerance
        if exec_segments(line):
            hits.append(f"{path}:{n}:{line.strip()}")
    flat_runners = set(runner_hits(text))
    if kind == "M":
        try:
            for cmd in json_commands(json.loads(text)):
                flat_runners.update(runner_hits(cmd))
        except ValueError:
            pass
    hits += [f"{path}: unpinned remote package: {r}" for r in sorted(flat_runners)]
    hits += [f"{path}: off-allowlist URL host: {h}"
             for h in sorted(set(url_hosts(text))) if h not in allowed]
    return hits


def main():
    allowed = load_allowlist()
    for raw in sys.stdin:
        kind, _, path = raw.rstrip("\n").partition("\t")
        if kind in ("P", "C", "M") and path:
            for h in scan(kind, path, allowed):
                print(h)
    return 0


if __name__ == "__main__":
    sys.exit(main())
