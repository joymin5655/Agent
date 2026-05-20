#!/usr/bin/env python3
"""Stop hook — 세션 종료 시 변경 파일 품질 요약.

git diff로 변경 파일을 수집하고, 각 파일의 AirLens 규칙 위반을 빠르게 검사.
차단하지 않고 정보 제공 (stderr 출력).
"""

import json
import os
import pathlib
import re
import subprocess
import sys
from datetime import date

PROJECT_ROOT = str(pathlib.Path(__file__).resolve().parents[2])
CLAUDE_LOG_DIR = os.path.join(PROJECT_ROOT, ".claude/logs")


def get_changed_files() -> list[str]:
    """git diff로 변경된 파일 목록 수집."""
    try:
        result = subprocess.run(
            ["git", "diff", "--name-only", "HEAD"],
            capture_output=True, text=True, timeout=5,
        )
        files = [f.strip() for f in result.stdout.strip().split("\n") if f.strip()]
        # Also check untracked files
        result2 = subprocess.run(
            ["git", "ls-files", "--others", "--exclude-standard"],
            capture_output=True, text=True, timeout=5,
        )
        untracked = [f.strip() for f in result2.stdout.strip().split("\n") if f.strip()]
        return files + untracked
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return []


def check_file(filepath: str) -> list[str]:
    """단일 파일에 대한 빠른 규칙 검사."""
    issues: list[str] = []

    if not os.path.exists(filepath):
        return issues

    try:
        with open(filepath, encoding="utf-8") as f:
            content = f.read()
    except OSError:
        return issues

    # Only check TSX/TS source files
    if not filepath.endswith((".tsx", ".ts")):
        return issues
    if "node_modules" in filepath or "dist/" in filepath:
        return issues

    basename = os.path.basename(filepath)

    # 1. Inline types (not in types.ts or types/*.ts)
    if "/types" not in filepath and "/types.ts" not in filepath:
        inline_types = re.findall(
            r"^(?:export\s+)?(?:interface|type)\s+(\w+)",
            content, re.MULTILINE,
        )
        non_props = [t for t in inline_types if not t.endswith("Props")]
        if non_props:
            issues.append(f"  인라인 타입: {', '.join(non_props[:3])}")

    # 2. Hardcoded hex colors in components
    if "/pages/" in filepath or "/components/" in filepath:
        hex_count = len(re.findall(r"\[#[0-9a-fA-F]{3,8}\]", content))
        if hex_count > 0:
            issues.append(f"  하드코딩 색상: {hex_count}건")

    # 3. console.log
    console_logs = len(re.findall(r"console\.log\(", content))
    if console_logs > 0:
        issues.append(f"  console.log: {console_logs}건")

    return issues


