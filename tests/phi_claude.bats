#!/usr/bin/env bats
load helpers

setup() {
  WRAP="$(phi_repo_root)/scripts/phi-claude.sh"
  install_fake_claude
  export_delegate_env
}

@test "refuses without key" {
  unset PHI_DELEGATE_API_KEY
  run "$WRAP" claude-opus-5 -p hi
  [ "$status" -eq 1 ]
  [[ "$output" == *"PHI_DELEGATE_API_KEY"* ]]
}

@test "refuses without ZDR attestation" {
  export PHI_DELEGATE_ZDR_ATTESTED=0
  run "$WRAP" claude-opus-5 -p hi
  [ "$status" -eq 1 ]
  [[ "$output" == *"ZDR"* ]]
}

@test "refuses fable models" {
  run "$WRAP" claude-fable-5 -p hi
  [ "$status" -eq 1 ]
  [[ "$output" == *"zero data retention"* ]]
}

@test "refuses when an OAuth login exists in the delegate config dir" {
  mkdir -p "$PHI_DELEGATE_CONFIG_DIR"
  touch "$PHI_DELEGATE_CONFIG_DIR/.credentials.json"
  run "$WRAP" claude-opus-5 -p hi
  [ "$status" -eq 1 ]
  [[ "$output" == *".credentials.json"* ]]
}

@test "sets isolated env and drops competing credentials" {
  export ANTHROPIC_AUTH_TOKEN=leak CLAUDE_CODE_OAUTH_TOKEN=leak ANTHROPIC_BASE_URL=https://evil.example
  run "$WRAP" claude-opus-5 -p hi
  [ "$status" -eq 0 ]
  grep -q '^ANTHROPIC_API_KEY=test-key-not-real$' "$FAKE_CLAUDE_ENV"
  grep -q '^ANTHROPIC_BASE_URL=https://api.anthropic.com$' "$FAKE_CLAUDE_ENV"
  grep -q "^CLAUDE_CONFIG_DIR=${PHI_DELEGATE_CONFIG_DIR}$" "$FAKE_CLAUDE_ENV"
  ! grep -q '^ANTHROPIC_AUTH_TOKEN=' "$FAKE_CLAUDE_ENV"
  ! grep -q '^CLAUDE_CODE_OAUTH_TOKEN=' "$FAKE_CLAUDE_ENV"
  grep -qx -- '--strict-mcp-config' "$FAKE_CLAUDE_ARGS"
  grep -qx -- 'WebSearch,WebFetch' "$FAKE_CLAUDE_ARGS"
  [ -f "$PHI_DELEGATE_CONFIG_DIR/.claude.json" ]
  ! grep -q 'test-key-not-real' "$FAKE_CLAUDE_ARGS"
}
