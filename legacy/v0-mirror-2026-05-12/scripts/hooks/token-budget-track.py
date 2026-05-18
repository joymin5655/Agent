#!/usr/bin/env python3
"""SessionStart hook — 자동 로드 컨텍스트 토큰 예산 트래커.

세션 시작 시 자동 로드되는 자원 (루트 CLAUDE.md, apps/web rules,
사용자 MEMORY.md)의 byte size 를 측정하여 토큰을 추정 (bytes / 3.5),
일별 JSON 로그에 기록하고 임계치 초과 시 stderr 경고 출력.

특징:
  - stdin pass-through (Claude Code 가 보낸 JSON 그대로 stdout)
  - 분석/경고는 stderr 로만 출력
  - 실패 silent — 훅이 세션 시작을 막지 않음
  - 같은 날 재실행 시 로그 마지막 값 유지 (덮어쓰기 append)
"""

from __future__ import annotations

import datetime as _dt
import json
import os
import pathlib
import sys
import traceback

# Claude Code 가 hook 호출 시 세션 cwd 를 CLAUDE_PROJECT_DIR 로 노출.
# 미설정 환경 (직접 실행/테스트) 에서는 script 위치 기반 fallback.
_env_root = os.environ.get("CLAUDE_PROJECT_DIR")
PROJECT_ROOT = (
    pathlib.Path(_env_root).resolve()
    if _env_root
    else pathlib.Path(__file__).resolve().parents[2]
)
# Claude Code transcoding 규칙: '/', ' ', '_' → '-' (project path → 디렉터리명)
_TRANSCODED = (
    str(PROJECT_ROOT).replace("/", "-").replace(" ", "-").replace("_", "-")
)
MEMORY_DIR = pathlib.Path.home() / ".claude" / "projects" / _TRANSCODED / "memory"

# 토큰 추정 상수 (Claude Code 평균 영문/한글 혼용 ~3.5 bytes/token)
BYTES_PER_TOKEN = 3.5
THRESHOLD_TOKENS = 15_000


def _measure(paths: list[pathlib.Path]) -> tuple[int, list[dict]]:
    """경로 리스트의 총 byte 와 파일별 detail 반환."""
    total_bytes = 0
    details: list[dict] = []
    for p in paths:
        if not p.exists() or not p.is_file():
            continue
        try:
            size = p.stat().st_size
        except OSError:
            continue
        total_bytes += size
        details.append(
            {
                "path": str(p),
                "bytes": size,
                "tokens_est": round(size / BYTES_PER_TOKEN),
            }
        )
    return total_bytes, details


def _collect_targets() -> dict[str, list[pathlib.Path]]:
    """측정 대상을 카테고리별로 모아서 반환.

    카테고리 (2026-05-06 Tier 0 T0-4 확장):
      - claude_md      : root CLAUDE.md (gitignored)
      - claudeignore   : .claudeignore (T0-2-A 신규, tracked)
      - rules          : apps/web/.claude/rules/*.md (web 영역, 하위 호환)
      - root_rules     : .claude/rules/*.md (T0-4 신규, 글로벌 룰)
      - obsidian_index : Obsidian-airlens/index.md (정본 진입점, gitignored)
      - memory         : ~/.claude/projects/{...}/memory/MEMORY.md (사용자 자동 메모리)
    """
    web_rules_dir = PROJECT_ROOT / "apps" / "web" / ".claude" / "rules"
    web_rules_files = sorted(web_rules_dir.glob("*.md")) if web_rules_dir.is_dir() else []
    root_rules_dir = PROJECT_ROOT / ".claude" / "rules"
    root_rules_files = sorted(root_rules_dir.glob("*.md")) if root_rules_dir.is_dir() else []
    return {
        "claude_md": [PROJECT_ROOT / "CLAUDE.md"],
        "claudeignore": [PROJECT_ROOT / ".claudeignore"],
        "rules": web_rules_files,
        "root_rules": root_rules_files,
        "obsidian_index": [PROJECT_ROOT / "Obsidian-airlens" / "index.md"],
        "memory": [MEMORY_DIR / "MEMORY.md"],
    }


def _build_record() -> dict:
    """자동 로드 자원 측정 결과 record 생성."""
    targets = _collect_targets()
    record: dict = {
        "timestamp": _dt.datetime.now().isoformat(timespec="seconds"),
        "bytes_per_token": BYTES_PER_TOKEN,
        "threshold_tokens": THRESHOLD_TOKENS,
        "categories": {},
        "totals": {"bytes": 0, "tokens_est": 0},
    }

    grand_bytes = 0
    for category, paths in targets.items():
        cat_bytes, details = _measure(paths)
        grand_bytes += cat_bytes
        record["categories"][category] = {
            "bytes": cat_bytes,
            "tokens_est": round(cat_bytes / BYTES_PER_TOKEN),
            "files": details,
        }

    record["totals"]["bytes"] = grand_bytes
    record["totals"]["tokens_est"] = round(grand_bytes / BYTES_PER_TOKEN)
    record["over_threshold"] = (
        record["totals"]["tokens_est"] > THRESHOLD_TOKENS
    )
    return record


def _append_log(record: dict) -> pathlib.Path:
    """일별 JSON 로그에 record append (같은 날 마지막 값 유지)."""
    today = _dt.date.today().isoformat()
    log_path = MEMORY_DIR / f"token-budget-{today}.json"

    payload: dict = {"date": today, "entries": []}
    if log_path.exists():
        try:
            existing = json.loads(log_path.read_text(encoding="utf-8"))
            if isinstance(existing, dict) and "entries" in existing:
                payload = existing
        except (json.JSONDecodeError, OSError):
            pass

    payload["entries"].append(record)
    payload["last"] = record  # convenience: 같은 날 마지막 값 유지

    MEMORY_DIR.mkdir(parents=True, exist_ok=True)
    log_path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return log_path


def main() -> None:
    raw = sys.stdin.read()
    # pass-through 먼저 (분석 실패해도 세션 시작 보존)
    print(raw, end="")
    sys.stdout.flush()

    try:
        record = _build_record()
        _append_log(record)

        if record["over_threshold"]:
            tokens = record["totals"]["tokens_est"]
            print(
                f"[TOKEN-BUDGET] 자동 로드 토큰 {tokens:,} "
                f"(>{THRESHOLD_TOKENS:,}) — CLAUDE.md/rules 점검 권장",
                file=sys.stderr,
            )
    except Exception:  # noqa: BLE001 - 훅은 silent on failure
        # 디버깅 필요 시 traceback 도 silent 로
        if "--debug" in sys.argv:
            traceback.print_exc(file=sys.stderr)


if __name__ == "__main__":
    main()
