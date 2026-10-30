#!/usr/bin/env python3
"""anonymize.py — strip authorship traces from a draft before external critique.

Deletes whole lines only (plus HTML-comment spans), so every remaining character is
byte-identical to the input and a critic's verbatim quote still matches the draft.

Removed: author / byline lines and a bare "이름:" label (only in the first 10 lines of the
body, after any front matter), a line holding nothing but an email address (plus blanks or
decoration), commit-style trailers (Co-Authored-By, Signed-off-by, "Generated with ..."),
HTML comments (<!-- -->), and author-like keys in a leading front-matter block.
Left alone: an email address inside a line of text ("문의: help@example.com"), an "Author:"
list item deep in the body, an unclosed "<!--" (warned on stderr, not deleted), and line
endings (CRLF stays CRLF).

usage: anonymize.py [FILE]   (stdin when FILE is absent or "-") -> stdout; count on stderr
"""
import re
import sys

AUTHOR_LINE = re.compile(
    r"^[\s>*_\-]*(?:\*\*)?(?:작성자|글쓴이|저자|필자|Author|Authored by|Written by|Prepared by|Posted by)(?:\*\*)?\s*[:：]",
    re.I)
NAME_LINE = re.compile(r"^[\s>*_\-]*(?:\*\*)?(?:이름|성명|Name)(?:\*\*)?\s*[:：]", re.I)
TRAILER = re.compile(
    r"^[\s>*_\-]*(?:Co-Authored-By|Signed-off-by|Reviewed-by)\s*:|^[\s>*_\-]*(?:🤖\s*)?Generated (?:with|by)\b",
    re.I)
EMAIL_ONLY = re.compile(r"^[\s>*_\-•·]*<?[\w.+-]+@[\w-]+(?:\.[\w-]+)+>?[\s>*_\-•·]*$")
FM_KEY = re.compile(r"""^["']?(?:author|authors|writer|byline|created_by|creator|contributors?)["']?\s*:""", re.I)
HEAD_LINES = 10  # byline-style lines (작성자:, Author:, 이름:) only count near the top of the body


def strip_front_matter(lines):
    """Drop author-like keys (and their list continuation) inside a leading --- block."""
    if not lines or lines[0].strip() != "---":
        return lines, 0
    end = next((i for i in range(1, len(lines)) if lines[i].strip() in ("---", "...")), None)
    if end is None:
        return lines, 0
    out, removed, skipping = [lines[0]], 0, False
    for ln in lines[1:end]:
        if FM_KEY.match(ln):
            skipping, removed = True, removed + 1
            continue
        if skipping and (ln[:1] in (" ", "\t") or ln.lstrip().startswith("- ")):
            removed += 1
            continue
        if skipping and not ln.strip():  # YAML lets a blank line sit inside the author list
            out.append(ln)
            continue
        skipping = False
        out.append(ln)
    return out + lines[end:], removed


def strip_comments(lines):
    """Remove <!-- ... --> spans; a line left blank only by a comment is dropped whole.

    Returns (lines, removed, unclosed). A "<!--" that never closes is not a comment we can
    bound, so it and everything after it stay verbatim and `unclosed` is True.
    """
    out, removed, in_comment, open_at = [], 0, False, 0
    for idx, ln in enumerate(lines):
        body = ln.rstrip("\r\n")
        eol = ln[len(body):]
        had = in_comment
        res, i = [], 0
        while i < len(body):
            if in_comment:
                j = body.find("-->", i)
                if j < 0:
                    i = len(body)
                else:
                    i, in_comment = j + 3, False
            else:
                j = body.find("<!--", i)
                if j < 0:
                    res.append(body[i:])
                    break
                res.append(body[i:j])
                i, in_comment, open_at = j + 4, True, idx
        text = "".join(res)
        touched = had or in_comment or text != body
        if touched and not text.strip():
            removed += 1
            continue
        out.append(text + eol if touched else ln)
    if in_comment:
        head, n, _ = strip_comments(lines[:open_at])
        return head + lines[open_at:], n, True
    return out, removed, False


def anonymize(text):
    """Return (anonymised text, removed line count, unclosed-comment flag)."""
    lines = text.splitlines(keepends=True)
    removed = 0
    lines, n = strip_front_matter(lines)
    removed += n
    lines, n, unclosed = strip_comments(lines)
    removed += n
    body_start = 0
    if lines and lines[0].strip() == "---":
        body_start = next((i + 1 for i in range(1, len(lines)) if lines[i].strip() in ("---", "...")), 0)
    out = []
    for idx, ln in enumerate(lines):
        head = body_start <= idx < body_start + HEAD_LINES
        if ((head and (AUTHOR_LINE.match(ln) or NAME_LINE.match(ln))) or TRAILER.match(ln)
                or EMAIL_ONLY.match(ln.rstrip("\r\n"))):
            removed += 1
            continue
        out.append(ln)
    return "".join(out), removed, unclosed


def main(argv):
    src = argv[1] if len(argv) > 1 else "-"
    if src == "-":
        data = sys.stdin.buffer.read().decode("utf-8")
    else:
        with open(src, encoding="utf-8", newline="") as fh:  # newline="": keep CRLF as is
            data = fh.read()
    out, removed, unclosed = anonymize(data)
    sys.stdout.buffer.write(out.encode("utf-8"))
    sys.stdout.buffer.flush()
    if unclosed:
        print("anonymize: warning: unclosed <!-- left in place; check it for author notes", file=sys.stderr)
    print(f"anonymize: removed {removed} line(s)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
