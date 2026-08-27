#!/usr/bin/env bash
# Symlink this repo into ~/.claude/skills/phi-delegate (idempotent).
# With --with-guard, also register scripts/guard-hook.sh as a PreToolUse
# hook in ~/.claude/settings.json so the orchestrator session is
# mechanically blocked from reading delegate artifacts.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_DIR="${HOME}/.claude/skills"
LINK_PATH="${SKILLS_DIR}/phi-delegate"
SETTINGS="${HOME}/.claude/settings.json"
with_guard=0
[ "${1:-}" = "--with-guard" ] && with_guard=1

mkdir -p "$SKILLS_DIR"
if [ -L "$LINK_PATH" ]; then
  if [ "$(readlink "$LINK_PATH")" = "$REPO_DIR" ]; then
    echo "Already installed: $LINK_PATH -> $REPO_DIR"
  else
    rm "$LINK_PATH"; ln -s "$REPO_DIR" "$LINK_PATH"
    echo "Updated: $LINK_PATH -> $REPO_DIR"
  fi
elif [ -e "$LINK_PATH" ]; then
  echo "Error: $LINK_PATH exists and is not a symlink. Remove it and rerun." >&2
  exit 1
else
  ln -s "$REPO_DIR" "$LINK_PATH"
  echo "Installed: $LINK_PATH -> $REPO_DIR"
fi

if [ "$with_guard" -eq 1 ]; then
  if ! command -v node >/dev/null 2>&1; then
    echo "Error: node is required to edit $SETTINGS" >&2
    exit 1
  fi
  # The hook command uses the skills symlink so it survives repo moves.
  hook_cmd="\"\$HOME\"/.claude/skills/phi-delegate/scripts/guard-hook.sh"
  mkdir -p "$(dirname "$SETTINGS")"
  [ -f "$SETTINGS" ] || echo '{}' >"$SETTINGS"
  HOOK_CMD="$hook_cmd" SETTINGS_PATH="$SETTINGS" node -e '
    const fs = require("fs");
    const p = process.env.SETTINGS_PATH;
    const cmd = process.env.HOOK_CMD;
    const s = JSON.parse(fs.readFileSync(p, "utf8"));
    s.hooks = s.hooks || {};
    s.hooks.PreToolUse = s.hooks.PreToolUse || [];
    const already = s.hooks.PreToolUse.some(g => (g.hooks || []).some(h => (h.command || "").includes("phi-delegate/scripts/guard-hook.sh")));
    if (!already) {
      s.hooks.PreToolUse.push({ matcher: "Read|Edit|Write|Bash|Grep|Glob|MultiEdit|NotebookEdit", hooks: [{ type: "command", command: cmd }] });
      fs.writeFileSync(p, JSON.stringify(s, null, 2) + "\n");
      console.log("Guard hook added to " + p);
    } else {
      console.log("Guard hook already present in " + p);
    }
  '
fi
