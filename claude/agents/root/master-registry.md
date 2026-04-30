# AirLens Master Agent Registry

> 정본 (SOT): `Obsidian-airlens/raw/docs/operations/AGENT_REGISTRY.md`
> 본 파일은 산출물이며 `scripts/sync_agent_registry.py` 가 자동 생성한다.
> Mirror: `Obsidian-airlens/raw/docs/operations/master-registry.json` (필요 시)

---

## 1. 목적

AirLens 플랫폼의 **모든 에이전트(글로벌 + 서브프로젝트)를 단일 인덱스로 통합**한다.
SOT 변경 후 `python3 scripts/sync_agent_registry.py` 실행으로 4 산출물이 재생성된다.

---

## 2. 산출 4 파일

| 경로 | 형식 | 비고 |
|---|---|---|
| `.claude/agents/master-registry.json` | JSON | 7-필드 schema |
| `.claude/agents/master-registry.md` | Markdown | 본 파일 |
| `AirLens-web/.claude/agents/registry.json` | JSON | web 21 agents 메타 |
| `AirLens-web/.claude/agents/registry-tier1.json` | JSON | 3 부서 키워드 라우팅 (훅 사용) |

---

## 3. 통계

- 총 agents: **59**
- Tier1 / Tier2 / Tier3: **13 / 27 / 19**
- scope=AirLens-web: **21**
- scope=global: **37**
- scope=AirLens-app: **1** (pending bootstrap)
- scope=AirLens-models: **0** (pending bootstrap)

---

## 4. 갱신 절차

1. SOT (`AGENT_REGISTRY.md` §3 표) 수정.
2. `python3 scripts/sync_agent_registry.py` 실행.
3. `python3 scripts/sync_agent_registry.py --check` 로 산출물 일치 확인.
4. 4 파일을 함께 커밋 (`chore(agents): sync registry — <변경 요지>`).

**금지**: 산출물 4 파일 수기 직접 수정. `registry-tier1.json` 키 이름 변경.

---

## 5. F2 D-H6 합의 인용

> 마스터 registry는 `AirLens-platform/.claude/agents/master-registry.json` (루트) + Obsidian mirror;
> worktree isolation은 **DB + app + models 부트스트랩만 강제**. 그 외(web 일반 PR, 정본 wiki 갱신,
> registry 자체 수정)는 main에서 작업 허용. (F2 Open Decisions, 2026-04-28)
