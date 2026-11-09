#!/usr/bin/env python3
"""gather_sources.py — collect the repository files a plan or design document cites.

usage: gather_sources.py DOC --repo DIR [--max-bytes 122880] [--per-file 40960]
       gather_sources.py --candidates DOC [-z]
Candidates: backticked tokens and markdown link targets that look like paths, with `:line` /
`:a-b` suffixes and `#anchors` removed, first mention first, duplicates dropped.
--candidates prints them (one per line, NUL-terminated with -z) and stops; URLs are left out.
Otherwise prints markdown: one `### <repo-relative path>` + fenced content per included file,
then `### Not included` with each skipped candidate and its reason (outside repository /
secret-like / no such path / untracked / not a file / binary / too large / over budget / URL).
A file is included only if its real path is inside --repo, git tracks it, it is not secret-like,
it is text, and it fits the caps. Nothing outside the repository is ever read or printed.
exit: 0 ok | 2 usage or setup error
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
SECRET_BASE = [".env*", "*.pem", "*.key", "id_rsa*", "*credential*", "*.p12"]
INLINE = re.compile(r"`((?:[^`\n]|\n(?![ \t]*\n))+)`")  # a code span may wrap, not cross a paragraph
LINK = re.compile(r"\]\(\s*<?([^)\s>]+)")
FENCE = re.compile(r"^(```|~~~).*?^\1[^\n]*$", re.DOTALL | re.MULTILINE)
URL = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*://")


def clean(tok):
    tok = tok.strip().strip("'\"").rstrip(".,;)")
    tok = tok.split("#", 1)[0]
    tok = re.sub(r":\d+(-\d+)?$", "", tok)
    return tok


def looks_like_path(tok):
    if not tok or tok.startswith("-") or not re.fullmatch(r"[\w./@+~%-]+", tok):
        return False
    if "/" in tok:
        return tok.strip("/") != "" and not tok.startswith("//")
    if tok.startswith(".env"):
        return True
    base = tok.rsplit(".", 1)
    return len(base) == 2 and bool(base[0]) and base[1].lower() in EXTS


def candidates(text, keep_urls=False):
    """(token, is_url) in first-mention order, deduplicated."""
    text = FENCE.sub("", text)
    raw = []
    for m in re.finditer(INLINE.pattern + "|" + LINK.pattern, text):
        if m.group(1) is not None:
            raw.extend(m.group(1).split())
        else:
            raw.append(m.group(2))
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
    if "secrets" in parts[:-1]:
        return True
    base = parts[-1]
    return any(fnmatch.fnmatch(base, p) for p in SECRET_BASE)


def tracked(repo, rel):
    r = subprocess.run(["git", "-C", repo, "ls-files", "--error-unmatch", "--", rel],
                       capture_output=True, text=True, check=False)
    return r.returncode == 0


def fence_for(text):
    longest = max((len(m) for m in re.findall(r"`+", text)), default=0)
    return "`" * max(3, longest + 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("doc")
    ap.add_argument("--repo")
    ap.add_argument("--max-bytes", type=int, default=122880)
    ap.add_argument("--per-file", type=int, default=40960)
    ap.add_argument("--candidates", action="store_true")
    ap.add_argument("-z", action="store_true")
    a = ap.parse_args()
    try:
        with open(a.doc, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError as e:
        print(f"gather_sources: cannot read {a.doc}: {e.strerror}", file=sys.stderr)
        return 2
    if a.candidates:
        sep = "\0" if a.z else "\n"
        for tok, _ in candidates(text):
            sys.stdout.write(tok + sep)
        return 0
    if not a.repo or not os.path.isdir(a.repo):
        print("gather_sources: --repo must be an existing directory", file=sys.stderr)
        return 2
    repo = os.path.realpath(a.repo)
    included, skipped, total = [], [], 0
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
        if secret_like(rel):
            skipped.append((tok, "secret-like"))
        elif not os.path.lexists(full):
            skipped.append((tok, "no such path"))
        elif not tracked(repo, rel):
            skipped.append((tok, "untracked"))
        elif not os.path.isfile(full):
            skipped.append((tok, "not a file"))
        else:
            size = os.path.getsize(full)
            if size > a.per_file:
                skipped.append((tok, "too large"))
                continue
            with open(full, "rb") as fh:
                data = fh.read()
            try:
                if b"\0" in data[:8192]:
                    raise ValueError
                body = data.decode("utf-8")
            except ValueError:
                skipped.append((tok, "binary"))
                continue
            if total + len(data) > a.max_bytes:
                skipped.append((tok, "over budget"))
                continue
            if any(rel == r for r, _ in included):
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
