-- supervisor_goals — goal state machine schema
-- See: docs/concepts/multi-session-worktree.md, core/infra/supervisor-goal.sh

CREATE TABLE IF NOT EXISTS supervisor_goals (
    goal_id TEXT PRIMARY KEY NOT NULL,
    plan_slug TEXT NOT NULL UNIQUE,
    objective TEXT NOT NULL,
    status TEXT NOT NULL CHECK(status IN (
        'active',
        'paused',
        'budget_limited',
        'complete',
        'aborted'
    )),
    token_budget INTEGER,
    tokens_used INTEGER NOT NULL DEFAULT 0,
    time_used_seconds INTEGER NOT NULL DEFAULT 0,
    current_wave INTEGER NOT NULL DEFAULT 1,
    total_waves INTEGER NOT NULL,
    waves_completed TEXT NOT NULL DEFAULT '[]',
    safeguard_aborts TEXT NOT NULL DEFAULT '[]',
    created_at_ms INTEGER NOT NULL,
    updated_at_ms INTEGER NOT NULL,
    last_heartbeat_ms INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_goal_status    ON supervisor_goals(status);
CREATE INDEX IF NOT EXISTS idx_goal_heartbeat ON supervisor_goals(last_heartbeat_ms);
CREATE INDEX IF NOT EXISTS idx_goal_slug      ON supervisor_goals(plan_slug);
