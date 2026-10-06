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

@test "a Bash command naming the skill repo's scripts is not exempt" {
  run bash -c "printf '%s' '{\"cwd\":\"/tmp\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"bash $(phi_repo_root)/scripts/collect.sh x --full-diff\"}}' | '$HOOK'"
  [ "$status" -eq 2 ]
}

@test "a file tool naming a path inside the skill repo is still exempt" {
  run bash -c "printf '%s' '{\"cwd\":\"/tmp\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$(phi_repo_root)/SKILL.md\",\"new_string\":\".phi-worktrees\"}}' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "reads of .phi-tasks that could reach a sidecar are blocked" {
  local c
  for c in 'cat .phi-tasks/*' 'cat .phi-tasks/01-x.pri*' 'ls .phi-tasks' 'scripts/delegate.sh .phi-tasks/01.md; cat .phi-tasks/*'; do
    run bash -c "printf '%s' '{\"cwd\":\"/tmp\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$c\"}}' | '$HOOK'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"private input sidecars"* ]]
  done
  run bash -c "printf '%s' '{\"cwd\":\"/tmp\",\"tool_name\":\"Grep\",\"tool_input\":{\"pattern\":\"x\",\"path\":\".phi-tasks\"}}' | '$HOOK'"
  [ "$status" -eq 2 ]
}

@test "plain script runs, mkdir, and spec writes may still name .phi-tasks" {
  local c
  for c in 'scripts/delegate.sh .phi-tasks/01-x.md --pr' 'bash /x/scripts/interactive.sh .phi-tasks/01-x.md --permission-mode acceptEdits' 'mkdir -p .phi-tasks'; do
    run bash -c "printf '%s' '{\"cwd\":\"/tmp\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$c\"}}' | '$HOOK'"
    [ "$status" -eq 0 ]
  done
  run bash -c "printf '%s' '{\"cwd\":\"/tmp\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\".phi-tasks/01-x.md\",\"content\":\"spec\"}}' | '$HOOK'"
  [ "$status" -eq 0 ]
}

@test "bracket globs and prefix tricks on .phi-tasks are blocked" {
  local c
  for c in 'cat .phi-task[s]/*' 'cat<.phi-tasks/01.pri*;scripts/delegate.sh' 'scripts/delegate.sh $(cat .phi-tasks/x)'; do
    run bash -c "printf '%s' '{\"cwd\":\"/tmp\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$c\"}}' | '$HOOK'"
    [ "$status" -eq 2 ]
  done
}

@test "quoted script arguments naming .phi-tasks are allowed" {
  local json="${BATS_TEST_TMPDIR}/payload.json"
  cat >"$json" <<'JSON'
{"cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"scripts/delegate.sh \".phi-tasks/01-fix visit.md\" --pr"}}
JSON
  run "$HOOK" <"$json"
  [ "$status" -eq 0 ]
  cat >"$json" <<'JSON'
{"cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"scripts/delegate.sh '.phi-tasks/01-fix visit.md'"}}
JSON
  run "$HOOK" <"$json"
  [ "$status" -eq 0 ]
}

@test "recursive grep is blocked only where delegate state exists, unless it excludes it" {
  local repo="${BATS_TEST_TMPDIR}/repo" json="${BATS_TEST_TMPDIR}/payload.json" c
  mkdir -p "$repo" && git init -q "$repo"
  payload() {
    python3 -c 'import json,sys; print(json.dumps({"cwd":sys.argv[1],"tool_name":"Bash","tool_input":{"command":sys.argv[2]}}, separators=(",", ":")))' "$1" "$2" >"$json"
  }
  payload "$repo" 'grep -R -n patient .'
  run "$HOOK" <"$json"
  [ "$status" -eq 0 ]
  mkdir -p "$repo/.phi-tasks"
  for c in 'grep -R -n patient .' 'grep -rn foo src' 'rg -uu patient'; do
    payload "$repo" "$c"
    run "$HOOK" <"$json"
    [ "$status" -eq 2 ]
  done
  for c in 'rg patient' 'git grep -n patient' "grep -rn x . --exclude-dir='.phi-*'"; do
    payload "$repo" "$c"
    run "$HOOK" <"$json"
    [ "$status" -eq 0 ]
  done
}

@test "a quoted script path naming .phi-tasks is allowed; an expanded one is not" {
  local json="${BATS_TEST_TMPDIR}/payload.json"
  cat >"$json" <<'JSON'
{"cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"bash \"/opt/phi delegate/scripts/delegate.sh\" \".phi-tasks/01-fix.md\" --pr"}}
JSON
  run "$HOOK" <"$json"
  [ "$status" -eq 0 ]
  cat >"$json" <<'JSON'
{"cwd":"/tmp","tool_name":"Bash","tool_input":{"command":"bash \"$HOME/scripts/delegate.sh\" .phi-tasks/01.md"}}
JSON
  run "$HOOK" <"$json"
  [ "$status" -eq 2 ]
}
