#!/usr/bin/env bats
# Only the orchestrator-guard line is checked: the rest needs a live API key.
load helpers

setup() {
  export_delegate_env
  unset PHI_DELEGATE_API_KEY
  mkdir -p "$HOME/.claude"
  CHECK="$(phi_repo_root)/scripts/check-env.sh"
}

@test "an enabled phi-delegate plugin counts as the orchestrator guard" {
  printf '{"enabledPlugins":{"phi-delegate@phi-delegate":true}}\n' >"$HOME/.claude/settings.json"
  run "$CHECK"
  [[ "$output" == *"ok    phi-delegate plugin enabled"* ]]
}

@test "the settings guard hook still counts" {
  printf '{"hooks":{"PreToolUse":[{"hooks":[{"command":"x/scripts/guard-hook.sh"}]}]}}\n' >"$HOME/.claude/settings.json"
  run "$CHECK"
  [[ "$output" == *"ok    orchestrator guard hook installed"* ]]
}

@test "neither warns" {
  printf '{}\n' >"$HOME/.claude/settings.json"
  run "$CHECK"
  [[ "$output" == *"warn  neither the phi-delegate plugin nor the guard hook"* ]]
}
