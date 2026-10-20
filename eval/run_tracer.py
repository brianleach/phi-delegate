"""Run PII-Tracer on every corpus sample and on the repo's fixtures.

Loads the model from a local directory only (HF_HUB_OFFLINE is forced), so
nothing is fetched at run time. Text longer than one window is split on line
boundaries and the span offsets are shifted back.

usage: run_tracer.py MODEL_DIR REPO CORPUS OUT [--device cuda|mps|cpu]
"""

import importlib.util
import json
import pathlib
import statistics
import sys
import time

# -I leaves the script folder off sys.path; preprocess.py lives beside this file
HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

# Loading, windowing, and span confidence come from the shipped detector, so
# the eval measures what phi-scan.sh runs. Its file name has a hyphen, so it
# is loaded by path. Importing it forces the Hugging Face hub offline.
sys.dont_write_bytecode = True  # no __pycache__ left in scripts/
_spec = importlib.util.spec_from_file_location("phi_detector", HERE.parent / "scripts" / "phi-detector.py")
detector = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(detector)
chunks, predict_conf = detector.chunks, detector.predict_conf

import torch  # noqa: E402

LABEL_TO_CAT = {
    "private_person": "person", "private_date": "date", "account_number": "id",
    "other_pii": "id", "private_address": "address", "private_email": "email",
    "private_phone": "phone", "private_url": "url", "secret": "secret",
}


def predict(model, text):
    spans, sens = [], 0.0
    for off, chunk in chunks(text):
        s, v = model.predict(chunk)
        sens = max(sens, v)
        spans += [{"label": x.label, "cat": LABEL_TO_CAT.get(x.label, x.label),
                   "start": x.start + off, "end": x.end + off} for x in s]
    return spans, sens


def para_chunks(text, cap=1200):
    """Blank-line paragraphs, split further on lines past cap characters."""
    pos = 0
    for para in text.split("\n\n"):
        start, buf = pos, ""
        for line in para.splitlines(keepends=True):
            if buf and len(buf) + len(line) > cap:
                yield start, buf
                start, buf = start + len(buf), ""
            buf += line
        if buf:
            yield start, buf
        pos += len(para) + 2


def spans_for(model, text, mode):
    parts = chunks(text) if mode == "whole" else para_chunks(text)
    return [dict(x, start=x["start"] + off, end=x["end"] + off)
            for off, part in parts for x in predict_conf(model, part)]


def main(model_dir, repo, corpus, out, device):
    from preprocess import Preprocessor
    pre = Preprocessor(repo)
    t_load = time.perf_counter()
    model = detector.load_model(model_dir, device)
    t_load = time.perf_counter() - t_load
    predict(model, "warm up the kernels")

    rows = [json.loads(l) for l in open(corpus)]
    inputs = [("corpus", r["id"], r["text"], "diff" if r["kind"] == "diff" else "default") for r in rows]
    for fx in sorted((pathlib.Path(repo) / "tests" / "fixtures").iterdir()):
        inputs.append(("fixtures", fx.name, fx.read_text(errors="replace"),
                       "diff" if fx.suffix == ".diff" else "default"))

    times, para_ms, results = [], [], []
    for suite, sid, text, profile in inputs:
        t0 = time.perf_counter()
        spans, sens = predict(model, text)
        if device == "mps":
            torch.mps.synchronize()
        dt = time.perf_counter() - t0
        if suite == "corpus":
            times.append(dt)
        # pre: the text after phi-scan's masks and diff drops, so offsets are
        # not comparable to gold spans; only the verdict and labels are scored
        ptext = pre(text, profile)
        pre_spans = spans_for(model, ptext, "whole")
        t1 = time.perf_counter()
        para_spans = spans_for(model, ptext, "para")
        para_ms.append(time.perf_counter() - t1) if suite == "corpus" else None
        results.append({"id": sid, "suite": suite, "flagged": bool(spans), "sensitivity": round(sens, 4),
                        "spans": spans, "cats": sorted({s["cat"] for s in spans}), "ms": round(1000 * dt, 1),
                        "pre_labels": sorted({s["label"] for s in pre_spans}),
                        "pre_spans": [{"label": x["label"], "conf": x["conf"]} for x in pre_spans],
                        "para_spans": [{"label": x["label"], "conf": x["conf"]} for x in para_spans]})
    with open(out, "w") as f:
        for res in results:
            f.write(json.dumps(res) + "\n")
    meta = {"device": device, "load_s": round(t_load, 1),
            "ms_median": round(1000 * statistics.median(times), 1),
            "ms_p95": round(1000 * sorted(times)[int(0.95 * len(times))], 1),
            "para_ms_median": round(1000 * statistics.median(para_ms), 1),
            "rss_gb": None}
    try:
        import resource
        meta["rss_gb"] = round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 2**30, 2)
    except Exception:
        pass
    pathlib.Path(out).with_suffix(".meta.json").write_text(json.dumps(meta))
    print(f"tracer: {json.dumps(meta)}", file=sys.stderr)


if __name__ == "__main__":
    a = sys.argv[1:]
    dev = detector.pick_device()
    if "--device" in a:
        i = a.index("--device")
        dev = a[i + 1]
        del a[i:i + 2]
    main(*a[:4], dev)
