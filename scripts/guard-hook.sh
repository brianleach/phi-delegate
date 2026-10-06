#!/usr/bin/env bash
# PreToolUse hook for the ORCHESTRATOR (subscription) session. Blocks any
# tool call whose input references the delegate's quarantined artifacts,
# so raw logs, worktree contents, and full diffs cannot be pulled into a
# session that is not covered by the BAA. Installed into
# ~/.claude/settings.json by install.sh --with-guard.
#
# Reads the hook JSON from stdin. Exit 2 blocks the call and feeds stderr
# back to the model; exit 0 allows it. Matching is done on the raw JSON
# text on purpose: it catches file_path, command, pattern, and any other
# field without depending on jq.
set -euo pipefail

payload="$(cat)"

# phi-claude.sh marks the covered delegate session. Plugin and managed hooks
# load there too, and the delegate must be able to read its own task copy.
if [ "${PHI_DELEGATE_SESSION:-}" = "1" ]; then
  exit 0
fi

# Developing this skill means editing files that name the quarantined
# paths. Exempt tool calls that target the skill repo itself, either by
# running with cwd inside it or, for file tools, by naming its resolved
# path. A Bash command that names the path is not exempt: every session
# runs the scripts by their full path. No delegate ever runs there. This is
# a developer convenience and it assumes an honest orchestrator; it is not
# a security boundary.
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cwd="$(printf '%s' "$payload" | sed -n 's/.*"cwd":"\([^"]*\)".*/\1/p' | head -n 1)"
if [ -n "$cwd" ] && [ -d "$cwd" ]; then
  cwd="$(cd "$cwd" && pwd -P)"
  case "$cwd" in
    "$repo_dir" | "$repo_dir"/*) exit 0 ;;
  esac
fi
if ! printf '%s' "$payload" | grep -q '"tool_name" *: *"Bash"' \
  && printf '%s' "$payload" | grep -qF -- "$repo_dir"; then
  exit 0
fi

# .phi-tasks/ may be named from Bash only in one plain run of a
# phi-delegate script (a path of plain characters, then plain or quoted
# arguments) or a mkdir of the folder: a glob, redirection, pipe, or chain
# can read a sidecar without naming it. Grep may not search it at all.
# ".phi-task" with no s also catches a bracket glob such as .phi-task[s].
# The command is pulled out of the JSON and unescaped; if that fails, it
# is not plain.
tasks_blocked=0
if printf '%s' "$payload" | grep -q -F '.phi-task'; then
  if printf '%s' "$payload" | grep -q '"tool_name" *: *"Grep"'; then
    tasks_blocked=1
  elif printf '%s' "$payload" | grep -q '"tool_name" *: *"Bash"'; then
    command="$(printf '%s' "$payload" | sed -n -E 's/.*"command" *: *"(([^"\\]|\\.)*)".*/\1/p' | head -n 1 \
      | sed -e 's/\\"/"/g' -e 's/\\\\/\\/g')"
    plain_arg="([^][:space:];&|\`\$<>(){}*?~\\'\"[]+|\"[^\"\$\`\\]*\"|'[^']*')"
    plain_script="^[[:space:]]*(bash[[:space:]]+)?([A-Za-z0-9_./~-]*/)?(delegate|interactive|collect|cleanup)\\.sh([[:space:]]+$plain_arg)*[[:space:]]*\$"
    plain_mkdir='^[[:space:]]*mkdir[[:space:]]+-p[[:space:]]+\.phi-tasks/?[[:space:]]*$'
    if ! printf '%s' "$command" | grep -q -E -e "$plain_script" -e "$plain_mkdir"; then
      tasks_blocked=1
    fi
  fi
fi

# A recursive grep walks into .phi-tasks/ and .phi-worktrees/ without naming
# them (grep does not skip git-excluded paths), so in a repo that has them
# it must exclude both; rg is fine unless told to ignore the excludes.
search_blocked=""
if printf '%s' "$payload" | grep -q '"tool_name" *: *"Bash"' && [ -n "$cwd" ]; then
  repo_root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$cwd")"
  if [ -d "$repo_root/.phi-tasks" ] || [ -d "$repo_root/.phi-worktrees" ]; then
    search_command="$(printf '%s' "$payload" | sed -n -E 's/.*"command" *: *"(([^"\\]|\\.)*)".*/\1/p' | head -n 1 \
      | sed -e 's/\\"/"/g' -e 's/\\\\/\\/g')"
    recursive_grep='(^|[[:space:];&|(])(e|f)?grep[[:space:]]+([^;&|]*[[:space:]])?(-[A-Za-z]*[rR][A-Za-z]*|--recursive|--dereference-recursive|-d[[:space:]]*recurse|--directories=recurse)([^A-Za-z0-9_]|$)'
    unignored_rg='(^|[[:space:];&|(])rg[[:space:]]+([^;&|]*[[:space:]])?(-[A-Za-z]*u[A-Za-z]*|--no-ignore[^[:space:]]*|--hidden)([^A-Za-z0-9_]|$)'
    if printf '%s' "$search_command" | grep -q -E -e "$recursive_grep" \
      && ! { printf '%s' "$search_command" | grep -q -E -e "--exclude-dir=[\"']?\.phi-(\*|tasks)" \
        && printf '%s' "$search_command" | grep -q -E -e "--exclude-dir=[\"']?\.phi-(\*|worktrees)"; }; then
      search_blocked="a recursive grep here would read .phi-tasks/ and .phi-worktrees/, which hold private input and delegate output; use rg, git grep, or the Grep tool (they skip git-excluded paths), or add --exclude-dir=.phi-*"
    elif printf '%s' "$search_command" | grep -q -E -e "$unignored_rg"; then
      search_blocked="rg with -u, --no-ignore, or --hidden here would read .phi-tasks/ and .phi-worktrees/; drop that flag"
    fi
  fi
fi

blocked_reason=""
if printf '%s' "$payload" | grep -q -E '\.phi-worktrees'; then
  blocked_reason=".phi-worktrees/ holds delegate worktrees and raw transcripts that may contain PHI"
elif printf '%s' "$payload" | grep -q -E '\.phi-handoff|\.phi-task\.md'; then
  blocked_reason="delegate-side task and handoff copies live inside the worktree and may contain PHI"
elif printf '%s' "$payload" | grep -q -E -- '--full-diff'; then
  blocked_reason="collect.sh --full-diff prints delegate output verbatim and is reserved for the human"
elif printf '%s' "$payload" | grep -q -E '\.private\.md'; then
  blocked_reason="*.private.md sidecars hold private input staged for a delegate"
elif [ "$tasks_blocked" -eq 1 ]; then
  blocked_reason=".phi-tasks/ holds private input sidecars; from Bash, name it only in a plain run of a phi-delegate script, and write specs with the Write tool"
elif [ -n "$search_blocked" ]; then
  blocked_reason="$search_blocked"
elif printf '%s' "$payload" | grep -q -E '\.phi-delegate/claude'; then
  blocked_reason="the delegate CLAUDE_CONFIG_DIR holds its own session state"
fi

if [ -n "$blocked_reason" ]; then
  echo "phi-delegate guard: blocked. $blocked_reason. Read the scanned handoff via scripts/collect.sh <name> instead, or ask the human to inspect it outside this session." >&2
  exit 2
fi
exit 0
