#!/usr/bin/env bats
# phi-scan.sh with PHI_DELEGATE_DETECTOR=pii-tracer, against a stub detector
# python: it prints FAKE_DETECTOR_OUT, exits FAKE_DETECTOR_STATUS, and writes a
# synthetic name to stderr so a test can prove stderr is never relayed.
load helpers

setup() {
  SCAN="$(phi_repo_root)/scripts/phi-scan.sh"
  export PHI_DELEGATE_ENV_FILE="${BATS_TEST_TMPDIR}/no-such-env"
  local bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$bin"
  cat >"${bin}/fake-python" <<'FAKE'
#!/usr/bin/env bash
echo "stub stderr: Maria Okafor" >&2
printf '%s\n' "$@" >"${FAKE_DETECTOR_ARGS}"
if [ -n "${PHI_DELEGATE_API_KEY:-}" ]; then echo present; else echo absent; fi >"${FAKE_DETECTOR_KEY}"
cp "$4" "${FAKE_DETECTOR_INPUT}"
printf '%b' "${FAKE_DETECTOR_OUT:-}"
exit "${FAKE_DETECTOR_STATUS:-0}"
FAKE
  chmod +x "${bin}/fake-python"
  export PHI_DELEGATE_DETECTOR=pii-tracer
  export PHI_DELEGATE_DETECTOR_PYTHON="${bin}/fake-python"
  export PHI_DELEGATE_DETECTOR_DIR="${BATS_TEST_TMPDIR}/model"
  export FAKE_DETECTOR_ARGS="${BATS_TEST_TMPDIR}/detector.args"
  export FAKE_DETECTOR_KEY="${BATS_TEST_TMPDIR}/detector.key"
  export FAKE_DETECTOR_INPUT="${BATS_TEST_TMPDIR}/detector.input"
  IN="${BATS_TEST_TMPDIR}/in.txt"
  printf 'mail ops@example.invalid\nPaired with Maria Okafor today.\nUpdated 3 rows.\nAsked Maria Okafor again.\n' >"$IN"
}

no_name_in_output() { [[ "$output" != *"Okafor"* ]]; }

