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
  run bash -c "printf 'DOB: 1970\nmail someone@example.com\n' | '$SCAN'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"dob-keyword"* ]]
  [[ "$output" == *"email-address"* ]]
}

# expect_class <class> <flagged|clean> <line>...: each line alone, scanned
# for that one class.
expect_class() {
  local class="$1" want="$2" line
  shift 2
  for line in "$@"; do
    run "$SCAN" --only "$class" <<<"$line"
    if [ "$want" = flagged ]; then
      [ "$status" -eq 1 ] || { echo "not flagged: $line"; return 1; }
    else
      [ "$status" -eq 0 ] || { echo "flagged: $line"; return 1; }
    fi
  done
}

@test "patient-name-keyword needs a capitalized value after the key" {
  expect_class patient-name-keyword flagged 'Patient name: Test Person' \
    '"first_name": "Maria"' 'first_name: "Maria"' "firstName = 'Maria'" \
    'LAST_NAME => "Sample"'
  expect_class patient-name-keyword clean 'self.first_name = params[:first_name]' \
    'attribute :first_name' 'SELECT first_name, dob FROM patients' 'first_name: "maria"'
}

@test "dob-keyword needs a date-like value after the key" {
  expect_class dob-keyword flagged 'DOB 3 Mar 1984' 'date of birth 01/02/1970' \
    'dob: "1984-03-03"' 'DOB: March 3, 1984'
  expect_class dob-keyword clean 'attribute :dob' 'dob FROM' \
    'the date of birth field rejects future dates' 'DOB may be blank'
}

@test "identifier-keyword needs an id-shaped value after the key" {
  expect_class identifier-keyword flagged 'MRN SYN0000123' 'MRN A123456' \
    'member id XKQ12345678' 'SSN (900-12-3456)' 'patient id: 48213' \
    'MRN #: 12345' 'social security number: 900-12-3456'
  expect_class identifier-keyword clean 'a migration for the MRN index' \
    'the member id column' 'MRN 123'
}

@test "date-words flags written-out dates but not a git date header" {
  expect_class date-words flagged 'born March 3, 1984' '3 Mar 1984' \
    'Sept. 12th, 2001' 'the 3rd of March 1984'
  expect_class date-words clean 'Date:   Mon Oct 19 14:32:10 2026 -0500' \
    'you may 3 times 2001' 'March 2001'
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

@test "a missing pattern file is an error, not a flagged scan" {
  cp "$(phi_repo_root)/scripts/phi-scan.sh" "${BATS_TEST_TMPDIR}/phi-scan.sh"
  run "${BATS_TEST_TMPDIR}/phi-scan.sh" <<<"clean text"
  [ "$status" -eq 2 ]
  [[ "$output" == *"pattern file missing"* ]]
}
