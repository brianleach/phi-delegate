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

@test "aws arn and ecr image uri are not flagged as long digit runs" {
  run bash -c "printf 'task arn:aws:ecs:us-east-1:123456789012:task/cluster/abc123\nimage 123456789012.dkr.ecr.us-east-1.amazonaws.com/app:tag-1\n' | '$SCAN'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"phi-scan: clean"* ]]
}

@test "bare long digit run is still flagged" {
  run bash -c "printf 'member 123456789012 updated\n' | '$SCAN'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"long-digit-run"* ]]
  [[ "$output" != *"123456789012"* ]]
}

@test "file argument works" {
  printf 'MRN 12345\n' >"${BATS_TEST_TMPDIR}/h.md"
  run "$SCAN" "${BATS_TEST_TMPDIR}/h.md"
  [ "$status" -eq 1 ]
}
