# Gate registry (T-2)

Every gate that emits a `deny` / `ask` / `block` decision — plus the
non-blocking `observe` / `advise` entries that share this registry — with the
**model weakness it assumes** and a **review date**. The governing principle: *an
assumption expires*. A gate written against a model failure mode that no longer
occurs becomes pure friction (permission-approval rubber-stamping); a gate that
never fires may be dead wiring. Neither is visible without a registry to compare
the live firing log against.

`core/infra/telemetry-digest.sh --gates` reads the **machine block** below plus
the runtime firing logs under `.agent/logs/` and reports, per gate:

- **DEAD** — zero in-window firings (the gate may be mis-wired or its failure
  mode is extinct; confirm before removing).
- **FATIGUE** — firings ≥ the fatigue threshold (default 50; `--fatigue N`): the
  gate is high-friction; check whether it is catching real problems or being
  rubber-stamped.
- **STALE** — `last_reviewed` + review window (default 90 days; `--stale-days N`)
  is in the past: the assumption is overdue for re-validation.
- **UNINSTRUMENTED** — the gate emits a decision but writes no firing log
  (`sink = -`), so fire-rate cannot be measured. Reported honestly rather than
  mislabeled DEAD (unmeasured is not zero).

## Machine block

Parsed by the digest. **Strict format** — one gate per line, exactly:

```
GATE <id> | <hook> | <decision> | <sink> | <match> | <last_reviewed> | <assumption>
```

- `<sink>` is a path relative to `.agent/logs/`, or `-` when the gate writes no log.
- Sink-record fields are measurement labels: keep them in the sink, never in the text a gate
  shows the model (`hook-protocol.md` § Out-of-band labels).
