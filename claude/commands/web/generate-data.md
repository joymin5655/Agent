ML 파이프라인을 실행하여 프론트엔드용 정적 데이터 파일을 업데이트합니다.

WORKFLOW:
1. `cd ../AirLens-models` 로 이동
2. `python main.py --mode predict --output ../AirLens-web/public/data/predictions/` 실행
3. `python main.py --mode dqss --output ../AirLens-web/public/data/` 실행
4. 생성된 파일 크기와 날짜 확인 (`ls -lh ../AirLens-web/public/data/`)
5. 이상 없으면 `cd ../AirLens-web` 로 복귀 보고
