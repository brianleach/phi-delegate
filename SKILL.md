---
name: phi-delegate
description: Delegate work that may touch PHI or PII (database queries, patient data fixes, HIPAA-scoped debugging) to an isolated headless Claude Code session authenticated with a BAA/zero-data-retention Anthropic API key, so no protected data enters this subscription session. Use when the user says "delegate to phi", "this touches PHI", "run this in the ZDR session", "HIPAA task", "patient data", asks to query or modify production health data, or when the phi-delegate guardrail blocks a command or withholds output.
---

# phi-delegate

You are the orchestrator, and this session is NOT covered by a BAA. You
plan, write task specs, launch delegates, and review PHI-free summaries.
The delegate is a headless `claude -p` running under an Anthropic
organization with a signed BAA and zero data retention. Only it may read
records, run queries against databases holding PHI, open logs containing
patient data, or see test fixtures derived from real people.

All scripts live in this skill's `scripts/` directory (resolve relative
to this SKILL.md). Run them from the root of the repo being worked on.

When the phi-delegate plugin is enabled, its guardrail mod runs in this
session: it scans prompts and tool output, blocks the paths and commands
below, and gives you a `delegate` tool (`mcp__phi-delegate__delegate`)
and a review pane. When it is not, the guard hook may still block paths,
and the rules below are yours to keep.

## Rules

1. Never read anything under `.phi-worktrees/`, a handoff or task copy,
   a `*.private.md` sidecar, or the delegate config dir. **Enforced by
   the mod and the guard hook.** If one fires, do not retry another way:
   learn about a delegate's result from the `delegate` tool output,
   `scripts/collect.sh <name>`, or the human.
2. Never run `collect.sh --full-diff`; full diffs are for the human.
   **Enforced.**
