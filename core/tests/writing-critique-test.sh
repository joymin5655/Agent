#!/usr/bin/env bash
# writing-critique-test.sh — offline battery for extras/skills/writing-critique.
#
# No external AI is ever called: critique.sh is pointed at a stand-in call-worker
# (WRITING_CRITIQUE_CALL_WORKER) that replays canned replies from tests/fixtures/.
#
# Contracts:
#   1. LAYOUT      — skill/rubric/prompt carry the pieces the procedure depends on.
#   2. ANONYMISE   — author lines, trailers, comments, author front-matter keys go; every
#                    other character is untouched (so critic quotes still match).
#   3. PARSE       — fenced/bare/echoed JSON is found (last valid wins), broken JSON fails,
#                    quotes not in the draft are dropped, duplicates merge, 12 max.
#   4. CRITIQUE    — both ok / one failed / both failed / exit 3 / exit 124; the critics run
#                    concurrently with a 240 s limit; AGENT_WORKER_YES is never set by the
#                    script; findings.json carries no vendor name.
#   5. DRIFT       — a changed number or flipped negation is caught; a style-only edit passes.
#   6. LOG/REPORT  — the log line holds metadata only (no document or critic text).
#
# Portability: bash + python3 stdlib. Usage: bash core/tests/writing-critique-test.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SK="$REPO_ROOT/extras/skills/writing-critique"
FX="$SK/tests/fixtures"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   — %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL — %s\n' "$1"; }
check() { # <label> <command...>
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; fi
}
# pyj <json-file> <python-expr over d> — true iff the expression is truthy
pyj() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1],encoding="utf-8")); sys.exit(0 if eval(sys.argv[2]) else 1)' "$1" "$2"; }

# ---------------------------------------------------------------- 1. layout
for f in SKILL.md references/rubric.md references/critic-prompt.md scripts/anonymize.py scripts/critique.sh \
         scripts/parse_findings.py scripts/drift_check.py scripts/log_run.py scripts/report.py \
         tests/fixtures/report-draft.md tests/fixtures/blog-clean.md; do
  [[ -f "$SK/$f" ]] && ok "exists: $f" || bad "missing: $f"
done
DESC="$(grep -m1 '^description:' "$SK/SKILL.md")"
check "SKILL name is writing-critique" grep -q '^name: writing-critique$' "$SK/SKILL.md"
for w in NOT proofread humanize council-review; do
  case "$DESC" in *"$w"*) ok "SKILL description mentions $w" ;; *) bad "SKILL description lacks $w" ;; esac
done
for r in R1 R2 R3 R4 R5; do
  check "SKILL defines reject code $r" grep -qF "**$r**" "$SK/SKILL.md"
done
check "critique.sh never mentions or assigns AGENT_WORKER_YES" bash -c "! grep -n 'AGENT_WORKER_YES' '$SK/scripts/critique.sh'"
check "SKILL.md never exports AGENT_WORKER_YES" bash -c "! grep -nE 'export[[:space:]]+AGENT_WORKER_YES' '$SK/SKILL.md'"
check "SKILL.md states the approval path as it is (exit 3, ask once, one-call flag)" bash -c "grep -q 'exit 3' '$SK/SKILL.md' && grep -q 'ask the user once' '$SK/SKILL.md' && grep -q 'that one invocation only' '$SK/SKILL.md' && grep -q 'If call-worker has a usage-policy command configured' '$SK/SKILL.md'"
check "SKILL.md no longer claims a policy hook already exists" bash -c "! grep -q 'where the install defines one' '$SK/SKILL.md'"
check "SKILL.md: edit the original, anonymise the final too, critic text untrusted, clean up WORK" bash -c "grep -q 'final.anon.md' '$SK/SKILL.md' && grep -q 'untrusted' '$SK/SKILL.md' && grep -q 'delete .WORK.' '$SK/SKILL.md' && grep -q 'accepted fixes go into it' '$SK/SKILL.md'"
check "README.ko.md counts 10 extras skills (no stale 9종)" bash -c "! grep -nE 'skills/ 9종|extras 플러그인에 9종' '$REPO_ROOT/README.ko.md'"
for w in fact logic reader fluency request format critical major minor; do
  check "rubric defines $w" grep -qF "\`$w\`" "$SK/references/rubric.md"
done
for w in '{{PURPOSE}}' '{{RUBRIC}}' '{{DRAFT}}' 'character for character' 'At most 12' 'changes_fact'; do
  check "prompt template has: $w" grep -qF -- "$w" "$SK/references/critic-prompt.md"
done
check "prompt template names no author or vendor" bash -c "! grep -qiE 'claude|gpt|gemini|codex|anthropic|openai' '$SK/references/critic-prompt.md'"
LEN="$(python3 -c 'import sys;print(len(open(sys.argv[1],encoding="utf-8").read()))' "$FX/report-draft.md")"
if [[ "$LEN" -ge 1400 && "$LEN" -le 1700 ]]; then ok "report draft is about 1,500 chars ($LEN)"; else bad "report draft length $LEN"; fi

# ------------------------------------------------------------- 2. anonymise
cat > "$T/anon-in.md" <<'IN'
---
title: T
author: Jane Doe
authors:
  - A
  - B
tags: x
---
작성자: Jane Doe
<!-- memo
 spans lines -->
