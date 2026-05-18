# Wiki Automation Coverage — supervisor dispatch 갭 닫기

## 목적

`agent-routing.jsonl` 분석 결과 **wiki-curator 19 dispatch 권장 / 0 invoke** 갭. 원인 = *사용자/Claude 가 이미 자동화된 hook 인벤토리를 인지하지 못함*. 새 skill 생성 회피, 자산 5종 인벤토리 + supervisor dispatch 정책 갱신으로 갭 닫기. 본 plan = `~/.claude/plans/commit-pr-automation.md` Wave 2.

## wiki 자동화 자산 5종 (이미 활성)

| # | 자산 | 종류 | 트리거 | 책임 |
|---|---|---|---|---|
| 1 | `.claude/skills/wiki-synth/SKILL.md` | skill (in-place) | 사용자 invoke | 새 wiki 페이지 생성 — slug + frontmatter 자동 |
| 2 | `scripts/hooks/wiki-auto-index.py` | PostToolUse hook (Write\|Edit) | 자동 | `Obsidian-airlens/wiki/` 신규/수정 파일 → `index.md` + `log.md` 자동 등록 |
| 3 | `scripts/hooks/wiki-supersede-suggest.py` (가정) + `.claude/skills/wiki-supersede-apply/SKILL.md` | hook + skill | hook 자동 / skill invoke | 의미 변경 자동 감지 → supersede 마커 추가 |
| 4 | `scripts/hooks/wiki-log-rotate.py` | SessionStart hook | 자동 | `log.md` 월별 rotation (2026-05-07 wire-up) |
| 5 | `.claude/skills/firecrawl-wiki-ingest/SKILL.md` | skill | invoke | 외부 docs Firecrawl crawl → `wiki/imports/<domain>/<slug>-<date>.md` |

**커버리지**: 신규 페이지 생성 / 인덱스 등록 / supersede 마커 / log rotation / 외부 docs ingest = wiki life cycle 5 단계 모두 자동.

## supervisor dispatch 정책 갱신

`scripts/hooks/supervisor.py` 가 `wiki-curator` 권장 시:

1. **읽기 전용 의도 (조사 / 점검 / 분석)** → 이미 자동화된 hook 으로 충분. 사용자에게 보고 권고:
   ```
   wiki 자동화 자산 5종 활성. invoke 불필요.
   확인: ls Obsidian-airlens/wiki/{synthesis,imports,concepts}/
   ```

2. **새 페이지 생성 의도** → `/wiki-synth` skill 권장 (이미 글로벌 활성).

3. **외부 docs ingest 의도** → `/firecrawl-wiki-ingest` skill 권장.

4. **supersede 마커 추가 의도** → `/wiki-supersede-apply` skill 권장.

5. **정본 9+1+3 변경 의도** (`Obsidian-airlens/raw/docs/{platform,web,app,ml,db}/*`) → `wiki-curator` 자동화 X. *사용자 결정* 강제 (`feedback_git_tracked_user_review.md`). git tracked 영역.

## 자동화 영역 매트릭스

| 영역 | 자동 | 사유 |
|---|---|---|
| `wiki/synthesis/<topic>-YYYY-MM-DD.md` 신규 | ✅ wiki-synth + auto-index | gitignored, 패턴 표준화 |
| `wiki/imports/<domain>/<slug>-YYYY-MM-DD.md` 신규 | ✅ firecrawl-wiki-ingest + auto-index | gitignored, 라이선스 frontmatter 의무 |
| `wiki/concepts/*.md` 갱신 | ✅ auto-index supersede 자동 | gitignored |
| `wiki/log.md` rotate | ✅ wiki-log-rotate (월별) | gitignored |
| **`Obsidian-airlens/raw/docs/*`** (정본 9+1+3) | ❌ 사용자 결정 | git tracked, supersede 마커 사용자 review |
| **`Obsidian-airlens/index.md`** | ❌ 사용자 결정 | git tracked (root index) |
| `Obsidian-airlens/raw/docs/operations/AGENT_HARNESS.md` | ❌ 사용자 결정 | git tracked |

`feedback_git_tracked_user_review.md` 정합 — gitignored 자동 / git tracked 사용자 결정.

## 보안 가드 (CRITICAL)

자동화된 5 자산 모두 다음 패턴 차단:

- `secrets/` / `.env*` / API key 키워드 → wiki 페이지에 자동 작성 금지 (`firecrawl-policy.md` 보안 가드 정합)
- 사용자 PII (`joymin5655@gmail.com` 등) → 자동 페이지 작성 차단
- 미공개 결정 마커 (`[INTERNAL]` / `[CONFIDENTIAL]` / `[NDA]`) → 자동 sync 차단 (`notion-external-share.md` 정합)

## supervisor.py invocation 갭 측정

**측정 명령**:
```bash
python3 -c "
import json, collections
matched = collections.Counter()
invoked_skills = collections.Counter()
for line in open('.claude/logs/agent-routing.jsonl'):
    try: r = json.loads(line)
    except: continue
    for a in r.get('matched_agents', []):
        matched[a] += 1
print('wiki-curator dispatch:', matched.get('wiki-curator', 0))
print('doc-writer dispatch:', matched.get('doc-writer', 0))
"
```

**T+30d (2026-06-06)**: 갭 감소 측정. wiki-curator dispatch 가 지속되면서 wiki-synth / firecrawl-wiki-ingest invoke 빈도 ≥ 5 면 본 정책 효과 검증. 0 이면 supervisor.py 룰 직접 보강.

## 결합 자산

- `.claude/skills/wiki-synth/SKILL.md` — 새 페이지 생성 (글로벌)
- `.claude/skills/firecrawl-wiki-ingest/SKILL.md` — 외부 ingest
- `.claude/skills/wiki-supersede-apply/SKILL.md` — supersede 마커
- `scripts/hooks/wiki-auto-index.py` — PostToolUse 자동 index
- `scripts/hooks/wiki-log-rotate.py` — SessionStart log rotate
- `.claude/rules/policy/firecrawl-policy.md` — 외부 ingest 정책
- `.claude/rules/policy/notion-external-share.md` — 외부 공유 정책
- `~/.claude/plans/commit-pr-automation.md` — 본 plan Wave 2

## History

- 2026-05-07 — 초기 룰 작성. `commit-pr-automation.md` plan Wave 2 적용. **새 skill 생성 회피** (wiki-synth + auto-index + supersede + log-rotate + firecrawl-wiki-ingest 5 자산이 이미 wiki life cycle 커버) — supervisor dispatch 갭은 *인벤토리 무지* 가 원인, 자동화 부재 아님. T+30d 측정 갱신.