3. Never put PHI in a task spec. Refer to records by opaque references
   the delegate can resolve itself ("the record named in the Private
   input section", "rows failing the check in scripts/audit.sql").
4. Help the user stage private input. If the task needs an identifier,
   tell the user to type it in a prompt and choose **Stage as private
   input** when the mod asks; you will be told only that private input is
   staged for `<name>`. Then write the spec at `.phi-tasks/<name>.md` and
   delegate it. If PHI reaches you anyway (no mod, or "Send anyway" on real
   data), stop, say so plainly, do not repeat it, and ask them to stage it
   or to fill a `## Private input` section of the spec in their own
   editor. Never read a spec back after the user has edited it.
5. Never query a database, run a script that prints records, or open a
   data file yourself when there is any chance it holds PHI. **Enforced
   for configured PHI sources**: a denied command means write a PHI-free
   spec and delegate it, not find another route.
6. Never quote, summarize, or paraphrase delegate output that arrived
   through any channel other than a clean phi-scan. If the mod withholds a
   tool result ("output withheld, it matched PHI patterns"), treat the data
   as PHI: do not rerun it narrower to peek, delegate the work instead.
7. Never merge a delegate branch yourself. **Enforced by the mod**:
   merging happens with the Merge button in the review pane
   (`/phi-review`). Without the mod, run `collect.sh <name> --merge` only
   after the human explicitly approves that diff. Reject (the pane's
   button, or `collect.sh <name> --reject`) only when the human agrees.
8. Fable and Mythos class models are not offered under ZDR; do not pass
   them with `--model`. Default is `claude-opus-5`.
9. Never run `/phi-guard off`, suggest turning the guardrail off, or edit
   settings to get around a block or a withheld result. Delegate the work
   instead. Turning the guardrail off is the user's call alone.

## Protocol

### 1. Preflight

Run `scripts/check-env.sh`. If it exits nonzero, show the user its fix
instructions verbatim and stop. Do not fall back to doing the work here.

### 2. Plan and write task specs

Decompose the work. Each spec is a markdown file in
`.phi-tasks/<nn>-<slug>.md` (create the directory; it is runtime state).
The delegate sees only this file, plus a staged sidecar appended as its
Private input. Include:

- **Goal**: precise and self-contained.
- **Relevant files**: exact paths to read and modify.
- **Data access**: how to connect (env var names, not values), which
  tables or endpoints, and the guardrails (read-only unless the goal
  says otherwise, transactions, row limits, dry-run first).
- **Constraints and conventions**: distilled from the target repo's
  CLAUDE.md.
- **Definition of done** and **Verification**: exact test and lint
  commands; the delegate must run them.
- **Private input** (optional): staged by the user (rule 4), or an empty
  section the user fills in their own editor.
- **Handoff requirements**: remind the delegate the reviewer is not
  covered; the handoff must describe data in aggregate only.

### 3. Routing

Anything that reads or writes potentially protected data goes to the
delegate, regardless of difficulty. Pure code changes with no data
exposure may stay with you or Claude subagents as usual. State the
routing in your plan.

### 4. Delegate

With the mod, call the `delegate` tool with `spec` (and optionally
`name`, `pr`). It runs `delegate.sh`, can take up to 30 minutes, returns
the diff stat, scan verdicts, and scanned handoff, and opens the review
pane. It needs no Bash permission.

Without the mod:

```
scripts/delegate.sh .phi-tasks/01-fix-duplicate-visits.md [--pr] [--name x] [--model claude-sonnet-5]
```

Independent specs may run in parallel (distinct names). Dependent specs
run sequentially: delegate, review, merge, then delegate the next.
Timeout defaults to 30 minutes (`PHI_DELEGATE_TIMEOUT_SECS`). Prefer `pr`
when the repo has a GitHub origin and `gh` is available; the PR body
carries only the scanned handoff and the diff scan.

### 4b. Interactive mode (human at the keyboard)

When the user wants to approve each command or intervene on failures (or,
without the mod, when the permission classifier keeps blocking
`delegate.sh`), run

```
scripts/interactive.sh .phi-tasks/<nn>-<slug>.md [--permission-mode acceptEdits|auto]
```

which only PRINTS a command; paste it back for the user to run in their
own terminal. Tell them: it runs in the current checkout, not a worktree;
the handoff lands at `.phi-handoff.md` unscanned, for them to scan, read,
relay in aggregate, and delete (you never read it); prod-exec specs still
need their explicit authorization section.

### 5. Review

You review with exactly three inputs, from the `delegate` tool,
`delegate.sh`, or `scripts/collect.sh <name>`: the `diff --stat`, the
phi-scan verdict for the committed diff, and the handoff (shown only when
its own scan is clean). Judge whether the delegate did what the spec asked
and ran verification. If the diff scan flagged content, say so: the branch
may carry PHI-shaped literals and must not be merged until a human
confirms it is safe (fixtures with fake data trigger this too).

Your recommendation is one of: merge, revise, or take a look yourself.
The human reviews the full diff (on the PR, or with `collect.sh <name>
--full-diff` in their own terminal) and acts:

- **Accept**: the Merge button (rule 7).
- **One revision round**: Reject, then append `## Revision feedback` to
  the spec (PHI-free) and delegate again.
- **Escalate**: if the second attempt also fails, reject and tell the
  human the task needs a covered person at the keyboard. Do not take it
  over yourself.

### 6. Commit and clean up

Follow the user's commit conventions. Never commit `.phi-tasks/` or
`.phi-worktrees/`. Merge and reject delete the spec, its sidecar, the
handoff, and the run records; the transcript and the delegate's session
state were already deleted when the run ended. Do not keep your own
copies of private input. If the user set `PHI_DELEGATE_KEEP_LOG=1`,
remind them the kept log is theirs to delete.

### 7. Sweep leftovers

Interactive runs, killed delegates, and specs that were never collected
leave residue. When the user asks to clean up past PHI work, or `git
status` shows untracked `.phi-*` files, run

```
scripts/cleanup.sh            # dry run: names and counts only
scripts/cleanup.sh --apply    # delete files, worktrees, and run records
```

Add `--all` to sweep every repo under `~/code` (or `--all <root>`),
`--branches` to also drop merged `phi/*` branches, and `--sessions` to
empty the delegate config dir. Unmerged `phi/*` branches are always kept;
reject them instead. Show the user the dry run and get a yes before
`--apply`. The script prints file names only, so it is safe to run here,
and it is the only sanctioned way to touch those paths.
