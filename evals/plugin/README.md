# Official plugin eval suite (`claude plugin eval`)

Routing evals for the five core skills (`spec`, `supervise`, `verify-completion`,
`council-review`, `wrap`) in the format read by Claude Code's built-in
`claude plugin eval` (requires v2.1.269+). It is separate from the repo's own
`evals/run-evals.py` datasets, which it does not touch.

Each skill has at least one "fires" case (a prompt where the skill should be invoked,
including Korean phrasing) and one "stays quiet" case (a plausible neighbor that
should not invoke it).

## Run

```bash
# from the repo root; costs model calls (about $3 and ~3 minutes for the full suite)
claude plugin eval . --eval-dir evals/plugin --trust-plugin --no-publish \
  -j 4 --model sonnet --max-cost-usd 15 --json /tmp/plugin-eval.json
```

- Default ablation is `with-without`: every case also runs with no plugin loaded.
- Do not pass `--allow-tools` or `--allow-real-servers`. No case is granted Bash, Write, or
  Edit (`allowed_tools: [Read, Glob, Grep, Skill]`), so nothing can commit, push, or call a
  paid worker lane. Each run starts in an empty sandbox workspace.
- Not wired into CI (it costs model calls). Run it manually or weekly, and after editing a
  skill's `description` / `when_to_use`.
- Results land in `evals/plugin/results/` (git-ignored).

## Cases

Every case has an `llm` grader (`behavior`, haiku judge) or a `regex` grader on the final
reply, plus a `tool_used: Skill` grader.

| Case | Prompt (gist) | Skill grader | Behavior grader |
|---|---|---|---|
| `spec-fires` | notification settings feature, "스펙이랑 플랜부터" | must invoke `spec` | llm: plans first |
| `spec-quiet` | explain `add(a, b)` | must NOT invoke `spec` | regex: no spec.md/plan.md talk |
| `supervise-fires` | "플랜 ... 승인됐어. /supervise ... 웨이브 돌려줘" | must invoke `supervise` | llm: tries to run the plan |
| `supervise-quiet` | how to fix a one-word README typo | must NOT invoke `supervise` | regex: no waves/dispatch |
| `verify-completion-fires` | "진짜 끝났는지 검증해줘" about a reported refactor | must invoke `verify-completion` | llm: checks or refuses to confirm |
| `verify-completion-quiet` | conceptual "tests passed" question | must NOT invoke | regex: no verdict |
| `council-review-fires` | "교차 리뷰해줘. codex랑 gemini 의견도" | must invoke `council-review` | llm: starts council or reports blocker |
| `council-review-quiet` | polish a one-line commit message | must NOT invoke | regex: no codex/gemini/council |
| `wrap-fires` | "커밋하고 푸쉬해줘" | must invoke `wrap` | llm: no fake completion claim |
| `wrap-fires-ship-it` | "wrap up 해서 PR 열어줘. ship this." | must invoke `wrap` | llm: same |
| `wrap-quiet` | what `git commit` / `git push` mean | must NOT invoke `wrap` | regex: no "committed/pushed" claim |

Notes on grading:

- `tool_used: Skill` graders in "fires" cases are with-only: under ablation they are a
  plugin-fired indicator and are not part of the score (without the plugin the skill cannot
  exist). Read them from the report or JSON (`arms.with[].graders`).
- "Quiet" cases set `arm: both`, `min: 0`, `max: 0`, so a wrong invocation lowers the score.
- Behavior graders are loose by design: the sandbox is empty, so a correct reply often
  reports a blocker (no diff, no plan, no Bash). That counts as a pass.

## Baseline (2026-10-20, v2.1.304, `--model sonnet`, 3 runs per arm)

Skill invocations out of 3 runs. "Fires" cases should be 3 with the plugin; "quiet" cases 0.

| Case | With plugin | Without plugin | Behavior pass (with / without) |
|---|---|---|---|
| `spec-fires` | 3/3 | 0/3 | 3/3 / 3/3 |
| `spec-quiet` | 0/3 | 0/3 | 3/3 / 3/3 |
| `supervise-fires` | 3/3 | 0/3 | 3/3 / 3/3 |
| `supervise-quiet` | 0/3 | 0/3 | 3/3 / 3/3 |
| `verify-completion-fires` | 3/3 | 0/3 | 3/3 / 3/3 |
| `verify-completion-quiet` | 0/3 | 0/3 | 3/3 / 3/3 |
| `council-review-fires` | 3/3 | 0/3 | 3/3 / 3/3 |
| `council-review-quiet` | 0/3 | 0/3 | 3/3 / 3/3 |
| `wrap-fires` ("커밋하고 푸쉬해줘") | **0/3** | 0/3 | 3/3 / 3/3 |
| `wrap-fires-ship-it` | 3/3 | 0/3 | 3/3 / 3/3 |
| `wrap-quiet` | 0/3 | 0/3 | 3/3 / 3/3 |

Suite result: 11/11 cases pass, mean Δ 0.00 (the scored graders pass in both arms), one run
$2.96 and 159 s.

Finding: the bare Korean "커밋하고 푸쉬해줘" does not invoke `wrap` from the plugin alone (0/3).
The skill's `description` / `when_to_use` only carry English triggers ("wrap up", "ship this");
the Korean routing today lives in the user's global CLAUDE.md, which the isolated eval session
does not load. Because the fires grader is with-only, the case still shows as passing; the
indicator is the signal. A Korean trigger in `skills/wrap/SKILL.md` would be the fix, tracked
separately from this suite.

## Limits

- Routing only. No case runs a skill to completion (no Bash, empty workspace), so the skills'
  real behavior is covered by the other evals and `core/tests/`.
- Scored graders are weak by design: Δ is about 0 because Claude answers these small prompts
  acceptably without the plugin. The signal is the fire rate, not Δ.
- Without the plugin, "fires" is 0 by construction; the with/without comparison on fire
  rate only proves the skill is the source of the invocation.
- Three runs per case; a 3/3 vs 2/3 difference is within noise. Re-run before acting on it.
- LLM judge is haiku by default; a rubric that looks too strict or lenient should be fixed
  by rewording or `--judge-model sonnet`.