**Author**: Jane Doe
첫 문장이다. 연락은 team@example.com 으로 한다.
둘째 줄 <!-- inline --> 이어진다.
이름: Jane Doe
Co-Authored-By: Some Tool <noreply@example.com>
🤖 Generated with [Some Tool](https://example.com)
jane@example.com
IN
printf -- '---\ntitle: T\ntags: x\n---\n첫 문장이다. 연락은 team@example.com 으로 한다.\n둘째 줄  이어진다.\n' > "$T/anon-want.md"
python3 "$SK/scripts/anonymize.py" "$T/anon-in.md" > "$T/anon-out.md" 2>/dev/null
check "anonymize removes author/trailer/comment lines, keeps all other characters" cmp -s "$T/anon-out.md" "$T/anon-want.md"
python3 "$SK/scripts/anonymize.py" "$T/anon-out.md" > "$T/anon-out2.md" 2>/dev/null
check "anonymize is idempotent" cmp -s "$T/anon-out.md" "$T/anon-out2.md"
python3 "$SK/scripts/anonymize.py" < "$FX/report-draft.md" > "$T/draft.anon.md" 2>/dev/null
check "report draft: author, byline and memo are gone" bash -c "! grep -qE 'Jane Doe|작성자|초고 메모|^author' '$T/draft.anon.md'"
if python3 - "$FX/report-draft.md" "$T/draft.anon.md" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read().splitlines()
out = open(sys.argv[2], encoding="utf-8").read().splitlines()
it = iter(src)
sys.exit(0 if all(any(o == s for s in it) for o in out) else 1)
PY
then ok "report draft: output is the input minus lines (kept lines verbatim, in order)"; else bad "report draft: kept lines changed"; fi
{
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do printf '본문 %s번 줄이다.\n' "$i"; done
  printf 'Author: 표의 항목 이름이다\n문의: help@example.com\n'
} > "$T/anon-mid.md"
python3 "$SK/scripts/anonymize.py" "$T/anon-mid.md" > "$T/anon-mid.out" 2>/dev/null
check "anonymize keeps a mid-body 'Author:' item line and a '문의: email' line" cmp -s "$T/anon-mid.md" "$T/anon-mid.out"
printf '작성자: Jane Doe\n본문 줄이다.\n' | python3 "$SK/scripts/anonymize.py" 2>/dev/null > "$T/anon-head.out"
check "anonymize still removes an author line inside the first 10 lines" cmp -s "$T/anon-head.out" <(printf '본문 줄이다.\n')
printf '본문이다\n<!-- 열린 메모\n메모 둘째 줄\n끝이다\n' > "$T/anon-open.md"
python3 "$SK/scripts/anonymize.py" "$T/anon-open.md" > "$T/anon-open.out" 2> "$T/anon-open.err"
check "anonymize leaves an unclosed <!-- in place" cmp -s "$T/anon-open.md" "$T/anon-open.out"
check "anonymize warns on stderr about the unclosed <!--" grep -q 'unclosed' "$T/anon-open.err"
printf '작성자: A\r\n본문 줄이다.\r\n<!-- m -->\r\n끝 줄이다.\r\n' > "$T/anon-crlf.md"
printf '본문 줄이다.\r\n끝 줄이다.\r\n' > "$T/anon-crlf.want"
python3 "$SK/scripts/anonymize.py" "$T/anon-crlf.md" > "$T/anon-crlf.out" 2>/dev/null
check "anonymize keeps CRLF line endings (file argument)" cmp -s "$T/anon-crlf.out" "$T/anon-crlf.want"
python3 "$SK/scripts/anonymize.py" < "$T/anon-crlf.md" > "$T/anon-crlf2.out" 2>/dev/null
check "anonymize keeps CRLF line endings (stdin)" cmp -s "$T/anon-crlf2.out" "$T/anon-crlf.want"
check "clean blog passes through unchanged" bash -c "python3 '$SK/scripts/anonymize.py' < '$FX/blog-clean.md' 2>/dev/null | cmp -s - '$FX/blog-clean.md'"
printf -- '---\ntitle: T\nauthors:\n  - Alice\n\n  - Bob\n"author": Carol\ntags: x\n---\n본문 줄이다.\n' > "$T/anon-fm2.md"
python3 "$SK/scripts/anonymize.py" "$T/anon-fm2.md" > "$T/anon-fm2.out" 2>/dev/null
check "anonymize drops an author list across a blank line, and a quoted author key" \
  bash -c "! grep -qE 'Alice|Bob|Carol' '$T/anon-fm2.out' && grep -qx 'tags: x' '$T/anon-fm2.out' && grep -qx '본문 줄이다.' '$T/anon-fm2.out'"

# ----------------------------------------------------------------- 3. parse
PF="$SK/scripts/parse_findings.py"
python3 "$PF" "$FX/critic-ok.json" --draft "$T/draft.anon.md" --label A > "$T/p-ok.json"; rc=$?
if [[ $rc -eq 0 ]]; then ok "parse: valid JSON exits 0"; else bad "parse: valid JSON exit $rc"; fi
check "parse: 5 kept; fabricated quote and duplicate dropped with reasons" \
  pyj "$T/p-ok.json" 'd["ok"] and len(d["findings"])==5 and d["dropped"]["reasons"]=={"quote_not_in_draft":1,"duplicate_merged":1} and d["verdict"]=="revise"'
check "parse: worst severity first, ids A1..A5, changes_fact kept" \
  pyj "$T/p-ok.json" '[f["id"] for f in d["findings"]]==["A1","A2","A3","A4","A5"] and d["findings"][0]["severity"]=="critical" and d["findings"][-1]["severity"]=="minor" and d["findings"][0]["changes_fact"] is True'
check "parse: duplicate merge keeps the higher severity" \
  pyj "$T/p-ok.json" '[f for f in d["findings"] if f["category"]=="fact"][0]["severity"]=="critical"'
python3 "$PF" "$FX/critic-fenced.txt" --draft "$T/draft.anon.md" > "$T/p-fen.json"
check "parse: fenced block inside prose" pyj "$T/p-fen.json" 'd["ok"] and len(d["findings"])==2'
python3 "$PF" "$FX/critic-broken.txt" --draft "$T/draft.anon.md" > "$T/p-brk.json"; rc=$?
if [[ $rc -eq 1 ]]; then ok "parse: broken JSON exits 1"; else bad "parse: broken JSON exit $rc"; fi
check "parse: broken JSON reports ok=false" pyj "$T/p-brk.json" 'not d["ok"] and d["findings"]==[]'
python3 "$PF" "$FX/critic-invalid.json" --draft "$T/draft.anon.md" > "$T/p-inv.json"
check "parse: out-of-range and missing fields are dropped as invalid_format" \
  pyj "$T/p-inv.json" 'd["ok"] and d["findings"]==[] and d["dropped"]["reasons"]=={"invalid_format":3}'
python3 "$PF" "$FX/critic-clean.json" --draft "$FX/blog-clean.md" > "$T/p-cl.json"
check "parse: clean verdict with no findings" pyj "$T/p-cl.json" 'd["ok"] and d["verdict"]=="ok" and d["findings"]==[]'
cat "$SK/references/critic-prompt.md" "$FX/critic-ok.json" > "$T/echo.txt"
python3 "$PF" "$T/echo.txt" --draft "$T/draft.anon.md" > "$T/p-echo.json"
check "parse: prompt echoed before the answer — the last JSON wins" pyj "$T/p-echo.json" 'd["ok"] and len(d["findings"])==5'
{ cat "$FX/critic-ok.json"; printf '\n{"verdict":[],"findings":[]}\n'; } > "$T/tail-invalid.txt"
python3 "$PF" "$T/tail-invalid.txt" --draft "$T/draft.anon.md" > "$T/p-tail.json"
check "parse: a later object with an invalid verdict does not displace the valid one" pyj "$T/p-tail.json" 'd["ok"] and len(d["findings"])==5'
python3 -c 'import sys; sys.stdout.write("{\"x\":" * 20000)' > "$T/hostile.txt"
if python3 - "$PF" "$T/hostile.txt" "$T/draft.anon.md" <<'PY'
import subprocess, sys, time
t = time.time()
p = subprocess.run([sys.executable, sys.argv[1], sys.argv[2], "--draft", sys.argv[3]], capture_output=True, timeout=30)
sys.exit(0 if p.returncode == 1 and time.time() - t < 3 else 1)
PY
then ok "parse: 100 KB of unclosed objects is rejected in bounded time"; else bad "parse: unclosed-object flood too slow or accepted"; fi
printf '가나다 라마바 사\n아자차 카타파 하\n' > "$T/ws-draft.md"
printf '{"verdict":"revise","findings":[{"quote":"가나다   라마바 사 아자차","problem":"p","suggestion":"s","category":"format","severity":"minor","changes_fact":false}]}' > "$T/ws.json"
python3 "$PF" "$T/ws.json" --draft "$T/ws-draft.md" > "$T/p-ws.json"
check "parse: quote matches after whitespace normalisation" pyj "$T/p-ws.json" 'len(d["findings"])==1'
python3 - "$T" <<'PY'
import json, sys
t = sys.argv[1]
words = [f"{i}번째 문장이다" for i in range(15)]
open(f"{t}/many-draft.md", "w", encoding="utf-8").write(". ".join(words) + ".\n")
fs = [{"quote": w, "problem": "p", "suggestion": "s", "category": "format", "severity": "minor", "changes_fact": False} for w in words]
json.dump({"verdict": "revise", "findings": fs}, open(f"{t}/many.json", "w", encoding="utf-8"), ensure_ascii=False)
PY
python3 "$PF" "$T/many.json" --draft "$T/many-draft.md" > "$T/p-many.json"
check "parse: capped at 12, the rest counted as over_limit" pyj "$T/p-many.json" 'len(d["findings"])==12 and d["dropped"]["reasons"]=={"over_limit":3}'
printf -- '---\nrole: x\nstatus: complete\n---\n\n' > "$T/fm.txt"
cat "$FX/critic-ok.json" >> "$T/fm.txt"
python3 "$PF" "$T/fm.txt" --draft "$T/draft.anon.md" > "$T/p-fm.json"
check "parse: capture front matter is skipped" pyj "$T/p-fm.json" 'd["ok"] and len(d["findings"])==5'
python3 - "$T" <<'PY'
import json, sys
t = sys.argv[1]
good = {"quote": "비용은 추후 검토한다.", "problem": "p-good", "suggestion": "s", "category": "request", "severity": "major", "changes_fact": False}
def w(name, findings):
    json.dump({"verdict": "revise", "findings": findings}, open(f"{t}/{name}.json", "w", encoding="utf-8"), ensure_ascii=False)
w("bad-list-cat", [dict(good, category=["fact"]), dict(good, quote="접근 권한이 없는 문서가 검색 결과에 보이면", severity=["x"]), {"quote": ["a"]}, good])
nocf = dict(good)
del nocf["changes_fact"]
w("no-cf", [nocf])
w("quote-len", [dict(good, quote="비용은"), dict(good, quote="비용은 추후\n검토한다."), dict(good, quote="가" * 301), dict(good, quote="가" * 7), good])
low = dict(good, severity="minor", problem="p-low", changes_fact=False)
high = dict(good, severity="critical", problem="p-high", changes_fact=False)
w("dup-low-first", [low, dict(high, changes_fact=True)])
w("dup-high-first", [dict(high, changes_fact=False), dict(low, changes_fact=True)])
PY
python3 "$PF" "$T/bad-list-cat.json" --draft "$T/draft.anon.md" > "$T/p-bl.json"; rc=$?
if [[ $rc -eq 0 ]]; then ok "parse: malformed (unhashable) values do not fail the critic"; else bad "parse: malformed values killed the critic (exit $rc)"; fi
check "parse: only the malformed findings are dropped (invalid_format), the good one stays" pyj "$T/p-bl.json" 'd["ok"] and len(d["findings"])==1 and d["findings"][0]["problem"]=="p-good" and d["dropped"]["reasons"]=={"invalid_format":3}'
python3 "$PF" "$T/no-cf.json" --draft "$T/draft.anon.md" > "$T/p-ncf.json"
check "parse: missing changes_fact counts as true" pyj "$T/p-ncf.json" 'd["findings"][0]["changes_fact"] is True'
python3 "$PF" "$T/quote-len.json" --draft "$T/draft.anon.md" > "$T/p-ql.json"
check "parse: 3-char, 7-char, 301-char and multi-line quotes dropped with separate reasons; 8+ kept" \
  pyj "$T/p-ql.json" 'len(d["findings"])==1 and d["dropped"]["reasons"]=={"quote_too_short":2,"quote_too_long":1,"quote_multiline":1}'
python3 "$PF" "$T/dup-low-first.json" --draft "$T/draft.anon.md" > "$T/p-d1.json"
check "parse: duplicate, low severity first then high — the high one stays with its wording, changes_fact OR-ed" \
  pyj "$T/p-d1.json" 'len(d["findings"])==1 and d["findings"][0]["severity"]=="critical" and d["findings"][0]["problem"]=="p-high" and d["findings"][0]["changes_fact"] is True and d["dropped"]["reasons"]=={"duplicate_merged":1}'
python3 "$PF" "$T/dup-high-first.json" --draft "$T/draft.anon.md" > "$T/p-d2.json"
check "parse: duplicate, high first then low — high stays, changes_fact still OR-ed" \
  pyj "$T/p-d2.json" 'len(d["findings"])==1 and d["findings"][0]["severity"]=="critical" and d["findings"][0]["problem"]=="p-high" and d["findings"][0]["changes_fact"] is True'
python3 "$PF" "$FX/critic-origonly.json" --draft "$T/draft.anon.md" > "$T/p-oo.json"
check "parse: quotes found only in the original (author line, HTML-comment memo) are dropped" \
  pyj "$T/p-oo.json" 'd["ok"] and d["findings"]==[] and d["dropped"]["reasons"]=={"quote_not_in_draft":2}'

# -------------------------------------------------------------- 4. critique
cat > "$T/fake-cw.sh" <<'FAKE'
#!/usr/bin/env bash
# stand-in call-worker: records what it was given, replays a canned reply by FAKE_MODE_<role>
role="${1:?}"; prompt="$(cat)"
tag="${role//-/_}"
echo "${AGENT_WORKER_YES:-unset}" > "$FAKE_DIR/yes.$role"
echo "${AGENT_WORKER_TIMEOUT_S:-unset}" > "$FAKE_DIR/tmo.$role"
python3 -c 'import time;print(time.time())' > "$FAKE_DIR/start.$role"
sleep "${FAKE_SLEEP:-0}"
python3 -c 'import time;print(time.time())' > "$FAKE_DIR/end.$role"
mv_="FAKE_MODE_${tag}"; mode="${!mv_:-ok}"
case "$mode" in
  ok)       body="$(cat "$FX/critic-ok.json")" ;;
  fenced)   body="$(cat "$FX/critic-fenced.txt")" ;;
  broken)   body="$(cat "$FX/critic-broken.txt")" ;;
  echo)     body="$prompt
