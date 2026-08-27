#!/usr/bin/env bats
load helpers

setup() { SCAN="$(phi_repo_root)/scripts/phi-scan.sh"; }

@test "clean text passes" {
  run bash -c "printf 'Updated 3 rows. Tests passed.\n' | '$SCAN'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"phi-scan: clean"* ]]
}

@test "ssn-shaped text is flagged without echoing it" {
  run bash -c "printf 'ssn is 123-45-6789\n' | '$SCAN'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ssn-shaped"* ]]
  [[ "$output" != *"123-45-6789"* ]]
}

@test "dob keyword and email are flagged" {
  run bash -c "printf 'DOB: unknown\nmail someone@example.com\n' | '$SCAN'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"dob-keyword"* ]]
  [[ "$output" == *"email-address"* ]]
}

@test "file argument works" {
  printf 'MRN 12345\n' >"${BATS_TEST_TMPDIR}/h.md"
  run "$SCAN" "${BATS_TEST_TMPDIR}/h.md"
  [ "$status" -eq 1 ]
}
