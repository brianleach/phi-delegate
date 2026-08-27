# phi-delegate

A Claude Code skill for HIPAA-covered engineering work. Your everyday
Claude Code session runs on a consumer subscription login that is not
covered by a BAA. This skill lets that session keep planning and
reviewing while anything that could touch protected health information
runs in a separate, headless `claude -p` process authenticated with an
API key from an Anthropic organization that has a signed BAA and zero
data retention (ZDR) enabled.

Nothing the delegate reads or writes comes back to the orchestrator
except a PHI-scanned handoff summary, `git diff --stat`, and a scan
verdict for the committed diff. You never have to log out of your
subscription to do PHI work.

## How isolation works

| Layer | Mechanism |
|---|---|
| Credentials | Delegate runs with `ANTHROPIC_API_KEY` set to `PHI_DELEGATE_API_KEY` only for that process. Every other credential (OAuth token, auth token, Bedrock/Vertex/Foundry switches, WIF, profiles) is unset. |
| Config | Delegate uses its own `CLAUDE_CONFIG_DIR` (`~/.phi-delegate/claude`), so it never sees `~/.claude` settings, hooks, or the subscription login. Runs fail if an OAuth login appears there. |
| Endpoint | `ANTHROPIC_BASE_URL` is forced to `https://api.anthropic.com` via both the environment and `--settings`, which outranks the target repo's `.claude/settings.json`. |
| Egress | `--strict-mcp-config` disables every MCP server; `WebSearch` and `WebFetch` are disallowed; telemetry and error reporting are off. |
| Model | Default `claude-opus-5`. Fable and Mythos class models are refused because they are not offered under ZDR. |
| Output | Raw transcript is written to `.phi-worktrees/<name>.log` (mode 600) and never printed. The delegate writes a handoff that is moved out of the tree, scanned by `phi-scan.sh`, and shown only when clean. |
| Orchestrator | `SKILL.md` forbids reading delegate artifacts. `install.sh --with-guard` adds a PreToolUse hook that mechanically blocks Read/Bash/Grep/Glob calls referencing `.phi-worktrees/`, handoff copies, or `--full-diff`. |
| Specs | Specs must be PHI-free. A `## Private input` section is filled by the human in their own editor; the orchestrator never reads it back. |

`phi-scan.sh` is a tripwire (SSN, phone, email, date, MRN and DOB
keywords, addresses, long digit runs). It reports counts only. It is not a
substitute for the delegate following its handoff instructions or for the
human reviewing the full diff.

## Requirements

- Claude Code CLI 2.1 or newer
- An Anthropic API key from an organization with a BAA and ZDR enabled
- `git`, `bash`, `curl`; `gh` for `--pr`; `node` for `install.sh --with-guard`

## Install

```bash
git clone https://github.com/brianleach/phi-delegate ~/code/phi-delegate
cd ~/code/phi-delegate
./install.sh --with-guard
cp .env.example .env    # then edit
scripts/check-env.sh
```

`.env` (gitignored):

```
PHI_DELEGATE_API_KEY=sk-ant-...
PHI_DELEGATE_ZDR_ATTESTED=1
# PHI_DELEGATE_MODEL=claude-opus-5
# PHI_DELEGATE_CONFIG_DIR=$HOME/.phi-delegate/claude
```

`PHI_DELEGATE_ZDR_ATTESTED=1` is a deliberate manual step: there is no API
that proves a key belongs to a ZDR org, so the operator confirms it in the
Console and attests. Runs refuse to start without it.

## Usage

In any repo, tell Claude Code "this touches PHI, delegate it" (or invoke
`/phi-delegate`). Claude will:

1. run `scripts/check-env.sh`
2. write a PHI-free spec to `.phi-tasks/<nn>-<slug>.md`, leaving a
   `## Private input` section for you when an identifier is needed
3. run `scripts/delegate.sh <spec> --pr`
4. show you the diff stat, scan verdicts, and the clean handoff
5. wait for you to review the full diff (on the PR, or
   `scripts/collect.sh <name> --full-diff` in your own terminal) and
   approve before `scripts/collect.sh <name> --merge`

Quarantined logs and handoffs stay under `.phi-worktrees/` until you
delete them.

## Compliance notes

This tool reduces the surface through which PHI can reach an uncovered
session; it does not by itself make a workflow HIPAA compliant. You still
need the BAA, ZDR enabled on the org, access controls on the databases the
delegate reaches, and human review of every change. Local artifacts under
`.phi-worktrees/` and the delegate's `CLAUDE_CONFIG_DIR` live on your
machine and fall under your device controls.

## Development

```bash
shellcheck scripts/*.sh install.sh tests/helpers.bash
bats tests/
```

## License

MIT
