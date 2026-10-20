"""PII-Tracer detector for phi-scan.sh.

usage: python -I phi-detector.py MODEL_DIR FILE

Prints one line "class<TAB>line_number" (1-based) per distinct class and line
holding a span the model labels with confidence at or above THRESHOLD. Prints
nothing when nothing is found. Exit 0 on success; on any failure a fixed
message goes to stderr (never input text or exception text) and the exit
status is 2, which phi-scan.sh reports as detector-error.

The model is loaded from the local directory only, with the Hugging Face hub
forced offline, so nothing is fetched at run time. eval/run_tracer.py imports
load_model, chunks, and predict_conf from this file, so the eval measures the
shipped code.
"""

import os
import sys

os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["TRANSFORMERS_VERBOSITY"] = "error"

# The labels the regex classes are blind to; dates, phones, and emails stay
# with the regex. Chosen by eval/score.py.
LABEL_TO_CLASS = {
    "private_person": "model-person",
    "private_address": "model-address",
    "account_number": "model-id",
    "other_pii": "model-id",
}
THRESHOLD = 0.8
CHUNK_CHARS = 10000  # well under 4096 tokens for English and code


def pick_device():
    import torch

    if torch.cuda.is_available():
        return "cuda"
    if torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def load_model(model_dir, device):
    from transformers import AutoModel

    # modeling_pii_masking.py is the remote code; setup-detector.sh pins its hash.
    model = AutoModel.from_pretrained(model_dir, trust_remote_code=True, local_files_only=True)
    return model.to(device).eval()


def chunks(text):
    """(offset, window) pairs, split on line boundaries at CHUNK_CHARS."""
    start, buf = 0, []
    pos = 0
    for line in text.splitlines(keepends=True):
        if buf and pos - start + len(line) > CHUNK_CHARS:
            yield start, "".join(buf)
            start, buf = pos, []
        buf.append(line)
        pos += len(line)
    if buf:
        yield start, "".join(buf)


def predict_conf(model, text):
    """Spans with a confidence: the mean over the span's tokens of 1 - P(O)."""
    import torch

    if not text.strip():
        return []
    tok = model.tokenizer
    enc = tok(text, return_offsets_mapping=True, return_tensors="pt", truncation=True,
              max_length=model.config.max_seq_len)
    if enc["input_ids"].shape[1] == 0:
        return []
    with torch.no_grad():
        out = model(input_ids=enc["input_ids"].to(model.device),
                    attention_mask=enc["attention_mask"].to(model.device))
    logits = out.logits[0].float().cpu()
    p_tag = 1.0 - logits.softmax(-1)[:, 0]
    offsets = [tuple(o) for o in enc["offset_mapping"][0].tolist()]
    res = []
    for sp in model.viterbi.decode(logits, offsets, text=text):
        idx = [i for i, (a, b) in enumerate(offsets) if a < sp.end and sp.start < b]
        conf = float(p_tag[idx].mean()) if idx else 0.0
        res.append({"label": sp.label, "start": sp.start, "end": sp.end, "conf": round(conf, 4)})
    return res


def hits(model, text):
    """Sorted distinct (line_number, class) pairs for qualifying spans."""
    found = set()
    for off, part in chunks(text):
        for sp in predict_conf(model, part):
            cls = LABEL_TO_CLASS.get(sp["label"])
            if cls is None or sp["conf"] < THRESHOLD:
                continue
            # Count "\n" only, the way sed and grep number lines; str.splitlines
            # also breaks on \r, \f, and Unicode separators.
            first = text.count("\n", 0, off + sp["start"]) + 1
            last = text.count("\n", 0, max(off + sp["end"] - 1, off + sp["start"])) + 1
            for n in range(first, last + 1):
                found.add((n, cls))
    return sorted(found)


def main(argv):
    import warnings

    warnings.simplefilter("ignore")
    if len(argv) != 2:
        raise ValueError
    model_dir, path = argv
    with open(path, encoding="utf-8", errors="replace", newline="") as f:
        text = f.read()
    model = load_model(model_dir, pick_device())
    lines = "".join(f"{cls}\t{n}\n" for n, cls in hits(model, text))
    sys.stdout.write(lines)
    sys.stdout.flush()


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except BaseException:  # noqa: BLE001 - every failure must look the same
        sys.stderr.write("phi-detector: failed\n")
        os._exit(2)
    sys.exit(0)
