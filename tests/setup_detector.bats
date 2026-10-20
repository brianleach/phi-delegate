#!/usr/bin/env bats
# setup-detector.sh offline: fake curl, uv, and venv python on PATH, and a
# copy of the script whose pinned hashes are rewritten to fake files' hashes.
load helpers

FILES="config.json model.safetensors modeling_pii_masking.py tokenizer.json tokenizer_config.json LICENSE"

hash_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{ print $1 }'
  else sha256sum "$1" | awk '{ print $1 }'; fi
}

setup() {
  export_delegate_env
  unset PHI_DELEGATE_DETECTOR_PYTHON PHI_DELEGATE_DETECTOR_DIR
  local bin="${BATS_TEST_TMPDIR}/bin" f h
  mkdir -p "$bin" "${BATS_TEST_TMPDIR}/scripts" "${BATS_TEST_TMPDIR}/payload"
  cp "$(phi_repo_root)/scripts/setup-detector.sh" "$(phi_repo_root)/scripts/load-env.sh" "${BATS_TEST_TMPDIR}/scripts/"
  SETUP="${BATS_TEST_TMPDIR}/scripts/setup-detector.sh"
  for f in $FILES; do
    printf 'fake %s\n' "$f" >"${BATS_TEST_TMPDIR}/payload/$f"
    h="$(hash_of "${BATS_TEST_TMPDIR}/payload/$f")"
    sed -E "s/^(MODEL_FILES=')?${f} [0-9a-f]{64}('?)\$/\\1${f} ${h}\\2/" "$SETUP" >"$SETUP.new"
    mv "$SETUP.new" "$SETUP"
  done
  chmod +x "$SETUP"
  export FAKE_PAYLOAD="${BATS_TEST_TMPDIR}/payload"
  export FAKE_LOG="${BATS_TEST_TMPDIR}/calls.log"
  : >"$FAKE_LOG"

  # curl -fsSL --retry 3 -o FILE URL: serves the payload, or junk for FAKE_CURL_BAD.
  cat >"${bin}/curl" <<'FAKE'
#!/usr/bin/env bash
out="" url=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac
done
echo "curl $url" >>"$FAKE_LOG"
name="${url##*/}"
if [ "$name" = "${FAKE_CURL_BAD:-}" ]; then echo tampered >"$out"; else cp "$FAKE_PAYLOAD/$name" "$out"; fi
FAKE
  # uv venv --python 3.12 DIR | uv pip install --python PY PKG...
  cat >"${bin}/uv" <<'FAKE'
#!/usr/bin/env bash
echo "uv $*" >>"$FAKE_LOG"
if [ "$1" = venv ]; then
  mkdir -p "$4/bin"
  cat >"$4/bin/python" <<'PY'
#!/usr/bin/env bash
echo "python $1 $2" >>"$FAKE_LOG"
[ -f "$(dirname "$0")/installed" ]
PY
  chmod +x "$4/bin/python"
elif [ "$1" = pip ]; then
  touch "$(dirname "$4")/installed"
fi
FAKE
  chmod +x "${bin}/curl" "${bin}/uv"
  export PATH="${bin}:${PATH}"
  MODEL_DIR="$HOME/.phi-delegate/detector/pii-tracer"
  VENV="$HOME/.phi-delegate/detector/venv"
}

@test "a fresh install creates the venv, downloads every file at the pinned revision, and says how to enable it" {
  run "$SETUP"
  [ "$status" -eq 0 ]
  grep -q "^uv venv --python 3.12 $VENV\$" "$FAKE_LOG"
  grep -q "^uv pip install --python $VENV/bin/python torch==2.14.1 transformers==5.20.2 safetensors==0.8.0 tokenizers==0.23.3\$" "$FAKE_LOG"
  [ "$(grep -c '^curl https://huggingface.co/perplexity-ai/PII-Tracer/resolve/d25c16f2e57e321f6d2527715c01df9112f956f5/' "$FAKE_LOG")" -eq 6 ]
  for f in $FILES; do cmp -s "$FAKE_PAYLOAD/$f" "$MODEL_DIR/$f"; done
  has "PHI_DELEGATE_DETECTOR=pii-tracer"
  [ "$(ls -A "$HOME/.phi-delegate/detector")" = "$(printf 'pii-tracer\nvenv')" ]
}

@test "a rerun skips files whose hash matches and an up-to-date venv" {
  "$SETUP" >/dev/null
  : >"$FAKE_LOG"
  run "$SETUP"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'hash matches, skipped' <<<"$output")" -eq 6 ]
  no_grep -e '^curl ' -e '^uv ' "$FAKE_LOG"
}

@test "a changed file on disk is downloaded again" {
  "$SETUP" >/dev/null
  echo changed >"$MODEL_DIR/tokenizer.json"
  : >"$FAKE_LOG"
  run "$SETUP"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^curl ' "$FAKE_LOG")" -eq 1 ]
  grep -q '/tokenizer.json$' "$FAKE_LOG"
  cmp -s "$FAKE_PAYLOAD/tokenizer.json" "$MODEL_DIR/tokenizer.json"
}

@test "a hash mismatch aborts, installs nothing, and deletes the download dir" {
  export FAKE_CURL_BAD=model.safetensors
  run "$SETUP"
  [ "$status" -eq 1 ]
  has "sha256 mismatch for model.safetensors; nothing was installed"
  [ ! -e "$MODEL_DIR" ]
  [ "$(ls -A "$HOME/.phi-delegate/detector")" = "venv" ]
}

@test "--check passes after an install and never downloads" {
  "$SETUP" >/dev/null
  : >"$FAKE_LOG"
  run "$SETUP" --check
  [ "$status" -eq 0 ]
  [ "$(grep -c '^ok    ' <<<"$output")" -eq 7 ]
  no_grep -e '^curl ' -e '^uv ' "$FAKE_LOG"
}

@test "--check fails on a missing install and changes nothing" {
  run "$SETUP" --check
  [ "$status" -eq 1 ]
  has "FAIL  config.json (missing or hash mismatch)"
  has "FAIL  venv at $VENV"
  [ ! -s "$FAKE_LOG" ]
  [ ! -e "$HOME/.phi-delegate/detector" ]
}

@test "--check catches a tampered file" {
  "$SETUP" >/dev/null
  echo tampered >"$MODEL_DIR/modeling_pii_masking.py"
  run "$SETUP" --check
  [ "$status" -eq 1 ]
  has "FAIL  modeling_pii_masking.py (missing or hash mismatch)"
  has "ok    config.json"
}

@test "an unknown argument is a usage error" {
  run "$SETUP" --force
  [ "$status" -eq 2 ]
  has "usage: setup-detector.sh [--check]"
}
