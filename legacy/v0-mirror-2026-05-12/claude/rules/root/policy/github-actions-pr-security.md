# GitHub Actions PR Security Policy

Last updated: 2026-05-07

## 목적

PR에서 실행되는 CI가 repository secret, App token, write-scoped `GITHUB_TOKEN`을 PR 작성자에게 노출하지 않도록 하는 정책이다. 이 문서는 `.github/workflows/**` 변경 시 반드시 확인해야 하는 기준이다.

## 핵심 판단

- Fork PR: GitHub는 기본적으로 repository secrets를 전달하지 않고 `GITHUB_TOKEN`도 read-only로 제한한다.
- Same-repo PR: collaborator나 bot이 같은 repository branch에서 PR을 열면 workflow 설정에 따라 secrets와 write token이 job에 들어갈 수 있다.
- 따라서 위험한 패턴은 "PR이 수정할 수 있는 코드를 실행하는 job"과 "secret/write token이 있는 job"을 섞는 것이다.

## 불변 규칙

1. `pull_request`에서 PR 코드를 checkout하고 `npm ci`, `npm run`, `npx`, `node apps/**`, `node scripts/**`, `python scripts/**`, `bash scripts/**`, `git push`를 실행하는 job은 `contents: read`만 사용한다.
2. PR 코드 실행 job의 `actions/checkout`은 `persist-credentials: false`를 설정한다.
3. `contents: write`, `pull-requests: write`, App private key, cloud API key, model API key 등 privileged credential이 필요한 job은 PR branch code를 실행하지 않는다.
4. Privileged job이 repo 파일을 실행해야 하면 반드시 trusted base checkout을 사용한다.

```yaml
- uses: actions/checkout@<pinned-sha>
  with:
    ref: ${{ github.base_ref }}
    persist-credentials: false
```

5. PR에 자동 commit/push가 필요하면 read-only PR job과 privileged trusted-base job을 분리하고, privileged job은 적용 파일 경로를 allowlist로 검증한다.
6. `pull_request_target`은 PR code build/test에 사용하지 않는다. 라벨링/댓글처럼 base context 작업에만 사용하고, head checkout을 금지한다.
7. `VITE_*`와 `EXPO_PUBLIC_*`는 client bundle에 들어가는 public 값이다. 여기에 secret을 저장하지 않는다.
8. `OPENAI_API_KEY`, `GEMINI_API_KEY`, App private key 같은 sensitive secret을 쓰는 PR job은 owner-only gate를 둔다.

```yaml
if: >
  github.event.pull_request.head.repo.full_name == github.repository &&
  github.event.pull_request.author_association == 'OWNER'
```

## 자동 검증

`scripts/maintenance/check-actions-pr-token-safety.py`가 다음 패턴을 CI에서 차단한다.

- `pull_request_target` 사용
- `pull_request` job에서 write permission과 PR checkout을 함께 사용
- sensitive `secrets.*`가 있는 job에서 PR-controlled code 실행
- sensitive `secrets.*`가 있는 PR job에 owner-only gate 또는 trusted base checkout이 없음

이 검사는 `.github/workflows/secret-scan.yml`의 `actions-pr-token-safety` job에서 실행된다.

## 기존 결정

- `i18n-auto-fill.yml`: PR에서는 read-only로 patch artifact만 생성한다. 자동 push는 제거했다.
- `visual.yml`: PR에서는 read-only로 visual test와 baseline artifact만 생성한다. `[visual-update]` label도 push하지 않는다.
- `review.yml`: `OPENAI_API_KEY`/`GEMINI_API_KEY`를 쓰는 model review job은 owner PR에서만 실행한다. PR comment를 쓰는 orchestrate job은 `pull-requests: write`를 유지하되, base branch의 trusted `review-orchestrate.cjs`만 실행한다.
