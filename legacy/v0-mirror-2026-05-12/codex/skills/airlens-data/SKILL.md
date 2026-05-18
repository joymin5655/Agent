---
name: airlens-data
description: AirLens data, air-quality analysis, and Supabase/PostgreSQL guidance. Use for ETL pipelines, atmospheric datasets, AQI/interpolation work, feature engineering, schema design, migrations, RLS, indexing, or database review.
---

# AirLens Data

Use this skill when work touches AirLens data pipelines, air-quality analysis, model input/output datasets, Supabase schemas, SQL migrations, RLS, or database performance.

## Current Data Policy

- Active sources are the only inputs for live snapshots.
- WAQI and OpenAQ are `historical_frozen` sources. Do not add or restore live WAQI/OpenAQ ingest for active snapshots.
- Research, backtesting, and historical analysis may use frozen WAQI/OpenAQ only when the dataset version and source status are explicit.
- Preserve provenance, dataset versions, timestamps, units, and source status in generated artifacts.

## Core Data Sources

- Active live/snapshot sources: Open-Meteo AQ, AirKorea, EEA where currently wired as active, Supabase Storage snapshots, static JSON fallbacks.
- Research or batch sources: MAIAC AOD NetCDF, ERA5 NetCDF, FIRMS CSV, EDGAR NetCDF, Sentinel-5P, CAMS, NASA SEDAC, PurpleAir, Google AQ when explicitly scoped.
- Data serving pattern: scheduled fetch -> Supabase Storage `aq-data/` -> `public/data/weather/current/` fallback -> client via `airQualityGrid.ts` / data-proxy style access.

## Pipeline Rules

- Make pipelines idempotent and partially re-runnable.
- Add data quality checks for null ratios, range limits, duplicates, temporal gaps, and spatial coverage.
- Keep all timestamps in UTC and coordinates in WGS84 (`EPSG:4326`).
- Use `xarray` for NetCDF and Parquet for large intermediate data. Do not copy the whole `Data/` directory.
- Prefer static JSON or cached views for UI hot paths.
- Client code must not call external data APIs directly; route through existing API or Edge Function patterns.

## Air-Quality Analysis

- State pollutant units and AQI scale every time: US EPA AQI, WHO guideline comparison, or Korean CAI are not interchangeable.
- PM2.5/PM10 are normally `ug/m3`; do not mix with ppm gas units.
- For interpolation, use IDW or a justified geostatistical method and report validation such as LOO-CV/R2 when practical.
- Do not infer area-wide conditions from station points without interpolation or spatial uncertainty.
- Do not claim long-term trends from a single snapshot.
- For Globe V2 overlays, match the project `OverlayGridData` contract and include p10/p50/p90 or quality metadata for estimates.

## Database Architecture

- New Supabase tables need schema, keys, indexes, RLS policies, and migration/rollback strategy together.
- Use `auth.uid()` for user-owned RLS, `gen_random_uuid()` for UUID primary keys, and `timestamptz DEFAULT now()` for timestamps.
- Index foreign keys, policy filters, hot join keys, time columns, and common composite filters.
- Large time-series tables should use partitioning, snapshot tables, retention, or an equivalent scaling strategy.
- Edge Functions may use `SERVICE_ROLE_KEY`; client code must use anon access and respect RLS.

## Database Review Checklist

Review SQL, migrations, or schema changes in this order:

1. Schema shape, data types, constraints, and foreign keys.
2. Indexes against actual `WHERE`, `JOIN`, ordering, and RLS policy patterns.
3. RLS and privilege boundaries, including public reads and service-role writes.
4. Query risks: `SELECT *`, unbounded scans, N+1 paths, missing pagination.
5. Migration safety: idempotency, backfill cost, locking, data-loss risk, rollback path.
6. Client-facing views or RPCs for hidden-column leaks and security-definer `search_path`.

Report concrete risks first, especially data loss, RLS bypasses, missing hot-path indexes, or migrations unsafe for production.
