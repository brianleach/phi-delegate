#!/usr/bin/env bats
load helpers

setup() {
  PREP="$(phi_repo_root)/scripts/prepare-sidecar.sh"
  setup_fixture_repo
}

mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

@test "creates the sidecar 600 in a 700 folder and excludes it from git" {
  run "$PREP" "$PWD" 01-fix
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(mode_of .phi-tasks)" = "700" ]
  [ "$(mode_of .phi-tasks/01-fix.private.md)" = "600" ]
  grep -qxF '.phi-tasks/' .git/info/exclude
  grep -qxF '.phi-worktrees/' .git/info/exclude
  [ -z "$(git status --porcelain)" ]
}

@test "is idempotent and does not repeat exclude lines" {
  "$PREP" "$PWD" 01-fix
  run "$PREP" "$PWD" 01-fix
  [ "$status" -eq 0 ]
  [ "$(grep -cxF '.phi-tasks/' .git/info/exclude)" -eq 1 ]
}

@test "refuses a symlinked .phi-tasks folder" {
  mkdir staging
  ln -s staging .phi-tasks
  run "$PREP" "$PWD" 01-fix
  [ "$status" -eq 1 ]
  [ ! -e staging/01-fix.private.md ]
}

@test "refuses a symlinked sidecar" {
  mkdir -p .phi-tasks
  ln -s ../seed.txt .phi-tasks/01-fix.private.md
  run "$PREP" "$PWD" 01-fix
  [ "$status" -eq 1 ]
}

@test "refuses outside a git repo and refuses bad names" {
  run "$PREP" "${BATS_TEST_TMPDIR}" 01-fix
  [ "$status" -ne 0 ]
  run "$PREP" "$PWD" ../escape
  [ "$status" -eq 2 ]
}
