#!/usr/bin/env bats
load helpers

setup() {
  INTERACTIVE="$(phi_repo_root)/scripts/interactive.sh"
  install_fake_claude
  export_delegate_env
  setup_fixture_repo
  mkdir -p .phi-tasks
  printf '# Task\n\nDo the thing.\n' >.phi-tasks/01-thing.md
}

@test "prints a command instead of running it by default" {
  run "$INTERACTIVE" .phi-tasks/01-thing.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"phi-claude.sh"* ]]
  [[ "$output" == *"claude-opus-5"* ]]
  [[ "$output" == *"--permission-mode default --allowedTools Bash"* ]]
  [[ "$output" == *"Read the file .phi-tasks/01-thing.md"* ]]
  [[ "$output" == *"phi-scan.sh"* ]]
  # nothing was launched
  [ ! -f "$FAKE_CLAUDE_ARGS" ]
}

@test "refuses a missing spec" {
  run "$INTERACTIVE" .phi-tasks/nope.md
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
}

@test "refuses bypassPermissions" {
  run "$INTERACTIVE" .phi-tasks/01-thing.md --permission-mode bypassPermissions
  [ "$status" -eq 1 ]
  [[ "$output" == *"never bypassPermissions"* ]]
}

@test "--run launches the wrapper with the prompt last and a terminating flag after it" {
  run "$INTERACTIVE" .phi-tasks/01-thing.md --permission-mode acceptEdits --run
  [ "$status" -eq 0 ]
  grep -qx -- 'acceptEdits' "$FAKE_CLAUDE_ARGS"
  grep -qx -- 'Bash' "$FAKE_CLAUDE_ARGS"
  grep -q -- 'Read the file .phi-tasks/01-thing.md' "$FAKE_CLAUDE_ARGS"
  # -p must NOT be present: this is the interactive session
  ! grep -qx -- '-p' "$FAKE_CLAUDE_ARGS"
  # the wrapper's own flags follow the prompt so --allowedTools cannot eat it
  grep -qx -- '--strict-mcp-config' "$FAKE_CLAUDE_ARGS"
}
