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
