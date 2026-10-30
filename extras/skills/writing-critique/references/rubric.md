# Writing critique rubric

Six categories, three severities. A finding names exactly one category and one severity.

## Categories

| `category` | What it checks |
|---|---|
| `fact` | Facts, numbers, dates, names, units. Do figures agree with each other inside the draft? Is a claim stated as certain without a source? |
| `logic` | Argument and structure. Does the conclusion follow from the evidence? Is the order of sections sound? Any gap, contradiction or circular step? |
| `reader` | Reader comprehension. Undefined jargon or abbreviations, missing background, a step the stated reader cannot follow, a buried main point. |
| `fluency` | Natural Korean. Awkward or translated-sounding phrasing, needless repetition, wrong register, ambiguous subject. Not spelling or spacing (that is proofreading). |
| `request` | Fit to the stated purpose. Does the draft answer what was asked, cover every requested item, and stay in scope? Needs the purpose line; without one, report only what is plainly missing. |
| `format` | Length and form. Over or under the asked length, heading and list use, a section in the wrong place, inconsistent layout. |

## Severities

| `severity` | Definition | Example |
|---|---|---|
| `critical` | A reader would be misled or the document fails its purpose if this stays. | A table total that contradicts the summary figure (`fact`); a requested cost comparison that is absent (`request`). |
| `major` | A reader can still get the point but will stumble, doubt it, or have to guess. | A conclusion that skips a step (`logic`); an undefined term in the first paragraph (`reader`). |
| `minor` | Polish. The document works without it. | A repeated sentence ending (`fluency`); a heading level that jumps (`format`). |

## `changes_fact`

Set `changes_fact: true` when applying the suggestion would change a number, date, name, claim or conclusion that the draft states (not merely how it is worded). A fix that only removes a contradiction by choosing one of two figures changes a fact; the author must say which one is right.

## Short examples

- `fact` / `critical` — quote: "처리 시간이 38% 줄었다" while the table shows 28%. Problem: the two figures disagree. `changes_fact: true`.
- `logic` / `major` — quote: "따라서 전면 도입이 타당하다". Problem: the evidence covers one team's pilot only. `changes_fact: false`.
- `reader` / `major` — quote: "RPO 기준을 충족한다". Problem: the abbreviation is never defined for a non-technical reader.
- `fluency` / `minor` — quote: "진행되어지는 것으로 사료된다". Problem: stacked passive and stiff register; suggest a plain active phrasing for that span only.
- `request` / `critical` — quote: "비용은 추후 검토한다". Problem: the purpose line asks for a cost comparison.
- `format` / `minor` — quote: a heading that repeats the one above it. Problem: duplicate heading.
