#!/usr/bin/env bats
load helpers

setup() {
  CLEANUP="$(phi_repo_root)/scripts/cleanup.sh"
  export_delegate_env
  setup_fixture_repo
  # Residue an interactive run or a killed delegate leaves behind.
  printf 'patient ssn 123-45-6789\n' >.phi-handoff.md
  printf 'aggregate only\n' >.phi-handoff-01-thing.md
  mkdir -p .phi-tasks
  printf '# Task\n\n## Private input\n\nMRN 99887766\n' >.phi-tasks/01-thing.md
  printf 'MRN 55443322\n' >.phi-tasks/01-thing.private.md
  mkdir -p .phi-worktrees
  git worktree add -q -b phi/01-thing .phi-worktrees/01-thing main
  printf 'delegate work\n' >>.phi-worktrees/01-thing/seed.txt
  git -C .phi-worktrees/01-thing commit -q -am "delegate commit"
  printf 'transcript\n' >.phi-worktrees/01-thing.log
  printf 'main\n' >.phi-worktrees/01-thing.base
  printf '.phi-tasks/01-thing.md\n' >.phi-worktrees/01-thing.spec
  export PHI_DELEGATE_CONFIG_DIR="${BATS_TEST_TMPDIR}/cfg"
  mkdir -p "$PHI_DELEGATE_CONFIG_DIR/run-stale"
  printf 'session\n' >"$PHI_DELEGATE_CONFIG_DIR/run-stale/history.jsonl"
}

@test "dry run lists residue by name, prints no contents, deletes nothing" {
  run "$CLEANUP"
  [ "$status" -eq 0 ]
  [[ "$output" == *".phi-handoff.md"* ]]
  [[ "$output" == *".phi-handoff-01-thing.md"* ]]
  [[ "$output" == *".phi-tasks/ (2 files)"* ]]
  [[ "$output" == *"private input sidecar: .phi-tasks/01-thing.private.md"* ]]
  [[ "$output" != *"55443322"* ]]
  [ -f .phi-tasks/01-thing.private.md ]
  [[ "$output" == *"worktree: .phi-worktrees/01-thing/"* ]]
  [[ "$output" == *".phi-worktrees/01-thing.log"* ]]
  [[ "$output" == *"branch (UNMERGED, kept): phi/01-thing"* ]]
  [[ "$output" == *"config dir:"* ]]
  [[ "$output" == *"dry run"* ]]
  [[ "$output" != *"123-45-6789"* ]]
  [[ "$output" != *"99887766"* ]]
  [ -f .phi-handoff.md ]
  [ -d .phi-tasks ]
  [ -d .phi-worktrees/01-thing ]
  git show-ref --verify --quiet refs/heads/phi/01-thing
}

@test "--apply removes files and worktrees but keeps an unmerged branch and sessions" {
  run "$CLEANUP" --apply
  [ "$status" -eq 0 ]
  [ ! -e .phi-handoff.md ]
  [ ! -e .phi-handoff-01-thing.md ]
  [ ! -d .phi-tasks ]
  [ ! -e .phi-tasks/01-thing.private.md ]
  [ ! -d .phi-worktrees ]
  git show-ref --verify --quiet refs/heads/phi/01-thing
  ! git worktree list --porcelain | grep -q phi-worktrees
  [ -f "$PHI_DELEGATE_CONFIG_DIR/run-stale/history.jsonl" ]
  [[ "$output" == *"kept (pass --sessions to delete)"* ]]
  [[ "$output" == *"removed"* ]]
}

@test "--apply --branches deletes only a merged phi branch" {
  git worktree remove --force .phi-worktrees/01-thing
  git branch -q phi/02-done main
  run "$CLEANUP" --apply --branches
  [ "$status" -eq 0 ]
  ! git show-ref --verify --quiet refs/heads/phi/02-done
  git show-ref --verify --quiet refs/heads/phi/01-thing
  [[ "$output" == *"branch (merged): phi/02-done"* ]]
  [[ "$output" == *"branch (UNMERGED, kept): phi/01-thing"* ]]
}

