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

blocked_reason=""
if printf '%s' "$payload" | grep -q -E '\.phi-worktrees'; then
  blocked_reason=".phi-worktrees/ holds delegate worktrees and raw transcripts that may contain PHI"
elif printf '%s' "$payload" | grep -q -E '\.phi-handoff|\.phi-task\.md'; then
  blocked_reason="delegate-side task and handoff copies live inside the worktree and may contain PHI"
elif printf '%s' "$payload" | grep -q -E -- '--full-diff'; then
  blocked_reason="collect.sh --full-diff prints delegate output verbatim and is reserved for the human"
elif printf '%s' "$payload" | grep -q -E '\.phi-delegate/claude'; then
  blocked_reason="the delegate CLAUDE_CONFIG_DIR holds its own session state"
fi

if [ -n "$blocked_reason" ]; then
  echo "phi-delegate guard: blocked. $blocked_reason. Read the scanned handoff via scripts/collect.sh <name> instead, or ask the human to inspect it outside this session." >&2
  exit 2
fi
exit 0