$(cat "$FX/critic-ok.json")" ;;
  origonly) body="$(cat "$FX/critic-origonly.json")" ;;
  revise0)  body='{"verdict":"revise","findings":[]}' ;;
  fallback) body="$(cat "$FX/critic-ok.json")"; extra=$'backend: fb-backend\nfallback_reason: primary unavailable' ;;
  fail)     echo "backend failed" >&2; exit 1 ;;
  approval) echo "call-worker: not approved" >&2; exit 3 ;;
  timeout)  exit 124 ;;
esac
cap="$FAKE_DIR/cap-$role.md"
printf -- '---\nrole: %s\n%sstatus: complete\n---\n\n%s\n' "$role" "${extra:+$extra$'\n'}" "$body" > "$cap"
echo "$cap"
FAKE
chmod +x "$T/fake-cw.sh"

run_critique() { # <outdir> [VAR=val ...]  — fresh FAKE_DIR per run
  local out="$1"; shift
  mkdir -p "$T/fk-$(basename "$out")"
  env -u AGENT_WORKER_YES -u AGENT_WORKER_TIMEOUT_S FAKE_DIR="$T/fk-$(basename "$out")" FX="$FX" \
      WRITING_CRITIQUE_CALL_WORKER="$T/fake-cw.sh" "$@" \
      bash "$SK/scripts/critique.sh" "$T/draft.anon.md" --purpose "비용까지 비교한 도입 검토 보고서, 독자는 팀장" --out "$out" > "$out.stdout" 2> "$out.stderr"
}
OPENAI=FAKE_MODE_advisor_writing_openai
GOOGLE=FAKE_MODE_advisor_writing_google

