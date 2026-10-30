#!/usr/bin/env python3
"""drift_check.py — did editing change what the document says?

usage: drift_check.py ORIGINAL FINAL
Pairs each original sentence with its closest final sentence and compares, per pair:
numbers with their sign and attached unit, IN ORDER (42분→30분 is not 30분→42분; 30분 and
"30 분" are not 30초; -5% is not 5%); Korean counting words (한·두·세… + unit, 두 팀 is not
세 팀); direction words (늘/줄/증가/감소/이상/이하/초과/미만, compared by direction, not
spelling); URLs (sentence punctuation after one is not part of it); email addresses; English
words; quoted text; negations by kind (않/못/없/아니/안/불가/말라/금지/불필요/not…);
obligation wording. Directions, URLs, emails, English words and quotes also compare in order
of appearance, so a swap between two subjects (매출은 증가·비용은 감소 → 매출은 감소·비용은
증가, or two names trading roles) is drift; the price is that a clause reorder carrying them
is reported too, and reverting it to the original order is the safe answer.
Also reports original sentences with no counterpart, new sentences that carry a figure, URL,
quote, obligation, negation or English word, and a large change in sentence count.
List numbers at line heads ("3. ") are ignored so renumbering a section is not drift.
stdout: JSON {"ok", "original_sentences", "final_sentences", "mismatches": [...], "summary": {...}}
exit:   0 no drift | 1 drift found (revert each listed sentence to its original wording)
        2 usage error or unreadable input
"""
import difflib
import json
import re
import sys

