#!/usr/bin/env bats
# Fixture corpus for phi-scan.sh precision. Every fixture is synthetic.
load helpers

setup() {
  SCAN="$(phi_repo_root)/scripts/phi-scan.sh"
  FX="$(phi_repo_root)/tests/fixtures"
}

# expect_verdict <clean|flagged> <fixture> [scanner args...]
expect_verdict() {
  local want="$1" fx="$2"
  shift 2
  run "$SCAN" "$@" "$FX/$fx"
  if [ "$want" = clean ]; then
    [ "$status" -eq 0 ] && [[ "$output" == *"phi-scan: clean"* ]]
  else
    [ "$status" -eq 1 ] && [[ "$output" == *"text withheld"* ]]
  fi
}

@test "clean: readme paragraph passes with keyword classes skipped" {
  expect_verdict clean clean-readme.md --skip dob-keyword,identifier-keyword --skip clinical-keyword
}
@test "clean: commit diff with author trailers passes under diff profile" {
  expect_verdict clean clean-commit.diff --profile diff
}
@test "clean: code diff with uuids and timestamps passes under diff profile" {
  expect_verdict clean clean-code.diff --profile diff
}
@test "clean: log excerpt passes" { expect_verdict clean clean-log.txt; }
@test "clean: json config passes" { expect_verdict clean clean-config.json; }

@test "dirty: ssn is flagged" { expect_verdict flagged dirty-ssn.txt; }
@test "dirty: phone and street address are flagged" { expect_verdict flagged dirty-contact.txt; }
@test "dirty: dob and patient name are flagged" { expect_verdict flagged dirty-dob.txt; }
@test "dirty: clinical and mrn are flagged" { expect_verdict flagged dirty-clinical.txt; }
@test "dirty: email in diff content is flagged under diff profile" {
  expect_verdict flagged dirty-content.diff --profile diff
}

@test "default profile still counts author emails in a diff" {
  expect_verdict flagged clean-commit.diff
  [[ "$output" == *"email-address"* ]]
}
@test "default flags still catch the readme keywords" { expect_verdict flagged clean-readme.md; }
@test "matched text never appears in output" {
  run "$SCAN" "$FX/dirty-ssn.txt"
  [[ "$output" != *"987-65"* ]]
}
@test "--only limits the classes checked" {
  expect_verdict clean dirty-ssn.txt --only email-address
  expect_verdict flagged dirty-ssn.txt --only ssn-shaped
  [[ "$output" != *"identifier-keyword"* ]]
}
@test "unknown class, empty class list, and unknown profile exit 2" {
  run "$SCAN" --skip no-such-class "$FX/clean-log.txt"
  [ "$status" -eq 2 ]
  run "$SCAN" --only , "$FX/clean-log.txt"
  [ "$status" -eq 2 ]
  run "$SCAN" --profile nope "$FX/clean-log.txt"
  [ "$status" -eq 2 ]
}
@test "allowlist drops matched lines after matching" {
  allow="${BATS_TEST_TMPDIR}/.phi-allow"
  printf '# synthetic test domain\n\n@example\\.invalid\n' >"$allow"
  expect_verdict clean clean-commit.diff --allow "$allow"
  expect_verdict flagged dirty-ssn.txt --allow "$allow"
  run "$SCAN" --allow "${BATS_TEST_TMPDIR}/missing" "$FX/clean-log.txt"
  [ "$status" -eq 2 ]
}