run_critique "$T/both" FAKE_SLEEP=1; rc=$?
FK="$T/fk-both"
if [[ $rc -eq 0 ]]; then ok "critique: both succeed, exit 0"; else bad "critique: both succeed exit $rc"; fi
check "critique: result both, both critics success" bash -c "grep -q '^result: both' '$T/both.stdout' && grep -q '^A: success' '$T/both.stdout' && grep -q '^B: success' '$T/both.stdout'"
check "critique: findings.json has A and B with 5 findings each" pyj "$T/both/findings.json" 'sorted(d)==["A","B"] and len(d["A"]["findings"])==5 and len(d["B"]["findings"])==5'
check "critique: ids carry the critic label" pyj "$T/both/findings.json" 'd["A"]["findings"][0]["id"]=="A1" and d["B"]["findings"][0]["id"]=="B1"'
check "critique: labels.json maps A/B to openai and google exactly once" pyj "$T/both/labels.json" 'sorted(v["company"] for v in d.values())==["google","openai"] and sorted(v["role"] for v in d.values())==["advisor-writing-google","advisor-writing-openai"]'
check "critique: findings.json names no vendor" bash -c "! grep -qiE 'openai|google|codex|gemini|advisor' '$T/both/findings.json'"
check "critique: the script does not set AGENT_WORKER_YES" bash -c "grep -qx unset '$FK/yes.advisor-writing-openai' && grep -qx unset '$FK/yes.advisor-writing-google'"
check "critique: each critic gets a 240 s limit" bash -c "grep -qx 240 '$FK/tmo.advisor-writing-openai' && grep -qx 240 '$FK/tmo.advisor-writing-google'"
if python3 - "$FK" <<'PY'
import sys
k = sys.argv[1]
g = lambda n, r: float(open(f"{k}/{n}.advisor-writing-{r}").read())
s = [g("start", "openai"), g("start", "google")]
e = [g("end", "openai"), g("end", "google")]
sys.exit(0 if max(s) < min(e) else 1)
PY
then ok "critique: the two critics run concurrently"; else bad "critique: critics ran one after the other"; fi
check "critique: prompt carries rubric, purpose and draft; no placeholder left, no author" \
  bash -c "grep -q 'critical' '$T/both/prompt.md' && grep -q '비용까지 비교한' '$T/both/prompt.md' && grep -q '비용은 추후 검토한다' '$T/both/prompt.md' && ! grep -q '{{' '$T/both/prompt.md' && ! grep -q 'Jane Doe' '$T/both/prompt.md'"

