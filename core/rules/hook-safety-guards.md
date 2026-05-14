# Hook Safety Guards

Default hook posture:

- Bash guard blocks broad deletion, protected-branch force push, `git reset --hard`, table drops, and secret reads.
- R4 mutex guard warns or blocks production resource conflicts.
- Supervisor guard is advisory by default and strict only when configured.
- TDD guard is dry-run by default and block only when configured.
- Logging hooks must be best effort and must not expose secret values.

Local-only files remain ignored:

```text
.claude/logs/
.claude/locks/
.claude/settings.local.json
.agent-harness/state/
secrets/
.env
.env.*
```
