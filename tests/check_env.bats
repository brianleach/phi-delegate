#!/usr/bin/env bats
# Only the orchestrator-guard and detector lines are checked: the rest needs a
# live API key.
load helpers

setup() {
  export_delegate_env
  unset PHI_DELEGATE_API_KEY
  mkdir -p "$HOME/.claude"
  CHECK="$(phi_repo_root)/scripts/check-env.sh"
}

@test "an enabled phi-delegate plugin counts as the orchestrator guard" {
  printf '{"enabledPlugins":{"phi-delegate@phi-delegate":true}}\n' >"$HOME/.claude/settings.json"
  run "$CHECK"
  [[ "$output" == *"ok    phi-delegate plugin enabled"* ]]
}

@test "the settings guard hook still counts" {
  printf '{"hooks":{"PreToolUse":[{"hooks":[{"command":"x/scripts/guard-hook.sh"}]}]}}\n' >"$HOME/.claude/settings.json"
  run "$CHECK"
  [[ "$output" == *"ok    orchestrator guard hook installed"* ]]
}

@test "neither warns" {
  printf '{}\n' >"$HOME/.claude/settings.json"
  run "$CHECK"
  [[ "$output" == *"warn  neither the phi-delegate plugin nor the guard hook"* ]]
}

@test "the detector is not checked while it is off" {
  printf '{}\n' >"$HOME/.claude/settings.json"
  run "$CHECK"
  lacks "detector"
}

install_fake_detector() {
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  cat >"${BATS_TEST_TMPDIR}/bin/fake-python" <<'FAKE'
#!/usr/bin/env bash
printf 'model-person\t1\n'
exit "${FAKE_DETECTOR_STATUS:-0}"
FAKE
  chmod +x "${BATS_TEST_TMPDIR}/bin/fake-python"
  export PHI_DELEGATE_DETECTOR=pii-tracer
  export PHI_DELEGATE_DETECTOR_PYTHON="${BATS_TEST_TMPDIR}/bin/fake-python"
  export PHI_DELEGATE_DETECTOR_DIR="${BATS_TEST_TMPDIR}/no-model"
  printf '{}\n' >"$HOME/.claude/settings.json"
}

@test "an enabled detector with no model files fails the install check; the smoke test still runs" {
  install_fake_detector
  run "$CHECK"
  [ "$status" -eq 1 ]
  has "FAIL  detector pii-tracer is enabled but its install does not check out"
  has "ok    detector smoke test: phi-scan.sh reports model-person"
}

@test "a failing detector fails the smoke test" {
  install_fake_detector
  export FAKE_DETECTOR_STATUS=2
  run "$CHECK"
  [ "$status" -eq 1 ]
  has "FAIL  detector smoke test: phi-scan.sh did not report model-person"
}
