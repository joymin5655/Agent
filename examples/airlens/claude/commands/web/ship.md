TypeScript 빌드 + lint 통과 후 git commit & push합니다.

WORKFLOW:
1. `npm run build` (tsc -b + vite build) 실행 — 실패 시 오류 보고 후 중단
2. `npm run lint` 실행 — 실패 시 오류 보고 후 중단
3. `git status`로 변경 파일 확인
4. 변경 내용을 요약한 descriptive commit message 작성 후 `git commit`
5. `git push`
