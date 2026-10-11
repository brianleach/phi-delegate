# phi-delegate

An always-on PHI guardrail for Claude Code, plus a covered lane for the
work that has to touch protected health information.

Your everyday Claude Code session runs on a consumer subscription login
that is not covered by a BAA. phi-delegate is a Claude Code plugin with
three parts:

- **The guardrail mod** (always on): function hooks inside the session
  that scan what you type and what tools return, block reads of delegate
  artifacts and commands that reach known PHI sources, and give the model
  a `delegate` tool instead. It reports class names and counts, never the
  matched text.
- **The covered lane** (the `phi-delegate` skill and `scripts/`): anything
  that could touch PHI runs in a separate, headless `claude -p` process
  authenticated with an API key from an Anthropic organization that has a
  signed BAA and zero data retention (ZDR) enabled. Nothing it reads or
  writes comes back except a PHI-scanned handoff summary, `git diff
  --stat`, and a scan verdict for the committed diff.
- **The guard hook** (fallback): `scripts/guard-hook.sh`, a PreToolUse
  settings hook that blocks reads of delegate artifacts on clients where
  mods do not run.

You never have to log out of your subscription to do PHI work. The mod is
new; everything that worked before still works the same way, with or
without it (see [Without the plugin](#without-the-plugin)).

## How isolation works

| Layer | Mechanism |
|---|---|
| Credentials | Delegate runs with `ANTHROPIC_API_KEY` set to `PHI_DELEGATE_API_KEY` only for that process. Every other credential (OAuth token, auth token, Bedrock/Vertex/Foundry switches, WIF, profiles) is unset. |
| Config | Delegate uses its own `CLAUDE_CONFIG_DIR` (`~/.phi-delegate/claude`), so it never sees `~/.claude` settings, hooks, or the subscription login. Runs fail if an OAuth login appears there. |
| Endpoint | `ANTHROPIC_BASE_URL` is forced to `https://api.anthropic.com` via both the environment and `--settings`, which outranks the target repo's `.claude/settings.json`. |
| Egress | `--strict-mcp-config` disables every MCP server; `WebSearch` and `WebFetch` are disallowed; telemetry and error reporting are off. |
| Model | Default `claude-opus-5`. Fable and Mythos class models are refused because they are not offered under ZDR. |
| Output | The raw transcript goes to a temp file, is checked for permission denials, and is securely deleted when the run ends (opt in to keeping it with `PHI_DELEGATE_KEEP_LOG=1`, mode 600, humans only). The delegate writes a handoff that is moved out of the tree and scanned by `phi-scan.sh`: clean handoffs are shown, flagged ones are deleted unread. |
| Residue | Each run gets its own `CLAUDE_CONFIG_DIR` subdirectory, deleted afterwards, so no history or debug logs survive. `collect.sh --merge` and `--reject` delete the handoff, the spec, its private input sidecar, any kept log, and the run records. After a task closes, the only PHI-adjacent thing left is the git branch itself, which is what the human reviews. |
| Orchestrator | `SKILL.md` forbids reading delegate artifacts. The plugin registers `guard-hook.sh` as a PreToolUse hook (or `install.sh --with-guard` adds it to user settings), which mechanically blocks Read/Bash/Grep/Glob calls referencing `.phi-worktrees/`, handoff copies, `*.private.md` sidecars, or `--full-diff`. |
| Mod | Function hooks in the orchestrator session: a `tool.call` guard (the rules above, plus `collect.sh --merge`), a PHI-source command deny, prompt interception, output scrubbing for the commands and tools that can reach records, the `delegate` tool, and a review pane whose buttons are the only way to merge. Every blocking hook fails closed. It stands down inside the delegate, which `phi-claude.sh` marks with `PHI_DELEGATE_SESSION=1`. |
| Push | `delegate.sh --pr` and `collect.sh --pr` scan the branch diff with `phi-scan.sh --profile diff` before anything is pushed. A flagged line stops both: no push, no PR, the branch stays local, and the script exits non-zero. `--push-flagged` overrides that, and the flagged lines then become public on the remote. |
| Bash scrub gap | Under the default `scrub_scope: data`, Bash output is scrubbed only for commands matching `scrub_commands` or `phi_sources`. A plain `cat` of a data file through Bash is not scrubbed, while the same file through Read is. Set `scrub_scope: all` to scrub every Bash result. |
| Specs | Specs must be PHI-free. Identifiers go in a private input sidecar the mod writes from a prompt you stage, or in a `## Private input` section you fill in your own editor; the orchestrator never reads either back. |

## The scanner

`scripts/phi-patterns.tsv` is the one pattern source. `phi-scan.sh` reads
it with `grep -E`, and the mod reads a generated TypeScript copy
(`scripts/gen-mod-data.sh` writes it; bats and CI fail when it drifts). A
parity test holds the two to identical per-class counts on every fixture
in `tests/fixtures/`.

The classes are SSN, phone, email, date, and ISO date shapes, street
addresses, long digit runs (the identifier classes), and DOB, identifier,
patient-name, and clinical keywords (the keyword classes). Output is counts
only. It is a tripwire, not a substitute for the delegate following its
handoff instructions or for the human reviewing the full diff.

Precision options: `--profile diff` drops git metadata lines (`diff --git`,
`index`, file headers, hunk headers, and `Author:`, `Signed-off-by:`,
`Co-Authored-By:` at column 0 or the 4-space commit message indent) so
author emails stop counting. Only lines outside a hunk are dropped: from
an `@@` line to the next `diff --git` or `commit` header every line is
content and scans, even when it looks like metadata.
`--profile prose` is for a human scanning documentation that talks about
PHI: it skips the `dob-keyword`, `identifier-keyword`, and
`clinical-keyword` classes and scans every other class; `delegate.sh` and
`collect.sh` never use it, so handoff scans keep the strict default.
`--only` and `--skip` take class names (comma separated, repeatable) and
compose with either profile; `--allow <file>` reads an allowlist,
conventionally `.phi-allow`, one regex per line, applied to matched lines.
The allowlist is never loaded implicitly. The synthetic corpus in
`tests/fixtures/` measures it: 7 clean fixtures pass, 11 dirty fixtures
flagged, and `edge-` fixtures pin behavior the script and the mod must
share (`bats tests/phi_scan_fixtures.bats`). The scanner runs in the C
locale, so results are the same on macOS, Linux, and in the mod; non-ASCII
letters are not case-folded. Prose about the scanner
itself trips the keyword classes under the default profile; use `--profile
prose` for it.

## Requirements

- Claude Code CLI 2.1.287 or newer for the mod (2.1 or newer for the skill
  alone)
- An Anthropic API key from an organization with a BAA and ZDR enabled
- `git`, `bash`, `curl`; `gh` for PRs; `node` for `install.sh --with-guard`

## Install

The plugin is the documented path. This repo is its own marketplace:

```bash
git clone https://github.com/brianleach/phi-delegate ~/code/phi-delegate
claude plugin marketplace add ~/code/phi-delegate
claude plugin install phi-delegate@phi-delegate
cd ~/code/phi-delegate && cp .env.example .env    # then edit
scripts/check-env.sh
```

Or, at the prompt of a terminal session:

```
/plugin install phi-delegate --marketplace brianleach/phi-delegate
```

Because the marketplace is a local folder listing the plugin at `./`, the
plugin is read in place: pull the repo and run `/reload-plugins`.

`.env` (gitignored, at this repo's root):

```
PHI_DELEGATE_API_KEY=sk-ant-...
PHI_DELEGATE_ZDR_ATTESTED=1
# PHI_DELEGATE_MODEL=claude-opus-5
# PHI_DELEGATE_CONFIG_DIR=$HOME/.phi-delegate/claude
```

`PHI_DELEGATE_ZDR_ATTESTED=1` is a deliberate manual step: there is no API
that proves a key belongs to a ZDR org, so the operator confirms it in the
Console and attests. Runs refuse to start without it.

### Options

Set with the `/config` rows (a change there reloads the mod at once), `/plugin
configure phi-delegate@phi-delegate`, or `claude plugin install --config
key=value` (the shell commands take effect in the next session):

| Option | Default | What it does |
|---|---|---|
| `guardrail` | `auto` | `auto` turns the mod on, except for a skill-only `install.sh` setup (a `phi-delegate` symlink in `~/.claude/skills`), where it stays off until you choose `on`. `off` turns it off anywhere. The `PHI_DELEGATE_GUARDRAIL=on` or `off` environment variable overrides it. The covered delegate always stands down. |
| `prompt_keyword_classes` | `false` | Also scan prompts and tool output for the keyword classes. Off because talking about schemas trips them. |
| `allowlist_file` | empty | A file of extended regexes, one per line, applied to matched lines (for example your company email domain). |
| `allowlist` | none | The same, as a list in the plugin's options, added to the file's entries. |
| `phi_sources` | `snowsql`, `psql` against a `*PROD*` variable | JavaScript regexes for Bash commands that reach PHI. A repo adds its own in a `.phi-sources` file at its root, same format. A pattern that does not compile, or a `.phi-sources` that cannot be read, blocks Bash until it is fixed. |
| `scrub_tool_output` | `true` | Replace flagged tool results with a counts-only notice. |
| `scrub_scope` | `data` | `data` scrubs only output that can carry records: Bash commands matching `scrub_commands` or `phi_sources`, Read of files matching `scrub_files`, tools matching `scrub_tools`, and background command output. Ordinary work (`gh`, `git`, reading repo files, browser tools) is not scrubbed. `all` scrubs every Bash, Read, Grep, and MCP result. A list entry that does not compile widens the scope to `all`. |
| `scrub_commands` | DB clients, `rails c`/`runner`, `kubectl exec`/`logs`, `aws ecs execute-command`/`logs`, `docker exec`/`logs`, `heroku run`, `curl`/`wget`, log CLIs | Regexes for data commands. |
| `scrub_tools` | MCP tools for Sentry, Datadog, and SQL or warehouse databases | Regexes for tool names. |
| `scrub_files` | `.csv`, `.tsv`, `.log`, `.sql`, `.dump`, `.jsonl`, `.xlsx`, `.parquet`, `.hl7`, `.dcm` and similar | Regexes for data files read with Read. |

### Without the plugin

The skill-only install still works and is unchanged:

```bash
./install.sh               # symlink the skill into ~/.claude/skills
./install.sh --with-guard  # also add guard-hook.sh to ~/.claude/settings.json
```

The symlink makes Claude Code load this folder as a plugin
(`phi-delegate@skills-dir`), but the mod stays off there by default, so
pulling this release changes nothing for an existing install: the skill
drives `delegate.sh` and `collect.sh` through Bash, the guard hook blocks
what it always blocked, and you approve merges in the conversation, as
before. To try the guardrail on that setup, turn it on:

```bash
echo '{"guardrail":"on"}' | claude plugin configure phi-delegate@skills-dir --values-stdin
```

or set `PHI_DELEGATE_GUARDRAIL=on` for one session. Do not combine the
symlink with a marketplace install: the skill would load twice, and with
the symlink present the marketplace copy also defaults to off.

## Usage

In any repo, tell Claude Code "this touches PHI, delegate it" (or invoke
the `phi-delegate` skill). Claude will:

1. run `scripts/check-env.sh`
2. write a PHI-free spec to `.phi-tasks/<nn>-<slug>.md`
3. call the `delegate` tool on it (or, without the mod, run
   `scripts/delegate.sh <spec> --pr`)
4. show you the diff stat, scan verdicts, and the clean handoff
5. leave the decision to you: with the mod, a review pane opens (reopen it
   with `/phi-review`) with Merge, Reject, and Open PR buttons that run
   `collect.sh`. The model cannot press them, and the mod blocks it from
   running `collect.sh --merge` itself. Review the full diff on the PR, or
   with `scripts/collect.sh <name> --full-diff` in your own terminal, first.

### Status and the session switch

The status line under the prompt reads `PHI shield on · N flagged` while the
guardrail is active, and `PHI shield off` when you turned it off on purpose.
A skill-only install that never opted in shows nothing.

`/phi-guard` shows the state; `/phi-guard on` and `/phi-guard off` change it
for the rest of the session. Turning it off asks you in a dialog first, so a
model that runs the command cannot switch the guardrail off by itself.

The scanner masks GitHub URLs (run and job IDs are long digit runs) and
timestamps (a date in 2000 or later with a time other than midnight) before
it scans. A date of birth stored as a datetime prints as midnight, and a
19xx date is never masked, so both still count.

### Private input

When the task needs an identifier, type it in a prompt. The mod flags it
and asks:

- **Stage as private input**: asks which task it is for, writes the prompt
  to `.phi-tasks/<name>.private.md` (mode 600), and sends the model only a
  note that private input is staged for `<name>`. `delegate.sh` appends the
  sidecar to the delegate's copy of the spec as its `## Private input`
  section; merge or reject deletes it.
- **Send anyway (no PHI)**: for a false positive, such as a format example.
- **Cancel**: the prompt is dropped.

A dismissed question drops the prompt. Messages nobody typed (background
task notifications, peers) that match are held back without asking.
Without the mod, leave a `## Private input` section in the spec and fill
it in your own editor.

### Interactive mode

To watch and approve each step yourself instead, ask for interactive mode.
Claude runs `scripts/interactive.sh <spec>`, which prints a command; you
run it in your own terminal and get the same isolated session with
permission prompts. A staged sidecar is named to that session as the
spec's Private input. The handoff lands at `.phi-handoff.md` in the repo,
unscanned, for you to read (`scripts/phi-scan.sh .phi-handoff.md` first)
and delete.

### Cleanup

Nothing PHI-bearing is left behind: the transcript and the delegate's
session state are deleted when the run ends, and merge or reject deletes
the spec, its sidecar, and the handoff. Secure deletion is best effort
(`shred` or `rm -P`); on APFS and SSDs full-disk encryption is the real
control.

Runs that end abnormally, and interactive sessions whose handoff was
never deleted, do leave residue. `scripts/cleanup.sh` finds it (stray
`.phi-handoff*.md`, `.phi-tasks/` and the sidecars in it,
`.phi-worktrees/`, `phi/*` branches, delegate session state) and lists it
by name; `--apply` deletes it, `--all` sweeps every repo under `~/code`,
`--branches` also drops merged `phi/*` branches, and `--sessions` empties
the delegate config dir. A branch counts as merged when it is an ancestor
of HEAD or when `gh` reports a merged PR for it, so squash-merged delegate
PRs qualify. Unmerged branches, and branches whose PR is open or was
closed without merging, are never deleted.

## Organization deployment

To put the guardrail on every machine, deploy it as an organization mod.
Have device management copy this repo to the same absolute path on every
machine (writable only by administrators), then add managed settings:

```json
{
  "extraKnownMarketplaces": {
    "phi-delegate": {
      "source": { "source": "directory", "path": "/opt/phi-delegate" }
    }
  },
  "enabledPlugins": { "phi-delegate@phi-delegate": true },
  "prependPlugins": ["phi-delegate@phi-delegate", "sec-default@builtin"],
  "pluginConfigs": {
    "phi-delegate@phi-delegate": {
      "options": { "guardrail": "on", "prompt_keyword_classes": false, "allowlist_file": "/opt/phi-delegate-allow" }
    }
  },
  "disableSideloadFlags": true
}
```

- The marketplace must be a directory listing the plugin by relative path
  so the plugin is read in place and counts as the organization's. A copy
  from a GitHub, git, URL, or npm source counts as a user's and is skipped
  by `prependPlugins`.
- `prependPlugins` replaces the default, so name `sec-default@builtin` to
  keep the built-in guard.
- `"guardrail": "on"` keeps the mod on even for a developer who also has
  the old `install.sh` symlink, where `auto` would leave it off.
- `disableSideloadFlags` rejects `--plugin-dir` (and `--plugin-url`,
  `--agents`, `--mcp-config`) so a session cannot be started around the
  policy that way.
- Confirm with `claude --debug`: the line for `phi-delegate@phi-delegate`
  should say `tier prepend`.

Caveats:

- `claude --safe-mode` starts a session with no installed mods, this one
  included. Only `guard-hook.sh` (a settings hook) still runs there.
- If the worker that runs installed mods crashes three times, Claude Code
  unloads every non-built-in mod for that session until `/reload-plugins`
  or a new session.
- CLI versions older than 2.1.287 do not load the mod. Mods are on by
  default from 2.1.286, and 2.1.287 ignores the old early-access
  `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS` switch.
- The mod covers Claude Code only (terminal, desktop, IDE). It does not
  see claude.ai chats, other tools, or programs the session starts
  outside its tool calls.
- Managed mods also load inside the covered delegate. The mod and the
  guard hook stand down there because `phi-claude.sh` exports
  `PHI_DELEGATE_SESSION=1`. That marker is honor system, not a security
  boundary: a user who sets it in the orchestrator turns the guardrail off.

## Compliance notes

This tool reduces the surface through which PHI can reach an uncovered
session; it does not by itself make a workflow HIPAA compliant. You still
need the BAA, ZDR enabled on the org, access controls on the databases the
delegate reaches, and human review of every change. The mod is a set of
heuristics in front of the model, not a sandbox: a pattern it does not
know passes.

The guards match what a tool call says, not what it touches. They stop the
mistakes that matter in practice (reading a delegate's worktree, globbing
the private input folder, a recursive grep that walks into it, running a
known PHI source), but the session
runs as you, with your file access, so a command spelled in a way the
guards do not recognize can still reach those files. The output scrubber
is the backstop for identifier-shaped values that come back from data
commands and tools (all tools with `scrub_scope: all`); output from a data
path it does not know, and names or free text with no identifier shape,
can pass it. Treat the guardrail as
protection against accidents, not against a session trying to get around
it. Local artifacts the delegate creates on your machine are
deleted after each task, but the overwrite is best effort, so FileVault
or equivalent disk encryption is still required.

## Development

```bash
shellcheck scripts/*.sh install.sh tests/helpers.bash
scripts/gen-mod-data.sh            # after editing phi-patterns.tsv or fixtures
claude plugin validate .
claude plugin test .
bats tests/
claude --plugin-dir .              # try the mod from this checkout
```

## Roadmap

Not built yet, and out of scope for the first version of the mod:

- A reversible pseudonymization vault, so the model can work with stable
  placeholders that map back to real values only in the covered lane
- Display masking of flagged text in the transcript (`ui.render`)
- Heartbeat and audit posting to a central monitoring service
- A local NER or trained detection sidecar beside the regex classes
- A network backstop proxy

## License

MIT
