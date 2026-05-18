GitHub Pages용 프로덕션 빌드 후 배포합니다.

WORKFLOW:
1. `bash scripts/build-gh.sh` 실행 (`DEPLOY_TARGET=github npm run build`)
2. 빌드 결과 `dist/` 크기 및 핵심 파일 확인
3. `npx gh-pages -d dist` 로 `gh-pages` 브랜치에 배포
4. 배포 완료 URL 확인: `https://{username}.github.io/AirLens/`