@test "off and unset give the same output as before and never run the detector" {
  export FAKE_DETECTOR_OUT='model-person\t1\n'
  local f p off unset
  for f in "$(phi_repo_root)"/tests/fixtures/*; do
    for p in default diff prose; do
      off="$(PHI_DELEGATE_DETECTOR=off "$SCAN" --profile "$p" "$f" 2>&1 || true)"
      unset="$(env -u PHI_DELEGATE_DETECTOR "$SCAN" --profile "$p" "$f" 2>&1 || true)"
      [ "$off" = "$unset" ]
      [[ "$off" != *"model-"* ]] || false
      [[ "$off" != *"detector-error"* ]] || false
    done
  done
  [ ! -e "$FAKE_DETECTOR_ARGS" ]
}

@test "model hits follow the regex classes, count distinct lines, and flag" {
  export FAKE_DETECTOR_OUT='model-person\t2\nmodel-person\t4\nmodel-person\t2\nmodel-id\t3\n'
  run "$SCAN" "$IN"
  [ "$status" -eq 1 ]
  has "model-person                 2 line(s)"
  has "model-id                     1 line(s)"
  has "phi-scan: 4 potential PHI line(s) flagged (text withheld)"
  [ "${lines[0]}" = "  email-address                1 line(s)" ]
  [ "${lines[1]}" = "  model-person                 2 line(s)" ]
  [ "${lines[2]}" = "  model-id                     1 line(s)" ]
  no_name_in_output
}

@test "the detector is run isolated on the scanned text with the model dir" {
  run "$SCAN" "$IN"
  [ "$status" -eq 1 ]
  [ "$(sed -n 1p "$FAKE_DETECTOR_ARGS")" = "-I" ]
  [ "$(sed -n 2p "$FAKE_DETECTOR_ARGS")" = "$(phi_repo_root)/scripts/phi-detector.py" ]
  [ "$(sed -n 3p "$FAKE_DETECTOR_ARGS")" = "$PHI_DELEGATE_DETECTOR_DIR" ]
  cmp -s "$IN" "$FAKE_DETECTOR_INPUT"
}

@test "the API key is kept out of the detector's environment" {
  export PHI_DELEGATE_API_KEY="test-key-not-real"
  run "$SCAN" "$IN"
  [ "$(cat "$FAKE_DETECTOR_KEY")" = "absent" ]
}

@test "a clean detector run adds nothing" {
  printf 'Updated 3 rows.\n' >"$IN"
  run "$SCAN" "$IN"
  [ "$status" -eq 0 ]
  [ "$output" = "phi-scan: clean" ]
}

@test "a nonzero detector exit is detector-error, even with valid output" {
  export FAKE_DETECTOR_OUT='model-person\t2\n' FAKE_DETECTOR_STATUS=3
  run "$SCAN" "$IN"
  [ "$status" -eq 1 ]
  has "detector-error               1 line(s)"
  lacks "model-person"
  has "text withheld"
  no_name_in_output
}

@test "a missing detector python is detector-error" {
  export PHI_DELEGATE_DETECTOR_PYTHON="${BATS_TEST_TMPDIR}/no-such-python"
  printf 'Updated 3 rows.\n' >"$IN"
  run "$SCAN" "$IN"
  [ "$status" -eq 1 ]
  has "detector-error               1 line(s)"
}

@test "malformed detector output is detector-error" {
  local bad
  for bad in 'model-person\tabc\n' 'bogus\t1\n' 'model-person\t99\n' 'model-person\t0\n' \
    'model-person 2\n' 'model-person\t2\textra\n' 'model-person\t2\n\n' 'Maria Okafor\n'; do
    export FAKE_DETECTOR_OUT="$bad"
    run "$SCAN" "$IN"
    [ "$status" -eq 1 ]
    has "detector-error               1 line(s)"
    lacks "model-person"
    no_name_in_output
  done
}

@test "a detector line number on the last line without a newline is in range" {
  printf 'Updated 3 rows.\nAsked Maria Okafor' >"$IN"
  export FAKE_DETECTOR_OUT='model-person\t2\n'
  run "$SCAN" "$IN"
  has "model-person                 1 line(s)"
  lacks "detector-error"
}

@test "--allow suppresses a model hit on an allowlisted line" {
  export FAKE_DETECTOR_OUT='model-person\t2\nmodel-person\t4\n'
  printf 'today\n' >"${BATS_TEST_TMPDIR}/allow"
  run "$SCAN" --only model-person --allow "${BATS_TEST_TMPDIR}/allow" "$IN"
  [ "$status" -eq 1 ]
  has "model-person                 1 line(s)"
  printf 'today\nagain\n' >"${BATS_TEST_TMPDIR}/allow"
  run "$SCAN" --only model-person --allow "${BATS_TEST_TMPDIR}/allow" "$IN"
  [ "$status" -eq 0 ]
  [ "$output" = "phi-scan: clean" ]
}

@test "--skip model-person drops that class" {
  export FAKE_DETECTOR_OUT='model-person\t2\n'
  run "$SCAN" --skip email-address --skip model-person "$IN"
  [ "$status" -eq 0 ]
  [ "$output" = "phi-scan: clean" ]
}

@test "--only model-id reports only that class" {
  export FAKE_DETECTOR_OUT='model-person\t2\nmodel-id\t3\nmodel-address\t4\n'
  run "$SCAN" --only model-id "$IN"
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "  model-id                     1 line(s)" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "--only and --skip cannot hide detector-error" {
  export FAKE_DETECTOR_STATUS=2
  run "$SCAN" --only model-id "$IN"
  [ "$status" -eq 1 ]
  has "detector-error               1 line(s)"
  run "$SCAN" --skip model-person,model-address,model-id,email-address "$IN"
  [ "$status" -eq 1 ]
  has "detector-error"
  run "$SCAN" --skip detector-error "$IN"
  [ "$status" -eq 2 ]
  has "unknown class: detector-error"
}

@test "model class names are valid for --only with the detector off" {
  export PHI_DELEGATE_DETECTOR=off
  run "$SCAN" --only model-person "$IN"
  [ "$status" -eq 0 ]
  [ "$output" = "phi-scan: clean" ]
}

@test "an unknown PHI_DELEGATE_DETECTOR value exits 2 without running anything" {
  export PHI_DELEGATE_DETECTOR=spacy
  run "$SCAN" "$IN"
  [ "$status" -eq 2 ]
  has "unknown PHI_DELEGATE_DETECTOR: spacy"
  [ ! -e "$FAKE_DETECTOR_ARGS" ]
}

@test "under --profile diff the detector reads the masked text with git metadata dropped" {
  cat >"$IN" <<'DIFF'
diff --git a/ops.md b/ops.md
index 1111111..2222222 100644
--- a/ops.md
+++ b/ops.md
@@ -1 +1,2 @@
 ops notes
+task arn:aws:ecs:us-east-1:123456789012:task/cluster/abc123
DIFF
  run "$SCAN" --profile diff "$IN"
  [ "$status" -eq 0 ]
  no_grep -e '^diff --git' -e '^index ' -e '^--- a/' -e '^+++ b/' -e '^@@' "$FAKE_DETECTOR_INPUT"
  grep -q '^+task \[ARN\]$' "$FAKE_DETECTOR_INPUT"
  no_grep '123456789012' "$FAKE_DETECTOR_INPUT"
  grep -q '^ ops notes$' "$FAKE_DETECTOR_INPUT"
}

@test "the detector's output file is removed when the scan ends" {
  export TMPDIR="${BATS_TEST_TMPDIR}/scan-tmp"
  mkdir -p "$TMPDIR"
  export FAKE_DETECTOR_OUT='model-person\t2\n'
  run "$SCAN" "$IN"
  [ "$status" -eq 1 ]
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "a .env setting turns the detector on and the environment wins over it" {
  export FAKE_DETECTOR_OUT='model-person\t2\n'
  printf 'PHI_DELEGATE_DETECTOR=pii-tracer\nPHI_DELEGATE_DETECTOR_PYTHON=%s\n' "$PHI_DELEGATE_DETECTOR_PYTHON" \
    >"${BATS_TEST_TMPDIR}/env"
  export PHI_DELEGATE_ENV_FILE="${BATS_TEST_TMPDIR}/env"
  unset PHI_DELEGATE_DETECTOR PHI_DELEGATE_DETECTOR_PYTHON
  run "$SCAN" --only model-person "$IN"
  [ "$status" -eq 1 ]
  has "model-person                 1 line(s)"
  run env PHI_DELEGATE_DETECTOR=off "$SCAN" --only model-person "$IN"
  [ "$status" -eq 0 ]
}
