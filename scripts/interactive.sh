#!/usr/bin/env bash
# Print (or run) the command for an INTERACTIVE delegate session: the same
# ZDR isolation as delegate.sh, but in the human's own terminal with
# permission prompts, so they can approve each command and intervene on
# failures. Run with --help for usage.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/load-env.sh"

usage() {
  cat <<'USAGE'
Usage: interactive.sh <task-spec.md> [--model <anthropic-model-id>] [--permission-mode <mode>] [--run]

Build the command that opens an interactive Claude Code session for a task
spec, authenticated with the ZDR/BAA key through phi-claude.sh. By default
the command is PRINTED for the human to paste into their own terminal; the
orchestrator session must not run it. With --run it is executed in place,
for a human who is already in a terminal.

Differences from delegate.sh, which the human must know:
  - runs in the current checkout, not a worktree. Use it for read-only
    or investigative specs; for specs that edit code, prefer delegate.sh
  - the handoff lands at ./.phi-handoff.md and is NOT phi-scanned or
    collected. The human reads it, and relays aggregates only. Scan it
    first with: scripts/phi-scan.sh .phi-handoff.md
  - permission mode defaults to "default" (every tool call prompts). Pass
    --permission-mode acceptEdits to match the headless run and still see
    each command scroll by
  - session state persists under the delegate CLAUDE_CONFIG_DIR until the
    human deletes it; delegate.sh deletes its per-run config dir itself

The spec path must be relative to the repo root and must not contain a
single quote.
USAGE
  exit 1
}

spec_file=""
model="$PHI_DELEGATE_MODEL"
permission_mode="default"
run_now=0

while [ $# -gt 0 ]; do
  case "$1" in
    --model)
      [ $# -ge 2 ] || usage
      model="$2"
      shift 2
      ;;
    --permission-mode)
      [ $# -ge 2 ] || usage
      permission_mode="$2"
      shift 2
      ;;
    --run)
      run_now=1
      shift
      ;;
    -h | --help)
      usage
      ;;
    *)
      if [ -z "$spec_file" ]; then
        spec_file="$1"
        shift
      else
        echo "error: unexpected argument: $1" >&2
        usage
      fi
      ;;
  esac
done

[ -n "$spec_file" ] || usage
if [ ! -f "$spec_file" ]; then
  echo "error: task spec not found: $spec_file" >&2
  exit 1
fi
case "$permission_mode" in
  default | acceptEdits | plan) ;;
  *)
    echo "error: permission mode must be default, acceptEdits, or plan (never bypassPermissions)" >&2
    exit 1
    ;;
esac

# Physical paths on both sides: on macOS git resolves /var to /private/var
# while a plain pwd may not, and the containment check below must agree.
repo_root="$(cd "$(git rev-parse --show-toplevel)" && pwd -P)"
abs_spec="$(cd "$(dirname "$spec_file")" && pwd -P)/$(basename "$spec_file")"
case "$abs_spec" in
  "$repo_root"/*) rel_spec="${abs_spec#"$repo_root"/}" ;;
  *)
    echo "error: the spec must live inside the repo: $repo_root" >&2
    exit 1
    ;;
esac
case "$rel_spec" in
  *"'"*)
    echo "error: spec path contains a single quote, which the printed command cannot carry" >&2
    exit 1
    ;;
esac

# Keep this prompt aligned with the one in delegate.sh. It contains no
# single quotes so it can be printed inside a single-quoted shell string.
prompt="Read the file $rel_spec in the current directory and complete the task it describes. Do not modify or delete that file.

You are running in a HIPAA-covered, zero-data-retention session. The person who reviews your work is NOT covered and will only see the file .phi-handoff.md that you write. Before you finish, write .phi-handoff.md in the current directory following the Handoff requirements section of the task file exactly. It MUST NOT contain protected health information or personal identifiers of any kind: no names, dates of birth, record or member IDs, addresses, phone numbers, emails, diagnoses, or literal database row values. Avoid dates and digit sequences longer than 6 characters, which the PHI scanner flags. Describe data in the aggregate instead. Do not commit .phi-tasks/ or .phi-handoff.md. Do not write PHI into source files, fixtures, seeds, tests, or commit messages."

wrapper="$SCRIPT_DIR/phi-claude.sh"

if [ "$run_now" = "1" ]; then
  cd "$repo_root"
  exec "$wrapper" "$model" --permission-mode "$permission_mode" --allowedTools Bash "$prompt"
fi

cat <<EOF
Run this in YOUR OWN terminal (not from the orchestrator session):

cd '$repo_root' && bash '$wrapper' $model \\
  --permission-mode $permission_mode --allowedTools Bash \\
  '$prompt'

Or, equivalently:

cd '$repo_root' && bash '$SCRIPT_DIR/interactive.sh' '$rel_spec' --permission-mode $permission_mode --run

When it finishes: the handoff is at $repo_root/.phi-handoff.md. Scan it with
  bash '$SCRIPT_DIR/phi-scan.sh' .phi-handoff.md
read it yourself, relay aggregates only to the orchestrator, then delete it.
EOF
