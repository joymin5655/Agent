# Rules — Overview (Critical 자동 로드 + Lazy 인덱스)

목적: `.claude/rules/*` 자동 로드 슬림화 (~140k → ~50k tokens). Critical 6 file 자동 가시 + 30 lazy file 인덱스. 본문 read 의무 = `policy/memory-discipline.md` R1.
정합성: 룰 본문 변경 시 본 인덱스 1줄도 동기 갱신 (drift 방지).

## Critical (자동 로드 — 6 file)

- [contributing.md](contributing.md) — TS strict / Python PEP 8 / 함수 50줄 soft (300줄 ceiling = CLAUDE.md only) / AAA test / build+lint+test / i18n en/ko 2-locale / PR 1 기능 단위.
- [public-repo.md](public-repo.md) — secret 하드코딩 금지 / `VITE_` 만 client / `SERVICE_ROLE_KEY` 서버 전용 / gitleaks 3중 / force-push to main 금지 / `--no-verify` 금지 / 타 agent branch 침범 금지.
- [external-plugin-policy.md](external-plugin-policy.md) — 7 plug-in (GSD / Context Mode / Claude Mem / /ultra-review / claude-md-management / addyosmani / vercel-labs) 충돌 매트릭스 C1-C8 + 작용 영역 정책.
- [multi-agent-worktree.md](multi-agent-worktree.md) — R1 worktree 강제 / R2 lock / R3 heartbeat / R4 자원 mutex / R4.1 file mutex / R5 PR serialize / R5.1 `--auto-push`+`--auto-merge` opt-in + Pre-push Layer 6 / R6 타 branch 침범 / R7.1 hook stack 실측 SOT / R10 untracked 보호 / R11-R14.
- [policy/security-guards.md](policy/security-guards.md) — 5 가드 SOT (production migration / secret / Edge Fn deploy / 결제 / ML uncertainty). 자동화 영원히 회피. 5 층 보안 stack (gitleaks → CI → hook → skill → policy).
- [policy/memory-discipline.md](policy/memory-discipline.md) — 인덱스 1줄 ≠ SOT. 키워드 매치 시 본문 read 의무. "가능성" / "추측" / "가짜" 단정 신호 = body read trigger.

## Lazy (필요 시 grep+Read — 30 file, `.claude/policy-archive/`)

