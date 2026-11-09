# Design document critique rubric

Five categories, three severities. A finding names exactly one category and one severity.

## Categories

| `category` | What it checks |
|---|---|
| `terms` | Undefined terms and hidden assumptions. A name, abbreviation or component a fresh reader cannot place; something the plan relies on without saying so. |
| `overdesign` | Complexity beyond the stated goal, or a simpler alternative the document ignores (one that already exists in the sources, or plainly needs less). |
| `contradiction` | The document disagrees with itself: two steps that cannot both hold, a goal and a step that conflict, figures or names that differ between sections. |
| `claims` | Claims against the sources. A file, function, command or behaviour the document says exists or works a certain way, while the included sources (or the repository, if you can read it) show otherwise. Missing or contradicted = `critical`. A path outside the repository is never a finding: say "not verified (outside repository)" in `paraphrase`. |
| `readiness` | Implementation readiness. A design choice still open, a file with no create/modify/delete intent, a step with no way to verify it, an edge case or failure path nobody handles. |

## Severities

| `severity` | Definition |
|---|---|
| `critical` | Building from this document would go wrong, or its premise is false (a cited file does not exist; two steps contradict). |
| `major` | An implementer would have to guess or decide something the document should have decided. |
| `minor` | Polish. The plan works without it. |

## `changes_fact`

Set `changes_fact: true` when applying the suggestion would change what the document claims about the current system, or a decision it states. Wording-only fixes are `false`.

## `paraphrase`

Before the findings, write `paraphrase`: 2-4 sentences saying what the document proposes and what it says the current system is. If the paraphrase would have to guess, the document is unclear: report that as a finding on the unclear passage.

## Short examples

- `claims` / `critical` — quote: "`send_retry()` 함수가 이미 재시도를 처리한다". Problem: the included source of that function has no retry.
- `readiness` / `major` — quote: "캐시 방식은 구현 중에 정한다". Problem: an open design choice.
- `overdesign` / `major` — quote: "새 설정 계층을 추가한다". Problem: one existing option already does this.
- `contradiction` / `major` — quote: "기존 API는 건드리지 않는다". Problem: step 3 modifies it.
- `terms` / `minor` — quote: "게이트가 통과해야 한다". Problem: which gate is not said.
