#!/usr/bin/env bash
# Install the optional PII-Tracer detector that phi-scan.sh runs when
# PHI_DELEGATE_DETECTOR=pii-tracer: a Python venv with pinned packages and
# the model files at a pinned revision, each checked against a pinned
# sha256 before it is moved into place. Safe to rerun: files whose hash
# already matches are not downloaded again.
#
# usage: setup-detector.sh [--check]
#   --check  verify the model file hashes and the venv's packages; no
#            downloads, no changes. Exit 1 when anything is missing or wrong.
#
# Locations (environment or .env, same as phi-scan.sh):
#   PHI_DELEGATE_DETECTOR_PYTHON  default $HOME/.phi-delegate/detector/venv/bin/python
#                                 (the venv is created two levels above it)
#   PHI_DELEGATE_DETECTOR_DIR     default $HOME/.phi-delegate/detector/pii-tracer
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/load-env.sh"

REPO_ID="perplexity-ai/PII-Tracer"
REVISION="d25c16f2e57e321f6d2527715c01df9112f956f5"
# file sha256, one per line
MODEL_FILES='config.json 7162c30da7009cfb9c9af6204782177ef6f5d88e2653fd87d6514308d97dcaa7
model.safetensors f6204155ec540c9323f706e284110ee848b462f0325dc1ece5c7263fc517bbd0
modeling_pii_masking.py c43724b9ac105a9b74d44aea7565e4c43ddc9d203f519324baa342be01269869
tokenizer.json cae14d1c8dda080f23792355b0692b826bf1f1da3c86ebc1b37548a391cf6526
tokenizer_config.json aa9c1b0a1c9b48c2f70bacdf64f7dab25194be4ffea0c6a6e4da262360a91d0a
LICENSE 7fbf88e9c951fe53eb614a46772d0b48ada6d50b351e5e11dcb64b4dc3fb8eb2'
PACKAGES="torch==2.14.1 transformers==5.20.2 safetensors==0.8.0 tokenizers==0.23.3"

PY="${PHI_DELEGATE_DETECTOR_PYTHON:-$HOME/.phi-delegate/detector/venv/bin/python}"
MODEL_DIR="${PHI_DELEGATE_DETECTOR_DIR:-$HOME/.phi-delegate/detector/pii-tracer}"
VENV_DIR="$(dirname "$(dirname "$PY")")"

check=0
case "${1:-}" in
  "") ;;
  --check) check=1 ;;
  *) echo "usage: setup-detector.sh [--check]" >&2; exit 2 ;;
esac

if command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 "$1" | awk '{ print $1 }'; }
elif command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$1" | awk '{ print $1 }'; }
else
  echo "error: need shasum or sha256sum" >&2
  exit 1
fi

# The venv has every pinned package at its pinned version and torch and
# transformers import.
packages_ok() {
  [ -x "$PY" ] || return 1
  # shellcheck disable=SC2086
  "$PY" -I -c '
import importlib.metadata as m, sys
want = dict(p.split("==") for p in sys.argv[1:])
if any(m.version(k) != v for k, v in want.items()):
    sys.exit(1)
import torch, transformers, safetensors, tokenizers
' $PACKAGES >/dev/null 2>&1
}

file_ok() {
  [ -f "$MODEL_DIR/$1" ] && [ "$(sha256 "$MODEL_DIR/$1")" = "$2" ]
}

if [ "$check" -eq 1 ]; then
  bad=0
  while read -r f want; do
    if file_ok "$f" "$want"; then
      echo "ok    $f"
    else
      echo "FAIL  $f (missing or hash mismatch)"
      bad=1
    fi
  done <<<"$MODEL_FILES"
  if packages_ok; then
    echo "ok    venv packages ($PACKAGES)"
  else
    echo "FAIL  venv at $VENV_DIR is missing or lacks $PACKAGES"
    bad=1
  fi
  exit "$bad"
fi

if packages_ok; then
  echo "==> venv up to date: $VENV_DIR"
else
  if [ ! -x "$PY" ]; then
    echo "==> creating venv: $VENV_DIR"
    mkdir -p "$(dirname "$VENV_DIR")"
    if command -v uv >/dev/null 2>&1; then
      uv venv --python 3.12 "$VENV_DIR"
    else
      command -v python3 >/dev/null 2>&1 || { echo "error: need uv or python3 (3.10 to 3.13)" >&2; exit 1; }
      python3 -c 'import sys; sys.exit(0 if (3, 10) <= sys.version_info[:2] <= (3, 13) else 1)' \
        || { echo "error: python3 must be 3.10 to 3.13 (or install uv)" >&2; exit 1; }
      python3 -m venv "$VENV_DIR"
    fi
  fi
  echo "==> installing $PACKAGES"
  # shellcheck disable=SC2086
  if command -v uv >/dev/null 2>&1; then
    uv pip install --python "$PY" $PACKAGES
  else
    "$PY" -m pip install $PACKAGES
  fi
  packages_ok || { echo "error: the venv still lacks $PACKAGES" >&2; exit 1; }
fi

# Download what is missing into a temp dir beside the model dir (same
# filesystem, so the final mv is a rename), verify every hash, and only then
# move the files into place.
mkdir -p "$(dirname "$MODEL_DIR")"
stage="$(mktemp -d "$(dirname "$MODEL_DIR")/.pii-tracer-download.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
need=""
while read -r f want; do
  if file_ok "$f" "$want"; then
    echo "==> $f: hash matches, skipped"
    continue
  fi
  echo "==> downloading $f"
  curl -fsSL --retry 3 -o "$stage/$f" "https://huggingface.co/$REPO_ID/resolve/$REVISION/$f"
  got="$(sha256 "$stage/$f")"
  if [ "$got" != "$want" ]; then
    echo "error: sha256 mismatch for $f; nothing was installed" >&2
    exit 1
  fi
  need="$need $f"
done <<<"$MODEL_FILES"
if [ -n "$need" ]; then
  mkdir -p "$MODEL_DIR"
  for f in $need; do mv "$stage/$f" "$MODEL_DIR/$f"; done
fi

echo
echo "detector installed: $MODEL_DIR"
echo "enable it by adding this line to the phi-delegate .env:"
echo "  PHI_DELEGATE_DETECTOR=pii-tracer"
echo "then run scripts/check-env.sh"