- `<match>` is the `guard` field value to count in the sink, or `*` to count every
  line in the sink (used when the sink holds exactly one gate's records).
- `<last_reviewed>` is `YYYY-MM-DD`.
- No `|` may appear in `<assumption>` (it is the last field, free prose otherwise).

<!-- gate-registry:begin -->
GATE destructive | pre-tool-guard.sh | deny | security-violations.jsonl | destructive | 2026-10-08 | Model will run an unscoped rm -rf / reset --hard / force-push when a plan says "clean up" or "start over". Review 2026-10-08: KEEP — the window's DEAD/FATIGUE flags cannot carry a sunset decision: firing logs are per-project cwd `.agent/logs/` (other projects' firings are invisible here) and this repo's security-violations sink mixes test-fixture rows into live ones (all 9254 rows carry session_id "main", only 661 flagged reproduce_test). Re-judge after backlog X-5 isolates test logs and aggregates across projects.
GATE production-data | pre-tool-guard.sh | ask | security-violations.jsonl | production-data | 2026-07-10 | Model will DROP/TRUNCATE a real table while iterating on a migration.
GATE secrets-bash | pre-tool-guard.sh | deny | security-violations.jsonl | secrets | 2026-10-08 | Model will cat/copy/exfiltrate a secrets file to "check" or "inventory" credentials. Review 2026-10-08: KEEP — the window's DEAD/FATIGUE flags cannot carry a sunset decision: firing logs are per-project cwd `.agent/logs/` (other projects' firings are invisible here) and this repo's security-violations sink mixes test-fixture rows into live ones (all 9254 rows carry session_id "main", only 661 flagged reproduce_test). Re-judge after backlog X-5 isolates test logs and aggregates across projects.
GATE verify-bypass | pre-tool-guard.sh | ask | security-violations.jsonl | verify-bypass | 2026-10-08 | Model will pass --no-verify to get past a failing pre-commit hook instead of fixing it. Review 2026-10-08: KEEP — the window's DEAD/FATIGUE flags cannot carry a sunset decision: firing logs are per-project cwd `.agent/logs/` (other projects' firings are invisible here) and this repo's security-violations sink mixes test-fixture rows into live ones (all 9254 rows carry session_id "main", only 661 flagged reproduce_test). Re-judge after backlog X-5 isolates test logs and aggregates across projects.
GATE lint-tamper | pre-tool-guard.sh | ask | security-violations.jsonl | lint-tamper | 2026-07-10 | Model will weaken a linter/gate config to make code pass rather than fix the code.
GATE review-override | pre-tool-guard.sh | deny | security-violations.jsonl | review-override | 2026-10-07 | Model will set AGENT_REVIEW_OVERRIDE, AGENT_WORKERS_DIR, AGENT_LOGS_DIR or GITHEAD_* itself to self-approve a risk-area commit or relocate the evidence ledger. Denies the recognised assignment forms anywhere in the message-stripped command and logs the attempt; a speed bump, not a boundary (brace/variable indirection, interpreter one-liners such as python/perl/node -e that set env, and scripts written then run evade it).
GATE evidence-ledger | pre-tool-guard.sh | deny | security-violations.jsonl | evidence-ledger | 2026-10-07 | Model will write or edit reviews.jsonl or review-override.jsonl to forge the review evidence the commit gate trusts; those ledgers are written only by call-worker.sh and review-evidence.py. Denies the recognised Bash write forms (secret-content-scan.py denies Write/Edit of ledger files inside the workers/logs dirs only; a project's own reviews.jsonl is unaffected) and logs the attempt; a speed bump, not a boundary: interpreter one-liners that write files and scripts written then run evade it.
GATE project-policy | pre-tool-guard.sh | deny | security-violations.jsonl | project-policy | 2026-10-08 | Model will git add large binary artifacts under data/artifacts/. DEAD-review 2026-07-15: KEEP — conditional-path gate; fires only where a consumer project defines artifact globs, zero in-window firings means no matching consumer activity, not an extinct assumption. Review 2026-10-08: KEEP — the window's DEAD/FATIGUE flags cannot carry a sunset decision: firing logs are per-project cwd `.agent/logs/` (other projects' firings are invisible here) and this repo's security-violations sink mixes test-fixture rows into live ones (all 9254 rows carry session_id "main", only 661 flagged reproduce_test). Re-judge after backlog X-5 isolates test logs and aggregates across projects.
GATE project-risk-area | pre-tool-guard.sh | ask | security-violations.jsonl | project-risk-area | 2026-10-12 | Model will modify files in a project-declared data/deploy/payment area (hook-config risk_areas.<area>.pattern) while iterating, without the owner deciding. Conditional-path gate (T-4): fires only where a consumer project declares a pattern, so zero firings means no consumer opted in, not dead wiring. Extension-only: it runs after every built-in guard and can only add an ask (or an explicit declared deny).
GATE secrets-content | secret-content-scan.py | deny | security-violations.jsonl | secrets | 2026-07-10 | Model will write a hardcoded API key / open() a secrets file / embed a token in an MCP payload.
GATE r4-mutex | r4-mutex-check.sh | ask | security-violations.jsonl | r4-mutex | 2026-10-08 | Two concurrent sessions will edit the same resource and clobber each other. DEAD-review 2026-07-15: KEEP — contention gate; multi-session campaigns are active and zero firings means no contention event in window (the failure mode it guards produced 3 real incidents before worktree isolation), not dead wiring. Review 2026-10-08: KEEP — the window's DEAD/FATIGUE flags cannot carry a sunset decision: firing logs are per-project cwd `.agent/logs/` (other projects' firings are invisible here) and this repo's security-violations sink mixes test-fixture rows into live ones (all 9254 rows carry session_id "main", only 661 flagged reproduce_test). Re-judge after backlog X-5 isolates test logs and aggregates across projects.
GATE context-mode | context-mode-guard.sh | ask | security-violations.jsonl | context-mode | 2026-10-08 | Model will run a production-db / deploy MCP action without confirmation. DEAD-review 2026-07-15: KEEP-CONDITIONAL — fate tied to the context-mode plugin itself, which the 2026-07-14 landscape re-check flagged for prompt-pollution review (W-10); retire this gate together with the plugin if the plugin is dropped. Review 2026-10-08: KEEP — the window's DEAD/FATIGUE flags cannot carry a sunset decision: firing logs are per-project cwd `.agent/logs/` (other projects' firings are invisible here) and this repo's security-violations sink mixes test-fixture rows into live ones (all 9254 rows carry session_id "main", only 661 flagged reproduce_test). Re-judge after backlog X-5 isolates test logs and aggregates across projects.
GATE quality-completion | session-quality-gate.py | block | quality-gate-violations.jsonl | * | 2026-10-08 | Model will end a session with style violations or failing completion tests left in the diff. DEAD-review 2026-07-15: RETIRE-CANDIDATE (superseded same-day). CORRECTION 2026-07-15b: **KEEP-CONDITIONAL** — the retirement investigation refuted its own premise: this hook is also the enforcement layer for **P3-1 `session.completion_tests`** (docs/hook-config.md "Completion tests"), so it is a conditional-path gate like project-policy — zero firings means no local consumer declares `completion_tests` and the default style scan scope (`src/`) misses local work patterns, not dead wiring (the gate is battery-verified in verify-all via quality-gate-completion-test.sh). Deleting it would silently unship a landed P3 feature. Real follow-up is adoption/generalization (W-6 `session.close_checks`), not removal. Guard-trim 2026-07-27: SPLIT — the subjective style scan (inline types / hex colors / console.log) is now ADVISORY by default (reported + logged, never blocks; opt back in via AGENT_QUALITY_STYLE_BLOCK=1); the block decision is owned by the objective completion_tests layer alone. Review 2026-10-08: KEEP — the window's DEAD/FATIGUE flags cannot carry a sunset decision: firing logs are per-project cwd `.agent/logs/` (other projects' firings are invisible here) and this repo's security-violations sink mixes test-fixture rows into live ones (all 9254 rows carry session_id "main", only 661 flagged reproduce_test). Re-judge after backlog X-5 isolates test logs and aggregates across projects.
GATE spec-gate | spec-gate.py | ask | spec-gate.jsonl | * | 2026-07-10 | Model will start substantive implementation with no approved spec/plan.
GATE tdd-guard | tdd-guard.py | ask | tdd-guard-dryrun.jsonl | * | 2026-07-10 | Model will write implementation code before a failing test exists.
GATE hardcoding | check-hardcoding.py | deny(opt-in; default=dryrun) | hardcoding.jsonl | hardcoding | 2026-10-08 | Model will inline design constants (colors, tick arrays) that belong in a config file. Guard-trim 2026-07-27: demoted deny -> DEFAULT DRYRUN (AGENT_HARDCODING_MODE=off/dryrun/block; the deny in this row is the opt-in block-mode decision) — a design-taste opinion is not an irreversibility/secret gate, and the gate shipped UNINSTRUMENTED with a docstring promising an unwired hook-config escape (fixed: sink added, escape claim honestly marked T-4-planned). Review 2026-10-08: KEEP — the window's DEAD/FATIGUE flags cannot carry a sunset decision: firing logs are per-project cwd `.agent/logs/` (other projects' firings are invisible here) and this repo's security-violations sink mixes test-fixture rows into live ones (all 9254 rows carry session_id "main", only 661 flagged reproduce_test). Re-judge after backlog X-5 isolates test logs and aggregates across projects.
GATE supervisor-ask | supervisor.py | ask | supervisor.jsonl | supervisor-ask | 2026-07-27 | Model will implement specialist-domain work (review/security) inline instead of dispatching the registered specialist. Registered 2026-07-27 after a registry-blindspot audit: the hook had logged ~440 records / 11 ask-intents in 30d while absent from this registry (firing but unreviewable). Records before 2026-07-27 lack the guard field, so the digest counts from registration forward; mode unchanged by registration — measure first, recalibrate on data at the next review.
GATE plan-scope-allow | plan-scope-allow.py | allow | plan-scope-allow.jsonl | * | 2026-07-11 | Post-plan-approval edit prompts get rubber-stamped (approval fatigue); auto-allow is safe only in-workspace, outside risk areas, while the session plan flag is live. Activation 3-way: AGENT_PLAN_ALLOW_MODE=on forces active, explicit non-"on" forces dark, unset delegates to the per-project trust tier (trust_tier.py — personal only, granted solely by user-side ~/.agent/trust.list outside every workspace; fail-closed collab).
GATE model-routing-observer | model-routing-observer.py | observe | model-routing.jsonl | * | 2026-10-08 | The call-time model-override convention (implementation=MID, fan-out=LOW) is not followed — unpinned dispatches silently inherit the session top model. Measured before enforced: 2026-07-11 audit found 7/7 dispatches at TOP. 2026-07-17: records gained a spend signal (prompt_chars, best-effort total_tokens) so manager-audit can rank relative dispatch cost. Review 2026-10-08: KEEP — the window's DEAD/FATIGUE flags cannot carry a sunset decision: firing logs are per-project cwd `.agent/logs/` (other projects' firings are invisible here) and this repo's security-violations sink mixes test-fixture rows into live ones (all 9254 rows carry session_id "main", only 661 flagged reproduce_test). Re-judge after backlog X-5 isolates test logs and aggregates across projects.
GATE model-routing-advisor | model-routing-advisor.py | advise | - | * | 2026-07-28 | Same leak model-routing-observer measures (unpinned dispatch inherits the session top model), caught only after the fact by that observer. This hook surfaces the reminder at the decision point — one combined additionalContext object on PreToolUse Task/Agent (the missing-`model` note, plus the `effort-floor` risk note when both apply) — so the dispatcher can add a `model` override or confirm the inherit is intentional before the call goes out. Advisory only: never blocks, never switches a model, writes no log of its own (sink -; model-routing-observer's sink stays the sole measured record).
GATE effort-floor | model-routing-advisor.py | advise | - | * | 2026-10-08 | ASSUMPTION (unverified in this repo): a subagent dispatched on risk-area work (security, auth, concurrency, storage, migration) without a high effort misses edge cases that more effort would catch; a spec-backed wave can safely run low. The hook adds one short note (in the same additionalContext object as the model note) only when the description or first 500 prompt chars name a risk area and `effort` is missing or invalid; a missing effort alone is never nudged, since Claude's Agent tool guidance sets effort only on request. Never blocks and writes no log of its own (sink -).
GATE session-tier-observer | session-tier-observer.py | observe | session-tier.jsonl | * | 2026-07-21 | An expensive session does execution/mechanical work inline because nothing tells it which tier rung it occupies; detection makes the routing convention visible while every dispatch decision stays caller-made (the policy's "detection allowed, switching rejected" line). SessionStart payload carries no model field (verified 2026-07-21), so detection is best-effort: stdin field when the runtime adds one, transcript tail on resume, settings default labeled as such. Transcript-sourced values are spoofable by conversation content (a quoted 'model: ...' line in the chat matches the tail scan) — the record's source field discloses this; treat transcript-tier rows as best-effort labels, not verified identity, by any future consumer (`telemetry-digest.sh --review` reads this sink for the tier distribution; /manager-audit does not).
GATE rubric-commit | rubric-commit-judge.sh | observe | rubric-score.jsonl | * | 2026-10-08 | A project's per-commit quality is never scored against its own rubric, so regressions land silently between on-demand verify-completion runs. Advisory by design (records, never blocks — the commit already happened); the deterministic half of the two-layer rubric design. Fires only where a consumer defines .agent/rubric.yml (conditional-path, like project-policy), so zero in-window firings means no consumer opted in, not dead wiring. Review 2026-10-08: KEEP — the window's DEAD/FATIGUE flags cannot carry a sunset decision: firing logs are per-project cwd `.agent/logs/` (other projects' firings are invisible here) and this repo's security-violations sink mixes test-fixture rows into live ones (all 9254 rows carry session_id "main", only 661 flagged reproduce_test). Re-judge after backlog X-5 isolates test logs and aggregates across projects.
GATE verify-observed | session-quality-gate.py | observe | verify-observed.jsonl | verify-observed | 2026-10-08 | A session rewrites code end to end, runs nothing, and ends clean. quality-completion only closes this where a consumer declares session.completion_tests ("Unset/empty => the gate does nothing"), which is why THAT gate shows zero local firings — so the unconditional half is missing. Layer 3 of session-quality-gate.py notes code-changes-with-no-observed-verification, fed by verify-observer.py's PostToolUse invocation records (which share this sink but carry hook=verify-observer.py, so the digest's hook filter counts firings only). OBSERVE-ONLY on purpose: it blocks only under AGENT_VERIFY_OBSERVER_BLOCK=1, because a gate whose net effect is unmeasured has not earned the right to block (see "Is the gate worth its noise?" below). Presence-only by necessity — this runtime supplies no exit status (measured 2026-07-30), so the advisory never claims anything passed. 2026-09-02 revision: the diff is scoped to files THIS session edited (read off transcript_path) and the note is emitted once per (session, changed-file set). Before that it read the whole dirty work tree while claiming "changed this session", and re-fired every Stop with no exit an agent could reach — a concurrent session's uncommitted file drove 80 firings in 7m22s in one session and 79 in another, ending only when a verification command happened to land in the sink. Review 2026-10-08: KEEP — the window's DEAD/FATIGUE flags cannot carry a sunset decision: firing logs are per-project cwd `.agent/logs/` (other projects' firings are invisible here) and this repo's security-violations sink mixes test-fixture rows into live ones (all 9254 rows carry session_id "main", only 661 flagged reproduce_test). Re-judge after backlog X-5 isolates test logs and aggregates across projects.
GATE completion-gate | completion-gate.sh | block(opt-in; default=dryrun) | completion-gate.jsonl | * | 2026-10-08 | Model claims done without deterministic evidence (false success 45-76%, arXiv 2606.09863; judge-only blocking overtrusts, arXiv 2406.07791) Review 2026-10-08: KEEP — the window's DEAD/FATIGUE flags cannot carry a sunset decision: firing logs are per-project cwd `.agent/logs/` (other projects' firings are invisible here) and this repo's security-violations sink mixes test-fixture rows into live ones (all 9254 rows carry session_id "main", only 661 flagged reproduce_test). Re-judge after backlog X-5 isolates test logs and aggregates across projects.
GATE council-escalation | council-escalation-gate.py | deny | security-violations.jsonl | council-escalation | 2026-08-21 | A council-scale diff (line/file threshold or a risk-area path, core/infra/council-threshold.sh) gets a plain Claude-solo code-reviewer dispatch instead of a multi-vendor /council-review, because the routing decision was left to a prompt suggestion nobody read — the same ~98% advisory-ignore rate supervisor.py's own dispatcher was built to correct. Escapes: council-review's own internal code-reviewer dispatch via a council-active flag bound to the diff hash it authorized (TTL AGENT_COUNCIL_ACTIVE_TTL_S, default 300s; state lives outside the reviewed repo, never trusted from inside it) and same-diff-hash single-deny with a stated reason (TTL AGENT_COUNCIL_DENY_TTL_S, default 3600s; a retry on the identical diff passes only when its prompt carries `council-unavailable: <reason>`, logged to the sink, so a caller that truly cannot run council-review is not stuck in a permanent deny loop — 2026-10-01: a bare identical retry is denied again; 2026-10-07: refused when the diff touches a risk-area path — that path's only escape is the user's logged AGENT_REVIEW_OVERRIDE at commit time, review-completeness row). 2026-08-21 security revision: escape-hatch state (flag, deny ledger) moved outside the repo and bound/timestamped so a hostile checkout can no longer forge or permanently seed a bypass; the firing log stays in-repo (write-only telemetry, never read back for a decision) so it is now measured here rather than UNINSTRUMENTED.
GATE review-completeness | git-hooks/pre-commit | block | - | * | 2026-10-07 | Model will commit risk-area files after a Claude-only (or failed-lane) review and call it a council review; the commit needs an external-vendor complete review bound to the staged content, or a user-set AGENT_REVIEW_OVERRIDE (logged to ~/.agent/logs/review-override.jsonl, outside this sink). Risk classes come from council-threshold.sh; its auth class is mirrored only in plan-scope-allow (never auto-allow) and deliberately not in spec-gate or tdd-guard, which exempt risk paths. A merge exempts a risk file only when it equals a parent contained in a remote DEFAULT branch; remote-tracking refs are local state an agent could rewrite, so this is a convenience for merging the default branch in, not proof. The ledger row binds the diff key to an external lane returned complete while this key was set, not to the bytes the vendor read. In this framework repo the gate code itself (core/git-hooks, review-evidence.py, council-threshold.sh, pre-tool-guard.sh) is editable in-tree. Cherry-pick and rebase run no pre-commit (observed) and are not gated. Auth class is out for sso/session/jwt/token*/password*/rbac/acl/iam/oidc/saml/mfa/otp/signin/signup/logout and non-code policy files except .rego.
GATE runtime-currency | runtime-currency.sh | block | - | * | 2026-09-26 | Runtime specs and model IDs rot within ~45 days; a stale registry means the adapters enforce against a CLI that no longer exists.
GATE circuit-breaker | circuit-breaker.py | advise | circuit-breaker.jsonl | circuit-breaker | 2026-10-12 | Model will retry the same failing Bash command in a loop instead of changing approach. ASSUMPTION (unmeasured until this sink): the text heuristic is the only live failure signal (the runtime sends no exit status, measured 2026-07-30), so its false-positive/negative rate is unknown; the sink's `signal` field separates text vs exit-status vs failure-event fires. Advisory only.
<!-- gate-registry:end -->

## Rule enforcement map

The gate list above answers "what does each gate assume"; this map answers the reverse
question: **for each written rule, what actually enforces it?** A rule with no enforcer is
a wish the model may follow or not, so it is marked `UNENFORCED` and counted, not hidden.
Prefer building the check over rewording the rule.

`core/tests/rule-map.sh` (a verify-all gate; battery `core/tests/rule-map-test.sh`) reads the
block below and **fails** on a dead enforcer path, a `hook:` enforcer not registered in
`hooks/hooks.json`, a malformed or duplicate row, a stray line in the block, an unmapped
`operating-contract.md` bullet, or an exception that is missing a reason / expiry / approver,
has an impossible date, or has expired. It only **warns** with the `PARTIAL` and `UNENFORCED`
counts — the numbers are the pressure.

Strict format, one row per line, `|`-separated, no `|` inside a field:

```
RULE <id> | <file> [§ section] | <rule, short> | <kind:path[,kind:path]>
RULE <id> | <file> [§ section] | <rule, short> | PARTIAL <kind:path[,kind:path]> ~ <what is NOT covered>
RULE <id> | <file> [§ section] | <rule, short> | UNENFORCED
EXCEPT <id> | <reason> | <YYYY-MM-DD expiry> | <approver>
```

`kind` is `hook`, `test`, `ci`, `lint`, `git-hook` or `script`; paths are repo-relative and
must exist. A plain enforcer list means the rule is fully covered in the modes this repo
ships (a gate that defaults to dryrun, or watches other paths, is not full coverage).
`PARTIAL` names the file that covers part of the rule and states the gap after ` ~ `. An
`EXCEPT` may only target a `PARTIAL` or `UNENFORCED` row and lapses on its expiry date.

<!-- rule-map:begin -->
RULE AG-1 | AGENTS.md § 1 | Plan before editing 3+ files or hooks/adapters/rules | PARTIAL hook:core/hooks/spec-gate.py,hook:core/hooks/plan-gate.py ~ spec-gate defaults to dryrun (logs only) and watches only src/app/pages/lib/server/components paths; no 3-file or hooks/adapters/rules trigger; plan-gate only records an approval flag
RULE AG-2 | AGENTS.md § 2 | Domain-neutral tree: sanitize audit returns zero matches outside legacy/ | test:core/tests/sanitize-audit.sh,ci:.github/workflows/ci.yml
RULE AG-3 | AGENTS.md § 3 | Core hook changes keep the canonical hook protocol; all adapters return the same decision | test:core/tests/adapter-parity.sh
RULE AG-4 | AGENTS.md § 4 | New hook gets a failing reproduce test first | PARTIAL hook:core/hooks/tdd-guard.py ~ defaults to dryrun and its scope is src/ only, which this repo does not have, so core/hooks edits are not covered
RULE AG-5a | AGENTS.md § 5 | Conventional commit prefixes | UNENFORCED
RULE AG-5b | AGENTS.md § 5 | One logical change per commit | UNENFORCED
RULE AG-5c | AGENTS.md § 5 | Pre-commit gitleaks and staged-file scan run on every commit | PARTIAL git-hook:core/git-hooks/pre-commit,git-hook:core/git-hooks/check-staged.py ~ runs only where core.hooksPath is set by setup.sh and is skipped by git commit --no-verify; gitleaks is skipped when not installed
RULE AG-5d | AGENTS.md § 5 | Never bypass hooks with --no-verify | PARTIAL hook:core/hooks/pre-tool-guard.sh ~ the verify-bypass gate asks (does not deny) and only sees commands run through a Claude Bash tool
RULE AG-5e | AGENTS.md § 5 | AI commits carry a Co-Authored-By tag | UNENFORCED
RULE AG-6a | AGENTS.md § 6 | Branch naming agent/task-slug | UNENFORCED
RULE AG-6b | AGENTS.md § 6 | Never push to main | PARTIAL hook:core/hooks/pre-tool-guard.sh ~ blocks only a force-push to main or master from a Claude Bash tool; a plain push to main is not stopped here (relies on host branch protection)
RULE AG-6c | AGENTS.md § 6 | PR carries what, why, how tested | UNENFORCED
RULE AG-6d | AGENTS.md § 6 | Hook, guard, permission or deploy PRs wait for human review and merge; other agents never merge | UNENFORCED
RULE AG-7 | AGENTS.md § Multi-session | Concurrent sessions register and take file mutexes before editing shared files | PARTIAL hook:core/hooks/r4-file-mutex-check.sh,hook:core/hooks/r4-mutex-check.sh,hook:core/hooks/agent-session-start.sh ~ the mutex hooks only ask when another session already holds the resource; registering a session is not forced (a failed start is ignored)
RULE AG-8 | AGENTS.md § Agent brain | Agents write only the raw/ quarantine, never curated notes or the vault | PARTIAL script:core/brain/brain-mcp.py,test:core/tests/brain-capture-test.sh ~ the MCP server exposes only the capture tool, but a direct file write into notes/ or the vault is not blocked
RULE AG-9a | AGENTS.md § Style | Guarded grep-count idiom in strict-mode shell | PARTIAL test:core/tests/pipefail-idiom-scan.sh ~ scans only core/hooks, core/infra, adapters, evals and setup.sh, only for the counting idiom, and skips scripts that lack set -e or pipefail
RULE AG-9c | AGENTS.md § Style | Every shell script starts with set -euo pipefail | UNENFORCED
RULE AG-9b | AGENTS.md § Style | Shell scripts are shellcheck clean (no CI step runs it) | UNENFORCED
RULE AG-10 | AGENTS.md § Style | Python is ruff clean and type-hinted (no CI step runs it) | UNENFORCED
RULE AG-11 | AGENTS.md § Style | Hook stdout is strict json.dumps, never print | UNENFORCED
RULE AG-12 | AGENTS.md § Style | Markdown prose at most 100 columns, no trailing whitespace | UNENFORCED
RULE AG-13 | AGENTS.md § Style | Comments only where the why is non-obvious | UNENFORCED
RULE OC-1 | rules/policy/operating-contract.md | Follow current scope and project guidance; ask about material decisions | UNENFORCED
RULE OC-2 | rules/policy/operating-contract.md | Back codebase claims with file:line or command output; say unverified otherwise | UNENFORCED
RULE OC-3 | rules/policy/operating-contract.md | Read before changing; verify ownership before touching shared branches or jobs | PARTIAL hook:core/hooks/r4-file-mutex-check.sh ~ only detects two sessions editing the same file; read-before-edit and process or branch ownership are not checked
RULE OC-4 | rules/policy/operating-contract.md | Run checks and review proportional to risk; a missing review is not clean | PARTIAL hook:core/hooks/council-escalation-gate.py,hook:core/hooks/session-quality-gate.py,git-hook:core/git-hooks/pre-commit ~ forces a council review only for council-scale or risk-path diffs; session-quality-gate runs tests only where a project declares completion_tests (none in this repo) and its verify-observed check is advisory unless AGENT_VERIFY_OBSERVER_BLOCK=1; neither can tell whether a report is honest
RULE OC-5 | rules/policy/operating-contract.md | Never skip Git hooks unless the user supplied the flag | PARTIAL hook:core/hooks/pre-tool-guard.sh ~ asks rather than denies, and only for commands issued through a Claude Bash tool
RULE OC-6 | rules/policy/operating-contract.md | Secrets, auth, billing, deploy changes need authorization; no secret values in output | PARTIAL hook:core/hooks/pre-tool-guard.sh,hook:core/hooks/secret-content-scan.py ~ asks on declared risk areas and blocks secret-shaped content in writes; whether the user authorized the concrete change is not checked, nor are secrets in chat output
RULE OC-7 | rules/policy/operating-contract.md | Verify hook registration and coverage before claiming enforcement | PARTIAL test:core/tests/registry-drift.sh,test:core/tests/adapter-parity.sh ~ checks registry drift and adapter decision parity; nothing stops an enforcement claim made without running them
RULE OC-8 | rules/policy/operating-contract.md | Query the brain first; write only the raw capture path | PARTIAL script:core/brain/brain-mcp.py,test:core/tests/brain-capture-test.sh ~ write path limited by the MCP tool; query-first and direct file writes are not enforced
RULE OC-9 | rules/policy/operating-contract.md | Keep progress in a handoff; never disable a failing test because it recurs | UNENFORCED
RULE OC-10 | rules/policy/operating-contract.md | Concise language; say what changed, why, how it was checked | UNENFORCED
<!-- rule-map:end -->

## Review discipline

When you re-validate a gate's assumption (it still catches real model failures, or
it's proven extinct), bump its `last_reviewed` date here. The digest's STALE
report is the reminder; this file is the record. Removing a gate is a code change
*plus* deleting its row here — the registry must not name a gate that no longer
ships (there is no separate drift gate for this file yet; keep it honest by hand).

### Is the gate worth its noise?

A healthy fire-rate is not the same as a positive contribution. Every firing
spends context: the reason text, the retry, the re-read. A gate that fires often
and correctly can still be **net-negative** if the noise it injects degrades the
rest of a long session more than the failures it catches cost. So the review
question is not "did it fire" but:

> **Is the session better off with this gate on than off?**

DEAD / FATIGUE / STALE do not answer that — they measure activity, not effect.
When there is no data to answer it, say so and treat the gate exactly like
`UNINSTRUMENTED`: unmeasured is not the same as fine. Two rules follow.

- **Measure before enforcing.** A new gate lands as `observe` with a sink, and
  earns `ask`/`deny`/`block` only once its firings can be shown to correspond to
  real problems. The reverse order ships enforcement whose value is a guess.
- **Sunset condition.** A gate that is DEAD across two consecutive review
  windows, with no new evidence for its assumption, becomes a retirement
  candidate — recorded on its row, the same way `project-policy` and `r4-mutex`
  recorded KEEP with a reason. Conditional-path gates (fire only where a consumer
  opts in) are exempt from the DEAD count but not from this question.

Origin: this criterion is adopted from the measurement protocol of an external
harness (the `fivetaku/fablize` plugin, its measurement-protocol doc §1/§7),
which puts the harness-paradox question first and states plainly that a zero-lift
result is a warning rather than a success. The counterfactual machinery that would answer it
properly — an on/off holdout arm — is backlog X-1, deliberately unbuilt until
designed: that same project shipped an unrun measurement layer, and an
instrument nobody executes measures nothing.

## Retired gates

A retired gate loses its `GATE` line (the digest would otherwise report it DEAD forever),
its hook registration and its place in `core/hooks/`; the script moves to
`legacy/<name>/` with a README that records the date, the reason and the restore steps.

- `top-edit-advisor` (advise, sink `-`, retired 2026-10-20): `legacy/top-edit-advisor/README.md`.
