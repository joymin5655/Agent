# Skill routing eval

A deterministic, model-free check that skill descriptions are *discriminable*: given a
user prompt, does the right skill's description score highest, and are any two
descriptions near-duplicates that would compete for the same prompt?

```bash
python3 evals/routing/run_routing_eval.py                      # repo skills/: strict coverage + lint errors fail
python3 evals/routing/run_routing_eval.py --floors evals/routing/floors.json   # what CI and the test run
python3 evals/routing/run_routing_eval.py --json               # machine-readable
bash core/tests/routing-eval-test.sh                           # the battery (also runs in verify-all)
```

## What it measures

- **Tier 1 lint** over every `SKILL.md` (disabled-for-model skills included): frontmatter
  `name` present and equal to its directory, `description` present and <= 1024 chars
  (Agent Skills spec; error), description + `when_to_use` > 1536 chars (listing
  truncation; warning), file <= 500 lines.
- **Tier 2 routing proxy**: each model-invocable skill becomes a TF-IDF vector over
  `name + description + when_to_use`. Every prompt in `cases.json` ranks all skills by
  cosine similarity. Reported: rank-1 rate, top-3 rate (positive prompts), negative
  violations (a negative prompt for skill X that ranks X first), and a near-collision
  list (pairwise description cosine above `--collision-threshold`, default 0.5; the five
  closest pairs are always printed).
- Tokenizer: lowercase word tokens with light English suffix stemming and stop-word
  removal, plus character bi/trigrams for Hangul runs. A prompt with zero lexical overlap
  is "no match" and ranks last (no alphabetical tie-break luck).
- Skills with `disable-model-invocation: true` are linted but not ranked.

## Limits

This is a **lexical proxy, not model behavior**. A model matches meaning, not tokens, so a
real model will route better than this ranking in general. Specifically:

- Descriptions are English. Korean prompts only match through shared Latin tokens
  (`codex`, `PR`, `/loop`, ...) or Korean words that appear in a description, so the
  Korean rank-1 rate here is a coverage signal ("does the description carry the Korean
  trigger phrases?"), not a prediction of failure. Both languages are reported separately.
- Near-collision scores flag description overlap worth reading; they do not prove a
  mis-route. Negative prompts are hand-written and few.
- The floors (`floors.json`, the single source read by CI and the test) are regression
  guards set slightly under the measured baseline.
- English positive prompts were written from the descriptions' own phrasing, so their
  100% mostly proves the descriptions contain their trigger words (a keyword-coverage
  check), not that unseen phrasings route correctly.
- "NOT for X" clauses in descriptions repeat the neighbouring skill's vocabulary, which
  inflates lexical similarity between skills that are deliberately separated; read a
  collision as "check the wording", not "merge them".
- Ties share the best rank (optimistic for positives, strict for negatives); zero-overlap
  prompts rank last. The English stemmer is a light suffix stripper, not Porter.
- Hangul bi/trigrams only help when a description contains Korean. With English-only
  descriptions the Korean rank is a keyword proxy for Latin tokens in the prompt.
- Coverage: the default repo run fails if a case names an absent skill or a ranked skill
  has no case; `--strict-coverage` applies that to custom pools.

## Running against your own skills

`--skills-dir` is repeatable and read-only. Skills from every directory are ranked
together; cases whose skill is absent are skipped (unless `--strict-coverage`), so the other skills act as
distractors and the near-collision list covers the whole pool:

```bash
python3 evals/routing/run_routing_eval.py --skills-dir skills --skills-dir ~/.claude/skills --collision-threshold 0.3
```

## Baseline (repo skills, 2026-10-20)

14 ranked skills (15 linted), 70 positive / 42 negative prompts: rank-1 71.4%, top-3 77.1%
(en 100% / 100%, ko 50% / 60%), 3 negative violations, 0 collisions above 0.5; closest
pair `harness-loop` <-> `loop` (0.34). CI floors (`floors.json`): rank-1 65, top-3 70, negative violations <= 4.

## Credit

The two-tier shape (structural lint, then stemmed TF-IDF ranking with near-collision
detection and a CI floor) is inspired by `run-evals.js` and its evals README in
[addyosmani/agent-skills](https://github.com/addyosmani/agent-skills) (MIT). This is an
independent Python implementation with a Korean-aware tokenizer.
