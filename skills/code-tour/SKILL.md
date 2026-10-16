---
name: code-tour
description: Write a human reading path through a codebase or a just-finished build — one tour file with the stack, file-role rules, an ordered reading path along one real user-visible flow, safe hands-on experiments, run steps and a glossary, every path cited and checked. The source tree is never modified. NOT for adding comments to source files (the tour lives outside the code), NOT a code review or completion check (that is code-reviewer / /verify-completion), and NOT the org-wide repo onboarding guide (that is ONBOARDING.md).
when_to_use: After /supervise or any large build when a human must understand what was produced, when picking up an unfamiliar stack or repo, or when handing a project to a teammate — "make a code tour", "how do I read this codebase", "reading order for this build", or `/code-tour [path|range] [--audience self|teammate|non-dev] [--out <file>]`.
tools: Read, Grep, Glob, Bash, Write
---

# /code-tour

## Goal

Generated code is only leverage if a human can read it. This skill writes one
**tour**: a file a person follows top to bottom to learn where things live, how
one real flow travels through the code, and what they can safely change to see
it react. The tour is a map. It never edits the code it describes, and every
path in it must exist.

Arguments:
- target — repo root (default), a sub-directory, or a git range (`<base>..HEAD`)
  to tour only what a build changed.
- `--audience` — `self` (default: terse, assumes a developer), `teammate`
  (adds the why behind stack choices), `non-dev` (every term in the glossary,
  no unexplained command).
- `--out` — default `<project>/docs/TOUR.md`.

## Steps

### 1. Identify the stack

Read the manifests that exist (`package.json`, `pyproject.toml`,
`Package.swift`, `go.mod`, `Cargo.toml`, …), the framework config files and
the README. For a range target, read `git diff --stat <range>` first. Note the
start time (`date '+%Y-%m-%d %H:%M:%S'`) for the untouched-tree check in step 7.

Done when: the language, framework, runtime, data store and deploy target are
each stated with the file:line they come from, as `none (no <config file>)`
when the project has none, or as `unknown`.

### 2. Derive the file-role rules

Find the 3–6 rules a reader needs to place any file, such as
"`app/**/page.tsx` is a screen and its folder path is the URL",
"`app/api/**/route.ts` is a server endpoint", or
"`supabase/migrations/*.sql` is an ordered schema change". Use CodeGraph when
`.codegraph/` exists, otherwise serena or Glob/Grep. Name folders the reader
should skip, such as dependency or build-output folders.

Done when: the rules form a table `rule | glob | matching files`, and every
glob matches at least one real file.

### 3. Trace one flow

Pick the most important user-visible flow (for a range target, the flow the
change serves) and follow it from entry to storage: screen → client state →
endpoint → domain logic → database or external service. A project without
some layer (a front-end-only app has no endpoint) stops at its last real layer
and says which layers do not exist. Write at most 12 reading steps. Each step
gives:

- the file and line range to open,
- what to look for in it (one sentence),
- a question the reader should be able to answer afterwards,
- how it connects to the next step: the import plus the call or component use
  (`<GlobeView />` counts) that links them, both cited.

Done when: each cited line range was re-opened and still shows what the step
says, and each step's link to the next is a real import or call, not an
inferred one.

### 4. Add hands-on experiments

Give 1–3 safe experiments: one visible edit (copy text, a color token, a list
item in seed or demo data), where to see the effect, and how to undo it.
Experiments stay outside auth, secret, billing, payment and migration paths. If
nothing visible can change safely, say so instead of inventing one.

Done when: each experiment names the exact line to change, the URL or command
that shows the result, what it will NOT change when a similar-looking value
lives elsewhere, and the revert step (the original value when the project has
no Git).

### 5. Write run steps

Copy only commands that exist in the repo (package scripts, Makefile targets,
README). List prerequisites with the command that checks each one (for
example `node -v`). Name required environment variables by key only and never
copy values out of `.env*` files. For a missing variable, describe what
happens (demo mode, crash) only if the code shows it, with the cite. When the
project needs no variables, say so and cite the search that found none.

Done when: every command traces to a repo file, and no secret value appears.

### 6. Build the glossary

Define each term the tour uses that the audience may not know, one line each,
in this project's terms ("slug = the `[slug]` URL segment that selects a book in
`books.ts`"). For `non-dev`, include every framework and file-type term on the
path.

Done when: every term in the glossary appears in the tour, and every
non-obvious term the tour uses is defined for its audience.

### 7. Write and check

Sections in order: Stack · File roles · Reading path · Experiments · Run ·
Glossary · Not covered. Keep these English headings; a tour in another
language may add a translation after each. Under "Not covered", list the areas
the tour skipped. If `--out` already exists, show the diff and ask before
overwriting.

Then, from the project root, check every path and line the tour cites. The
check reads single-token code spans only, so commands with spaces and URLs are
skipped by design:

```bash
grep -oE '`[^` ]+`' <out> | tr -d '`' | grep -v '://' | grep '/' \
  | grep -v '[*<{]' | sort -u | while read -r ref; do
    p=${ref%%:*}; l=${ref#"$p"}; l=${l#:}; l=${l%%[-–]*}
    [ -e "$p" ] || { echo "MISSING $ref"; continue; }
    case $l in ''|*[!0-9]*) ;;
      *) [ "$l" -le "$(wc -l < "$p")" ] || echo "BAD-LINE $ref" ;; esac
  done
```

Then confirm the tree is untouched: in a Git repo, `git status --short` lists
nothing but a tour file inside the repo; otherwise
`find . -type f -newermt "<start time>" -not -path './node_modules/*'` lists
nothing but that file.

Done when: the path check prints nothing and the untouched-tree check passes.
Re-run the path check after any later edit to the tour.

## Rules

- The source tree stays untouched; the tour file is the only write.
- Cite, don't recall: a claim about the code carries the path:line it came from.
- One flow traced deeply beats every module listed shallowly. Breadth goes in
  "File roles" and "Not covered".
