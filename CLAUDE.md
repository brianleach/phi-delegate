# phi-delegate

A Claude Code plugin for HIPAA-covered work: an always-on guardrail mod in
the interactive session (a consumer subscription login, not covered by a
BAA), plus a covered lane that delegates anything that could touch PHI to
a headless `claude -p` session authenticated with an API key from an
Anthropic organization that has a signed BAA and zero data retention.
Nothing the delegate sees comes back to the orchestrator except a
PHI-scanned handoff summary and file names.

## Repo layout

- `.claude-plugin/plugin.json` - the plugin manifest (skill, mod, guard
  hook, `userConfig` options); `marketplace.json` lists it at `./` so the
  repo is its own local marketplace
- `SKILL.md` - the skill definition, loaded as the plugin's single root
  skill (or symlinked into `~/.claude/skills/phi-delegate` by install.sh)
- `hooks/`
  - `hooks.json` - names the mod's module and registers guard-hook.sh as a
    PreToolUse settings hook, the fallback where mods do not run
  - `register.tsx` - the mod: stand-down in covered sessions, the guard
    port, PHI-source denies, prompt interception and private input
    staging, output scrubbing, the `delegate` tool, the review pane, and
    the status line
  - `guard.ts` - the mod's pure guard rules
  - `scan.ts` - the mod's port of phi-scan.sh
  - `patterns.generated.ts` - generated copy of scripts/phi-patterns.tsv
- `types/index.d.ts` - the mod's `$.state` contract
- `scripts/`
  - `check-env.sh` - preflight: CLI, ZDR key and attestation, config dir
    isolation, guard hook, API auth, smoke test
  - `phi-claude.sh` - wrapper that runs claude with the ZDR key, its own
    CLAUDE_CONFIG_DIR, no MCP, no web tools, no telemetry
  - `load-env.sh` - sourced helper filling PHI_DELEGATE_* from the
    gitignored .env (environment wins)
  - `delegate.sh` - run a task spec in an isolated worktree; prints only
    diff --stat, scan results, and a clean handoff
  - `collect.sh` - stat/scan/merge/reject a finished worktree
  - `interactive.sh` - print (or with --run, exec) the command for an
    interactive ZDR session on a spec, for a human who wants permission
    prompts; the handoff is not scanned or collected
  - `cleanup.sh` - sweep leftover handoffs, specs, worktrees, run
    records, merged phi/* branches, and session state; dry run by
    default, names and counts only
  - `phi-scan.sh` - heuristic PHI tripwire; reports counts, never text
  - `phi-patterns.tsv` - the one pattern source for phi-scan.sh and the mod
  - `gen-mod-data.sh` - writes the TypeScript copies of the patterns and
    fixtures; `--check` fails on drift
  - `guard-hook.sh` - PreToolUse hook for the orchestrator that blocks
    access to `.phi-worktrees/`, handoff copies, `*.private.md` sidecars,
    and `--full-diff`; stands down when PHI_DELEGATE_SESSION=1
- `install.sh` - skill-only install: symlinks the skill; `--with-guard`
  also registers the hook in user settings
- `tests/` - bats suite, offline; `tests/mod/` holds the mod's
  `claude plugin test` files, including the scanner parity test

## Conventions

- Bash scripts use `set -euo pipefail` and must be shellcheck clean.
- This repo is public. Examples, defaults, and test data stay generic
  (example.invalid, synthetic identifiers); no organization or project
  names.
- Edit patterns only in `scripts/phi-patterns.tsv`, then run
  `scripts/gen-mod-data.sh`. Regexes must mean the same thing to
  `grep -E` and JavaScript; the parity test checks every fixture.
- The plugin is the documented install path; install.sh and the
  skill-only flow must keep working unchanged. The mod adds behavior and
  never removes a script flag or output line.
- Mod hooks fail closed: every gating `tool.call` and `prompt.submit` hook
  has a `.catch` that denies or drops. A mod's nested `tool.call` hooks
  are answered by the outermost one's `.catch`, so those never replay
  `next(e)`. Functions that take `$` are declared at the module's top
  level, where `claude plugin validate` can trace them.
- The mod and guard-hook.sh do nothing when PHI_DELEGATE_SESSION=1, which
  phi-claude.sh exports for the delegate; managed mods load there too.
- Private input staged by the mod lives in `.phi-tasks/<name>.private.md`
  (mode 600) and is deleted with its spec; nothing but the task name
  reaches the model.
- No em dashes anywhere in generated docs. Use hyphens, commas, or colons.
- Never write API keys, PHI, or absolute home paths into committed files.
- Runtime state lives under `.phi-worktrees/` (worktrees, clean
  handoffs, run records) and `.phi-tasks/` (task specs) in the target
  repo. Both are gitignored there via `.git/info/exclude` and must stay
  that way.
- Leave no PHI on disk: transcripts and the per-run CLAUDE_CONFIG_DIR are
  deleted when a run ends, flagged handoffs are deleted unread, and
  merge/reject deletes the spec, handoff, and records (`secure_rm`, best
  effort). Any new artifact must follow the same rule.
- The guard hook and the mod's guard exempt calls that target this repo's
  own resolved path so the plugin can be developed from an orchestrator
  session.
- Default model is `claude-opus-5`. Fable and Mythos class models are
  refused because they are not offered under zero data retention.
- The delegate reaches Anthropic only through per-invocation environment
  variables set by `phi-claude.sh`, with `CLAUDE_CONFIG_DIR` pointed at
  `$HOME/.phi-delegate/claude`. Never touch `~/.claude/settings.json`
  except through `install.sh --with-guard`.
- Secrets come from the environment or the gitignored `.env` at this
  repo's root. The key variable is `PHI_DELEGATE_API_KEY`, never
  `ANTHROPIC_API_KEY`, so it cannot be confused with a non-ZDR key.
- Delegate sessions use `--permission-mode acceptEdits --allowedTools Bash
  --strict-mcp-config --disallowedTools WebSearch,WebFetch`, never
  `--dangerously-skip-permissions`.
- Anything printed to the orchestrator's stdout must pass through
  `phi-scan.sh` first or be structurally PHI-free (file names, counts).
- AGENTS.md is a symlink to this file. Edit CLAUDE.md only.
