#!/usr/bin/env bash
# Preflight for the phi-delegate skill. Verifies the claude CLI, the ZDR
# key and attestation, isolation of the delegate config dir, the guard
# hook in the orchestrator's settings, direct API auth, and a live smoke
# test through phi-claude.sh. Exits nonzero with fix instructions.
set -euo pipefail

SMOKE_TIMEOUT_SECS="${PHI_DELEGATE_SMOKE_TIMEOUT_SECS:-120}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

key_source="environment"
[ -n "${PHI_DELEGATE_API_KEY:-}" ] || key_source=""
# shellcheck source=/dev/null
. "$SCRIPT_DIR/load-env.sh"
[ -z "$key_source" ] && [ -n "${PHI_DELEGATE_API_KEY:-}" ] && key_source=".env file"
model="$PHI_DELEGATE_MODEL"

failures=0
with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"
  else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}
pass() { printf 'ok    %s\n' "$1"; }
warn() { printf 'warn  %s\n      note: %s\n' "$1" "$2"; }
fail() { printf 'FAIL  %s\n      fix: %s\n' "$1" "$2"; failures=$((failures + 1)); }

if command -v claude >/dev/null 2>&1; then
  pass "claude CLI found ($(claude --version 2>/dev/null || echo 'version unknown'))"
else
  fail "claude CLI not found on PATH" "npm install -g @anthropic-ai/claude-code"
fi

if [ -n "${PHI_DELEGATE_API_KEY:-}" ]; then
  pass "PHI_DELEGATE_API_KEY present via $key_source"
else
  fail "PHI_DELEGATE_API_KEY is not set" \
    "put PHI_DELEGATE_API_KEY=<key from the BAA/ZDR org> in the skill repo's gitignored .env"
fi

if [ "${PHI_DELEGATE_ZDR_ATTESTED:-0}" = "1" ]; then
  pass "ZDR attestation set (PHI_DELEGATE_ZDR_ATTESTED=1)"
else
  fail "PHI_DELEGATE_ZDR_ATTESTED is not 1" \
    "confirm in the Anthropic Console that the key's organization has a signed BAA and zero data retention enabled, then add PHI_DELEGATE_ZDR_ATTESTED=1 to .env"
fi

case "$model" in
  *fable*|*mythos*) fail "model $model is not offered under zero data retention" "set PHI_DELEGATE_MODEL=claude-opus-5" ;;
  *) pass "model: $model" ;;
esac

if [ -f "$PHI_DELEGATE_CONFIG_DIR/.credentials.json" ]; then
  fail "OAuth credentials found in the delegate config dir $PHI_DELEGATE_CONFIG_DIR" \
    "rm $PHI_DELEGATE_CONFIG_DIR/.credentials.json so the delegate can only use the ZDR key"
else
  pass "delegate config dir isolated: $PHI_DELEGATE_CONFIG_DIR (no OAuth login)"
fi

if [ -f "${HOME}/.claude/settings.json" ] && grep -q 'guard-hook.sh' "${HOME}/.claude/settings.json" 2>/dev/null; then
  pass "orchestrator guard hook installed in ~/.claude/settings.json"
else
  warn "guard hook not installed in ~/.claude/settings.json" \
    "run install.sh --with-guard so the orchestrator session is mechanically blocked from reading .phi-worktrees/"
fi

if [ -n "${PHI_DELEGATE_API_KEY:-}" ] && command -v curl >/dev/null 2>&1; then
  body_file="$(mktemp "${TMPDIR:-/tmp}/phi-check.XXXXXX")"
  trap 'rm -f "$body_file"' EXIT
  http_code="$(curl -sS -o "$body_file" -w '%{http_code}' --max-time 30 \
    -X POST "https://api.anthropic.com/v1/messages" \
    -H "x-api-key: ${PHI_DELEGATE_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d '{"model":"'"$model"'","max_tokens":16,"messages":[{"role":"user","content":"Reply with the single word: ready"}]}' 2>/dev/null)" || http_code="000"
  if [ "$http_code" = "200" ]; then
    pass "api.anthropic.com accepted the key for $model"
  else
    fail "api.anthropic.com returned HTTP $http_code for $model" \
      "check the key; response: $(tail -c 300 "$body_file" | tr '\n' ' ')"
  fi
fi

if [ "$failures" -eq 0 ]; then
  printf '...   smoke test: claude -p via phi-claude.sh (timeout %ss)\n' "$SMOKE_TIMEOUT_SECS"
  if smoke_output=$(with_timeout "$SMOKE_TIMEOUT_SECS" "$SCRIPT_DIR/phi-claude.sh" "$model" \
    -p "Reply with the single word: ready" </dev/null 2>&1) && [ -n "$smoke_output" ]; then
    pass "smoke test succeeded ($(printf '%s' "$smoke_output" | tail -c 100 | tr '\n' ' '))"
  else
    fail "smoke test failed" "try: scripts/phi-claude.sh $model -p 'say hello'. Output: $(printf '%s' "$smoke_output" | tail -c 300 | tr '\n' ' ')"
  fi
else
  echo "skip  smoke test (fix the failures above first)"
fi

echo
if [ "$failures" -gt 0 ]; then
  echo "check-env: NOT READY ($failures problem(s))"
  exit 1
fi
echo "check-env: ready to delegate PHI work"
