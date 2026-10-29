# Goal spec — the start gate for `--goal-mode`

A goal-mode run is resumable, budgeted and can run for hours, so it must begin from a goal that
can be checked, not from a direction. Write the spec to `.agent/plans/<slug>/goal.json`, make
`goal-spec-check.py` pass, then start with `supervisor-goal.sh init ... --spec <file>`.

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/core/infra/goal-spec-check.py" .agent/plans/<slug>/goal.json
bash "${CLAUDE_PLUGIN_ROOT}/core/infra/supervisor-goal.sh" init <slug> <N> [<budget>] "<objective>" \
  --spec .agent/plans/<slug>/goal.json
```

Exit 2 from either one means the goal is not started; the stderr line names the field.

## Fields

| Field | Type | What it must say |
|---|---|---|
| `outcome` | string | One sentence stating what is true when the goal is done. Not an activity. |
| `verify` | list of strings | One or more commands a stranger can run to see the outcome. Each must pass the deny list (`completion-verify.py --check-command`). |
| `threshold` | string | What result of `verify` counts as done: a true/false condition, or a number with its unit and how many runs. |
| `scope_in` | list of strings | Paths or areas the run may change. |
| `scope_out` | list of strings | Paths or areas it must not touch. |
| `stop_when` | list of strings | Situations where the run stops and asks a person instead of deciding. |
| `budget` | object, optional | `waves` and/or `tokens`, positive integers. Set it only when the user gave a limit; leave it out otherwise. |

## What the check does with it

- A missing, empty or mistyped field is refused and named.
- `outcome` is refused when it opens with an activity (keep, continue, work on, improve,
  investigate, research, explore, make progress, ...) and states no end state.
- `threshold` is refused when it holds no digit and none of pass / fail / true / false / zero /
  none / all / every / no / exit.
- Each `verify` command is run through the same deny list the completion gate uses; a refused
  command is never run.
- One `verify` entry is one command, run as written; an entry with a newline or NUL is refused.
- A `verify` entry may not contain `$(` or a backtick: the audit never runs command substitution,
  so the check refuses it (write the comparison in a helper script instead of `test "$(cat f)" = ok`).
- With `--spec`, `<slug>` must match `[A-Za-z0-9][A-Za-z0-9._-]*` (`init` exits 2 otherwise), and the
  spec copy always lives at `<plans>/<slug>/goal.json` — also when the plan is a flat `<slug>.md`.
- `init --spec` stores the spec in the goal state. The audit of the goal's last wave runs the
  stored `verify` commands next to the checks it reads from the plan, so the end state is checked
  by the same record that gates `advance-wave`. If `goal.json` in the plan dir was changed or
  deleted since `init`, or a stored check is missing or malformed — or the stored spec itself is gone
  or the state db cannot be read — that audit fails (`init --spec` marks the goal). A goal started
  without `--spec` only warns.

## Limits

The check reads the shape of the words, not their meaning. A spec can pass and still describe
a weak goal (a `verify` that cannot fail, a `threshold` that is always met, a scope that is far
too wide). It also cannot tell whether the commands actually test the outcome. Read the spec
before starting; the gate only stops the cases that are plainly not goals.

## Weak and strong

Weak — refused:

```json
{ "outcome": "Keep improving the importer",
  "verify": ["bash core/tests/importer-test.sh"],
  "threshold": "looks better" }
```

It names an activity, and nothing says when it stops.

Strong:

```json
{
  "outcome": "Importing the 1000-row fixture takes under 2 s and importer-test.sh exits 0",
  "verify": ["bash core/tests/importer-test.sh", "bash core/tests/importer-bench.sh"],
  "threshold": "both exit 0, and the bench prints a time under 2 s on 3 consecutive runs",
  "scope_in": ["core/infra/importer.sh", "core/tests/importer-test.sh"],
  "scope_out": ["core/hooks/", "release and version files"],
  "stop_when": ["the speed-up needs a change to a hook or a risk-area file",
                "a check fails 3 times in a row after different fixes"],
  "budget": { "waves": 4 }
}
```

When the user's request is only an activity ("keep working on X"), turn it into an outcome with
them before writing the spec; do not invent a threshold for them.
