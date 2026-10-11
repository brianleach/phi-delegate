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
  cp "$ROOT"/scripts/*.sh "$ROOT"/scripts/phi-patterns.tsv "$SPY_DIR/"
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

@test "a staged private input sidecar becomes the Private input section, unprinted" {
  printf 'MRN 99887766\n' >"${BATS_TEST_TMPDIR}/01-task.private.md"
  cat >"${BATS_TEST_TMPDIR}/bin/claude" <<'FAKE'
#!/usr/bin/env bash
cp .phi-task.md "${FAKE_TASK_COPY}"
printf 'done\n' >.phi-handoff.md
echo '{"type":"result","result":"done"}'
FAKE
  export FAKE_TASK_COPY="${BATS_TEST_TMPDIR}/task-copy.md"
  run "$ROOT/scripts/delegate.sh" "${BATS_TEST_TMPDIR}/01-task.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"appended staged private input from 01-task.private.md"* ]]
  [[ "$output" != *"99887766"* ]]
  grep -qx 'do an offline task' "$FAKE_TASK_COPY"
  grep -qx '## Private input' "$FAKE_TASK_COPY"
  grep -qx 'MRN 99887766' "$FAKE_TASK_COPY"
  [ ! -f .phi-worktrees/01-task/.phi-task.md ]
}

@test "without a sidecar the task copy is the spec alone" {
  cat >"${BATS_TEST_TMPDIR}/bin/claude" <<'FAKE'
#!/usr/bin/env bash
cp .phi-task.md "${FAKE_TASK_COPY}"
echo '{"type":"result","result":"done"}'
FAKE
  export FAKE_TASK_COPY="${BATS_TEST_TMPDIR}/task-copy.md"
  run "$ROOT/scripts/delegate.sh" "${BATS_TEST_TMPDIR}/01-task.md"
  [ "$status" -eq 0 ]
  cmp -s "$FAKE_TASK_COPY" "${BATS_TEST_TMPDIR}/01-task.md"
}

@test "refuses a sidecar passed as the spec" {
  printf 'MRN 99887766\n' >"${BATS_TEST_TMPDIR}/01-task.private.md"
  run "$ROOT/scripts/delegate.sh" "${BATS_TEST_TMPDIR}/01-task.private.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"private input sidecar"* ]]
  [[ "$output" != *"99887766"* ]]
}

@test "merge and reject delete the sidecar with the spec" {
  printf 'MRN 99887766\n' >"${BATS_TEST_TMPDIR}/01-task.private.md"
  "$ROOT/scripts/delegate.sh" "${BATS_TEST_TMPDIR}/01-task.md" >/dev/null
  run "$ROOT/scripts/collect.sh" 01-task --merge
  [ "$status" -eq 0 ]
  [ ! -f "${BATS_TEST_TMPDIR}/01-task.private.md" ]
  printf 'do an offline task\n' >"${BATS_TEST_TMPDIR}/02-task.md"
  printf 'MRN 99887766\n' >"${BATS_TEST_TMPDIR}/02-task.private.md"
  "$ROOT/scripts/delegate.sh" "${BATS_TEST_TMPDIR}/02-task.md" >/dev/null
  run "$ROOT/scripts/collect.sh" 02-task --reject
  [ "$status" -eq 0 ]
  [ ! -f "${BATS_TEST_TMPDIR}/02-task.private.md" ]
  [ ! -f "${BATS_TEST_TMPDIR}/02-task.md" ]
}

# Fake gh for collect.sh --pr: no PR exists until create is called.
install_fake_gh_pr() {
  local bin="${BATS_TEST_TMPDIR}/ghbin"
  mkdir -p "$bin"
  cat >"${bin}/gh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_GH_ARGS}"
case "$1 $2" in
  "pr view") [ -f "${FAKE_GH_ARGS}.created" ] && echo "https://example.invalid/pr/7" && exit 0; exit 1 ;;
  "pr create") cp "$(printf '%s\n' "$@" | sed -n '/--body-file/{n;p;}')" "${FAKE_GH_ARGS}.body"; touch "${FAKE_GH_ARGS}.created"; echo "https://example.invalid/pr/7" ;;
esac
FAKE
  chmod +x "${bin}/gh"
  export PATH="${bin}:${PATH}" FAKE_GH_ARGS="${BATS_TEST_TMPDIR}/gh.args"
  git init -q --bare "${BATS_TEST_TMPDIR}/origin.git"
  git remote add origin "${BATS_TEST_TMPDIR}/origin.git"
}

@test "collect --pr opens a draft PR from the scanned handoff once, then prints it" {
  install_fake_gh_pr
  "$ROOT/scripts/delegate.sh" "${BATS_TEST_TMPDIR}/01-task.md" >/dev/null
  run "$ROOT/scripts/collect.sh" 01-task --pr
  [ "$status" -eq 0 ]
  [[ "$output" == *"draft PR: https://example.invalid/pr/7"* ]]
  grep -q 'Updated seed.txt' "${FAKE_GH_ARGS}.body"
  grep -q 'phi-scan: clean' "${FAKE_GH_ARGS}.body"
  git -C "${BATS_TEST_TMPDIR}/origin.git" show-ref --verify --quiet refs/heads/phi/01-task
  run "$ROOT/scripts/collect.sh" 01-task --pr
  [ "$status" -eq 0 ]
  [[ "$output" == *"==> PR: https://example.invalid/pr/7"* ]]
  [ "$(grep -c '^pr create' "$FAKE_GH_ARGS")" -eq 1 ]
}

@test "collect --pr refuses to push or open a PR when the diff scan flags a line" {
  install_fake_gh_pr
  export FAKE_EDIT="contact jane.doe@example.invalid"
  "$ROOT/scripts/delegate.sh" "${BATS_TEST_TMPDIR}/01-task.md" >/dev/null
  run "$ROOT/scripts/collect.sh" 01-task --pr
  [ "$status" -ne 0 ]
  [[ "$output" == *"potential PHI line(s) flagged"* ]]
  [[ "$output" == *"not pushing and not opening a PR"* ]]
  [[ "$output" != *"jane.doe"* ]]
  ! git -C "${BATS_TEST_TMPDIR}/origin.git" show-ref --verify --quiet refs/heads/phi/01-task
  [ ! -f "${FAKE_GH_ARGS}.created" ]
  git show-ref --verify --quiet refs/heads/phi/01-task
  run "$ROOT/scripts/collect.sh" 01-task --pr --push-flagged
  [ "$status" -eq 0 ]
  [[ "$output" == *"draft PR: https://example.invalid/pr/7"* ]]
  git -C "${BATS_TEST_TMPDIR}/origin.git" show-ref --verify --quiet refs/heads/phi/01-task
}

@test "delegate --pr refuses to push or open a PR when the diff scan flags a line" {
  install_fake_gh_pr
  export FAKE_EDIT="contact jane.doe@example.invalid"
  run "$ROOT/scripts/delegate.sh" "${BATS_TEST_TMPDIR}/01-task.md" --pr
  [ "$status" -ne 0 ]
  [[ "$output" == *"potential PHI line(s) flagged"* ]]
  [[ "$output" == *"not pushing and not opening a PR"* ]]
  [[ "$output" == *"handoff (phi-scan clean)"* ]]
  [[ "$output" != *"jane.doe"* ]]
  ! git -C "${BATS_TEST_TMPDIR}/origin.git" show-ref --verify --quiet refs/heads/phi/01-task
  [ ! -f "${FAKE_GH_ARGS}.created" ]
  git show-ref --verify --quiet refs/heads/phi/01-task
}

@test "delegate --pr --push-flagged keeps the old behaviour and opens the PR" {
  install_fake_gh_pr
  export FAKE_EDIT="contact jane.doe@example.invalid"
  run "$ROOT/scripts/delegate.sh" "${BATS_TEST_TMPDIR}/01-task.md" --pr --push-flagged
  [ "$status" -eq 0 ]
  [[ "$output" == *"draft PR: https://example.invalid/pr/7"* ]]
  grep -q 'flagged' "${FAKE_GH_ARGS}.body"
  git -C "${BATS_TEST_TMPDIR}/origin.git" show-ref --verify --quiet refs/heads/phi/01-task
}
