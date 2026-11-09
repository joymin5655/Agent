#!/usr/bin/env python3
"""gather_sources.py — collect the repository files a plan or design document cites.

usage: gather_sources.py DOC --repo DIR --harness-root DIR [--max-bytes 122880] [--per-file 40960]
       gather_sources.py --candidates DOC [--all] [-z]
Candidates: backticked tokens and markdown link targets that look like paths, with `:line` /
`:a-b` suffixes and `#anchors` removed, first mention first, duplicates dropped. Parentheses,
square brackets and `$` may be part of a path (`app/(auth)/x.tsx`, `[...nextauth]`); a bracket is
trimmed from a token's edge only when unbalanced.
--candidates prints them (one per line, NUL-terminated with -z) and stops; URLs are left out.
--all (only with --candidates) adds every bare path-like run anywhere in the text, fenced blocks
included, after the inline/link candidates (a run is ASCII only, so a Korean particle ends it).
Source gathering uses the inline/link candidates only.
Otherwise prints markdown: one `### <repo-relative path>` + fenced content per included file,
then `### Not included` with each skipped candidate and its reason (outside repository /
secret-like / no such path / untracked / not a file / binary / too large / over budget / URL).
A file is included only if its real path is inside --repo, git has it staged (the text inlined
is the staged version from the index, never the working-tree copy), it is not secret-like
(name or folder of the cited path and of the resolved path, the project's declared
risk_areas.secrets.paths read through --harness-root, or secret-looking content), it is text, and
it fits the caps. Nothing outside the repository is ever read or printed; matches are never shown.
exit: 0 ok | 2 usage or setup error (also: the project's declared secret paths cannot be read)
"""
import argparse
import fnmatch
import os
import re
import subprocess
import sys

EXTS = {"py", "sh", "md", "json", "yml", "yaml", "toml", "ts", "tsx", "js", "jsx", "mjs", "cjs",
        "go", "rs", "rb", "java", "kt", "swift", "php", "cs", "c", "h", "cc", "cpp", "hpp", "sql",
        "txt", "cfg", "ini", "html", "css", "scss", "vue", "svelte", "ex", "exs", "scala", "dart",
        "rego", "lock", "env", "pem", "key", "p12"}
SECRET_BASE = [".env*", "*.pem", "*.key", "id_rsa*", "*credential*", "*.p12", "id_ed25519*",
               "id_ecdsa*", "id_dsa*", "*.pfx", "*.jks", "*.keystore", "*.p8", "*.ppk", ".npmrc",
               ".netrc", ".pypirc", "*.tfvars", "*.tfstate*", "*secret*", "*.gpg", "*.asc",
               "*.kdbx", ".pgpass", ".htpasswd"]
SECRET_DIRS = {"secret", "secrets", ".ssh", ".aws", ".gnupg", "credentials", "keys", ".kube",
               ".docker"}
CONTENT_SECRETS = [re.compile(p) for p in (
    "-----BEGIN " + "[A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?" + "-----",
    r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b",
    r"\b[sr]k_(?:live|test)_[A-Za-z0-9]{16,}",
    r"\bglpat-[A-Za-z0-9_-]{20,}",
    r"\bhf_[A-Za-z0-9]{30,}",
    r"\bnpm_[A-Za-z0-9]{30,}",
    r"\bxapp-[A-Za-z0-9-]{10,}",
    r"\bGOCSPX-[A-Za-z0-9_-]{20,}",
    r"hooks\.slack\.com/services/[A-Za-z0-9/]{20,}",
    # scheme://user:password@ — template placeholders ($ { } < >) are not a password
    r"\b[A-Za-z][A-Za-z0-9+.-]{0,30}://[^\s:/@${}<>]{1,256}:[^\s/@${}<>]{1,256}@",
    r"\bgh[pousr]_[A-Za-z0-9]{36,}\b",
    r"\bgithub_pat_[A-Za-z0-9_]{22,}\b",
    r"\bxox[abeprs]-[A-Za-z0-9-]{10,}",
    r"\bsk-[A-Za-z0-9_-]{20,}",
    r"\bAIza[0-9A-Za-z_-]{35}\b",
    r"\beyJ[A-Za-z0-9_\-]{20,}\.eyJ[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}\b",
)]
RUN = re.compile(r"[A-Za-z0-9_./@+~%$()\[\]-]+")
INLINE = re.compile(r"`((?:[^`\n]|\n(?![ \t]*\n))+)`")  # a code span may wrap, not cross a paragraph
LINK = re.compile(r"\]\(\s*<?([^)\s>]+)")
FENCE = re.compile(r"^(```|~~~).*?^\1[^\n]*$", re.DOTALL | re.MULTILINE)
URL = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*://")


