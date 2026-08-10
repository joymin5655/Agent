# See the harness catch things — 3 reproducible scenarios

Every scenario below runs against a plain clone in under a minute, with no AI
runtime attached — the gates are ordinary scripts, so you can watch them decide
before you ever wire them into Claude Code / Codex / Gemini. Outputs shown are
real, captured from these exact commands.

Prereqs: a clone of this repo, `bash`, `python3`. Run everything from the repo
root.

---

## 1. A secret read gets denied at the tool boundary

`core/hooks/pre-tool-guard.sh` is the PreToolUse gate every adapter routes
shell commands through. Feed it the canonical event JSON for a `secrets/` read
— the same JSON your AI runtime would send:

```bash
echo '{"ai":"claude","event":"PreToolUse","tool_name":"Bash",
      "tool_input":{"command":"cat secrets/api-key.txt"}}' \
  | bash core/hooks/pre-tool-guard.sh
```

Decision (deny, with a teaching message — WHY it fired, FIX to self-correct):

```
Direct secrets/ access blocked (Risk Area #2: secrets).
WHY: reading secret files into a session exposes plaintext credentials to logs and transcripts.
FIX: use environment variables read by your server-side code; for inventory, list key NAMES only (awk -F= on the env file, first field).
```

Same script, same decision, under all three AI CLIs — that parity is what
`core/tests/adapter-parity.sh` machine-proves.

## 2. A false "done" claim gets REFUTED

An agent claims the work is complete; nothing it cites actually exists. The
deterministic verifier (`core/infra/completion-verify.py`, Layer 1 of
`/verify-completion`) re-checks the claim in a separate context:

```bash
SCRATCH=$(mktemp -d)
cat > "$SCRATCH/claim.json" <<'EOF'
{
  "claim": {
    "summary": "Implemented the parser and its tests; all green.",
    "files": [{"path": "src/parser.py", "contains": "def parse"}],
    "tests": ["python3 -m pytest tests/ -q"]
  }
}
EOF
python3 core/infra/completion-verify.py --root "$SCRATCH" "$SCRATCH/claim.json"
```

Verdict (exit code 1 — usable as a CI or wave gate):

```json
{"verdict": "REFUTED", "score": 0.0,
 "target": "Implemented the parser and its tests; all green.",
 "dimensions": {"files": {"passed": 0, "total": 1},
                "tests": {"passed": 0, "total": 1},
                "assertions": {"passed": 0, "total": 0}},
 "refutations": ["file does not exist: src/parser.py",
                 "test did not pass: python3 -m pytest tests/ -q"],
 "schema_version": "1.0.0"}
```

Refute-by-default: a malformed claim, a missing file, a crashed judge — every
ambiguous path resolves to REFUTED, never to a quiet CONFIRMED. The semantic
judge on top (Layer 2) follows the same rule.

## 3. Planted PII / domain taint fails the sanitize gate

The sanitize gate blocks prior-project taint **and machine-identity PII**
(real home paths, device hostnames — `rules/public-repo.md`
§ Machine-identity PII). Plant a fake home path in an untracked file — the
forbidden string is assembled at runtime here so this doc itself stays clean:

```bash
P="/Us"; printf 'backup at %sers/demo-user/project\n' "$P" > scratch-note.md
bash core/tests/sanitize-audit.sh
```

```
FAIL — taint detected in files outside legacy/:
  scratch-note.md
```

Clean up and it goes green again:

```bash
rm scratch-note.md && bash core/tests/sanitize-audit.sh
```

```
PASS — no taint detected (scope: tracked + untracked-unignored; excluded legacy/, self, ci.yml)
```

CI runs the same script plus a `--range` scan over every PR commit, so a token
added in one commit and removed in the next still fails the build.

---

## Recording a demo GIF (maintainers)

The three scenarios above are the intended on-camera moments. To record:

```bash
# asciinema (terminal cast, then convert)
brew install asciinema agg
asciinema rec demo.cast    # run scenario 1-3, exit
agg demo.cast demo.gif     # or: agg --theme monokai --font-size 16

# alternative: VHS (scripted, reproducible)
brew install vhs           # write a .tape script driving the same commands
```

Keep the cast under 60 seconds; lead with scenario 2 (the false-"done" catch)
— it is the differentiator. Commit the GIF under a new `docs/assets/`
directory and link it from the README hero section.
