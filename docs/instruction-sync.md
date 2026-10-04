# Shared instructions without shared runtime assumptions

`rules/policy/operating-contract.md` owns the common behavioral policy. The updater
copies its text into a bounded managed block in Claude's user CLAUDE.md and Codex's
user AGENTS.md. Runtime/personal text outside the block stays byte-for-byte intact.
It does not merge JSON/TOML settings or install hooks, permissions, MCPs, or plugins.

```bash
bash setup.sh --instructions-only --dry-run # read-only; 1 means drift, 0 means current
bash setup.sh --instructions-only           # backup changed files, then sync
```

Targets can be overridden with `CLAUDE_GLOBAL_INSTRUCTIONS` and
`CODEX_GLOBAL_AGENTS`; default Codex home also respects `CODEX_HOME`.
The direct Python command accepts `--claude PATH`, `--codex PATH`, and `--check`.
Supplying only one target updates only that runtime. Malformed managed markers
and symlinks fail before any target is changed. Backups use unique names beside
each changed file; repeated application is a no-op. Restore a backup to undo it.
An I/O failure during a multi-file write may leave one target updated; rerun after
fixing the failure or restore that target's backup.

Full `setup.sh --claude` / `--codex` also installs the shared block. These legacy
full-install modes can replace configuration files after confirmation; use the
instructions-only path when maintaining an existing personal setup.

## Ownership and coverage

- Keep machine paths, historical transcripts and audit backups outside the public repo.
- For a workspace, use AGENTS.md for common guidance and a local `@AGENTS.md` import
  in CLAUDE.md when needed by the host. Do not copy histories into live instructions.
- Claude resolves imports relative to the importing file. Codex discovers global and
  project instruction chains; it does not implement Claude's `@` import syntax.
- Codex normally starts project discovery at the Git root. Workspace guidance above
  that root needs an explicit personal instruction to read it, or project integration.
- Hooks require native registration. Shell-wrapper tests only prove that wrapper's
  path; they do not prove interception of native tools or a live session.
- Retain platform-specific routing and features in their owning runtime. Do not add
  model IDs, approval bypasses or blanket plugin migrations to the common block.

## Verification

```bash
python3 core/tests/sync-instructions-test.py
bash core/tests/instruction-setup-test.sh
bash core/tests/sanitize-audit.sh
```

After applying, inspect the managed blocks and restart sessions. Confirm loaded
instruction sources in Claude `/context` and Codex's instruction summary. Do not
report live session loading as verified from a file comparison alone.

References (checked 2026-09-26):
- https://learn.chatgpt.com/docs/agent-configuration/agents-md
- https://learn.chatgpt.com/docs/config-file/config-reference
- https://code.claude.com/docs/en/memory
