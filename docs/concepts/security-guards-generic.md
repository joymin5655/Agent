# Concept — Project Risk Areas (Generic Security Guards)

6 layers of defense against destructive AI actions. Each layer is independent — bypass one, others still trip.

See [`../../rules/policy/security-guards.md`](../../rules/policy/security-guards.md) for the rule definitions.

---

## The 6 layers

```
1. gitleaks (pre-commit)        ← catches secrets in staged changes
   ↓ if bypassed
2. CI workflow (post-push)      ← catches secrets in pushed commits
   ↓ if bypassed
3. AI hook chain (PreToolUse)   ← catches secret READS / writes / risky commands
   ↓ if bypassed
4. Skill / wrap step            ← human-in-loop pre-merge check
   ↓ if bypassed
5. Policy doc                   ← documented rules for risk areas
   ↓ if bypassed
6. Pre-push hook                ← catches secret diffs at push time
```

Each layer covers different bypass paths. The most common bypass paths the framework defends against:

| Bypass attempt | Caught by |
|---|---|
| Hardcoded `AWS_SECRET=AKIA...` in `.env` | Layer 1 (gitleaks at commit) |
| Same, committed with `--no-verify` | Layer 2 (CI) + Layer 6 (pre-push) |
| Bash `cat secrets/db.env` | Layer 3 (pre-tool-guard hook) |
| Python `open("secrets/x")` written to a file | Layer 3 (secret-content-scan hook) |
| Direct `psql production` migration | Layer 3 (r4-mutex-check hook) |
| MCP `apply_migration` for production | Layer 3 (r4-mutex-check hook on MCP tool) |
| Writing JWT literal in a markdown doc | Layer 3 (secret-content-scan on Write/Edit) |
| MCP `firecrawl_scrape` with URL containing `sk-...` | Layer 3 (secret-content-scan on MCP) |

---

## What's a "Risk Area"?

A risk area is a category of operation that should NEVER happen automatically — always require human confirmation OR be blocked outright.

The framework defines 5 default risk areas (each project can customize):

| # | Default ID | What it covers | Default decision |
|---|---|---|---|
| 1 | data | DB migrations, direct SQL on production | `ask` (require confirmation) |
| 2 | secrets | `secrets/`, `.env*`, hardcoded credentials | `deny` (block always) |
| 3 | deploy | Server-side function/lambda deploys | `ask` |
| 4 | payment | Live billing / Stripe / Polar / IAP code | `ask` |
| 5 | domain-output | User-facing forecast/prediction outputs (must include uncertainty) | `ask` |

You define your own in `hook-config.yml`. See [`../customization.md`](../customization.md).

---

## Why "ask" vs "deny"?

- **`deny`** — never appropriate for an automated action. Force user to use another mechanism (e.g., a manual `kubectl` command, NOT through the AI).
- **`ask`** — risky but legitimate. AI surfaces it, user confirms. Audit trail in transcript.

Layer 3 hooks return whichever decision your `hook-config.yml` specifies per risk area.

---

## Why 6 layers?

Single-layer defense fails. Examples from real incidents:

- **gitleaks-only** — bypassed by `--no-verify` or branch protection misconfig
- **CI-only** — secret already in commit history when CI fires
- **Hook-only** — fails if hook timeouts / misconfigured
- **Policy doc-only** — doc rot; not enforced

The 6 layers stack defense in depth. Layers 1-2 catch most. Layer 3 catches what they miss. Layer 4 catches workflow-level mistakes. Layer 5 is the human policy that wraps all of them. Layer 6 catches secret diffs at push time as a final backstop.

---

## How to extend

`risk_areas:` in `hook-config.yml` is declarative — a documented record of
your project's policy shape. Today, `pre-tool-guard.sh` matches against
patterns hardcoded in the script itself, not a dynamic read of this file.
To add a project-specific risk area, fork `pre-tool-guard.sh` and add your
pattern there; keep the corresponding `risk_areas:` entry as a record of
intent:

```yaml
# hook-config.yml — documents intent; pre-tool-guard.sh itself must be
# forked to actually enforce it (see docs/customization.md)
risk_areas:
  - id: legacy-system-api
    description: "Calls to the deprecated legacy API"
    paths: ["src/lib/legacy-client/**"]
    commands: ["curl .*legacy.internal"]
    decision: ask
```

The one mechanism that *is* dynamically loaded per project — no fork
required — is the secret-scan pattern extension via `.agent/hook-config.yml`.
See [`../customization.md`](../customization.md) for the full
real-vs-documented split.

---

## Cross-AI parity

All 3 adapters (Claude / Codex / Gemini) must enforce risk areas identically. The cross-AI parity test verifies:

```bash
echo '{"ai":"claude-code", ...secrets/db.env...}' | claude-code-adapter pre-tool-guard
# expect: {"permissionDecision":"deny", ...}

echo '{"ai":"codex", ...secrets/db.env...}' | codex-adapter pre-tool-guard
# expect: same denial

echo '{"ai":"gemini", ...secrets/db.env...}' | gemini-adapter pre-tool-guard
# expect: same denial
```

---

## See also

- [`../../rules/policy/security-guards.md`](../../rules/policy/security-guards.md) — canonical 6-layer rule
- [`../../rules/public-repo.md`](../../rules/public-repo.md) — git safety guardrails
- [`../../core/hooks/secret-content-scan.py`](../../core/hooks/secret-content-scan.py) — secret pattern scanner
- [`../../core/hooks/pre-tool-guard.sh`](../../core/hooks/pre-tool-guard.sh) — primary Bash/Write hook
- [`../../core/hooks/r4-mutex-check.sh`](../../core/hooks/r4-mutex-check.sh) — risk-area resource mutex
- [`../customization.md`](../customization.md) — how to define your own risk areas
