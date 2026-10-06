#!/usr/bin/env bats
load helpers

setup() { HOOK="$(phi_repo_root)/scripts/guard-hook.sh"; }

@test "allows unrelated tool calls" {
  run bash -c "printf '%s' '{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"src/app.rb\"}}' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "blocks reads under .phi-worktrees" {
  run bash -c "printf '%s' '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat .phi-worktrees/x.log\"}}' | '$HOOK'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"blocked"* ]]
}

@test "blocks --full-diff" {
  run bash -c "printf '%s' '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"scripts/collect.sh x --full-diff\"}}' | '$HOOK'"
  [ "$status" -eq 2 ]
}

@test "allows collect.sh without full diff" {
  run bash -c "printf '%s' '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"scripts/collect.sh x --merge\"}}' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "exempts calls targeting the skill repo itself" {
  run bash -c "printf '%s' '{\"cwd\":\"$(phi_repo_root)\",\"tool_input\":{\"file_path\":\"scripts/delegate.sh\",\"content\":\".phi-worktrees\"}}' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "blocks private input sidecars" {
  run bash -c "printf '%s' '{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\".phi-tasks/01-x.private.md\"}}' | '$HOOK'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"private input"* ]]
}

@test "stands down inside a covered delegate session" {
  run bash -c "printf '%s' '{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\".phi-task.md\"}}' | PHI_DELEGATE_SESSION=1 '$HOOK'"
  [ "$status" -eq 0 ]
  run bash -c "printf '%s' '{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\".phi-task.md\"}}' | '$HOOK'"
  [ "$status" -eq 2 ]
}
