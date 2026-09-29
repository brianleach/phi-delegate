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

# Run delegate.sh and collect.sh from a copy of scripts/ whose phi-scan.sh
# is a spy: it logs its argv, one call per line, then runs the real
# scanner. Lets a test pin which scans use which profile.
install_scan_spy() {
  SPY_DIR="${BATS_TEST_TMPDIR}/spy-scripts"
  mkdir -p "$SPY_DIR"
  cp "$ROOT"/scripts/*.sh "$SPY_DIR/"
  mv "$SPY_DIR/phi-scan.sh" "$SPY_DIR/phi-scan.real.sh"
  export SCAN_SPY_LOG="${BATS_TEST_TMPDIR}/scan-calls.log"
  cat >"$SPY_DIR/phi-scan.sh" <<'SPY'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$SCAN_SPY_LOG"
exec "$(dirname "$0")/phi-scan.real.sh" "$@"
SPY
  chmod +x "$SPY_DIR/phi-scan.sh"
}

# The diff is piped in, so its call is exactly the flags; the handoff call
# names the handoff file and must stay on the default profile.
assert_scan_profiles() {
  grep -qx -- '--profile diff' "$SCAN_SPY_LOG"
  grep -q 'handoff\.md$' "$SCAN_SPY_LOG"
  [ -z "$(grep -- 'handoff.*--profile\|--profile.*handoff' "$SCAN_SPY_LOG")" ]
}

@test "delegate scans the diff with the diff profile and the handoff without it" {
  install_scan_spy
  run "$SPY_DIR/delegate.sh" "${BATS_TEST_TMPDIR}/01-task.md"
  [ "$status" -eq 0 ]
  assert_scan_profiles
}

@test "collect scans the diff with the diff profile and the handoff without it" {
  install_scan_spy
  "$SPY_DIR/delegate.sh" "${BATS_TEST_TMPDIR}/01-task.md" >/dev/null
  : >"$SCAN_SPY_LOG"
  run "$SPY_DIR/collect.sh" 01-task
  [ "$status" -eq 0 ]
  assert_scan_profiles
}

@test "refuses on detached HEAD" {
  git checkout -q --detach
  run "$ROOT/scripts/delegate.sh" "${BATS_TEST_TMPDIR}/01-task.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"detached HEAD"* ]]
}