- [actions-billing-admin-merge.md](../policy-archive/actions-billing-admin-merge.md) — Actions billing 한도 hit 시 admin merge SOP. 4 trigger + 5 가드 체크리스트 + §2 분기 (gitleaks billing fail vs 진짜 leak) + jsonl evidence sink.
- [addyosmani-agent-skills.md](../policy-archive/addyosmani-agent-skills.md) — addyosmani/agent-skills (33.9K⭐ MIT) 4 skill 선별 이식. 11 keep / 8 hybrid / 2 skip. namespace 충돌 회피.
- [agent-harness-security-tooling.md](../policy-archive/agent-harness-security-tooling.md) — 보안 OSS shortlist + AI/Agent Security 도구. persona overlay 6 / domain 4 / tool profile 4. OWASP LLM/MCP/Agentic 기준.
- [ai-usage-tracking.md](../policy-archive/ai-usage-tracking.md) — AI 사용 패턴 추적 SOT (2026-05-18 신규). L1 raw 8 jsonl → L2 memory 4 type → L3 weekly digest → L4 정본 후보. 4 영역. T+7d/T+14d/T+30d/T+60d trigger.
- [assets-retention.md](../policy-archive/assets-retention.md) — `assets/` 자산 생명주기 SOT. Retention 매트릭스 (snapshot 90일 / mockup 180일 / screenshots root 직행). `_archive/<YYYY-MM>/`.
- [auth-boundary.md](../policy-archive/auth-boundary.md) — 라우팅 ≠ 보안. Frontend route = UX / Edge Fn `requireAuth()` = 보안. 31 Edge Fn 분류 (User JWT 21 / Service Role 9 / dual 1).
- [data-source-integrity.md](../policy-archive/data-source-integrity.md) — 외부 source 변조 차단 (Round D2). 4 Edge Fn + 8 batch ingest. Integrity 4 패턴 (TLS / ETag / SHA256 / Zod). 변조 시 DQSS F + p10-p90 NaN.
- [dqss-uncertainty-policy.md](../policy-archive/dqss-uncertainty-policy.md) — Glass-box §5 advisory hook (Round D3). 19 ML 출력 컴포넌트 audit. PostToolUse warning only. block X / rewrite X.
- [external-plugin-claude-md-management.md](../policy-archive/external-plugin-claude-md-management.md) — claude-md-management plug-in (Anthropic 공식 Apache 2.0). 4 CLAUDE.md drift audit + path 화이트리스트 + Claude Mem 와의 차이. C6 (저위험).
- [firecrawl-policy.md](../policy-archive/firecrawl-policy.md) — Firecrawl MCP 화이트리스트 (~75 도메인). rate limit (도메인당 50 page/일). 라이선스 frontmatter 의무. wiki/imports/ 경로.
- [hugging-face-research.md](../policy-archive/hugging-face-research.md) — HF MCP 9 tool ML 7 도메인 (AOD/SDID/Camera AI/PARAAD/DQSS/TFT/GNN) 라우팅. arXiv ID 의무 + top-5 by citation in 3y.
- [humanizer-agent.md](../policy-archive/humanizer-agent.md) — `blader/humanizer` MIT 패턴 카탈로그. 영어 외부 공개 텍스트 한정. 5 가드 영역 (i18n / Glass-box / 한국어 / 코드 주석 / 보안) 작용 X.
- [idor-response-policy.md](../policy-archive/idor-response-policy.md) — IDOR 응답 코드 SOT. 4 매트릭스 (401 / 200 본인 / 403 권한부재 / 404 타인). 31 Edge Fn audit + frontend 11 매치 + i18n parity.
- [magic-21st-policy.md](../policy-archive/magic-21st-policy.md) — Magic-21st 4 tool design variant. AirLens 토큰 자동 주입 (`#25e2f4` / `#0a0f1a` / Inter / Crimson Pro). AI Slop 4 패턴 ban. Glass-box 의무.
- [matt-pocock-skills.md](../policy-archive/matt-pocock-skills.md) — Matt Pocock 6 skill (`grill-with-docs` / `grill-me` / `tdd` / `diagnose` / `improve-codebase-architecture` / `caveman`). 네이밍 충돌 회피.
- [model-artifact-integrity.md](../policy-archive/model-artifact-integrity.md) — ML model artifact 변조 차단 (Round D4). Supabase Storage `app-models` / sky-seg ONNX. 3-Layer attestation (hash / verify / Ed25519).
- [notion-external-share.md](../policy-archive/notion-external-share.md) — 정본 외부 공유 4 PRD (Platform / Web / App / Models). Architecture·DB·Operations internal-only. one-way sync. 수동 invoke. secret/PII diff scan.
- [obsidian-raw-retention.md](../policy-archive/obsidian-raw-retention.md) — `Obsidian-airlens/raw/` 외부 자료 생명주기. 정본 14체계 자동 작용 X. AI agents 학습 90일 / 학술 paper 영구 / claude session 90일.
- [plan-first-clarifying.md](../policy-archive/plan-first-clarifying.md) — 4-tier 분류 (trivial / interactive / autonomous / conversational). M3 활성 후 interactive 매치 시 clarifying-Q 4종. 슬래시 = 강제 autonomous.
- [production-stale-cache-diagnosis.md](../policy-archive/production-stale-cache-diagnosis.md) — production "옛 디자인" 신고 진단 SOT. 3-step (incognito 1초 먼저 → deploy 정합 → 캐시 정리). 4 anti-pattern.
- [rate-limit-policy.md](../policy-archive/rate-limit-policy.md) — Edge Function rate-limit middleware enforce. 31 Edge Fn / 14 미적용. `_shared/rate-limit.ts` 2-layer. hook Phase 1 warning-only / T+14d Phase 2 차단.
- [rls-policy.md](../policy-archive/rls-policy.md) — RLS 정책 SOT (Round D1). 62 ENABLE RLS / 139 CREATE POLICY / 26 service_role bypass Edge Fn. 표준 `<table>_<role>_<action>` + 5-tier role 분류.
- [same-name-skill-priority.md](../policy-archive/same-name-skill-priority.md) — 동명 skill 우선순위 매트릭스 (8 skill — hook / Matt Pocock / context-mode / superpowers / addyosmani / gstack). T+30d (2026-06-05) 데이터 기반 결정.
- [sequential-thinking-routing.md](../policy-archive/sequential-thinking-routing.md) — `sequentialthinking` MCP 트리거 (architecture / multi-step migration / refactor / ML pipeline / cross-domain). max 8 step·세션당 3 호출. caveman 우선.
- [skill-adoption-comparison.md](../policy-archive/skill-adoption-comparison.md) — 외부 OSS skill 도입 시 8-컬럼 비교 표 의무. 자동 skip / 자동 adopt 둘 다 회피 — row-by-row 사용자 결정.
- [strong-goal-template.md](../policy-archive/strong-goal-template.md) — 약한 vs 강한 goal 6 패턴 (target state / SoT / AC / validation / boundaries / stop) + 복붙 템플릿 + 약한 detect 신호. supervisor-goal-mode.md sister (입력 품질).
- [subagent-memory-policy.md](../policy-archive/subagent-memory-policy.md) — Anthropic 2.1+ subagent `memory` frontmatter. 3 scope (user / project / local) + AirLens default = local (gitignored). 3 메모리 시스템 역할 분리.
- [supervisor-delegation.md](../policy-archive/supervisor-delegation.md) — `/supervise` skill. plan → supervisor 위임. default = 옵션 A full auto. 6 안전장치 (stop / 5 가드 / R4.1 / gitleaks / test / type) 즉시 중단.
- [supervisor-goal-mode.md](../policy-archive/supervisor-goal-mode.md) — `/supervise --goal-mode` opt-in (Codex /goal 패턴 흡수). SQLite goal state (5 status) + audit protocol (requirement→evidence) + token budget hard limit. supervisor.py 본문 수정 X. Wave 0-3 완료 / Wave 4-6 deferral.
- [supervisor-tune.md](../policy-archive/supervisor-tune.md) — `/supervisor-tune` skill. agent-routing.jsonl 분석 → 갱신 안 제시 (옵션 C 보고만 default / 옵션 D 자동 적용 화이트리스트 강제). 자동 룰 변경 X.
- [vercel-labs-agent-skills.md](../policy-archive/vercel-labs-agent-skills.md) — vercel-labs/agent-skills (26.3K⭐) 2 skill CLI 채택 (RN / view-transitions). stack mismatch 게이트 (Cloudflare Pages — Vercel 종속 skip).
- [wiki-automation-coverage.md](../policy-archive/wiki-automation-coverage.md) — wiki life cycle 5 자산 (wiki-synth / auto-index / supersede / log-rotate / firecrawl-ingest). supervisor wiki-curator dispatch 갭 처리.
- [wiki-measurement.md](../policy-archive/wiki-measurement.md) — Karpathy LLM Wiki §Lint + §Query 측정 SOT. 2 hook (SessionStart stale-alert 180d + Stop file-back-track) Phase 1 advisory.
- [wrap-skill.md](../policy-archive/wrap-skill.md) — `/wrap` skill. push 사용자 무조건 / commit + PR 8 영역 자동. 5 가드 자동 abort. 화이트리스트 path + gitleaks Layer 1.

## Read-on-demand 패턴

```
Q: 룰에 있던 것 같은데?
A: grep -l "<keyword>" .claude/rules/ .claude/policy-archive/   # 1초 위치 확인
   Read 해당 file
```

자동 로드 ~140k → ~50k tokens (lazy 30 file = 본문 read 의무). 5 가드 0 침범 (security-guards / memory-discipline 자동 로드 keep).