run_critique "$T/one" "$OPENAI=fail"
check "critique: one critic fails — result one, told to use the other alone" bash -c "grep -q '^result: one' '$T/one.stdout' && grep -q 'failed' '$T/one.stdout' && grep -q 'only one critic' '$T/one.stdout'"
check "critique: one fails — labels.json records failed for openai, success for google" pyj "$T/one/labels.json" '[v["status"] for v in d.values() if v["company"]=="openai"]==["failed"] and [v["status"] for v in d.values() if v["company"]=="google"]==["success"]'

run_critique "$T/none" "$OPENAI=fail" "$GOOGLE=broken"; rc=$?
if [[ $rc -eq 4 ]]; then ok "critique: no critic answered exits 4"; else bad "critique: both unusable exit $rc (want 4)"; fi
check "critique: both unusable — result none, proceed without external review, no substitute" bash -c "grep -q '^result: none' '$T/none.stdout' && grep -q 'external review unavailable' '$T/none.stdout' && grep -q 'do not substitute' '$T/none.stdout'"
check "critique: both unusable — no findings" pyj "$T/none/findings.json" 'd["A"]["findings"]==[] and d["B"]["findings"]==[]'

run_critique "$T/appr" "$OPENAI=approval"
check "critique: exit 3 becomes approval-needed" pyj "$T/appr/labels.json" '[v["status"] for v in d.values() if v["company"]=="openai"]==["approval-needed"]'
check "critique: approval-needed critic skipped, the other still used" bash -c "grep -q '^result: one' '$T/appr.stdout' && grep -q 'approval-needed' '$T/appr.stdout'"
check "critique: with one answer, the critic awaiting approval is named with how to add it" bash -c "grep -q '^critic [AB] needs approval: to add it' '$T/appr.stdout'"

run_critique "$T/tmo" "$GOOGLE=timeout"
check "critique: exit 124 becomes timeout" pyj "$T/tmo/labels.json" '[v["status"] for v in d.values() if v["company"]=="google"]==["timeout"]'

run_critique "$T/echo" "$OPENAI=echo" "$GOOGLE=fenced"
check "critique: echoed prompt and fenced reply both parse" pyj "$T/echo/labels.json" 'all(v["status"]=="success" for v in d.values())'

run_critique "$T/appr2" "$OPENAI=approval" "$GOOGLE=approval"; rc=$?
if [[ $rc -eq 4 ]]; then ok "critique: both need approval exits 4"; else bad "critique: both approval exit $rc (want 4)"; fi
check "critique: both need approval — the result line says 'approval needed', not a failure" bash -c "grep -q '^result: none (approval needed' '$T/appr2.stdout' && ! grep -q 'failed' '$T/appr2.stdout' && grep -q 'ask the user once' '$T/appr2.stdout'"
run_critique "$T/mixed" "$OPENAI=approval" "$GOOGLE=fail"; rc=$?
if [[ $rc -eq 4 ]]; then ok "critique: approval-needed plus a failure exits 4"; else bad "critique: approval plus failure exit $rc (want 4)"; fi
if python3 - "$T/mixed" <<'PY'
import json, re, sys
d = sys.argv[1]
want = [k for k, v in json.load(open(f"{d}/labels.json", encoding="utf-8")).items() if v["company"] == "openai"]
text = open(f"{d}/status.txt", encoding="utf-8").read()
m = re.search(r"^result: none \(approval needed: critic ([AB]); the other failed\)$", text, re.M)
sys.exit(0 if m and [m.group(1)] == want and "ask the user once" in text
         and "external review unavailable" not in text else 1)
