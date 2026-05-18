# Core Rules (AirLens-web)

5개 원본 룰을 통합한 정본 (system-design-principles + data-fetching + no-hardcoding + ecs-architecture + canvas-rendering).
원본 백업: `_backup-local/agent-env-snapshot-2026-04-28/rules-original/`

---

## 1. 시스템 설계 6원칙 (ENFORCED)

Plan Mode 진입, 새 모듈 추가, 코드 리뷰 시 검증한다.

1. **SoC** — 모듈은 단일 관심사만 (`api/hooks/store/components` 레이어 위반 금지)
2. **Encapsulation** — Store 내부 상태 직접 접근 금지, 상수는 config import
3. **Loose Coupling** — Cross-Store 호출 없음, 모듈 간 의존은 인터페이스로
4. **Scalability** — N배 사용자 증가 시 비용 선형 이하 (Server-Collect, CDN)
5. **Resilience** — 단일 실패가 전체 정지 안 함 (`Promise.allSettled`, 폴백, 서킷 브레이커)
6. **Security** — 민감 데이터 클라이언트 노출 금지 (RLS, env, SERVICE_ROLE_KEY 서버 전용)

상세: `Obsidian-airlens/wiki/concepts/system-design-principles.md`, `Skills/system-design-primer/README.md`.

---

## 2. Server-Collect, Client-Display (CRITICAL)

**Client(브라우저)는 외부 API를 직접 호출하지 않는다.** 모든 외부 데이터는 서버에서 미리 수집되어 정적 JSON 또는 캐시된 DB 레코드로 제공된다.

```
WRONG:  Browser → Open-Meteo / AirKorea / HuggingFace
CORRECT: Cron/Edge Function → DB/Storage → Browser reads cache
```

### 허용된 클라이언트 fetch 타겟

| Target | OK | Example |
|--------|-----|---------|
| `/data/*.json` (static) | Yes | `public/data/weather/current/aq-grid.json` |
| Supabase DB (RLS) | Yes | `supabase.from('weather_history').select()` |
| Supabase Storage | Yes | `storage/v1/object/public/wind-data/` |
| Supabase Edge Functions | Yes | `/functions/v1/data-proxy?route=airkorea` |
| External API directly | **NO** | `api.open-meteo.com`, `huggingface.co` |

### 데이터 파이프라인

```
[Cron / GitHub Actions / Edge Function]  → collect from external APIs
[Supabase DB / Storage / public/data/]   → serve cached data
[Browser]                                 → reads pre-collected data
```

폴백 체인: Supabase DB (freshest) → Supabase Storage → `public/data/` static JSON.

### 단속

- `src/api/`는 상대 경로(`/data/...`) 또는 `VITE_SUPABASE_URL`만 fetch 가능
- `src/`에서 `fetch('https://api.open-meteo.com/...')` / `fetch('https://huggingface.co/...')` = 위반

상세: `Obsidian-airlens/wiki/concepts/data-pipeline.md`.

---

## 3. No Hardcoding (CRITICAL — HOOK ENFORCED)

### 3-1. 상수는 config import

모든 상수, 설정값, 메타데이터는 config/설정 파일에서 단일 소스로 정의 후 import한다.

```typescript
// WRONG: 컴포넌트에 직접 정의 / 같은 상수를 여러 파일에 복사
const SEGMENTS = [[0, [16, 185, 129]], [12, [16, 185, 129]]];

// CORRECT: config 단일 소스 → import
// src/lib/earth/config.ts
export const PM25_COLOR_SCALE = [...];
export const IDW_CONFIG = { station: { power: 2.0, maxDistanceDeg: 15 } };

// 컴포넌트
import { PM25_COLOR_SCALE, IDW_CONFIG } from '../lib/earth/config';
```

허용 예외: Tailwind 클래스명, JSX `aria-label`/`placeholder`, 테스트 fixture.
위반 시 PreToolUse 훅이 Write/Edit 차단 가능.

