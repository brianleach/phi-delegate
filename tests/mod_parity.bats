#!/usr/bin/env bats
# The mod's scanner and phi-scan.sh read one pattern file. The generated
# TypeScript copies must match it, and claude plugin test holds the mod's
# counts to the script's on every fixture.
load helpers

@test "generated pattern and fixture copies match their sources" {
  run "$(phi_repo_root)/scripts/gen-mod-data.sh" --check
  [ "$status" -eq 0 ]
}

@test "editing the pattern file without regenerating is caught" {
  copy="${BATS_TEST_TMPDIR}/copy"
  mkdir -p "$copy"
  cp -R "$(phi_repo_root)/scripts" "$(phi_repo_root)/hooks" "$(phi_repo_root)/tests" "$copy/"
  printf 'class\textra-class\t-\tidentifier\tzzz\n' >>"$copy/scripts/phi-patterns.tsv"
  run "$copy/scripts/gen-mod-data.sh" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"stale: hooks/patterns.generated.ts"* ]]
}

@test "mod scanner gives phi-scan.sh counts on every fixture (claude plugin test)" {
  command -v claude >/dev/null 2>&1 || skip "claude CLI not on PATH"
  run claude plugin test "$(phi_repo_root)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"every fixture gives phi-scan.sh per-class counts"* ]]
  [[ "$output" != *"(fail)"* ]]
}