def _trim(tok):
    """Strip trailing `.,;`, a trailing `)`/`]` and a leading `(`/`[` only while unbalanced."""
    prev = None
    while tok != prev:
        prev = tok
        tok = tok.rstrip(".,;")
        for op, cl in (("(", ")"), ("[", "]")):
            while tok.endswith(cl) and tok.count(cl) > tok.count(op):
                tok = tok[:-1]
            while tok.startswith(op) and tok.count(op) > tok.count(cl):
                tok = tok[1:]
    return tok


def clean(tok):
    tok = _trim(tok.strip().strip("'\""))
    tok = tok.split("#", 1)[0]
    tok = re.sub(r":\d+(-\d+)?$", "", tok)
    return _trim(tok)


def looks_like_path(tok):
    if not tok or tok.startswith("-") or not re.fullmatch(r"[\w./@+~%$()\[\]-]+", tok):
        return False
    if "/" in tok:
        return tok.strip("/") != "" and not tok.startswith("//")
    if tok.startswith(".env"):
        return True
    base = tok.rsplit(".", 1)
    return len(base) == 2 and bool(base[0]) and base[1].lower() in EXTS


def candidates(text, keep_urls=False, all_runs=False):
    """(token, is_url) in first-mention order, deduplicated. all_runs adds, after the
    inline/link candidates, every bare path-like run of the full text (fences included)."""
    full = text
    text = FENCE.sub("", text)
    raw = []
    for m in re.finditer(INLINE.pattern + "|" + LINK.pattern, text):
        if m.group(1) is not None:
            raw.extend(m.group(1).split())
        else:
            raw.append(m.group(2))
    if all_runs:
        raw.extend(RUN.findall(full))
    seen, out = set(), []
    for tok in raw:
        is_url = bool(URL.match(tok.strip().strip("'\"")))
        if is_url:
            tok = tok.strip().strip("'\"").rstrip(".,;)")
        else:
            tok = clean(tok)
            if not looks_like_path(tok):
                continue
        if tok in seen or (is_url and not keep_urls):
            continue
        seen.add(tok)
        out.append((tok, is_url))
    return out


def secret_like(rel):
    parts = rel.lower().split("/")
    if SECRET_DIRS.intersection(parts[:-1]):
        return True
    base = parts[-1]
    return any(fnmatch.fnmatch(base, p) for p in SECRET_BASE)


def project_secret_tokens(harness_root, repo):
    """The project's declared risk_areas.secrets.paths tokens; None when they cannot be honored."""
    hooks = os.path.join(harness_root or "", "core", "hooks")
    if not harness_root or not os.path.isfile(os.path.join(hooks, "hook_config.py")):
        print(f"gather_sources: --harness-root must hold core/hooks/hook_config.py: {harness_root}",
              file=sys.stderr)
        return None
    sys.path.insert(0, hooks)
    try:
        import hook_config
        if hook_config.risk_areas_unparseable(repo):
            print("gather_sources: the project's risk_areas cannot be parsed (PyYAML missing); "
                  "its declared secret paths cannot be honored", file=sys.stderr)
            return None
        return list(hook_config.load_risk_area_secret_paths(repo))
    except (ImportError, SyntaxError, AttributeError) as e:  # fail closed; loaders never raise
        print(f"gather_sources: cannot load hook_config ({type(e).__name__}); "
              "the project's declared secret paths cannot be honored", file=sys.stderr)
        return None
    finally:
        if sys.path and sys.path[0] == hooks:
            sys.path.pop(0)


