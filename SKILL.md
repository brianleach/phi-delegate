---
name: phi-delegate
description: Delegate work that may touch PHI or PII (database queries, patient data fixes, HIPAA-scoped debugging) to an isolated headless Claude Code session authenticated with a BAA/zero-data-retention Anthropic API key, so no protected data enters this subscription session. Use when the user says "delegate to phi", "this touches PHI", "run this in the ZDR session", "HIPAA task", "patient data", or asks to query or modify production health data.
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

## Hard rules (non-negotiable)

1. Never read, cat, grep, tail, open, or glob anything under
   `.phi-worktrees/`. That includes `*.log`, `*.handoff.md`, and the
   worktree directories. `collect.sh` and `delegate.sh` are the only way
   to learn about a delegate's result. A guard hook enforces this when
   installed; obey it even when it is not.
2. Never run `collect.sh --full-diff`. Full diffs are for the human.
3. Never put PHI in a task spec. Refer to records by opaque references
   the delegate can resolve itself ("the record whose ID the user placed
   in the Private input section", "rows failing the check in
   scripts/audit.sql"). If you need the user to supply an identifier,
   leave a `## Private input` section with placeholder text and tell the
   user to fill it in with their own editor. Never read the spec back
   after the user has edited it.
4. If the user pastes PHI into this conversation, stop, say so plainly,
   do not repeat it, and ask them to move it into the Private input
   section of a spec file instead. Continue only with the PHI-free parts.
5. Never query a database, run a script that prints records, or open a
   data file yourself when there is any chance it holds PHI. Delegate it.
6. Never quote, summarize, or paraphrase delegate output that arrived
   through any channel other than a clean phi-scan.
7. Fable and Mythos class models are not offered under ZDR; do not pass
   them with `--model`. Default is `claude-opus-5`.

## Protocol

### 1. Preflight

Run `scripts/check-env.sh`. If it exits nonzero, show the user its fix
instructions verbatim and stop. Do not fall back to doing the work here.

### 2. Plan and write task specs

Decompose the work. Each spec is a markdown file in
`.phi-tasks/<nn>-<slug>.md` (create the directory; it is runtime state).
The delegate sees only this file. Include:

- **Goal**: precise and self-contained.
- **Relevant files**: exact paths to read and modify.
- **Data access**: how to connect (env var names, not values), which
  tables or endpoints, and the guardrails (read-only unless the goal
  says otherwise, transactions, row limits, dry-run first).
- **Constraints and conventions**: distilled from the target repo's
  CLAUDE.md.
- **Definition of done** and **Verification**: exact test and lint
  commands; the delegate must run them.
- **Private input** (optional): an empty section for identifiers the
  human fills in themselves. Say so in your message to the user.
- **Handoff requirements**: remind the delegate the reviewer is not
  covered; the handoff must describe data in aggregate only.

### 3. Routing

Anything that reads or writes potentially protected data goes to the
delegate, regardless of difficulty. Pure code changes with no data
exposure may stay with you or Claude subagents as usual. State the
routing in your plan.

### 4. Delegate

```
scripts/delegate.sh .phi-tasks/01-fix-duplicate-visits.md [--pr] [--name x] [--model claude-sonnet-5]
```

Independent specs may run in parallel (distinct names). Dependent specs
run sequentially: delegate, review, merge, then delegate the next.
Timeout defaults to 30 minutes (`PHI_DELEGATE_TIMEOUT_SECS`).

Prefer `--pr` when the repo has a GitHub origin and `gh` is available.
The PR body carries only the scanned handoff and the diff scan, never
the spec or the transcript.

### 5. Review

You review with exactly three inputs, all printed by `delegate.sh` or
`scripts/collect.sh <name>`:

1. `diff --stat` (file names and line counts)
2. the phi-scan verdict for the committed diff
3. the handoff, shown only when its own scan is clean

Judge from those whether the delegate did what the spec asked and ran
verification. If the diff scan flagged content, say so: the branch may
carry PHI-shaped literals and must not be merged until a human confirms
it is safe (fixtures with fake data trigger this too).

**Human approval rule**: never merge without the human explicitly
approving that specific diff after reviewing it themselves (on the PR,
or with `collect.sh <name> --full-diff` in their own terminal). Your
recommendation is one of: merge, revise, or take a look yourself.

Then take one action:

- **Accept**: `scripts/collect.sh <name> --merge` after approval.
- **One revision round**: `scripts/collect.sh <name> --reject`, append
  `## Revision feedback` to the spec (PHI-free), delegate again.
- **Escalate**: if the second attempt also fails, reject and tell the
  human the task needs a covered person at the keyboard. Do not take it
  over yourself.

### 6. Commit and clean up

Follow the user's commit conventions (`/commit` if their setup requires
it). Never commit `.phi-tasks/` or `.phi-worktrees/`. After a task is
fully closed, remind the user that quarantined logs and handoffs remain
under `.phi-worktrees/` and should be deleted when no longer needed.
