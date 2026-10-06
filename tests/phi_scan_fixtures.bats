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
@test "dirty: paren area code with a space is flagged as phone-shaped" {
  expect_verdict flagged dirty-phone-paren.txt --only phone-shaped
  [[ "$output" == *"phone-shaped"* ]]
  [[ "$output" != *"0142"* ]]
}
@test "phone-shaped covers every separator form" {
  local form
  for form in '555-555-0142' '555.555.0142' '(555)555-0142' '(555) 555-0142'; do
    run "$SCAN" --only phone-shaped <<<"call $form today"
    [ "$status" -eq 1 ]
    [[ "$output" == *"phone-shaped"* ]]
  done
}
@test "delegate diff with an author email is clean only under diff profile" {
  expect_verdict clean clean-delegate.diff --profile diff
  expect_verdict flagged clean-delegate.diff
  [[ "$output" == *"email-address"* ]]
}
@test "prose profile: readme passes with no --skip flags" {
  expect_verdict clean clean-readme.md --profile prose
}
@test "prose profile: ssn and phone in prose are still flagged" {
  expect_verdict flagged dirty-prose-ssn.md --profile prose
  [[ "$output" == *"ssn-shaped"* ]]
  [[ "$output" == *"phone-shaped"* ]]
  [[ "$output" != *"clinical-keyword"* ]]
  [[ "$output" != *"identifier-keyword"* ]]
  [[ "$output" != *"dob-keyword"* ]]
  [[ "$output" != *"4320"* ]]
}
@test "prose profile composes with --only and --skip" {
  expect_verdict clean dirty-prose-ssn.md --profile prose --only clinical-keyword
  expect_verdict flagged dirty-prose-ssn.md --profile prose --only ssn-shaped
  [[ "$output" != *"phone-shaped"* ]]
  expect_verdict flagged dirty-prose-ssn.md --profile prose --skip ssn-shaped
  [[ "$output" == *"phone-shaped"* ]]
  [[ "$output" != *"ssn-shaped"* ]]
  expect_verdict clean dirty-prose-ssn.md --profile prose --skip ssn-shaped,phone-shaped
}
@test "dirty: author-shaped diff context line is scanned under diff profile" {
  expect_verdict flagged dirty-context-author.diff --profile diff
  [[ "$output" == *"email-address"* ]]
}
@test "diff profile drops author-shaped content only at git metadata positions" {
  local line
  for line in ' Author: someone@example.com' '+Author: someone@example.com' \
    '-Signed-off-by: someone@example.com' ' Co-Authored-By: someone@example.com' \
    '  Author: someone@example.com'; do
    run "$SCAN" --profile diff --only email-address <<<"$line"
    [ "$status" -eq 1 ]
  done
  for line in 'Author: someone@example.com' '    Co-Authored-By: someone@example.com'; do
    run "$SCAN" --profile diff --only email-address <<<"$line"
    [ "$status" -eq 0 ]
  done
}
@test "dirty: a 3-space Author: context line inside a hunk is scanned under diff profile" {
  # One leading space plus three is four, the trailer shape; inside a hunk
  # it is content, so the email in it counts while the commit header's do not.
  expect_verdict flagged dirty-hunk-author.diff --profile diff
  [[ "$output" == *"email-address                1 line(s)"* ]]
  expect_verdict flagged dirty-hunk-author.diff
  [[ "$output" == *"email-address                3 line(s)"* ]]
}
@test "a hunk ends at the next commit header, so later trailers drop again" {
  run "$SCAN" --profile diff --only email-address <<<"$(printf '%s\n' \
    '@@ -1 +1 @@' '    Author: in.hunk@example.org' \
    'commit 1a2b3c4' '    Signed-off-by: trailer@example.org')"
  [ "$status" -eq 1 ]
  [[ "$output" == *"email-address                1 line(s)"* ]]
}
@test "dirty: a carriage return does not end a line, so the line still scans" {
  expect_verdict flagged dirty-cr-trailer.txt --profile diff
  [[ "$output" == *"ssn-shaped"* ]]
}
@test "edge: non-ASCII case folding is the same on every platform (C locale)" {
  expect_verdict clean edge-unicode-street.txt
  LC_ALL=en_US.UTF-8 expect_verdict clean edge-unicode-street.txt
}
@test "dirty: a merge commit's combined diff is scanned inside its @@@ hunk" {
  expect_verdict flagged dirty-combined-diff.diff --profile diff
  [[ "$output" == *"ssn-shaped"* ]]
  [[ "$output" != *"email-address"* ]]
}
@test "clean: real git log -p capture passes under diff profile" {
  expect_verdict clean clean-log-p.diff --profile diff
  expect_verdict flagged clean-log-p.diff
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
