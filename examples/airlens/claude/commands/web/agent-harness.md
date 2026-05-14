PGE(Planner-Generator-Evaluator) 품질 보증 루프를 실행합니다.

ARGUMENTS: $ARGUMENTS — 실행할 작업 설명 (예: "Today 페이지에 실시간 데이터 연결")

WORKFLOW:

## 1. 의도 분류
- QUERY → 바로 답변 (하네스 불필요)
- SIMPLE_EDIT → 단일 에이전트 직접 실행
- FEATURE → PGE 루프 실행 (아래)
- MULTI_DEPT → 부서별 병렬 PGE 루프

## 2. 리스크 판정
- LOW: 단일 파일 수정, 스타일 변경 → max_retries=1
- MEDIUM: 다중 파일, 새 컴포넌트 → max_retries=3
- HIGH: 아키텍처 변경, DB 스키마, 보안 → max_retries=5

## 3. 부서 라우팅
`.claude/agents/registry-tier1.json`의 triggerKeywords로 부서 매칭:
- frontend: UI/UX, 컴포넌트, 디자인, i18n, Globe, 접근성
- engineering: ML, DB, API, Edge Function, 테스트, 보안, 성능
- operations: 배포, 문서, 비용, 위키

## 4. PGE 루프 (FEATURE/MULTI_DEPT)

### Generator Phase
1. 부서 manager가 적합한 에이전트 선택 (registry.json 참조)
2. 에이전트가 코드 생성/수정

### Context Reset (방화벽)
3. Generator의 추론 과정을 Evaluator에게 전달하지 않음

### Evaluator Phase (블라인드 리뷰)
4. 평가 기준:
   - Build (2점): `npm run build` 또는 `pytest` 통과
   - Lint (2점): `npm run lint` 통과
   - Test (2점): 테스트 통과 + 커버리지
   - Code Quality (2점): style-reviewer + performance-reviewer
   - AirLens Rules (2점): 하드코딩 금지, types.ts, i18n, Glass-Box

5. 판정:
   - ≥ 7.0 + 모든 차원 > 0 → **PASS** → 완료
   - 5.0–6.9 → **RETRY** → Generator에 피드백 → 재생성 (max N cycles)
   - < 5.0 → **FAIL** → 구조적 분석 + memory/에 기록

### Circuit Breaker
- 1회 실패: 피드백과 함께 재시도
- 2회 실패: 5초 대기 + 모델 업그레이드 (haiku→sonnet, sonnet→opus)
- 3회 실패: 사용자에게 ESCALATE

## 5. 완료 보고
```
[PGE] 결과: PASS/FAIL
  점수: X.X/10.0
  사이클: N/max
  에이전트: agent-id (model)
  부서: department
  변경 파일: [file list]
```
