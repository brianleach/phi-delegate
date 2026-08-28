#!/usr/bin/env bats
load helpers

setup() {
  ROOT="$(phi_repo_root)"
  install_fake_claude
  export_delegate_env
  setup_fixture_repo
  printf 'do an offline task\n' >"${BATS_TEST_TMPDIR}/01-task.md"
}

@test "delegate runs, quarantines log, prints clean handoff, commits work" {
  run "$ROOT/scripts/delegate.sh" "${BATS_TEST_TMPDIR}/01-task.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"handoff (phi-scan clean)"* ]]
  [[ "$output" == *"Updated seed.txt"* ]]
  [[ "$output" != *'"type":"result"'* ]]
  [ ! -f .phi-worktrees/01-task.log ]
  [ -f .phi-worktrees/01-task.handoff.md ]
  [ -z "$(ls -A "$PHI_DELEGATE_CONFIG_DIR" 2>/dev/null)" ]
  [ ! -f .phi-worktrees/01-task/.phi-task.md ]
  [ ! -f .phi-worktrees/01-task/.phi-handoff.md ]
  git show-ref --verify --quiet refs/heads/phi/01-task
  [ "$(git rev-list --count main..phi/01-task)" -eq 1 ]
  grep -qxF '.phi-worktrees/' .git/info/exclude
}

@test "handoff containing PHI-shaped text is withheld" {
  export FAKE_HANDOFF="patient ssn 123-45-6789 updated"
  run "$ROOT/scripts/delegate.sh" "${BATS_TEST_TMPDIR}/01-task.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"handoff WITHHELD"* ]]
  [[ "$output" != *"123-45-6789"* ]]
  [ ! -f .phi-worktrees/01-task.handoff.md ]
}

@test "PHI_DELEGATE_KEEP_LOG=1 keeps the transcript at mode 600" {
  PHI_DELEGATE_KEEP_LOG=1 run "$ROOT/scripts/delegate.sh" "${BATS_TEST_TMPDIR}/01-task.md"
  [ "$status" -eq 0 ]
  [ -f .phi-worktrees/01-task.log ]
  [ "$(stat -c '%a' .phi-worktrees/01-task.log 2>/dev/null || stat -f '%Lp' .phi-worktrees/01-task.log)" = "600" ]
}

@test "collect shows stat and merges after review" {
  "$ROOT/scripts/delegate.sh" "${BATS_TEST_TMPDIR}/01-task.md" >/dev/null
  run "$ROOT/scripts/collect.sh" 01-task
  [ "$status" -eq 0 ]
  [[ "$output" == *"seed.txt"* ]]
  [[ "$output" == *"diff scan: phi-scan: clean"* ]]
  run "$ROOT/scripts/collect.sh" 01-task --merge
  [ "$status" -eq 0 ]
  grep -q 'delegate wrote this' seed.txt
  [ ! -d .phi-worktrees/01-task ]
  [ ! -f .phi-worktrees/01-task.handoff.md ]
  [ ! -f .phi-worktrees/01-task.spec ]
  [ ! -f "${BATS_TEST_TMPDIR}/01-task.md" ]
}

@test "collect --reject removes worktree and branch" {
  "$ROOT/scripts/delegate.sh" "${BATS_TEST_TMPDIR}/01-task.md" >/dev/null
  run "$ROOT/scripts/collect.sh" 01-task --reject
  [ "$status" -eq 0 ]
  [ ! -d .phi-worktrees/01-task ]
  ! git show-ref --verify --quiet refs/heads/phi/01-task
  [ ! -f "${BATS_TEST_TMPDIR}/01-task.md" ]
}

@test "refuses on detached HEAD" {
  git checkout -q --detach
  run "$ROOT/scripts/delegate.sh" "${BATS_TEST_TMPDIR}/01-task.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"detached HEAD"* ]]
}
