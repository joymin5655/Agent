# Contributing

Thanks for considering a contribution — this project is a safety harness, so
the bar it sets for itself applies to every PR: machine-verified, honest docs,
no self-approval.

## Quick path

1. **Read** [`docs/getting-started.md`](docs/getting-started.md) (5-minute
   install) and [`rules/contributing.md`](rules/contributing.md) (code style,
   commit conventions, PR discipline).
2. **Branch** from `main` (`feat/…`, `fix/…`, `chore/…`). No force-push to
   `main`, no `--no-verify` — see [`rules/public-repo.md`](rules/public-repo.md).
3. **Verify locally** before opening a PR — the same battery CI runs:

   ```bash
   bash core/tests/verify-all.sh          # every gate + battery + evals
   bash core/tests/verify-all.sh --shard 1/4   # one quarter of it (CI runs 4 shards in parallel)
   bash setup.sh --doctor                 # environment / wiring diagnosis
   ```

   A clean local run needs `gitleaks`, `jq` and `sqlite3` on your PATH (and a Python whose
   `sqlite3` has FTS5): the checks pinned in `core/tests/verify-all-must-run.txt` fail instead
   of skipping when a tool is missing. CI excuses only the two gitleaks checks.

4. **Open a PR** — the template asks for a test plan. CI must be green
   (8 jobs: secret scan, plugin validation, sanitize, supply-chain,
   doc-reality, evals, verify-all, clean-install).

## Ground rules worth knowing up front

- **Docs are not allowed to lie** — `core/tests/doc-reality.sh` fails the
  build if a doc names a file that doesn't exist or a declared count drifts.
- **Domain neutrality + PII** — `core/tests/sanitize-audit.sh` blocks
  prior-project taint and machine-identity PII (real home paths, device
  hostnames). Use placeholder spellings (`$HOME/…`, `/Users/<name>`,
  `example-host`) in docs and fixtures.
- **New hooks must keep cross-AI parity** — one canonical protocol, three
  adapters; `core/tests/adapter-parity.sh` must stay green. See
  [`docs/hook-protocol.md`](docs/hook-protocol.md).
- **Tests ship with behavior** — a new gate or guard lands with a paired
  RED-mutation test (see existing `core/tests/*-test.sh` for the convention).

## Not sure where to start?

Open an issue first — bug reports and feature requests both have templates.
Small, well-scoped PRs merge fastest.
