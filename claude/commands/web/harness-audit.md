# Harness Audit Command

Run the AirLens common harness audit from the repository root.

## Usage

`/harness-audit [repo|hooks|skills|commands|agents] [--format text|json]`

## Source Of Truth

Use the repo-local deterministic script:

```bash
node scripts/harness-audit.js repo --format text --root "/workspace/internal-platform"
```

For JSON output:

```bash
node scripts/harness-audit.js repo --format json --root "/workspace/internal-platform"
```

## Rules

- Do not rescore manually.
- Report failed checks and top actions from script output.
- Treat Claude and Codex as separate runtimes with shared Obsidian and shared scripts.
- Use `Obsidian-airlens/wiki/concepts/claude-codex-collaboration-harness.md` for the collaboration model.

## Arguments

`$ARGUMENTS`
