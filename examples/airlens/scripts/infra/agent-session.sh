#!/usr/bin/env bash
# Multi-agent session coordinator for AirLens.
# Rule reference: .claude/rules/multi-agent-worktree.md

set -euo pipefail

resolve_canonical_root() {
  local common_dir root
  if common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
    if [[ "$(basename "$common_dir")" == ".git" ]]; then
      root="$(dirname "$common_dir")"
    else
      root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    fi
    (cd "$root" 2>/dev/null && pwd -P) && return 0
  fi
  git rev-parse --show-toplevel 2>/dev/null || pwd -P
}

REPO_ROOT="$(resolve_canonical_root)"
LOCK_DIR="$REPO_ROOT/.claude/locks"
LOCK_FILE="$LOCK_DIR/active-sessions.json"
LOCK_MUTEX_DIR="$LOCK_DIR/.mutex.d"
LOCK_HOLDER="$LOCK_MUTEX_DIR/holder"
WORKTREES_DIR="$REPO_ROOT/.worktrees"

AGENT="${AGENT:-claude}"
AGENT_SESSION_ID_ENV="${AGENT_SESSION_ID:-}"
SESSION_ID="${AGENT_SESSION_ID_ENV:-${AGENT}-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
SESSION_PID="${AGENT_SESSION_PID:-0}"
if [[ ! "$SESSION_PID" =~ ^[0-9]+$ ]]; then
  SESSION_PID=0
fi

mkdir -p "$LOCK_DIR" "$WORKTREES_DIR"

if ! command -v jq >/dev/null 2>&1; then
  echo "agent-session.sh requires jq (brew install jq)" >&2
  exit 127
fi

now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# Walk the parent process chain to find the claude binary's PID. This gives a
# stable identifier per-claude-session so register/heartbeat hooks invoked
# under the same claude process converge on one lock entry. Returns 1 if no
# claude ancestor found.
claude_pid_walk() {
  local pid="${PPID:-$$}"
  local guard=0 comm ppid
  while [[ "$pid" -gt 1 && "$guard" -lt 16 ]]; do
    comm="$(ps -p "$pid" -o comm= 2>/dev/null | head -1)"
    case "$comm" in
      *claude*) echo "$pid"; return 0 ;;
    esac
    ppid="$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')"
    [[ -z "$ppid" || "$ppid" == "$pid" ]] && break
    pid="$ppid"
    guard=$((guard + 1))
  done
  return 1
}

iso_minus_minutes() {
  local mins="$1"
  date -u -v-"${mins}"M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -d "-${mins} min" +"%Y-%m-%dT%H:%M:%SZ"
}

init_lock_file() {
  if [[ ! -f "$LOCK_FILE" ]]; then
    echo '{"sessions":[],"shared_resource_locks":{}}' > "$LOCK_FILE"
  fi
}

# T0-C: retry git worktree add when .git/config.lock race occurs.
# Two parallel `git worktree add` invocations can collide on the lockfile;
# we back off (1/2/3/5/8s) and retry up to 5 times before surfacing the error.
worktree_add_retry() {
  local i err
  err="$(mktemp)"
  for i in 1 2 3 5 8; do
    if git -C "$REPO_ROOT" worktree add "$@" 2>"$err"; then
      rm -f "$err"
      return 0
    fi
    if [[ -e "$REPO_ROOT/.git/config.lock" ]] || grep -q "config.lock\|cannot lock ref" "$err"; then
      echo "agent-session: .git/config.lock race detected, retrying in ${i}s" >&2
      sleep "$i"
      continue
    fi
    cat "$err" >&2
    rm -f "$err"
    return 1
  done
  echo "agent-session: worktree add failed after 5 retries" >&2
  cat "$err" >&2
  rm -f "$err"
  return 1
}