def _git(repo, *args):
    return subprocess.run(["git", "-C", repo, "-c", "core.fsmonitor=", *args],
                          capture_output=True, check=False)


def staged_size(repo, rel):
    """Size of the stage-0 index entry for the exact path rel (no globbing); None if none."""
    r = _git(repo, "cat-file", "-s", ":0:" + rel)
    if r.returncode != 0:
        return None
    try:
        return int(r.stdout.strip())
    except ValueError:
        return None


def staged_blob(repo, rel):
    r = _git(repo, "cat-file", "blob", ":0:" + rel)
    return r.stdout if r.returncode == 0 else None


def fence_for(text):
    longest = max((len(m) for m in re.findall(r"`+", text)), default=0)
    return "`" * max(3, longest + 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("doc")
    ap.add_argument("--repo")
    ap.add_argument("--max-bytes", type=int, default=122880)
    ap.add_argument("--per-file", type=int, default=40960)
    ap.add_argument("--harness-root")
    ap.add_argument("--candidates", action="store_true")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("-z", action="store_true")
    a = ap.parse_args()
    if a.all and not a.candidates:
        print("usage: gather_sources.py --candidates DOC [--all] [-z]  (--all needs --candidates)",
              file=sys.stderr)
        return 2
    try:
        with open(a.doc, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError as e:
        print(f"gather_sources: cannot read {a.doc}: {e.strerror}", file=sys.stderr)
        return 2
    if a.candidates:
        sep = "\0" if a.z else "\n"
        for tok, _ in candidates(text, all_runs=a.all):
            sys.stdout.write(tok + sep)
        return 0
    if not a.repo or not os.path.isdir(a.repo):
        print("gather_sources: --repo must be an existing directory", file=sys.stderr)
        return 2
    repo = os.path.realpath(a.repo)
    proj = project_secret_tokens(a.harness_root, repo)
    if proj is None:
        return 2
    included, skipped, total = [], [], 0
    handled = set()
    for tok, is_url in candidates(text, keep_urls=True):
        if is_url:
            skipped.append((tok, "URL"))
            continue
        path = os.path.expanduser(tok)  # `~/x` is a home path, not a repo folder named "~"
        full = os.path.realpath(path if os.path.isabs(path) else os.path.join(repo, path))
        if os.path.commonpath([repo, full]) != repo:
            skipped.append((tok, "outside repository"))
            continue
        rel = os.path.relpath(full, repo)
        cited = os.path.normpath(os.path.relpath(path, repo) if os.path.isabs(path) else path)
        if (cited, rel) in handled:
            continue
        handled.add((cited, rel))
        if secret_like(cited) or secret_like(rel):
            skipped.append((tok, "secret-like"))
        elif any(t and (t in cited or t in rel) for t in proj):
            skipped.append((tok, "secret-like (project)"))
        elif not os.path.lexists(full):
            skipped.append((tok, "no such path"))
        elif (size := staged_size(repo, rel)) is None:
            skipped.append((tok, "not a file" if os.path.isdir(full) else "untracked"))
        else:
            if size > a.per_file:
                skipped.append((tok, "too large"))
                continue
            data = staged_blob(repo, rel)
            if data is None:
                skipped.append((tok, "untracked"))
                continue
            try:
                if b"\0" in data[:8192]:
                    raise ValueError
                body = data.decode("utf-8")
            except ValueError:
                skipped.append((tok, "binary"))
                continue
            if any(rx.search(body) for rx in CONTENT_SECRETS):
                skipped.append((tok, "secret-like content"))
                continue
            if any(rel == r for r, _ in included):
                continue
            if total + len(data) > a.max_bytes:
                skipped.append((tok, "over budget"))
                continue
            total += len(data)
            included.append((rel, body))
    out = []
    for rel, body in included:
        f = fence_for(body)
        out.append(f"### {rel}\n\n{f}\n{body.rstrip(chr(10))}\n{f}\n")
    if not included:
        out.append("(no repository file cited by the document could be included)\n")
    if skipped:
        out.append("### Not included\n\n" + "\n".join(f"- {t} — {why}" for t, why in skipped) + "\n")
    sys.stdout.write("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
