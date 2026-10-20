# core/hooks/

AI-agnostic hook implementations. Each script reads a canonical event JSON from `stdin` and writes a canonical decision JSON to `stdout` (or empty stdout for `allow`). See [`../../docs/hook-protocol.md`](../../docs/hook-protocol.md) for the contract.

## Ported in v0.1.0 (this release)

| Hook | Event | Purpose |
|---|---|---|
| `pre-tool-guard.sh` | PreToolUse (Bash) | Bash command safety — destructive deletion, force push, secrets/.env access, DROP/TRUNCATE TABLE; `review-override` denies the recognised forms that set `AGENT_REVIEW_OVERRIDE`/`AGENT_WORKERS_DIR`/`AGENT_LOGS_DIR`/`GITHEAD_*`, `evidence-ledger` denies writes to `reviews.jsonl`/`review-override.jsonl` (logged; Bash speed bumps, not boundaries: interpreter one-liners and run-after-write scripts evade them) |
| `secret-content-scan.py` | PreToolUse (Write/Edit/MultiEdit + MCP write tools) | Secret bypass patterns in file content + MCP URL/query/content payloads; also denies Write/Edit of the review evidence ledgers (`reviews.jsonl`, `review-override.jsonl`) inside the workers/logs dirs |
| `r4-mutex-check.sh` | PreToolUse (`*`) | Resource mutex — production-db, edge-function-deploy, production-deploy |
| `r4-file-mutex-check.sh` | PreToolUse (Write/Edit/MultiEdit) | File-level mutex when another session is editing the same path |
| `r4-file-mutex-register.sh` | SessionStart (`baseline`) + PostToolUse Bash (`commit`) | Register worktree-commit-changed files in lock file |
| `agent-session-start.sh` | SessionStart | Register session + GC stale entries + broadcast started + emit dashboard context |
| `agent-session-heartbeat.sh` | UserPromptSubmit + PostToolUse | Heartbeat the active session to keep it fresh |
| `context-mode-guard.sh` | PreToolUse (Context-Mode `ctx_execute*` tools) | Block Context-Mode plugin sandbox bypass of R4 / secrets |
| `tdd-guard.py` | PreToolUse (Write/Edit) | Block new prod code unless a failing test exists in the same area |
| `spec-gate.py` | PreToolUse (Write/Edit/MultiEdit) | Gate substantive impl edits when no plan is approved this session — `ask` unless the plan-approval flag exists (written by `plan-gate.py`). Escape: `/spec` writes spec.md+plan.md then approve via ExitPlanMode, or `AGENT_SPEC_GATE_MODE=off`; modes off/dryrun/block (default dryrun) |
| `plan-scope-allow.py` | PreToolUse (Write/Edit/MultiEdit, last in chain) | Auto-allow accelerator — once a plan is approved this session, in-workspace non-risk edits skip the native permission prompt. Emits only `allow` or nothing (never deny/ask); risk areas, `.agent/hook-config.yml`, `.git/`, and out-of-workspace paths always pass through. Env-gated: `AGENT_PLAN_ALLOW_MODE=on` (default off) |
| `circuit-breaker.py` | PostToolUse (Bash) | Detect repeated Bash failures + advise strategy change. Failure classification prefers a machine exit status (resolved by key PRESENCE, so a successful `0` is not discarded as falsy) and falls back to a narrowed text heuristic that scrubs zero-count phrasings (`0 errors`) — this runtime supplies no exit status, measured 2026-07-30 |
| `verify-observer.py` | PostToolUse (Bash) | Pure observer — record that a verification command was INVOKED this session (family label only: tests/battery/typecheck/lint/build; no command text, so no secret-leak surface). Read by `session-quality-gate.py` layer 3, which advises when the session diff carries code changes and nothing was ever run — scoped to files this session actually edited (from `transcript_path`) and emitted once per changed-file set, so a concurrent session's uncommitted work is neither attributed here nor repeated every Stop. Never claims a verification passed (no exit status available). Sink `.agent/logs/verify-observed.jsonl` |
| `rubric-commit-judge.sh` | PostToolUse (Bash) | Advisory per-commit rubric scoring — on `git commit`, if `.agent/rubric.yml` exists, runs `core/infra/rubric-score.py` and appends the verdict to `.agent/logs/rubric-score.jsonl`; never blocks (deterministic half of the two-layer rubric design; the semantic half is skills/verify-completion) |
| `check-hardcoding.py` | PreToolUse (Write/Edit) | Detect hardcoded color arrays / gradients / UI metadata |
| `session-init.py` | SessionStart | Surface project agent inventory + cleanup per-session flags |
| `session-close.sh` | Stop | Session cleanup + broadcast done + optional macOS notification |
| `plan-gate.py` | PostToolUse (Agent + ExitPlanMode) | Set plan-approval flag after plan-class agent or ExitPlanMode |
| `model-routing-observer.py` | PostToolUse (Task/Agent) | Pure observer — classify each subagent dispatch's model choice (override / pinned_specialist / inherit_top) into `.agent/logs/model-routing.jsonl`, plus a spend signal (`prompt_chars`, best-effort `total_tokens`) consumed by `core/infra/manager-audit.sh`; measures the docs/model-routing.md call-time convention before any enforcement |
| `model-routing-advisor.py` | PreToolUse (Task/Agent) | Decision-time advisory — one combined `additionalContext` object when a dispatch has no `model` override (not a registry-pinned specialist, not `Plan`, whose inherit is intended), and/or when its description or first 500 prompt chars name a risk area (security/auth/concurrency/storage/migration) with no valid `effort` (note: use `effort: high` if an effort policy applies). A missing `effort` alone is never nudged. Never blocks, never switches a model, writes no log of its own — advisory only, the observer's sink stays the sole measured record |
| `session-tier-observer.py` | SessionStart | Pure observer — best-effort detect the session's model tier (stdin model field → transcript tail → settings default) and surface the routing advisory on stderr ("session=TOP; execution dispatches at MID/LOW"); logs to `.agent/logs/session-tier.jsonl` (audit trail; /manager-audit does not consume it yet — future wiring). Detection is allowed, switching is not (docs/model-routing.md) |
| `supervisor.py` | UserPromptSubmit + PreToolUse (Write/Edit/MultiEdit) + PostToolUse (Task/Agent) | v0.2 minimal dispatcher — records a registry-keyword intent, `ask`s on the next edit (once), resolves on specialist dispatch; independent security file-glob matcher; ghost→executor fallback; `AGENT_SUPERVISOR_MODE=observe` downgrades to stderr |
| `council-escalation-gate.py` | PreToolUse (Task/Agent) | Deny a plain `code-reviewer` dispatch when `core/infra/council-threshold.sh` judges the staged diff council-scale (line/file threshold or a risk-area path), pointing at `/council-review --staged`. Escapes: a council-active flag bound to the diff hash it authorized (TTL `AGENT_COUNCIL_ACTIVE_TTL_S`, default 300s — council-review's own internal dispatch is never self-blocked; set/cleared via `--council-flag set` / `--council-flag clear`, never a raw touch), and same-diff-hash single-deny with a stated reason (TTL `AGENT_COUNCIL_DENY_TTL_S`, default 3600s — a retry on the identical diff passes only when its prompt carries `council-unavailable: <reason>` (≥10 chars, logged); a bare identical retry is denied again; refused outright when the diff touches a risk-area path, whose only escape is the user's logged `AGENT_REVIEW_OVERRIDE` at commit time). Escape-hatch state lives outside the reviewed repo (`~/.agent/state/council` by default, `AGENT_COUNCIL_STATE_DIR` seam) so a hostile checkout can't forge or backdate it; the firing log stays in-repo (`security-violations.jsonl`) since it's write-only telemetry, never read back for a decision |

