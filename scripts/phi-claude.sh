#!/usr/bin/env bash
# Shared wrapper: run the claude CLI as an isolated delegate authenticated
# with the ZDR/BAA API key, in its own CLAUDE_CONFIG_DIR, with every
# outbound path except api.anthropic.com closed off. Used by check-env.sh
# and delegate.sh. Run with no arguments for usage.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/load-env.sh"

ANTHROPIC_URL="https://api.anthropic.com"

if [ $# -lt 1 ]; then
  echo "usage: phi-claude.sh <model> [claude args...]" >&2
  echo "  <model> is an Anthropic model ID, e.g. claude-opus-5" >&2
  echo "  put a positional prompt BEFORE --allowedTools, --disallowedTools, --tools," >&2
  echo "  and --add-dir: those flags are variadic and swallow whatever follows them" >&2
  exit 1
fi
model="$1"
shift

case "$model" in
  *[!A-Za-z0-9._-]*)
    echo "error: model contains unexpected characters: $model" >&2
    exit 1
    ;;
  *fable*|*mythos*)
    echo "error: $model is not offered under zero data retention; use claude-opus-5 or claude-sonnet-5" >&2
    exit 1
    ;;
esac

if [ -z "${PHI_DELEGATE_API_KEY:-}" ]; then
  echo "error: PHI_DELEGATE_API_KEY is not set (export it, or put it in the skill repo's gitignored .env)" >&2
  exit 1
fi
if [ "${PHI_DELEGATE_ZDR_ATTESTED:-0}" != "1" ]; then
  echo "error: PHI_DELEGATE_ZDR_ATTESTED is not 1. Set it only after confirming the key belongs to an" >&2
  echo "       Anthropic organization with a signed BAA and zero data retention enabled." >&2
  exit 1
fi
if ! command -v claude >/dev/null 2>&1; then
  echo "error: claude CLI not found on PATH" >&2
  exit 1
fi

# A dedicated config dir keeps the delegate away from ~/.claude entirely:
# no subscription OAuth credentials, no user settings.json (fireconnect
# style base URL rewrites, third-party hooks), no shared session files.
config_dir="$PHI_DELEGATE_CONFIG_DIR"
mkdir -p "$config_dir"
chmod 700 "$config_dir"
if [ -f "$config_dir/.credentials.json" ]; then
  echo "error: $config_dir/.credentials.json exists: someone logged in to a Claude account inside the" >&2
  echo "       delegate config dir. Remove it so runs can only authenticate with the ZDR API key." >&2
  exit 1
fi
# Skip first-run onboarding so headless -p runs never block on a prompt.
if [ ! -f "$config_dir/.claude.json" ]; then
  printf '{"hasCompletedOnboarding":true}\n' >"$config_dir/.claude.json"
  chmod 600 "$config_dir/.claude.json"
fi

# Command-line settings outrank project settings files in the target repo,
# so a .claude/settings.json there cannot redirect traffic elsewhere. The
# key is passed only through the environment: settings JSON lands on argv,
# which is visible in the process list.
settings_json="$(printf '{"env":{"ANTHROPIC_BASE_URL":"%s","ANTHROPIC_MODEL":"%s","ANTHROPIC_DEFAULT_OPUS_MODEL":"%s","ANTHROPIC_DEFAULT_SONNET_MODEL":"%s","ANTHROPIC_DEFAULT_HAIKU_MODEL":"%s","CLAUDE_CODE_SUBAGENT_MODEL":"%s","DISABLE_TELEMETRY":"1","DISABLE_ERROR_REPORTING":"1"}}' \
  "$ANTHROPIC_URL" "$model" "$model" "$model" "$model" "$model")"

# Egress controls:
#   - WebFetch/WebSearch disallowed: they could carry PHI to arbitrary hosts.
#   - --strict-mcp-config with no --mcp-config: every MCP server the target
#     repo or user configured (Linear, Sentry, ...) is ignored.
#   - telemetry, error reporting, and nonessential traffic off.
#   - every alternative credential and provider switch is unset so the only
#     usable auth is the ZDR key against api.anthropic.com.
# --allowedTools, --disallowedTools, --tools, and --add-dir are variadic:
# every positional after one of them is consumed as a list item until the
# next flag. A later flag ends the list but does not give back a positional
# the list already took, so a prompt placed right after such a flag is
# lost no matter what follows it (headless -p then waits on stdin, an
# interactive session opens with an empty input box). Two consequences:
#   - The caller's "$@" goes BEFORE the wrapper's own flags, because the
#     wrapper ends with --disallowedTools and a prompt appended after that
#     would be swallowed as a tool name.
#   - Callers must still put their prompt before any variadic flag of
#     their own. The wrapper cannot fix that ordering, so it refuses the
#     ambiguous case instead of letting the run silently lose its prompt.
open_list=""
last=""
for arg in "$@"; do
  last="$arg"
  case "$arg" in
    --allowedTools|--allowed-tools|--disallowedTools|--disallowed-tools|--tools|--add-dir)
      open_list=1 ;;
    -*)
      open_list="" ;;
  esac
done
if [ -n "$open_list" ]; then
  # A tool pattern (Bash, Read, Bash(git:*), mcp__a__b, comma lists of
  # those) or a directory path is fine as the last list item. Anything
  # with whitespace outside a pattern's parentheses is a prompt.
  case "$last" in
    /*|./*|../*|~*) : ;;
    *[[:space:]]*)
      if ! printf '%s' "$last" | grep -Eq '^[A-Za-z0-9_-]+(\([^)]*\))?(,[A-Za-z0-9_-]+(\([^)]*\))?)*$'; then
        echo "error: the last argument looks like a prompt but follows a variadic flag, so claude would read it" >&2
        echo "       as a tool name or directory. Put the prompt before --allowedTools/--disallowedTools/--tools/--add-dir." >&2
        exit 1
      fi
      ;;
  esac
fi
exec env \
  -u ANTHROPIC_AUTH_TOKEN \
  -u CLAUDE_CODE_OAUTH_TOKEN \
  -u ANTHROPIC_CUSTOM_HEADERS \
  -u CLAUDE_CODE_USE_BEDROCK \
  -u CLAUDE_CODE_USE_VERTEX \
  -u CLAUDE_CODE_USE_FOUNDRY \
  -u ANTHROPIC_PROFILE \
  -u ANTHROPIC_FEDERATION_RULE_ID \
  -u ANTHROPIC_IDENTITY_TOKEN \
  -u ANTHROPIC_IDENTITY_TOKEN_FILE \
  PHI_DELEGATE_SESSION=1 \
  CLAUDE_CONFIG_DIR="$config_dir" \
  ANTHROPIC_BASE_URL="$ANTHROPIC_URL" \
  ANTHROPIC_API_KEY="$PHI_DELEGATE_API_KEY" \
  ANTHROPIC_MODEL="$model" \
  ANTHROPIC_DEFAULT_OPUS_MODEL="$model" \
  ANTHROPIC_DEFAULT_SONNET_MODEL="$model" \
  ANTHROPIC_DEFAULT_HAIKU_MODEL="$model" \
  ANTHROPIC_SMALL_FAST_MODEL="$model" \
  CLAUDE_CODE_SUBAGENT_MODEL="$model" \
  DISABLE_TELEMETRY=1 \
  DISABLE_ERROR_REPORTING=1 \
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  claude --model "$model" --settings "$settings_json" "$@" \
  --strict-mcp-config \
  --disallowedTools "WebSearch,WebFetch"
