#!/usr/bin/env bash
# Run the detector eval: synthetic corpus -> phi-scan.sh -> PII-Tracer -> report.
# Results land in eval/out/ (gitignored). Not part of CI: it needs the model.
#
#   PHI_DELEGATE_DETECTOR_PYTHON  python with torch and transformers installed
#   PHI_DELEGATE_DETECTOR_DIR     local PII-Tracer checkout (never fetched here)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
PY="${PHI_DELEGATE_DETECTOR_PYTHON:?set PHI_DELEGATE_DETECTOR_PYTHON}"
MODEL="${PHI_DELEGATE_DETECTOR_DIR:?set PHI_DELEGATE_DETECTOR_DIR}"
OUT="$HERE/out"
mkdir -p "$OUT"
"$PY" -I "$HERE/gen_corpus.py" "$OUT/corpus.jsonl"
"$PY" -I "$HERE/run_regex.py" "$REPO" "$OUT/corpus.jsonl" "$OUT/regex.jsonl"
"$PY" -I "$HERE/run_tracer.py" "$MODEL" "$REPO" "$OUT/corpus.jsonl" "$OUT/tracer.jsonl"
"$PY" -I "$HERE/score.py" "$OUT/corpus.jsonl" "$OUT/regex.jsonl" "$OUT/tracer.jsonl" "$OUT/report.md"