### Residual risk — `pre-tool-guard.sh` guard 5 (secrets path)

Guard 5 lexes a nominated command like a shell and denies on any doubt, with a work cap and a 2 s
alarm so a slow scan cannot outlive the hook timeout. It is still a speed bump against careless
reads, not a sandbox. Known gaps (the first and the fourth are pinned as allow in the guard test):

- A git history or `git config --file` read whose path is produced by an expansion, e.g.
  `git show "HEAD:$(echo ...)"`, is allowed: the additive git branch denies only on a path it can
  read literally.
- Variable-held code strings: a code string that reaches a program through a variable (`python3 -c
  "$X"`, `GIT_PAGER='...' git log`, `AL='!cmd' git --config-env=alias.x=AL x`, `PS4='$(...)'` before
  `set -x`, a `git config alias.x '!...'` run later), and a path handed to a program through its
  environment (`P=<dir>/k prog`, `GIT_CONFIG_GLOBAL=<dir>/k git config -l`).
- Names from outside the line: the scan judges how a path is spelled inside the command line. A
  directory name that comes out of the environment, a file or decoded text (`base64 -d`), or out
  of any other command whose line does not spell it (`cat "$(cat names.txt)"/k`), is not seen. Nor
  is a name that a program computes instead of printing (reversed, hex, `tr` ranges).