PY
then ok "critique: approval-needed plus a failure names the critic to approve, not 'unavailable'"; else bad "critique: mixed approval/failure lost the approval line"; fi
run_critique "$T/rev0" "$OPENAI=revise0" "$GOOGLE=origonly"
check "critique: verdict revise with nothing left is success-empty on both critics, apart from success" bash -c "[ \$(grep -c 'success-empty' '$T/rev0.stdout') -eq 2 ] && ! grep -q ': success (' '$T/rev0.stdout'"
check "critique: success-empty is recorded in labels.json" pyj "$T/rev0/labels.json" 'all(v["status"]=="success-empty" for v in d.values())'
check "critique: findings citing original-only lines are dropped (quote_not_in_draft)" pyj "$T/rev0/findings.json" 'sorted(e["dropped"]["total"] for e in d.values())==[0,2]'
run_critique "$T/fb" "$GOOGLE=fallback"
check "critique: backend and fallback reason from the capture header land in labels.json" pyj "$T/fb/labels.json" 'sorted((v["backend"], v["fallback_reason"]) for v in d.values() if v["company"]=="google")==[("fb-backend","primary unavailable")] and all(v["fallback_reason"]=="" for v in d.values() if v["company"]=="openai")'
check "critique: a fallback shows in the status lines" bash -c "grep -q 'fell back to fb-backend: primary unavailable' '$T/fb.stdout' && grep -q 'fell back' '$T/fb/status.txt'"
mkdir -p "$T/fk-np" "$T/fk-ep"
env -u AGENT_WORKER_YES FAKE_DIR="$T/fk-np" FX="$FX" WRITING_CRITIQUE_CALL_WORKER="$T/fake-cw.sh" \
    bash "$SK/scripts/critique.sh" "$T/draft.anon.md" --out "$T/np" > "$T/np.stdout" 2>&1; rc=$?
if [[ $rc -eq 0 ]]; then ok "critique: --purpose omitted runs normally"; else bad "critique: no --purpose exit $rc"; fi
check "critique: omitted purpose reads '명시 없음' in the prompt" grep -q '명시 없음' "$T/np/prompt.md"
env -u AGENT_WORKER_YES FAKE_DIR="$T/fk-ep" FX="$FX" WRITING_CRITIQUE_CALL_WORKER="$T/fake-cw.sh" \
    bash "$SK/scripts/critique.sh" "$T/draft.anon.md" --purpose "" --out "$T/ep" > "$T/ep.stdout" 2>&1; rc=$?
if [[ $rc -eq 0 ]]; then ok "critique: empty --purpose runs normally"; else bad "critique: empty --purpose exit $rc"; fi
check "critique: empty purpose reads '명시 없음' in the prompt" grep -q '명시 없음' "$T/ep/prompt.md"

check "critique: usage error exits 2" bash -c "bash '$SK/scripts/critique.sh' 2>/dev/null; [ \$? -eq 2 ]"

# ----------------------------------------------------------------- 5. drift
cat > "$T/orig.md" <<'EOF'
# 보고서

시범 운영에서 검색 시간이 42분에서 30분으로 줄었다. 접근 권한이 없는 문서는 결과에 나오지 않아야 한다. 비용은 월 3,000,000원이며 https://example.com/pricing 에 공개되어 있다. 보안 사고는 한 건도 없었다. 담당자는 "문서 검색 개선"이라는 이름으로 과제를 등록했다. Slack 연동은 지원하지 않는다.
EOF
cat > "$T/style.md" <<'EOF'
# 보고서

