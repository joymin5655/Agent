# Evidence-First (verify before you assert)

The harness is opinionated about session coordination, secret hygiene, and
policy enforcement — but until now it said nothing about the failure that
underlies most bad routing and bad advice: **asserting the current state of the
world from memory instead of from a fresh read.** This rule closes that gap.

A dispatch that names a specialist who does not exist, an "it's a cache drift"
diagnosis offered before any file was opened, a "that path is safe" claim with
no scan behind it — these are the same mistake wearing different hats. The fix
is one habit: *a claim about present state must be backed by evidence gathered
in the same turn, or it must be labelled a guess.*

## The rule

1. **State claims need a same-turn read.** Any assertion about what currently
   exists — a file's contents, a tool/agent's availability, a version, a
   registry entry, a config value, whether a path is guarded — must be grounded
   in a tool result from *this* turn (Read, Grep, Glob, a command, a registry
   load). Training-data recall and "I remember this repo" do not count.

2. **If you can't verify, say "guess" out loud.** When a read isn't possible
   (cost, access, time), the claim ships with an explicit hedge — "I haven't
   confirmed, but likely…" — never as fact. The reader must be able to tell
   verified state from inference at a glance.

3. **Never demand a provider you haven't confirmed exists.** Before a hook,
   prompt, or plan requires dispatching an agent / calling a tool / running a
   script, confirm the provider is real *and reachable in this runtime*. A
   requirement that names a phantom is worse than no requirement: it deadlocks —
   the gate blocks the work, and the thing that would unblock it can't be
   invoked. (This is exactly the ghost-specialist deadlock `agent-inventory.py`
   and the supervisor's ghost-fallback exist to prevent.)

4. **Prefer the cheapest disconfirming check.** One `ls`, one registry load, one
   `grep` is almost always cheaper than a wrong assertion and the rework it
   triggers. Reach for the check that could prove you *wrong*, not the one that
   flatters your first guess.

## Why it's a rule and not just advice

The 218-event routing audit (see `rules/policy/specialist-routing.md`) is the
same lesson from the dispatch side: advisory hints get ignored ~98% of the time,
so the harness *enforces* routing rather than suggesting it. Evidence-first is
the read-side twin. It is enforced two ways:

- **At session start** — `core/hooks/agent-inventory.py` reconciles the active
  registry against the agent `*.md` providers actually present, writes the truth
  to `.agent/state/agent-inventory.json`, and quarantines any entry with no
  provider. Nothing downstream can demand a ghost.
- **At dispatch time** — `core/hooks/supervisor.py` refuses to `ask` for a
  specialist that isn't a real, in-session provider (ghost-fallback), now also
  honouring the inventory quarantine set.

The CI drift guard (`core/tests/registry-drift.sh`, check 4) enforces the same
invariant for the shipped repo: every registry id must have a matching
`agents/<id>.md`. Evidence-first extends that guarantee from build time to every
consumer session — including project registry overrides that CI never sees.

## Quick test

Before you write a sentence that describes the current state of the system, ask:
*"What did I read, this turn, that makes this true?"* If the answer is "nothing,"
either read it or mark it a guess.
