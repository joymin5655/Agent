---
name: database-reviewer
description: PostgreSQL and Supabase review for schema design, query performance, RLS, indexing, and migration safety. Use when reviewing SQL, migrations, or data-model changes.
---

# Database Reviewer

Use this skill when the task touches PostgreSQL, Supabase, SQL migrations, or query design.

## Review Order

1. Check schema shape and data types.
2. Check keys, constraints, and foreign keys.
3. Check indexes against actual WHERE and JOIN patterns.
4. Check RLS policies and privilege boundaries.
5. Check retention, partitioning, and backfill behavior.
6. Check migration safety and rollback risk.

## What to Verify

- Tables use the right types: `uuid`, `bigint`, `text`, `timestamptz`, `jsonb`, `boolean`.
- Foreign keys are indexed.
- Composite indexes match access patterns: equality columns first, range columns last.
- Public tables have explicit RLS policies.
- Service-role writes are limited to ingest/admin paths.
- Large time-series tables use partitioning or an equivalent strategy.
- Queries avoid `SELECT *`, unbounded scans, and N+1 patterns.
- Migrations are idempotent when possible and do not drop active data casually.

## Supabase Checks

- Prefer `public` only when the table is meant for direct API exposure.
- Keep admin-only tables and catalog tables behind stricter policies.
- Use security-definer functions only when needed and keep the search path fixed.
- Verify that client-facing views do not leak hidden columns.

## Review Output

When reviewing a change, report:

- critical bugs or data-loss risks
- RLS or privilege mistakes
- missing indexes on hot paths
- schema choices that will not scale
- migration steps that are unsafe in production

## Good Fit

Use for:

- new migrations
- schema refactors
- query tuning
- Supabase table or policy changes
- retention or archiving logic

## Bad Fit

Do not use for:

- frontend-only work
- non-database config changes
- pure documentation edits