시범 운영 결과 검색 시간은 42분에서 30분으로 단축되었다. 접근 권한이 없는 문서는 결과에 나오지 않아야 한다. 비용은 월 3,000,000원이고 https://example.com/pricing 에서 확인할 수 있다. 보안 사고는 한 건도 없었다. 담당자는 "문서 검색 개선"이라는 이름으로 과제를 등록했다. Slack 연동은 지원하지 않는다.
EOF
python3 "$SK/scripts/drift_check.py" "$T/orig.md" "$T/orig.md" > "$T/d0.json"; rc=$?
if [[ $rc -eq 0 ]]; then ok "drift: identical text passes"; else bad "drift: identical exit $rc"; fi
python3 "$SK/scripts/drift_check.py" "$T/orig.md" "$T/style.md" > "$T/d-style.json"; rc=$?
if [[ $rc -eq 0 ]]; then ok "drift: style-only rewording passes"; else bad "drift: style-only rewording flagged (exit $rc)"; cat "$T/d-style.json"; fi
drift_expect() { # <name> <from> <to> <kind>
  python3 - "$T/orig.md" "$T/$1.md" "$2" "$3" <<'PY'
import sys
s = open(sys.argv[1], encoding="utf-8").read()
assert sys.argv[3] in s, sys.argv[3]
open(sys.argv[2], "w", encoding="utf-8").write(s.replace(sys.argv[3], sys.argv[4]))
PY
  python3 "$SK/scripts/drift_check.py" "$T/orig.md" "$T/$1.md" > "$T/d-$1.json"; local rc=$?
  if [[ $rc -eq 1 ]] && pyj "$T/d-$1.json" "'$4' in d['summary'] and not d['ok']"; then ok "drift catches: $1 ($4)"; else bad "drift missed: $1 ($4, exit $rc)"; fi
}
drift_expect number "30분으로" "13분으로" number
drift_expect cost "3,000,000원" "300,000원" number
drift_expect negation "한 건도 없었다" "한 건도 있었다" negation
drift_expect negation2 "지원하지 않는다" "지원한다" negation
drift_expect obligation "나오지 않아야 한다" "나오지 않는다" obligation
drift_expect url "example.com/pricing" "example.org/pricing" url
drift_expect quote "문서 검색 개선" "문서 검색 강화" quote
drift_expect english "Slack 연동" "Teams 연동" english
python3 - "$T/orig.md" "$T/dropped.md" <<'PY'
import sys
s = open(sys.argv[1], encoding="utf-8").read().replace(" 보안 사고는 한 건도 없었다.", "")
open(sys.argv[2], "w", encoding="utf-8").write(s)
PY
python3 "$SK/scripts/drift_check.py" "$T/orig.md" "$T/dropped.md" > "$T/d-drop.json"
check "drift catches a deleted sentence" pyj "$T/d-drop.json" '"missing_sentence" in d["summary"]'
python3 - "$T/orig.md" "$T/added.md" <<'PY'
import sys
s = open(sys.argv[1], encoding="utf-8").read().rstrip("\n") + " 도입 후 만족도는 95%였다.\n"
open(sys.argv[2], "w", encoding="utf-8").write(s)
PY
python3 "$SK/scripts/drift_check.py" "$T/orig.md" "$T/added.md" > "$T/d-add.json"
check "drift catches an added numeric claim" pyj "$T/d-add.json" '"added_claim" in d["summary"]'
drift_pair() { # <name> <original text> <final text> <want: "clean" or kinds...>
  local name="$1" a="$2" b="$3"; shift 3
  printf '%s\n' "$a" > "$T/dp-$name.a.md"; printf '%s\n' "$b" > "$T/dp-$name.b.md"
  python3 "$SK/scripts/drift_check.py" "$T/dp-$name.a.md" "$T/dp-$name.b.md" > "$T/dp-$name.json"; local rc=$?
  if [[ "$1" == clean ]]; then
    if [[ $rc -eq 0 ]]; then ok "drift passes: $name"; else bad "drift false alarm: $name (exit $rc)"; cat "$T/dp-$name.json"; fi
    return
  fi
  local k miss=""
  for k in "$@"; do pyj "$T/dp-$name.json" "'$k' in d['summary']" || miss="$miss $k"; done
  if [[ $rc -eq 1 && -z "$miss" ]]; then ok "drift catches: $name ($*)"; else bad "drift missed: $name (exit $rc, missing:$miss)"; fi
}
drift_pair order "검색 시간이 42분에서 30분으로 줄었다." "검색 시간이 30분에서 42분으로 늘었다." number direction
drift_pair order-only "검색 시간이 42분에서 30분으로 줄었다." "검색 시간이 30분에서 42분으로 줄었다." number
drift_pair unit-min-sec "검색 시간은 30분이다." "검색 시간은 30초이다." number
drift_pair unit-pct-people "만족도는 38%이다." "만족도는 38명이다." number
drift_pair unit-particle-ok "검색 시간은 30분이다." "검색 시간은 30분입니다." clean
drift_pair numeral "다른 부서에서 두 주 동안 추가 시범을 한다." "다른 부서에서 세 주 동안 추가 시범을 한다." numeral
drift_pair numeral-ok "보안 사고는 한 건도 없었다." "보안 사고는 한 건도 없었다." clean
drift_pair dir-more "접수된 불만이 100건 이상이다." "접수된 불만이 100건 이하이다." direction
drift_pair dir-synonym "검색 시간이 줄었다." "검색 시간이 단축되었다." clean
drift_pair neg-an "이 설정은 안 된다." "이 설정은 된다." negation
drift_pair neg-bulga "이 방식은 사용이 불가하다." "이 방식은 사용이 가하다." negation
drift_pair neg-malla "이 파일은 지우지 말라." "이 파일은 지우자." negation
drift_pair neg-kind "한 건도 접수되지 않았다." "한 건도 접수되지 못했다." negation
drift_pair need-unneed "권한 확인이 필요하다." "권한 확인이 불필요하다." negation obligation
drift_pair sign "이익률은 -5%이다." "이익률은 5%이다." number
drift_pair unit-space "처리 시간은 30 분이다." "처리 시간은 30 초이다." number
drift_pair unit-space-ok "처리 시간은 30 분이다." "처리 시간은 30분이다." clean
drift_pair range-date-ok "기간은 2026-10-30부터 3-5일이다." "기간은 2026-10-30부터 3-5일입니다." clean
drift_pair numeral-team "두 팀이 참여했다." "세 팀이 참여했다." numeral
drift_pair dir-swap "매출은 증가하고 비용은 감소했다." "매출은 감소하고 비용은 증가했다." direction
drift_pair name-swap "담당자는 Alice이고 검토자는 Bob이다." "담당자는 Bob이고 검토자는 Alice이다." english
drift_pair quote-swap "“성공”에서 “실패”로 바뀌었다." "“실패”에서 “성공”으로 바뀌었다." quote
drift_pair url-period-ok "주소는 https://example.com/docs." "주소는 https://example.com/docs 에 있다." clean
drift_pair list-numbers $'## 1. 배경\n현재 상태를 설명한다.\n## 2. 결과\n결과를 설명한다.' $'## 1. 배경\n현재 상태를 설명한다.\n## 2. 방법\n방법을 적는다.\n## 3. 결과\n결과를 설명한다.' clean
drift_pair list-items $'1. 첫째 항목을 확인한다.\n2. 둘째 항목을 확인한다.' $'2. 첫째 항목을 확인한다.\n3. 둘째 항목을 확인한다.' clean
printf '그는 "그렇게 하자." 이후 30분이 걸렸다. (참고 자료이다.) 끝이다.\n' > "$T/split.md"
python3 "$SK/scripts/drift_check.py" "$T/split.md" "$T/split.md" > "$T/d-split.json"
check "drift splits a sentence after a closing quote or parenthesis (4 sentences)" pyj "$T/d-split.json" 'd["original_sentences"]==4 and d["ok"]'
drift_pair added-neg "도구를 도입한다." "도구를 도입한다. 이것은 사실이 아니다." added_claim
drift_pair added-eng "도구를 도입한다." "도구를 도입한다. 후보는 Notion이다." added_claim
python3 "$SK/scripts/drift_check.py" "$T/orig.md" "$T/no-such-file.md" > /dev/null 2>&1; rc=$?
if [[ $rc -eq 2 ]]; then ok "drift: a missing input file exits 2 (not 1)"; else bad "drift: missing file exit $rc (want 2)"; fi
check "drift names the offending sentence" pyj "$T/d-negation.json" 'd["mismatches"][0]["original"].startswith("보안 사고")'

