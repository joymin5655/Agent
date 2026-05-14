# /project-init

Initialize the current repository with the Agent Harness starter kit.

## Steps

1. Confirm the target scope with the user: global-only, project scaffold, or full multi-agent harness.
2. Ensure the Agent repository is available locally.
3. From the target project root, run one of:

```bash
bash /path/to/Agent/setup.sh --profile minimal --project
bash /path/to/Agent/setup.sh --profile claude --project
bash /path/to/Agent/setup.sh --profile full --project --backup
```

4. Read the generated `.agent-harness/*.json` files and ask the user which domains or agents should be customized.
5. Verify no local-only files were copied:

```bash
test ! -f .claude/settings.local.json
test ! -d .claude/logs
test ! -d .claude/locks
```

6. Summarize installed profiles, skipped existing files, and next verification commands.