acquire_mutex() {
  local timeout=10 i
  for ((i=0; i<timeout*10; i++)); do
    if mkdir "$LOCK_MUTEX_DIR" 2>/dev/null; then
      echo "$$" > "$LOCK_HOLDER"
      return 0
    fi
    local holder; holder=$(cat "$LOCK_HOLDER" 2>/dev/null || true)
    if [[ -n "$holder" ]] && ! kill -0 "$holder" 2>/dev/null; then
      # holder PID dead: stale, recover
      rm -f "$LOCK_HOLDER"
      rmdir "$LOCK_MUTEX_DIR" 2>/dev/null || true
    elif [[ -z "$holder" ]]; then
      # holder missing: either acquire-window race (mkdir succeeded, echo
      # not yet written) or truly stale (process killed between lines).
      # Recover only if mutex_dir age >= 2s — past the race window.
      local mtime now age
      mtime=$(stat -f %m "$LOCK_MUTEX_DIR" 2>/dev/null \
            || stat -c %Y "$LOCK_MUTEX_DIR" 2>/dev/null \
            || echo 0)
      now=$(date +%s)
      age=$((now - mtime))
      if (( age >= 2 )); then
        rm -f "$LOCK_HOLDER"
        rmdir "$LOCK_MUTEX_DIR" 2>/dev/null || true
      fi
    fi
    sleep 0.1
  done
  echo "agent-session: mutex timeout (10s)" >&2
  return 1
}

release_mutex() {
  if [[ -f "$LOCK_HOLDER" ]] && [[ "$(cat "$LOCK_HOLDER" 2>/dev/null)" == "$$" ]]; then
    rm -f "$LOCK_HOLDER"
    rmdir "$LOCK_MUTEX_DIR" 2>/dev/null || true
  fi
}
trap release_mutex EXIT

update_lock() {
  init_lock_file
  acquire_mutex || return 1
  local rc=0 tmp
  tmp="$(mktemp "${LOCK_FILE}.XXXXXX")" || { release_mutex; return 1; }
  if jq "$@" "$LOCK_FILE" > "$tmp"; then
    mv "$tmp" "$LOCK_FILE"
  else
    rc=$?
    rm -f "$tmp"
  fi
  release_mutex
  return $rc
}

cmd_start() {
  local slug="${1:-}"
  if [[ -z "$slug" ]]; then echo "usage: agent-session.sh start <task-slug>" >&2; exit 2; fi
  local branch="${AGENT}/${slug}"
  local worktree="$WORKTREES_DIR/${AGENT}-${slug}"

  if [[ -e "$worktree" ]]; then
    echo "✗ worktree already exists: $worktree" >&2
    exit 1
  fi

  cmd_gc >/dev/null
  git -C "$REPO_ROOT" worktree prune

  if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
    worktree_add_retry "$worktree" "$branch"
  else
    worktree_add_retry -b "$branch" "$worktree"
  fi

  local entry
  entry=$(jq -n \
    --arg sid "$SESSION_ID" --arg ag "$AGENT" --argjson pid "$SESSION_PID" \
    --arg wt "$worktree" --arg br "$branch" \
    --arg ts "$(now_iso)" --arg sm "${TASK_SUMMARY:-}" \
    '{session_id:$sid, agent:$ag, pid:$pid, worktree:$wt, branch:$br, started_at:$ts, heartbeat_at:$ts, task_summary:$sm}')

  update_lock --argjson e "$entry" '.sessions += [$e]'

  echo "✓ session $SESSION_ID started"
  echo "  agent:    $AGENT"
  echo "  branch:   $branch"
  echo "  worktree: $worktree"
  echo
  echo "  cd \"$worktree\""
}

cmd_stop() {
  local target="$SESSION_ID"
  local source="AGENT_SESSION_ID"

  if [[ -z "$AGENT_SESSION_ID_ENV" ]]; then
    if cwd_session_meta; then
      target="$SESSION_ID"
      source="cwd"
    else
      echo "agent-session: no AGENT_SESSION_ID set and cwd is not under $WORKTREES_DIR; no session released"
      return 0
    fi
  fi

  update_lock --arg sid "$target" '.sessions |= map(select(.session_id != $sid))'
  echo "✓ session $target released ($source)"
  echo "  to remove worktree: git worktree remove <path>"
}