# ------------------------------------------------------------- 6. log/report
cat > "$T/decisions.json" <<'EOF'
[{"id":"A1","decision":"accept"},{"id":"A2","decision":"reject","reason":"R2"},{"id":"A3","decision":"accept"},
 {"id":"B1","decision":"accept"},{"id":"B2","decision":"reject","reason":"R3"},{"id":"B3","decision":"reject","reason":"R3"}]
EOF
LOG="$T/wc.jsonl"
WRITING_CRITIQUE_LOG="$LOG" python3 "$SK/scripts/log_run.py" --draft "$T/draft.anon.md" --kind general \
  --labels "$T/both/labels.json" --findings "$T/both/findings.json" --decisions "$T/decisions.json" --drift "$T/d0.json" > /dev/null; rc=$?
if [[ $rc -eq 0 ]]; then ok "log_run: appends a line"; else bad "log_run: exit $rc"; fi
check "log: one JSON line with hash, length, kind, critics, counts, reasons, drift" \
  pyj "$LOG" 'len(d["doc"]["sha"])==12 and d["doc"]["kind"]=="general" and d["doc"]["chars"]>1000 and len(d["critics"])==2 and d["accepted"]==3 and d["rejected"]==3 and d["reject_reasons"]=={"R2":1,"R3":2} and d["drift"]["passed"] is True and {c["company"] for c in d["critics"]}=={"openai","google"}'
check "log: per-critic severity and category counts, undecided counted" \
  pyj "$LOG" 'all(c["findings"]==5 and c["by_severity"]["critical"]==2 and c["by_category"]["fact"]==1 and c["undecided"]==2 for c in d["critics"])'
if python3 - "$LOG" "$T/draft.anon.md" "$FX/critic-ok.json" <<'PY'
import json, re, sys
log = open(sys.argv[1], encoding="utf-8").read()
draft = open(sys.argv[2], encoding="utf-8").read()
crit = json.load(open(sys.argv[3], encoding="utf-8"))
probes = [f[k] for f in crit["findings"] for k in ("quote", "problem", "suggestion")]
probes += [s.strip() for s in re.split(r"[.\n]", draft) if len(s.strip()) >= 6]
probes = [p for p in probes if len(p) >= 6]
sys.exit(1 if any(p in log for p in probes) or "Jane" in log else 0)
PY
then ok "log: no document text, quote, problem or suggestion in the log"; else bad "log: leaked text"; fi
printf '[{"id":"A1","decision":"reject"}]' > "$T/nodec.json"
WRITING_CRITIQUE_LOG="$T/x.jsonl" python3 "$SK/scripts/log_run.py" --draft "$T/draft.anon.md" --kind general \
  --labels "$T/both/labels.json" --findings "$T/both/findings.json" --decisions "$T/nodec.json" >/dev/null 2>&1; rc=$?
if [[ $rc -ne 0 && ! -s "$T/x.jsonl" ]]; then ok "log_run: a rejection without a reason code is refused, nothing written"; else bad "log_run: reasonless rejection accepted (exit $rc)"; fi
WRITING_CRITIQUE_LOG="$LOG" python3 "$SK/scripts/log_run.py" --draft "$FX/blog-clean.md" --kind user-voiced \
  --labels "$T/none/labels.json" --findings "$T/none/findings.json" > /dev/null
check "log: second line, user-voiced kind, failed critics recorded" bash -c "[ \$(wc -l < '$LOG') -eq 2 ] && tail -n1 '$LOG' | grep -q user-voiced && tail -n1 '$LOG' | grep -q failed"
WRITING_CRITIQUE_LOG="$LOG" python3 "$SK/scripts/report.py" --json > "$T/rep.json"
check "report --json: per-critic success rate, accept rate, categories" \
  pyj "$T/rep.json" 'd["runs"]==2 and d["critics"]["openai"]["runs"]==2 and d["critics"]["openai"]["success_rate"]==0.5 and d["critics"]["google"]["accept_rate"] is not None and d["critics"]["openai"]["by_category"]["fact"]==1'
LOG2="$T/wc2.jsonl"
for d in appr rev0 fb; do
  WRITING_CRITIQUE_LOG="$LOG2" python3 "$SK/scripts/log_run.py" --draft "$T/draft.anon.md" --kind general \
    --labels "$T/$d/labels.json" --findings "$T/$d/findings.json" > /dev/null
done
WRITING_CRITIQUE_LOG="$LOG2" python3 "$SK/scripts/report.py" --json > "$T/rep2.json"
check "report: approval-needed, success-empty and fallback are counted apart from failure" \
  pyj "$T/rep2.json" 'd["critics"]["openai"]["approval_needed"]==1 and d["critics"]["openai"]["failed"]==0 and d["critics"]["openai"]["success_empty"]==1 and d["critics"]["google"]["fallback"]==1 and d["critics"]["google"]["success_empty"]==1'
check "report: approval-needed is left out of the success-rate base" pyj "$T/rep2.json" 'd["critics"]["openai"]["runs"]==3 and d["critics"]["openai"]["success_rate"]==1.0'
check "log: backend and fallback flag recorded, still no text" bash -c "grep -q '\"fallback\": true' '$LOG2' && grep -q 'fb-backend' '$LOG2' && ! grep -q 'primary unavailable' '$LOG2'"
check "report: table prints a row per critic" bash -c "WRITING_CRITIQUE_LOG='$LOG' python3 '$SK/scripts/report.py' --days 7 | grep -q '^openai'"
check "report: a missing log is not an error" bash -c "WRITING_CRITIQUE_LOG='$T/absent.jsonl' python3 '$SK/scripts/report.py' | grep -q '0 run'"

echo
echo "writing-critique-test: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