- Operands that never name the directory: `find . -type f -exec cat {} +`, `cat $(find . -type f)`
  and `grep -r PATTERN .` reach `secrets/` without spelling it. A mention of `secrets/` in a
  comment, in prose or as a search pattern on the same line does not change what they read, so stage
  2 lets them through, as the first stage does when the line has no mention at all (the xargs guard
  of this hook still denies `... | xargs cat` next to a mention). A mention that is a path (`ls
  secrets/`) next to a reader that walks into directories is denied: see the paragraph on walking
  readers below.
- Roots judged by their name: a root that reaches the directory through a symlink or a mount that
  already exists (`tar cf a.tar link ; ls secrets/` with `link` pointing at it) is compared by its
  spelling and cleared. `ag` is not installed on the machine this was written on: its options come
  from its manual, never from a run, and an option the manual does not list keeps the deny. `rg`
  with no operand reads stdin when stdin is a pipe; the scan assumes the working directory, which
  can only deny more. A program that walks but is no guard verb (`ditto`, `pax`, `cpio`, `7zz`) is
  unknown to the scan.
- Two-step reads and git commands the scan does not list: a file that one command copies into git
  (`git add secrets/k`, `git hash-object -w`, `git update-index --add`) and a later command prints
  (`git diff --cached`, `git cat-file -p`) is two steps, and the first prints nothing, so `git add
  secrets/...` and `git rm --cached secrets/...` pass. Commands that print a file's content but are
  neither nominated nor known readers (`git diff-files -p`, `git checkout-index --stdout`, `git
  whatchanged -p`, `git reflog -p`) are not seen; `git check-mailmap --mailmap-file`, `git ls-files
  --exclude-from`, `git apply` and `git am` read a file but print no content. A message that `git
  commit -F` stored is printed by a later `git log` or `git tag -n` that needs no `secrets/` on its
  line: the storing call is the one that is denied.
- Messages taken from an object instead of a file: the reuse and reedit options of `git notes`
  (`-C`, `-c`, `--reuse-message`, `--reedit-message`) store a blob such as `HEAD:secrets/k` as a
  note that a later `git notes show` prints. The scan models `-F` and `--file`, not these, so `git
  notes append -C HEAD:secrets/k HEAD` passes; `git notes add` is denied only because the
  first-stage match finds the guard verb `dd` in `add`.