# Fake gh: reports the PR state named in FAKE_GH_STATE for any --head query.
install_fake_gh() {
  local bin="${BATS_TEST_TMPDIR}/ghbin"
  mkdir -p "$bin"
  cat >"${bin}/gh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"${FAKE_GH_ARGS}"
if [ -n "${FAKE_GH_STATE:-}" ]; then
  printf '[{"number":42,"state":"%s"}]\n' "$FAKE_GH_STATE"
else
  printf '[]\n'
fi
FAKE
  chmod +x "${bin}/gh"
  export PATH="${bin}:${PATH}"
  export FAKE_GH_ARGS="${BATS_TEST_TMPDIR}/gh.args"
  git remote add origin https://example.invalid/owner/repo.git
}

@test "a squash-merged PR on GitHub marks a non-ancestor branch as merged" {
  install_fake_gh
  export FAKE_GH_STATE=MERGED
  git worktree remove --force .phi-worktrees/01-thing
  run "$CLEANUP" --apply --branches
  [ "$status" -eq 0 ]
  [[ "$output" == *"branch (merged via PR #42): phi/01-thing"* ]]
  ! git show-ref --verify --quiet refs/heads/phi/01-thing
  grep -qx -- "--head" "$FAKE_GH_ARGS"
  grep -qx -- "phi/01-thing" "$FAKE_GH_ARGS"
}

@test "an open or closed-unmerged PR keeps the branch" {
  install_fake_gh
  git worktree remove --force .phi-worktrees/01-thing
  export FAKE_GH_STATE=OPEN
  run "$CLEANUP" --apply --branches
  [[ "$output" == *"PR #42 still open, kept"* ]]
  git show-ref --verify --quiet refs/heads/phi/01-thing
  export FAKE_GH_STATE=CLOSED
  run "$CLEANUP" --apply --branches
  [[ "$output" == *"PR #42 closed without merge, kept"* ]]
  git show-ref --verify --quiet refs/heads/phi/01-thing
}

@test "--no-github skips the PR lookup and keeps the branch" {
  install_fake_gh
  export FAKE_GH_STATE=MERGED
  run "$CLEANUP" --no-github
  [ "$status" -eq 0 ]
  [[ "$output" == *"branch (UNMERGED, kept): phi/01-thing"* ]]
  [ ! -f "$FAKE_GH_ARGS" ]
}

@test "no origin means no GitHub lookup" {
  run "$CLEANUP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"branch (UNMERGED, kept): phi/01-thing"* ]]
}

@test "--apply --sessions empties the delegate config dir" {
  run "$CLEANUP" --apply --sessions
  [ "$status" -eq 0 ]
  [ -d "$PHI_DELEGATE_CONFIG_DIR" ]
  [ -z "$(ls -A "$PHI_DELEGATE_CONFIG_DIR")" ]
}

@test "--all sweeps every repo under a root and skips non-repos" {
  export PHI_DELEGATE_CONFIG_DIR="${BATS_TEST_TMPDIR}/no-cfg"
  root="${BATS_TEST_TMPDIR}/root"
  mkdir -p "$root/plain" "$root/other"
  git init -q -b main "$root/other"
  printf 'x\n' >"$root/other/.phi-handoff.md"
  run "$CLEANUP" --all "$root"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$root/other"* ]]
  [[ "$output" != *"$root/plain"* ]]
  [[ "$output" == *"found 1 items"* ]]
}

@test "a clean repo reports clean" {
  rm -f .phi-handoff.md .phi-handoff-01-thing.md
  rm -rf .phi-tasks
  git worktree remove --force .phi-worktrees/01-thing
  git branch -q -D phi/01-thing
  rm -rf .phi-worktrees
  rm -rf "$PHI_DELEGATE_CONFIG_DIR"
  run "$CLEANUP"
  [ "$status" -eq 0 ]
  [[ "$output" == *"clean"* ]]
  [[ "$output" == *"found 0 items"* ]]
}