### 3-2. 모르면 모른다고 말한다

데이터/구조/확신이 없으면 추측하지 않고 사용자에게 질문한다. "~인 것 같습니다" 대신 "~를 확인해야 합니다".

```
WRONG: "이 API는 아마 이런 형식일 것입니다" → 추측 후 구현
CORRECT: "이 API 응답 구조를 확인할 수 없습니다. 샘플을 보여주시겠어요?"
```

### 3-3. 행동 전 Why/Effect/Scope 설명

파일 생성/수정/삭제, 패키지 설치 전 항상 설명한다.

```
"config.ts에 PM25_COLOR_SCALE 추가합니다.
 - 왜: pm25Overlay/policyOverlay/policyMap 3곳에 중복 정의됨
 - 효과: 단일 소스로 통합 → 색상 변경 시 한 곳만 수정
 - 영향: 3개 파일에서 로컬 정의를 import로 교체"
```

상세: `Obsidian-airlens/wiki/concepts/no-hardcoding.md`.

---

## 4. ECS Architecture (Web Adaptation)

데이터-로직을 분리하고, 시스템 간 직접 호출을 금지한다.

### 4-1. Cross-Store 직접 호출 금지 (CRITICAL)

Store 파일에서 다른 Store를 import / `getState()` 접근 금지.

```typescript
// WRONG: notificationStore가 authStore를 직접 호출
import { useAuthStore } from './authStore';
subscribeToNotifications: () => {
  const { user } = useAuthStore.getState();  // 시스템 간 호출
}

// CORRECT: Hook(시스템)이 두 Store를 오케스트레이션
// useNotifications.ts
const userId = useAuthStore(s => s.user?.id);
const { subscribe } = useNotificationStore();
useEffect(() => { if (userId) subscribe(userId); }, [userId, subscribe]);
```

검증: `grep -r "use.*Store" src/store/ --include="*.ts" | grep -v "export const use"` 결과 0건.

### 4-2. Realtime 이벤트는 큐 패턴 (HIGH)

Supabase Realtime `.on()` 콜백 내 즉시 mutation 금지. 큐에 적재 후 다음 렌더 사이클에 Hook이 처리.

```typescript
// CORRECT: 큐 적재 + Hook 소비
channel.on('INSERT', (payload) => {
  set(state => ({ pendingEvents: [...state.pendingEvents, payload.new] }));
});

function useProcessRealtimeQueue() {
  const pending = useStore(s => s.pendingEvents);
  const flush = useStore(s => s.flushPending);
  useEffect(() => { if (pending.length > 0) flush(); }, [pending, flush]);
}
```

콜백 즉시 mutation = 즉시 리렌더 = 다른 effect 트리거 = Call Chain. 큐 + 다음 틱 = ECS의 EntityCommandBuffer.

### 4-3. 실행 흐름 가시성 (MEDIUM)

`useEffect` 체인 (A 상태 → B 트리거 → C 트리거) 금지. 단일 오케스트레이팅 훅으로 통합하거나 명시적 async 순서.

### 4-4. 레이어 매핑

| ECS | AirLens-web | 규칙 |
|-----|------------|------|
| Component | `store/` | 순수 데이터 + setter, 비즈니스 로직 금지, 다른 Store import 금지, API 호출 금지 |
| System | `hooks/` | 비즈니스 로직, Store 간 중개 |
| — | `api/` | 외부 I/O, 순수 함수 |
| — | `components/` | 렌더링 + Store 읽기 + Hook 호출 |

`check-cross-store.sh` PostToolUse 훅이 Store 편집 시 자동 감지.

상세: `Obsidian-airlens/wiki/concepts/ecs-philosophy-web.md`, `Obsidian-airlens/wiki/concepts/harness-engineering.md`.

---

## 5. Canvas 2D Rendering

### 5-1. Non-Finite Guard (CRITICAL)

Canvas 2D API는 non-finite 값에서 throw한다. 항상 가드.

