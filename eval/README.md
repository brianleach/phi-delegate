# Detector eval

Measures `scripts/phi-scan.sh` and the PII-Tracer model against a seeded,
fully synthetic corpus, so a pattern or threshold change can be judged by
what it catches and what it withholds. Every value is generated: names come
from generic first and last name lists, emails use `example.invalid`, phones
use the 555-01xx range, and SSNs use the never-issued 9xx area.

Not run in CI, because it needs the model.

## Run

```sh
PHI_DELEGATE_DETECTOR_PYTHON=/path/to/venv/bin/python \
PHI_DELEGATE_DETECTOR_DIR=/path/to/pii-tracer \
eval/run.sh
```

The report is `eval/out/report.md`. The model is loaded from the local
directory with the Hugging Face hub forced offline.

## Files

- `gen_corpus.py` - the templates, in three buckets: `phi` (an identifier
  is present), `clean` (ordinary engineering text that must not be
  withheld), and `clinical-only` (medical detail with no identifier).
  Each sample has a kind, `handoff`, `output`, or `diff`, which picks the
  phi-scan profile the way `delegate.sh` and `collect.sh` do.
- `run_regex.py` - runs `phi-scan.sh` on every sample and on
  `tests/fixtures/`.
- `preprocess.py` - applies phi-scan's mask rows and diff drops in Python,
  read from `scripts/phi-patterns.tsv`, so the model can be scored on the
  same text the scanner matches.
- `run_tracer.py` - runs the model on raw and preprocessed text, with a
  confidence per span (the mean of 1 - P(O) over the span's tokens), in
  whole-sample and per-paragraph windows.
- `score.py` - the gate verdict per bucket and kind, category recall, span
  quality, per-template results, a confidence and window sweep, and the
  fixture verdicts.

## Reading it

The corpus was written with the regex scanner's known gaps in mind, so the
headline recall overstates the gap on real handoffs. The per-template
table is the useful part: it shows where each detector is blind.