def read_jsonl_for_date(filepath: str, date_str: str) -> list[dict]:
    if not os.path.exists(filepath):
        return []
    records = []
    try:
        with open(filepath, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if str(record.get("ts") or "").startswith(date_str):
                    records.append(record)
    except OSError:
        return []
    return records


def high_risk_evidence_warnings() -> list[str]:
    today = date.today().isoformat()
    supervisor_records = read_jsonl_for_date(
        os.path.join(CLAUDE_LOG_DIR, "supervisor-routing.jsonl"),
        today,
    )
    agent_records = read_jsonl_for_date(
        os.path.join(CLAUDE_LOG_DIR, "agent-routing.jsonl"),
        today,
    )
    dispatched = {str(item.get("subagent_type")) for item in agent_records if item.get("subagent_type")}
    warnings = []
    for record in supervisor_records:
        if record.get("risk") != "HIGH" and record.get("intent") != "MULTI_DEPT":
            continue
        required = [item for item in record.get("matched_agents", []) if str(item).lower() != "plan"]
        if not required:
            continue
        covered = dispatched.intersection(required)
        if not covered:
            prompt = str(record.get("prompt_first_160") or "").strip()
            warnings.append(
                "  high-risk evidence missing: "
                f"intent={record.get('intent', 'unknown')} risk={record.get('risk', 'unknown')} "
                f"workflow={record.get('workflow') or 'none'} required={', '.join(required)} "
                f"prompt={prompt[:80]}"
            )
    return warnings


def main() -> None:
    # Stop hook input: {"session_id":"...","transcript_path":"...","cwd":"...",
    #                   "hook_event_name":"Stop","stop_hook_active":bool}
    stop_hook_active = False
    try:
        stdin_data = json.load(sys.stdin)
        if isinstance(stdin_data, dict):
            stop_hook_active = bool(stdin_data.get("stop_hook_active", False))
    except (json.JSONDecodeError, EOFError):
        pass

    # Escape hatch: AIRLENS_QUALITY_GATE_BLOCK=0 → advisory only (no block)
    block_enabled = os.environ.get("AIRLENS_QUALITY_GATE_BLOCK", "1") == "1"

    files = get_changed_files()
    src_files = [f for f in files if "src/" in f and f.endswith((".tsx", ".ts"))]
    evidence_warnings = high_risk_evidence_warnings()

    if not src_files:
        if evidence_warnings:
            print("[Quality Gate] Supervisor evidence warnings:\n" + "\n".join(evidence_warnings), file=sys.stderr)
        # No source files changed — skip
        print(json.dumps({}))
        sys.exit(0)

    total_issues = 0
    file_reports: list[str] = []

    for filepath in src_files:
        issues = check_file(filepath)
        if issues:
            total_issues += len(issues)
            file_reports.append(f"  {os.path.basename(filepath)}:\n" + "\n".join(f"    {i}" for i in issues))

    if total_issues == 0:
        print(f"[Quality Gate] {len(src_files)}개 파일 검사 완료. 위반 없음.", file=sys.stderr)
        if evidence_warnings:
            print("[Quality Gate] Supervisor evidence warnings:\n" + "\n".join(evidence_warnings), file=sys.stderr)
        print(json.dumps({}))
        sys.exit(0)

    summary = (
        f"[Quality Gate] {len(src_files)}개 파일 검사, {total_issues}건 위반:\n"
        + "\n".join(file_reports)
    )
    if evidence_warnings:
        summary += "\n[Quality Gate] Supervisor evidence warnings:\n" + "\n".join(evidence_warnings)
    print(summary, file=sys.stderr)

    # 위반 기록 누적 (크로스-세션 학습용)
    violations_file = "/tmp/airlens-session-violations.json"
    try:
        from datetime import date
        existing = {}
        if os.path.exists(violations_file):
            with open(violations_file, encoding="utf-8") as vf:
                existing = json.load(vf)
        today = date.today().isoformat()
        if today not in existing:
            existing[today] = []
        existing[today].append({
            "files": len(src_files),
            "issues": total_issues,
            "details": file_reports[:5],
        })
        with open(violations_file, "w", encoding="utf-8") as vf:
            json.dump(existing, vf, ensure_ascii=False, indent=2)
    except Exception:
        pass  # 기록 실패해도 훅 자체는 정상 종료

    # 완료 게이트: 첫 Stop에서 위반 발견 시 decision:block 으로 마무리 차단.
    # stop_hook_active=True → 이미 한 번 block했음, 사용자가 통과 결정 → advisory only.
    # AIRLENS_QUALITY_GATE_BLOCK=0  → 강제 advisory mode.
    if block_enabled and not stop_hook_active:
        reason = (
            f"{summary}\n\n"
            "응답 마무리 차단. 다음 중 하나 선택:\n"
            "  (a) 위반 해결 — types.ts 이동 / 토큰화 / console.log 제거 후 응답 계속.\n"
            "  (b) 의도적 위반 — 사유 명시 후 응답 계속 (다음 Stop은 자동 통과).\n"
            "  (c) 강제 비활성 — 환경변수 AIRLENS_QUALITY_GATE_BLOCK=0 (전체 세션 advisory)."
        )
        print(json.dumps({"decision": "block", "reason": reason}))
        sys.exit(0)

    print(json.dumps({}))
    sys.exit(0)


if __name__ == "__main__":
    main()