```typescript
const r = projection.scale();
if (!isFinite(r) || r <= 0) return;
ctx.createRadialGradient(cx, cy, r, cx, cy, r * 1.25);
```

가드 필수: `createRadialGradient` (6 params), `createLinearGradient` (4), `arc` (x/y/radius, radius >= 0), `moveTo`/`lineTo`.
주요 발생 원인: container 0 사이즈 시 `projection.scale()`, `projection.invert()` null, 좌표 변환 0 나눔.

### 5-2. Container Size Guard

```typescript
const w = container.clientWidth, h = container.clientHeight;
if (w === 0 || h === 0) return;  // layout not ready
```

### 5-3. DPR 처리

```typescript
const dpr = Math.min(window.devicePixelRatio || 1, 2);
const pw = Math.round(w * dpr), ph = Math.round(h * dpr);
canvas.width = pw; canvas.height = ph;
canvas.style.width = `${w}px`; canvas.style.height = `${h}px`;
```

### 5-4. 스텝 스킵 금지

Production 오버레이는 매 픽셀 렌더. `step > 1` 사용 금지 (블록 모양 발생). 성능 필요 시 Web Worker 또는 저해상도 + CSS 업스케일.

### 5-5. 데이터 독립 로딩

단일 데이터 소스로 무관한 기능을 블록하지 않는다.

```typescript
// CORRECT: 독립 로딩
const [windResult] = await Promise.allSettled([fetchWind()]);
await loadStations();
drawStationMarkers();  // 항상 동작
if (windResult.status === 'fulfilled' && windResult.value) {
  startParticles(windResult.value);
}
```

### 5-6. Overlay Alpha 가이드

- PM2.5 heatmap: `alpha >= 0.7`
- Wind speed overlay: `alpha ~0.4`
- Wind particles: 흰/회색 trails, `0.2 → 0.85` (tail → head)

상세: `Obsidian-airlens/wiki/concepts/canvas-rendering.md`.

---

## 6. Three.js / R3F Discipline

3D 컴포넌트(`/globe`, particle viz)는 메모리/프레임 압박이 크다. 다음 원칙을 위반하면 LCP/메모리 회귀 발생.

- **Suspense 경계 의무** — 무거운 3D 트리(텍스처, GLTF, AOD overlay)는 `<Suspense fallback={…}>` 안에서만 마운트. 직접 마운트 시 첫 paint 차단.
- **`useFrame` 메모이즈** — 콜백 내부에서 `new Vector3()`, `new Color()` 등 객체 생성 금지. 모듈 스코프 또는 `useMemo`로 캐시.
- **GL 자원 cleanup 의무** — `geometry.dispose()`, `material.dispose()`, `texture.dispose()`를 unmount effect에 포함. drei `<primitive>` 사용 시도 동일.
- **i18n build 실패 강제** — i18n 키 누락 시 `npm run i18n:check`가 실패해야 함. 누락 키로 빌드 통과시키지 않음 (위 1.6 항목 강화).

상세 패턴: `Obsidian-airlens/wiki/concepts/three-js-discipline.md` (작성 예정 — 현재는 본 섹션이 정본).

---

## 7. Visual Regression (UI 레이아웃 변경 PR)

레이아웃/스타일/색상에 영향이 있는 PR (Globe, Today snap-scroll, AppLayout, hero/CTA, card grid 등)은 `npm run test:visual` (Playwright `tests/visual/`) 실행 후 스냅샷 diff 를 PR 본문에 첨부.

- `tests/visual/` 디렉토리는 현재 미생성 — 신설은 별도 plan
- 신설 전 PR 은: (a) layout 영향 범위를 PR 본문에 명시, (b) `npm run test:e2e` 의 시각적으로 영향받는 케이스 수동 확인
- `playwright.config.ts` 의 `expect.toHaveScreenshot` threshold 는 기본값 (0.2) 유지. 의도적 변경 시만 갱신
