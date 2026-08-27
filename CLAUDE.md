# phi-delegate

A Claude Code skill for HIPAA-covered work. The interactive Claude Code
session (a consumer subscription login, not covered by a BAA) plans work
and delegates anything that could touch PHI to a headless `claude -p`
session authenticated with an API key from an Anthropic organization that
has a signed BAA and zero data retention. Nothing the delegate sees comes
back to the orchestrator except a PHI-scanned handoff summary and file
names.

## Repo layout

- `SKILL.md` - the skill definition Claude Code loads (this repo is
  symlinked into `~/.claude/skills/phi-delegate`)
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
  - `phi-scan.sh` - heuristic PHI tripwire; reports counts, never text
  - `guard-hook.sh` - PreToolUse hook for the orchestrator that blocks
    access to `.phi-worktrees/`, handoff copies, and `--full-diff`
- `install.sh` - symlinks the skill; `--with-guard` also registers the hook
- `tests/` - bats suite, offline

## Conventions

- Bash scripts use `set -euo pipefail` and must be shellcheck clean.
- No em dashes anywhere in generated docs. Use hyphens, commas, or colons.
- Never write API keys, PHI, or absolute home paths into committed files.
- Runtime state lives under `.phi-worktrees/` (worktrees, quarantined
  logs, handoffs) and `.phi-tasks/` (task specs) in the target repo. Both
  are gitignored there via `.git/info/exclude` and must stay that way.
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
