# 재시도 설계

`src/app.py`의 전송 함수에 재시도를 추가하고, `billing/charge.py`도 같은 방식으로 바꾼다.
관련 메모는 `AGENTS.md`와 [참고](AGENTS.md#top)에 있다. `src/untracked.py`, `.env`,
`secrets/prod.txt`, `config/server.pem`, `src/blob.bin`, `src/big.txt`, `src/link.txt`, `/etc/hosts`,
`../outside.txt`, `OUTSIDE_PATH`, [사이트](https://example.com/x)도 본다.
`src/app.py:10-20`은 이미 재시도를 처리한다고 가정한다.
캐시 방식은 구현 중에 정한다.
새 설정 계층을 추가한다.
