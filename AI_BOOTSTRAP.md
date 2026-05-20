# AI Workspace Bootstrap (Required for ALL Agents)

> **CRITICAL DIRECTIVE:** If you are an AI agent (Gemini, Codex, Claude, etc.) reading this file, you MUST follow these initialization steps BEFORE executing any code modifications, running commands, or providing architectural advice.

This project uses a highly structured multi-agent harness. You are entering a shared workspace where strict rules prevent collisions and ensure security.

## Step 1: Establish Core Context
You must immediately read and internalize the project's Single Source of Truth (SOT) for rules:
- **READ:** `.claude/rules/OVERVIEW.md`
  - This file contains the index for critical rules. If your task touches on any domain listed there (e.g., security, deployment, external plugins), you MUST read the corresponding detailed file in `.claude/rules/`.

## Step 2: Establish Agent-Specific Context
Based on your identity, read your specific configuration:
- If you are **Gemini**: READ `GEMINI.md`
- If you are **Claude** or **Codex**: READ `CLAUDE.md`

## Step 3: Load Appropriate Skills
This repository uses extracted knowledge skills.
- **SCAN:** List the contents of `.omc/skills/`.
- If your assigned task matches the trigger keywords of any skill file, READ that skill file before proceeding.

## Step 4: Multi-Agent Safety Pledge
Acknowledge the following constraints internally:
1. **Never use blind line-number replacements.** All file edits must be anchored by exact string matching or content hashes (The Harness Problem).
2. **Never attempt full automation in Guarded Domains** (Production DB, Secrets, Edge Fn Deploy, Payment, ML Uncertainty).
3. **Respect Worktree Isolation.** Do not modify files currently locked by other agents (check `.claude/locks/` if instructed).

---
*Proceed with your task only after acknowledging and loading the context from Steps 1-3.*