cmd_list() {
  init_lock_file
  jq -r '
    "── Active sessions ──",
    (if (.sessions | length) == 0 then "  (none)"
     else (.sessions[] | "  [\(.agent)] \(.session_id)\n    branch=\(.branch)  pid=\(.pid)\n    started=\(.started_at)  hb=\(.heartbeat_at)\n    worktree=\(.worktree)")
     end),
    "",
    "── Shared resource locks ──",
    (if (.shared_resource_locks | length) == 0 then "  (none)"
     else (.shared_resource_locks | to_entries[] | "  \(.key)  owner=\(.value.session_id)  claimed=\(.value.claimed_at)")
     end)
  ' "$LOCK_FILE"
}

cmd_gc() {
  init_lock_file
  local hb_cutoff res_cutoff
  hb_cutoff=$(iso_minus_minutes 30)
  res_cutoff=$(iso_minus_minutes 60)

  local pids; pids=$(jq -r '.sessions[].pid' "$LOCK_FILE" 2>/dev/null || true)
  local alive_pids=()
  for pid in $pids; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then alive_pids+=("$pid"); fi
  done
  local alive_json="[]"
  if (( ${#alive_pids[@]} > 0 )); then
    alive_json=$(printf '%s\n' "${alive_pids[@]}" | jq -Rsc 'split("\n")|map(select(length>0)|tonumber)')
  fi

  # GC layers (run in order):
  #   1. PID dead OR heartbeat > 30min OR resource lock > 60min — jq pass below
  #   2. worktree directory missing — session_store.py gc (B1 plan)
  update_lock --argjson alive "$alive_json" --arg hb "$hb_cutoff" --arg rc "$res_cutoff" '
    .sessions |= map(select(
      .heartbeat_at >= $hb
      and (.pid == 0 or (.pid as $p | $alive | index($p) != null))
    ))
    | .shared_resource_locks |= with_entries(select(.value.claimed_at >= $rc))
  '

  # Layer 2 — worktree existence check (silent, best-effort).
  run_store gc >/dev/null 2>&1 || true
}

cmd_claim() {
  local resource="${1:-}"
  if [[ -z "$resource" ]]; then echo "usage: agent-session.sh claim <resource>" >&2; exit 2; fi
  init_lock_file
  cmd_gc >/dev/null

  local owner
  owner=$(jq -r --arg r "$resource" '.shared_resource_locks[$r].session_id // empty' "$LOCK_FILE")
  if [[ -n "$owner" && "$owner" != "$SESSION_ID" ]]; then
    echo "✗ resource '$resource' already claimed:" >&2
    jq -r --arg r "$resource" '.shared_resource_locks[$r] | "  owner=\(.session_id)  claimed=\(.claimed_at)"' "$LOCK_FILE" >&2
    exit 1
  fi
  update_lock --arg sid "$SESSION_ID" --arg r "$resource" --arg ts "$(now_iso)" \
    '.shared_resource_locks[$r] = {session_id:$sid, claimed_at:$ts}'
  echo "✓ claimed '$resource' for $SESSION_ID"
}

cmd_release() {
  local resource="${1:-}"
  if [[ -z "$resource" ]]; then echo "usage: agent-session.sh release <resource>" >&2; exit 2; fi
  update_lock --arg r "$resource" 'del(.shared_resource_locks[$r])'
  echo "✓ released '$resource'"
}

cmd_who_claims() {
  local resource="${1:-}"
  if [[ -z "$resource" ]]; then echo "usage: agent-session.sh who-claims <resource>" >&2; exit 2; fi
  init_lock_file
  jq -r --arg r "$resource" '
    .shared_resource_locks[$r] as $v
    | if $v == null then "(none)"
      else "owner_session=\($v.session_id)  claimed_at=\($v.claimed_at)"
      end
  ' "$LOCK_FILE"
}

cmd_heartbeat() {
  update_lock --arg sid "$SESSION_ID" --arg ts "$(now_iso)" \
    '.sessions |= map(if .session_id == $sid then .heartbeat_at = $ts else . end)'
}

# Derive AGENT / SLUG / SESSION_ID / WORKTREE from cwd if inside the
# canonical .worktrees/<agent>-<slug>/ directory. Nested .worktrees are ignored.
# Sets globals on success; returns 1 if cwd is not a known worktree.
cwd_session_meta() {
  local cwd rel wt_name wt
  cwd="$(pwd -P)"
  case "$cwd" in
    "$WORKTREES_DIR"/*) ;;
    *) return 1 ;;
  esac
  rel="${cwd#"$WORKTREES_DIR"/}"
  wt_name="${rel%%/*}"
  wt="$WORKTREES_DIR/$wt_name"
  [[ -d "$wt" ]] || return 1
  if [[ "$wt_name" =~ ^(claude|codex|gemini)-(.+)$ ]]; then
    AGENT="${BASH_REMATCH[1]}"
    SLUG="${BASH_REMATCH[2]}"
    SESSION_ID="${AGENT}-wt-${SLUG}"
    WORKTREE="$wt"
    return 0
  fi
  return 1
}

# Set globals AGENT/SESSION_ID/WORKTREE for a main-tree session. Returns 0 if
# cwd is the canonical repo root (visibility-only fallback for R1.1 read-only
# shared-tree work). Otherwise 1. Stable session_id derived from the claude
# binary PID so SessionStart/Heartbeat/Stop hooks converge on one entry.
cwd_main_meta() {
  local cwd; cwd="$(pwd -P)"
  [[ "$cwd" == "$REPO_ROOT" ]] || return 1
  AGENT="${AGENT:-claude}"
  WORKTREE="$REPO_ROOT"
  local cpid; cpid="$(claude_pid_walk 2>/dev/null || true)"
  [[ -z "$cpid" ]] && cpid="$$"
  SESSION_ID="${AGENT_SESSION_ID_ENV:-${AGENT}-main-${cpid}}"
  SLUG="main"
  return 0
}

cmd_register_cwd() {
  local cwd_type="worktree"
  if cwd_session_meta; then
    cwd_type="worktree"
  elif cwd_main_meta; then
    cwd_type="main"
  else
    return 0
  fi
  init_lock_file
  local existing
  existing=$(jq -r --arg sid "$SESSION_ID" '.sessions[]? | select(.session_id == $sid) | .session_id' "$LOCK_FILE" 2>/dev/null || true)
  local branch
  branch=$(git -C "$WORKTREE" branch --show-current 2>/dev/null || echo "${AGENT}/${SLUG}")
  local ts; ts="$(now_iso)"
  local pid_val=0
  if [[ "$cwd_type" == "main" ]]; then
    pid_val="$(claude_pid_walk 2>/dev/null || echo 0)"
  fi
  if [[ -n "$existing" ]]; then
    update_lock --arg sid "$SESSION_ID" --arg ts "$ts" \
      '.sessions |= map(if .session_id == $sid then .heartbeat_at = $ts else . end)'
  else
    local entry
    entry=$(jq -n \
      --arg sid "$SESSION_ID" --arg ag "$AGENT" --argjson pid "$pid_val" \
      --arg wt "$WORKTREE" --arg br "$branch" --arg ts "$ts" \
      --arg ct "$cwd_type" --arg sm "${TASK_SUMMARY:-hook-managed}" \
      '{session_id:$sid, agent:$ag, pid:$pid, worktree:$wt, branch:$br, started_at:$ts, heartbeat_at:$ts, cwd_type:$ct, task_summary:$sm}')
    update_lock --argjson e "$entry" '.sessions += [$e]'
  fi
}

cmd_heartbeat_cwd() {
  if ! cwd_session_meta && ! cwd_main_meta; then return 0; fi
  update_lock --arg sid "$SESSION_ID" --arg ts "$(now_iso)" \
    '.sessions |= map(if .session_id == $sid then .heartbeat_at = $ts else . end)'
}

cmd_stop_cwd() {
  if ! cwd_session_meta && ! cwd_main_meta; then return 0; fi
  update_lock --arg sid "$SESSION_ID" '.sessions |= map(select(.session_id != $sid))'
}

# T1-A: record file edit in current session's files[] for R4.1 file mutex.
# Idempotent: updates last_edit if path already present, else appends.
# Resolves SESSION_ID from cwd worktree if available (matches r4-file-mutex-check.sh).
cmd_touch() {
  local path="${1:-}"
  if [[ -z "$path" ]]; then echo "usage: agent-session.sh touch <repo-relative-path>" >&2; exit 2; fi
  init_lock_file

  # Prefer cwd-derived session_id (consistent across hook invocations)
  if cwd_session_meta 2>/dev/null; then
    : # SESSION_ID set by cwd_session_meta
  fi

  local ts; ts="$(now_iso)"
  update_lock --arg sid "$SESSION_ID" --arg p "$path" --arg ts "$ts" '
    .sessions |= map(
      if .session_id == $sid then
        .files = (.files // []) |
        if (.files | map(.path) | index($p)) != null then
          .files |= map(if .path == $p then .last_edit = $ts else . end)
        else
          .files += [{path: $p, first_seen: $ts, last_edit: $ts}]
        end
      else . end
    )
  '
}

usage() {
  cat <<'USAGE' >&2
agent-session.sh — multi-agent session coordinator

USAGE:
  AGENT=claude|codex|gemini agent-session.sh <command> [args]

COMMANDS:
  start <task-slug>      create worktree + register lock entry
  stop                   release lock entry (worktree removal manual)
  list                   show active sessions + shared resource locks
  gc                     garbage-collect stale entries (dead PID, hb > 30min,
                         missing worktree dir)
  claim <resource>       acquire mutex for shared resource (e.g. production-db)
  release <resource>     release mutex
  who-claims <resource>  show current owner of a resource (read-only)
  heartbeat              update heartbeat_at for current session
  register-cwd           hook helper: upsert lock entry from cwd worktree (pid=0)
  heartbeat-cwd          hook helper: heartbeat using cwd-derived session_id
  stop-cwd               hook helper: release lock entry from cwd worktree
  touch <path>           record file edit in this session's files[] (R4.1 file mutex)

  --- Tier 2 (cross-session work feed) ---
  broadcast <event> <message> [--to <sid>] [--files f1,f2] [--rationale <msg>]
                         append typed event to work-feed.jsonl
                         events: started/intent/decision/committed/pr_opened/blocked/handoff/done
  dashboard [--format=summary|json]
                         show active sessions + shared locks + recent feed.
                         summary (default) = 5-line text; json = full payload
  peek <session_id> [n]  show one session entry + its recent events (default n=20)
  update --task-state <pending|in_progress|blocked|reviewing|completed>
         [--current-intent <s>] [--last-summary <s>]
                         patch self session entry (Tier 2 fields)
  tail-feed [n] [--session <sid>]
                         tail recent feed events (default n=20)
  subscribe              list .claude/subscribers/<name>.{py,sh}; run one in bg

ENV:
  AGENT             default 'claude'. Set to 'codex' or 'gemini' otherwise.
  AGENT_SESSION_ID  override generated session id.
  AGENT_SESSION_PID long-lived owner pid for GC; default 0 means heartbeat-only.
  TASK_SUMMARY      optional 1-line description for `start`.

FILES:
  .claude/locks/active-sessions.json   lock state (gitignored)
  .worktrees/<agent>-<slug>/           worktree per session

REQUIRES: jq, git, flock
RULE:     .claude/rules/multi-agent-worktree.md
USAGE
}

# --- Tier 2 commands (delegate to session_store.py for typed schema + jsonl) ---

# Resolve self session_id: prefer cwd-derived (claude-wt-<slug>); fall back to
# AGENT_SESSION_ID env; then cwd_main_meta (R11.1 main-tree visibility — same
# id used by register-cwd so broadcast events bind to the registered entry);
# else error. Lock file is the central one.
resolve_self_session_id() {
  if cwd_session_meta 2>/dev/null; then
    echo "$SESSION_ID"
    return 0
  fi
  if [[ -n "${AGENT_SESSION_ID:-}" ]]; then
    echo "$AGENT_SESSION_ID"
    return 0
  fi
  if cwd_main_meta 2>/dev/null; then
    echo "$SESSION_ID"
    return 0
  fi
  return 1
}

run_store() {
  # session_store.py lives next to this script (handles worktree base where the
  # canonical root has not yet merged the same file). Falls back to repo root.
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  local store="$script_dir/session_store.py"
  [[ -f "$store" ]] || store="$REPO_ROOT/scripts/infra/session_store.py"
  python3 "$store" "$@"
}

cmd_broadcast() {
  local event="${1:-}" msg="${2:-}"
  if [[ -z "$event" || -z "$msg" ]]; then
    echo "broadcast: usage: broadcast <event> <message> [--to <sid>] [--files f1,f2] [--rationale <msg>]" >&2
    return 2
  fi
  shift 2
  local sid
  if ! sid="$(resolve_self_session_id)"; then
    echo "broadcast: cannot resolve self session_id (cwd not a worktree, AGENT_SESSION_ID unset)" >&2
    return 2
  fi
  run_store broadcast "$event" "$msg" --session-id "$sid" "$@"
}

cmd_dashboard() {
  # B3 plan — default --format=summary (5-line text, token-slim).
  # --format=json recovers full JSON (back-compat for advanced callers).
  local fmt="summary"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --format=*) fmt="${1#--format=}"; shift ;;
      --format)   fmt="${2:-summary}"; shift 2 ;;
      *) shift ;;
    esac
  done
  case "$fmt" in
    summary|json) ;;
    *) echo "dashboard: --format must be summary|json (got '$fmt')" >&2; return 2 ;;
  esac
  run_store dashboard --format "$fmt"
}

cmd_peek() {
  local sid="${1:-}" n="${2:-20}"
  if [[ -z "$sid" ]]; then
    echo "peek: usage: peek <session_id> [n]" >&2
    return 2
  fi
  run_store peek "$sid" --n "$n"
}

cmd_update() {
  local sid
  if ! sid="$(resolve_self_session_id)"; then
    echo "update: cannot resolve self session_id" >&2
    return 2
  fi
  run_store update "$sid" "$@"
}

cmd_tail_feed() {
  local n=20 sid=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session) sid="$2"; shift 2 ;;
      --n) n="$2"; shift 2 ;;
      *) n="$1"; shift ;;
    esac
  done
  if [[ -n "$sid" ]]; then
    run_store tail-feed --n "$n" --session-id "$sid"
  else
    run_store tail-feed --n "$n"
  fi
}

cmd_subscribe() {
  local sub_dir="$REPO_ROOT/.claude/subscribers"
  if [[ ! -d "$sub_dir" ]]; then
    echo "(no subscribers; create $sub_dir/<name>.{py,sh} to add daemons)" >&2
    return 0
  fi
  local target="${1:-}"
  if [[ -z "$target" ]]; then
    echo "available subscribers:" >&2
    find "$sub_dir" -maxdepth 1 -type f \( -name '*.py' -o -name '*.sh' \) -exec basename {} \; | sort
    return 0
  fi
  local script="$sub_dir/$target"
  [[ -f "$script" ]] || script="$sub_dir/$target.py"
  [[ -f "$script" ]] || script="$sub_dir/$target.sh"
  if [[ ! -f "$script" ]]; then
    echo "subscribe: unknown subscriber: $target" >&2
    return 2
  fi
  case "$script" in
    *.py) nohup python3 "$script" >/dev/null 2>&1 & ;;
    *.sh) nohup bash "$script" >/dev/null 2>&1 & ;;
  esac
  echo "subscribe: launched $target (pid=$!)"
}

case "${1:-}" in
  start)         shift; cmd_start "$@" ;;
  stop)          shift; cmd_stop "$@" ;;
  list)          shift; cmd_list "$@" ;;
  gc)            shift; cmd_gc "$@" ;;
  claim)         shift; cmd_claim "$@" ;;
  release)       shift; cmd_release "$@" ;;
  who-claims)    shift; cmd_who_claims "$@" ;;
  heartbeat)     shift; cmd_heartbeat "$@" ;;
  register-cwd)  shift; cmd_register_cwd "$@" ;;
  heartbeat-cwd) shift; cmd_heartbeat_cwd "$@" ;;
  stop-cwd)      shift; cmd_stop_cwd "$@" ;;
  touch)         shift; cmd_touch "$@" ;;
  broadcast)     shift; cmd_broadcast "$@" ;;
  dashboard)     shift; cmd_dashboard "$@" ;;
  peek)          shift; cmd_peek "$@" ;;
  update)        shift; cmd_update "$@" ;;
  tail-feed)     shift; cmd_tail_feed "$@" ;;
  subscribe)     shift; cmd_subscribe "$@" ;;
  -h|--help|help|"") usage; exit 0 ;;
  *) echo "unknown command: $1" >&2; usage; exit 2 ;;
esac
