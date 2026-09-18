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

@test "caller args come before the wrapper's own variadic --disallowedTools" {
  # The wrapper ends with --disallowedTools, which is variadic. If the
  # wrapper's flags came first, a caller's trailing prompt would be
  # consumed as a disallowed tool name.
  run "$WRAP" claude-opus-5 -p --no-session-persistence "do the task"
  [ "$status" -eq 0 ]
  prompt_line=$(grep -nx -- 'do the task' "$FAKE_CLAUDE_ARGS" | head -1 | cut -d: -f1)
  disallowed_line=$(grep -nx -- '--disallowedTools' "$FAKE_CLAUDE_ARGS" | head -1 | cut -d: -f1)
  [ "$prompt_line" -lt "$disallowed_line" ]
  grep -qx -- 'WebSearch,WebFetch' "$FAKE_CLAUDE_ARGS"
}

@test "refuses a prompt left inside an open variadic list" {
  # A flag after the prompt ends the list but does not give back the
  # positional the list already consumed, so this must fail loudly rather
  # than start a run with no prompt.
  run "$WRAP" claude-opus-5 --permission-mode default --allowedTools Bash "do the task"
  [ "$status" -eq 1 ]
  [[ "$output" == *"looks like a prompt but follows a variadic flag"* ]]
  [ ! -f "$FAKE_CLAUDE_ARGS" ]
}

@test "accepts a prompt placed before a variadic flag" {
  run "$WRAP" claude-opus-5 "do the task" --permission-mode default --allowedTools Bash
  [ "$status" -eq 0 ]
  prompt_line=$(grep -nx -- 'do the task' "$FAKE_CLAUDE_ARGS" | head -1 | cut -d: -f1)
  allowed_line=$(grep -nx -- '--allowedTools' "$FAKE_CLAUDE_ARGS" | head -1 | cut -d: -f1)
  [ "$prompt_line" -lt "$allowed_line" ]
}

@test "accepts a spaced tool pattern or a directory as the last list item" {
  run "$WRAP" claude-opus-5 -p "do the task" --allowedTools "Bash(npm run test:*)"
  [ "$status" -eq 0 ]
  grep -qxF -- 'Bash(npm run test:*)' "$FAKE_CLAUDE_ARGS"
  run "$WRAP" claude-opus-5 -p "do the task" --add-dir "/tmp/with space"
  [ "$status" -eq 0 ]
  grep -qx -- '/tmp/with space' "$FAKE_CLAUDE_ARGS"
}