MATCH_MIN = 0.3
URL = re.compile(r"https?://[^\s)>\]\"']+|www\.[^\s)>\]\"']+")
URL_TAIL = ".,;:!?"  # a sentence's own punctuation right after a URL
EMAIL = re.compile(r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+")
# a number with its sign (a minus not right after a letter or digit, so 3-5 and 2026-10-30 stay
# unsigned) plus the unit after it, glued or after one space; only known units count, so a
# particle (30이다, 30입니다) is not drift
UNITS2 = ("개월", "시간", "퍼센트", "페이지", "달러", "만원")
UNITS1 = "분초일주월년세명곳건개원%배번회장권점위호층개"
NUM = re.compile(r"(?:(?<![\w.])[-−])?\d[\d,]*(?:\.\d+)?(?:[ \t]?(?:" + "|".join(UNITS2)
                 + "|[" + re.escape(UNITS1) + "]))?")
KNUM = re.compile(r"(?<![가-힣])(?:한|두|세|네|다섯|여섯|일곱|여덟|아홉|열|스무)\s*"
                  r"(?:개월|개국|시간|가지|가구|차례|군데|사람|단계|마리|개|명|곳|건|주|달|분|번|해|째"
                  r"|팀|배|살|권)")
ENG = re.compile(r"[A-Za-z][A-Za-z\-']*")
QUOTE = re.compile(r"\"([^\"]+)\"|“([^”]+)”|‘([^’]+)’|「([^」]+)」|'([^']{2,})'")
NEG = re.compile(r"(?P<않>않)|(?P<못>못)|(?P<없>없)|(?P<아니>아니|아닌)|(?P<안>(?<![가-힣])안\s)|(?P<불가>불가(?!피))"
                 r"|(?P<말라>말라|마라|말아)|(?P<금지>금지)|(?P<불필요>불필요)"
                 r"|(?P<not>\bnot\b|n't\b)|(?P<no>\bno\b)|(?P<never>\bnever\b)|(?P<without>\bwithout\b)", re.I)
OBL = re.compile(r"해야|하여야|[아어]야\s*(?:한|합|하)|(?<!불)필요|반드시|\bmust\b|\bshould\b|\bshall\b|\bneed to\b|\brequired?\b", re.I)
DIRECTION = re.compile(r"(?P<down>줄었|줄어|줄이|줄인|줄여|감소|하락|단축|감축|떨어)|(?P<up>늘었|늘어|늘리|늘린|늘려|증가|상승|증대|향상|올랐|올라)"
                       r"|(?P<ge>이상)|(?P<le>이하)|(?P<gt>초과)|(?P<lt>미만)")
CLOSERS = "\"'”’」』)\\]"
SPLIT = re.compile(r"(?:(?<=[.!?。])|(?<=[.!?。][" + CLOSERS + r"])|(?<=[.!?。][" + CLOSERS + r"]{2}))\s+")
LIST_HEAD = re.compile(r"^\d+\.\s+")


def sentences(text):
    out = []
    for line in text.splitlines():
        line = re.sub(r"^[\s#>*\-+|]+", "", line).replace("**", "").strip()
        line = LIST_HEAD.sub("", line)
        if not line or re.fullmatch(r"[-=_|\s:]+", line):
            continue
        for s in SPLIT.split(line):
            if s.strip():
                out.append(s.strip())
    return out


def seq(items):
    """Order of first appearance, repeats dropped: a swap is drift, saying it twice is not."""
    return list(dict.fromkeys(items))


def features(s):
    urls = [u.rstrip(URL_TAIL) for u in URL.findall(s)]
    rest = URL.sub(" ", s)
    emails = EMAIL.findall(rest)
    rest = EMAIL.sub(" ", rest)
    return {
        "number": [re.sub(r"\s", "", n.replace(",", "")).replace("−", "-")
                   for n in NUM.findall(rest)],  # order matters
        "numeral": [re.sub(r"\s+", "", n) for n in KNUM.findall(rest)],
        "direction": seq(m.lastgroup for m in DIRECTION.finditer(s)),
        "url": seq(urls),
        "email": seq(emails),
        "english": seq(w.lower() for w in ENG.findall(rest)),
        "quote": [next(g for g in m if g) for m in QUOTE.findall(rest)],
        "negation": sorted(m.lastgroup for m in NEG.finditer(s)),
        "obligation": len(OBL.findall(s)),
    }


def pair_up(orig, fin):
    scored = []
    for i, a in enumerate(orig):
        for j, b in enumerate(fin):
            r = difflib.SequenceMatcher(None, a, b, autojunk=False).ratio()
            if r >= MATCH_MIN:
                scored.append((r, i, j))
    scored.sort(key=lambda t: (-t[0], t[1], t[2]))
    pairs, used_i, used_j = [], set(), set()
    for _, i, j in scored:
        if i not in used_i and j not in used_j:
            pairs.append((i, j))
            used_i.add(i)
            used_j.add(j)
    return sorted(pairs), used_i, used_j


def main(argv):
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        orig = sentences(open(argv[1], encoding="utf-8").read())
        fin = sentences(open(argv[2], encoding="utf-8").read())
    except OSError as e:
        print(f"drift_check: cannot read input: {e.strerror}: {e.filename}", file=sys.stderr)
        return 2
    pairs, used_i, used_j = pair_up(orig, fin)
    mism = []
    for i, j in pairs:
        fa, fb = features(orig[i]), features(fin[j])
        for k in fa:
            if fa[k] != fb[k]:
                mism.append({"kind": k, "original": orig[i], "final": fin[j], "detail": {"original": fa[k], "final": fb[k]}})
    for i, s in enumerate(orig):
        if i not in used_i:
            mism.append({"kind": "missing_sentence", "original": s, "final": "", "detail": {}})
    for j, s in enumerate(fin):
        if j not in used_j:
            f = features(s)
            if any(f[k] for k in ("number", "numeral", "url", "email", "quote", "obligation", "negation", "english")):
                mism.append({"kind": "added_claim", "original": "", "final": s, "detail": {}})
    n0, n1 = len(orig), len(fin)
    if abs(n0 - n1) > max(2, 0.2 * n0):
        mism.append({"kind": "sentence_count", "original": "", "final": "", "detail": {"original": n0, "final": n1}})
    summary = {}
    for m in mism:
        summary[m["kind"]] = summary.get(m["kind"], 0) + 1
    print(json.dumps({"ok": not mism, "original_sentences": n0, "final_sentences": n1,
                      "mismatches": mism, "summary": summary}, ensure_ascii=False, indent=2))
    return 1 if mism else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