- Reading through a ref that points at a blob: `git tag t HEAD:secrets/k` (or `git update-ref refs/x
  <blob>`) stores a ref to the file's blob and prints nothing, and a later `git show t` or `git
  cat-file -p t` names no path, so no stage sees the read. 0.8.0 denied `git tag t HEAD:secrets/k`,
  because `tag` contains the guard verb `ag`; `git update-ref` it allowed.
- Forms that stage 1 never nominates, so that stage 2 never sees them: a `cd` or `pushd` into the
  directory followed by a relative path (`(cd secrets && cat k)`), the last argument of the previous
  command (`echo secrets/k; cat $_`) and a name decoded on the way (`... | base64 -d | xargs cat`).
  None of them puts a guard verb in front of a literal `secrets/`, and 0.8.0 passed them too.
- Write-then-run scripts: a script written by one command and run by the next is a file, not text
  on this command line. The same holds for interpreter bodies and heredocs, a program that runs a
  quoted string but is not a known carrier, text that reaches a quoted `"$(...)"` only through a
  file the command writes, and obfuscation that the first-stage regex never nominates.
- The per-line marker: `supply-chain-scan.sh` class 4 skips a line that carries
  `supply-chain-scan: allow-literal <reason>`, which this hook needs for its wrapper-name list.
  The marker is read from the line itself, so it would also hide a real spawn written on that
  line: review every use. It is per line, never per file or per class.
- Size: stage 2 is a Python program of about sixteen hundred lines embedded in this shell file,
  which makes the hook hard to read and to lint as Python. Moving it into a module next to the hook
  (precedent: `hook_config.py`) is a follow-up.
- Sibling hooks: only `pre-tool-guard.sh` keeps the working directory out of its python3 helpers
  (`-I`, or a pruned `sys.path` for the one that needs PyYAML). `agent-proxy.sh`,
  `context-mode-guard.sh`, `r4-mutex-check.sh` and `r4-file-mutex-check.sh` still start a plain
  `python3`, so a `json.py` in the working directory can stand in for the standard module there.
- Host timeout: `hooks/hooks.json` sets no timeout for this hook, so the host default applies
  (documented as 600 s for command hooks). A hook the host kills, or one that crashes, prints no
  decision and the Claude Code adapter then lets the call through (`docs/hook-protocol.md`
  section 4; the Codex adapter fails closed). Stage 2 therefore decides inside its own 2 s alarm,
  and a stage 2 that fails in any way (python3 missing, a non-zero exit, SIGKILL or SIGTERM, a
  spent budget, an empty, garbled or truncated answer) is a deny. If python3 is missing for the
  whole hook, the event cannot be parsed and every guard of this file allows, as before.

Where bash and zsh read the same text differently, the lexer cannot tell which text is code and says
`unparseable`, so the nominating deny stands: an expansion or a `$"..."` string as a heredoc
delimiter (bash drops the dollar sign, zsh keeps it), `$[ ]`, a quote or a dollar-quote inside a
double-quoted `${ }`, `<<(`, a `(` glued to a word (a zsh glob), a `(` after a blank that follows a
command word (`echo (a|b)`: a syntax error for bash, a glob group that can reach across lines for
zsh; a subshell after `;`, `|`, `&&`, `{` or a keyword, and a `case` pattern, are not such a word),
`$$` before a brace or a quote (bash keeps an unbalanced brace as text, zsh refuses it), a `$`
followed by two line continuations (zsh then reads it as a plain character), a line continuation
inside a token, a heredoc delimiter line whose match depends on a line continuation (for `<<-` bash
strips the tabs of the joined line, zsh those of the first physical line only), a blank or operator
inside a `name[...]` or array-literal `[sub]=` subscript (bash keeps the span in one word), a
redirection operator inside a `name=( ... )` literal (text for bash, a here-document or a refusal
for zsh), a `<<` anywhere in `[[ ... ]]` and a `<`, `>` or malformed `${` in the regex operand of
`[[ ... =~ ... ]]`, a brace inside `${ }` (bash ends the expansion at the first `}`, zsh counts
nested braces), a `#` inside `[[ ... ]]` (a comment for bash, part of a pattern for zsh), a `}` that
no `{` in its own word matches (bash keeps it in the word, zsh ends the word there and closes an
open group), a `$'...'` escape whose bytes depend on the shell (`\c`, `\u`, `\U`, a NUL written
`\0`, `\x00` or `\400`: bash ends a word at a NUL, which ends a here-document at its first empty
line, and zsh keeps it; also a code below 7 or above 127, `\x` without digits and an unknown escape
such as `\q`, where bash keeps the backslash and zsh drops it; only `\n \t \r \a \b \e \E \f \v \\
\' \" \?` and a hex or octal code from 7 to 127 are decoded), and a shell or `source` that reads its
script from stdin (`sh -`, `bash -s`, `/dev/stdin`). A keyword glued to `((` (`for((`, `while((`)
opens an arithmetic list, whose `<<` is a shift. zsh runs the words after a test as its body (`if [[
t ]] cmd`, `if (( n )) cmd`, `if { t } cmd`, `for ((;;)) cmd`, `{ ... } always { ... }`); the scan
reads them as a command too. `file -f`, `tree --fromfile`, `du --files0-from`, git's
`--pathspec-from-file`, `git blame -S`, `git fast-export --import-marks`, `git credential-store
--file` and `git interpret-trailers FILE` print what they find in the file they are given, so they
count as readers. So do the options by which git stores a file as a message: `-F` and `--file` of
`git commit`, `tag`, `merge`, `commit-tree`, `notes` and `fmt-merge-msg`, and `git commit -t`, since
a later `git tag -n999`, `git log` or `git notes show` prints it (`git tag -a v1 -F secrets/k; git
tag -n999 v1`). git takes any unique prefix of a long option (`--fil=`); the scan takes every prefix
of an option it lists (`--f=` too), unique or not. A `git -c name=value` whose value names the path
(an alias `!cmd`, `core.pager`), written out or spelled with a glob, a brace group or quotes
(`alias.x=!cat secre[t]s/k`), is doubt, and so is the code string of an interpreter that spells it
(`ruby -e 'puts Dir["secre[t]s/*"]'`). `git rebase -x`, `git submodule foreach` and the program of
`--upload-pack`, `--receive-pack` and `--exec` (fetch, pull, push, clone, ls-remote) hand their
argument to a shell and are scanned as a command line (so are difftool, filter-branch and bisect,
which are doubt when they name the path), and rsync/tar `--include` selects what they read, so it
counts as an operand. A git history or config read (`git show REV:secrets/k`, `git config -f
secrets/k -l`) is denied on a parsed read and on anything that is not an answer: the 2 s alarm, a
crash, a spent work or nesting budget, a missing python3, a non-zero exit, a killed process, an
empty, garbled or truncated answer. Only a scan that finished and found no read (`inert`, `doubt`,
`unparseable`) allows, as before. That second regex also nominates the git commands that take a file
or a message of their own (`commit`, `tag`, `merge`, `notes`, `commit-tree`, `fmt-merge-msg`,
`credential-store`, `interpret-trailers`, `fast-export`, `fast-import`, and the users of
`--pathspec-from-file`: `add`, `rm`, `reset`, `restore`, `checkout`, `stash`); `git add secrets/k`
and `git rm --cached secrets/k` print nothing and pass. `git log` and `git show` may name the path
when every option they carry prints commits, names or counts (`--oneline`, `--name-only`, `--stat`,
`-s`, `--format=...`, `-n`, `--since=...`, and ordering, selection and rename options such as
`--topo-order`, `--diff-filter=...` and `-M`; `git show` also needs one of the options that replace
its default patch): the path then only selects commits. A patch option (`-p`, `-u`, `--patch`) keeps
the read wherever it stands, even in front of a `-s` or `--no-patch` (git lets the last of them win,
which the scan does not model: `git show -p --no-patch HEAD -- secrets/k` is denied). The options
are an allowlist, not a list of patch options, so one nobody listed cannot make a read pass: `-p`,
`-U`, `-c`, `--cc`, `-L`, `--word-diff`, `--check`, `--output`, a pickaxe, any option this scan does
not know, a `REV:path` blob, and an expansion before `--` that may supply an option keep the deny.

Stage 1 only sees a literal `secrets/`, so stage 2 also judges how a path is spelled. An operand of
a reader, a `cd` or `pushd` target, a git pathspec or `-C` directory, and the directory option of a
launcher (`env -C`) is a read when one of its path components can read as the word `secrets`:
written out (also as a last component without the slash, `grep -r KEY secrets`), spelled with a glob
(`secre[t]s/k`, `s*/k`, `*/k`), spelled with a brace group (`{secrets,x}/k`, `sec{r,s}ets/k`; a
group of more than 64 words is not enumerated and denies) or built from pieces (`"$A"rets/k`,
`$A$B/k`, `$(echo sec)rets/k`). The last component of an operand has to be able to read as `secrets`
itself; a component before a slash may also end in it, as the written-out `x-secrets/k` does, so
`data_*/k` and `x-secre[t]s/k` count, while `src*`, `docs/*.md`, `"$f".bak` and `file{1..3}.txt` as
the last component do not. The match is made behind an `=` or a `:` too (`dd if=...`, `host:...`).
An expansion may bring a slash of its own, so a last component that ends in one counts when the
value could finish the name (`x-secre"$A"`), and so does a name that an expansion cuts off
(`secrets"$S"k`). A component that is one bare expansion (`"$D"/k`) is not judged, as before: its
value is unknown here. What counts instead is a name that the line hands to it: the value or key of
an assignment (`D=secrets`, `m[secrets]=1`), an element of an array literal, a `for` word list, the
arguments of any command that is no reader (`echo`, `printf`, `set`, `export CDPATH=...`, `find`,
`git`, a program that rewrites text), the program text of `sed` and `awk`, a here-string, a global
alias or a launcher option. It carries the name when it is the word or a glob, brace or piece-built
spelling of it, also a name that ends in it with a character of its own (`D=x-secrets`) or has it
inside (`D=secretsX`, for a later `${D%X}`). The words of consecutive `echo` and `printf` commands
are put side by side (`echo -n secr; echo -n ets/k`), a `printf` conversion (`%s`) or character code
(`\057`) counts as an unknown piece, and an item after the first of a list that a splitting consumer
hands on (an unquoted expansion, `read`, `xargs`, `set --`: `D="x secrets"`, `a,secrets`) is judged
too. Such a name makes the line doubt whenever a reader or a `cd` can use it.

Options that pick files, and readers that walk. The value of an option that selects which files a
reader reads is an operand like a path: `rg -g`, `--glob`, `--iglob` and `--type-add`, `ag -G` and
`--file-search-regex`, `grep --include` (BSD grep matches it against the whole path, GNU grep
against the base name; both are denied) and the rsync and tar `--include` above. A glob that can
spell the directory (`'secrets/**'`, `'*secrets/*'`) selects it, and `rg --files` or `rg -l`, which
print names only, are denied like a content read. An exclusion picks nothing (`rg -g '!secrets/**'`,
`--exclude-dir`, `--exclude`): it is no operand, and it is not modelled as taking the directory out
of a walk either. A reader that walks into directories reads everything below its roots: `grep -r`
and `rgrep`, `rg` and `ag` (no operand: the working directory), `git grep`, `tar c`, `zip -r`, `cp
-r`, `rsync -a`, `scp -r`, `7z a`, `diff -r` and `gunzip -r`; an abbreviated long option (`cp
--recurs`, `grep --rec`) counts as the option it abbreviates. When the line also names a `secrets/`
path as a path (`ls secrets/`, `stat x/secrets/k`; a search pattern, prose, a comment or the text of
a heredoc does not count) and a root is, holds or may hold it (`.`, `x/` for `x/secrets/`, `~`,
`..`, an absolute path against a relative one, a pattern, a variable, `host:dir`, a `tar -C` or
`-T`, a `git -C`), or the line changes directory (`cd`, `pushd`, `env -C`), the line is doubt. Only
a root that provably lies side by side with the path is cleared: both relative or both absolute,
with a different name at the same depth (`src/` and `secrets/`, `y/` and `x/secrets/`).

The scan is deliberately conservative where text can be split: a secrets path inside a quoted word
with blanks (`' <dir>/k'`) counts as named once an unquoted `$( )`, `$var`, `for` list, `xargs` or
`read`, or a reshaping pipeline, can cut it into a path. The cost is a false positive when prose
that names the directory sits next to an unquoted `$var` operand; quoting the operand
(`cat "$f"`) lets it through.

## Roadmap — v0.2.0 ports

The following hooks exist in the prior project but are deferred because they require either:
- Significant rewrite to be project-agnostic
- A canonical schema that hasn't been generalized yet
- External plugin dependencies

| Deferred hook | Reason | Equivalent v0.1.0 substitute |
|---|---|---|
| `supervisor.py` (54KB original) | Full registry-aware orchestrator — intent classifier + multi-dept fan-out | v0.2 minimal dispatcher shipped (keyword intent + `ask` + dispatch-resolve + security glob); the full 54KB orchestrator remains deferred |
| `memory-explore-verify.py` | Needs `_memory_drift_patterns.py` catalog rewrite | Manual code-review for memory writes |
| `policy-drift-watch.py` | Path-list specific to source project | None — projects implement their own drift watch via `hook-config.yml: memory_protected_paths` |
| `claude-mem-watch.py` | Tied to Claude-Mem plug-in (third-party) | None — Claude-Mem users can install the plug-in's own hook |
| `wiki-*` hooks (5) | Tied to source project wiki layout | None — projects bring their own wiki conventions |
| `domain-uncertainty-check.py` | Domain-output uncertainty enforcement | Define via `hook-config.yml: risk_areas[id=domain-output]` |
| `rate-limit-check.py` | Project-specific Edge Function inventory | Project implements rate-limit check |
| `fk-type-precheck.py` | Project DB FK type drift | Project DB-specific |
| `route-change-guard.py` | Project router path list | Project routing-specific |
| `record-*` hooks (4) | Project telemetry — easy to adapt | Generic broadcast via `agent-session.sh broadcast` |
| `classify-prompt.py` | Plan-tier classifier — generic but config-coupled | Manual tier classification by user |
| `broadcast-on-bash.py` | Auto-broadcast Bash decisions to work-feed | Manual `agent-session.sh broadcast` calls |
| `token-budget-track.py` | Token usage telemetry | None — AI runtimes typically expose this natively |
| `admin-merge-track.py` | PR admin-merge evidence sink | None — use `gh pr view` for audit |
| `supervisor-goal-*.py` (3) | Goal-mode TUI / heartbeat / budget | None — manual goal tracking |

## Adding your own hook

1. Write a reproduce test in `core/tests/<hook-name>-test.sh` (must fail before you implement).
2. Implement the hook script following the canonical protocol.
3. Register it in the relevant adapter's `settings.template` under the right matcher.
4. Run adapter parity smoke test: `bash core/tests/adapter-parity.sh`.
5. Add the row to this README.

## Pass-through hooks

The default for many of these hooks is pass-through (no decision needed). The protocol contract: **empty stdout = allow**. Do NOT write `null`, `{}`, or the raw input — some AI runtimes will fail validation.

```python
# correct
sys.exit(0)

# WRONG — produces validation errors
print("null")
print(json.dumps({}))
```

See `docs/hook-protocol.md` § 3 for the full contract.
