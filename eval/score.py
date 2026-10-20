"""Score regex and PII-Tracer results against the synthetic gold labels.

usage: score.py CORPUS REGEX_RESULTS TRACER_RESULTS OUT_MD
"""

import collections
import json
import pathlib
import sys

ID_CATS = ["person", "date", "id", "phone", "email", "address"]
# The labels regex is blind to; dates, phones and emails stay with the regex.
SELECTED = {"private_person", "private_address", "account_number", "other_pii"}


def load(path):
    return {(r["suite"], r["id"]): r for r in map(json.loads, open(path))}


def pct(n, d):
    return "-" if d == 0 else f"{100 * n / d:.0f}% ({n}/{d})"


def table(header, rows):
    out = ["| " + " | ".join(header) + " |", "|" + "---|" * len(header)]
    out += ["| " + " | ".join(str(c) for c in row) + " |" for row in rows]
    return "\n".join(out)


def main(corpus, regex_path, tracer_path, out_md):
    gold = [json.loads(l) for l in open(corpus)]
    rx, tr = load(regex_path), load(tracer_path)
    tmeta = json.loads(pathlib.Path(tracer_path).with_suffix(".meta.json").read_text())

    def t(g):
        return tr[("corpus", g["id"])]

    def r(g):
        return rx[("corpus", g["id"])]["flagged"]

    detectors = {
        "regex": r,
        "tracer raw": lambda g: t(g)["flagged"],
        "tracer pre": lambda g: bool(t(g)["pre_labels"]),
        "tracer pre, selected": lambda g: bool(SELECTED & set(t(g)["pre_labels"])),
        "regex OR tracer pre, selected": lambda g: r(g) or bool(SELECTED & set(t(g)["pre_labels"])),
    }
    legend = ["Variants:", "",
              "- **tracer raw**: PII-Tracer on the raw text, any label flags.",
              "- **tracer pre**: PII-Tracer on the text after phi-scan's masks (ARN, ECR, GitHub URL, timestamps) "
              "and, for diffs, its git-metadata drops.",
              "- **tracer pre, selected**: as pre, but only person, address, account_number and other_pii labels flag.",
              "- **regex OR tracer pre, selected**: the proposed combined gate.", ""]
    names = list(detectors)
    md = ["# PHI detector eval: phi-scan.sh vs PII-Tracer", "",
          f"Synthetic corpus: {len(gold)} samples. Every value is generated (example.invalid, 555-01xx, 9xx SSNs).", ""]
    md += legend

    # 1. gate verdict by bucket
    md += ["## Gate verdict (does the scan withhold the text?)", "",
           "phi: higher is better (recall). clean: lower is better (false-flag rate). "
           "clinical-only: medical detail with no identifier, shown for reference.", ""]
    rows = []
    for bucket in ["phi", "clean", "clinical-only"]:
        gs = [g for g in gold if g["bucket"] == bucket]
        rows.append([bucket] + [pct(sum(detectors[n](g) for g in gs), len(gs)) for n in names])
    md += [table(["bucket"] + names, rows), ""]

    rows = []
    for kind in ["handoff", "output", "diff"]:
        for bucket in ["phi", "clean"]:
            gs = [g for g in gold if g["kind"] == kind and g["bucket"] == bucket]
            if gs:
                rows.append([kind, bucket] + [pct(sum(detectors[n](g) for g in gs), len(gs)) for n in names])
    md += ["### By kind", "", table(["kind", "bucket"] + names, rows), ""]

    # 2. per-category recall, sample level: the gold category is present and
    # the detector reported that same category somewhere in the sample
    md += ["## Category recall (sample level, right category reported)", ""]
    rows = []
    for cat in ID_CATS + ["clinical"]:
        gs = [g for g in gold if any(s["cat"] == cat for s in g["spans"])]
        r_hit = sum(cat in rx[("corpus", g["id"])]["cats"] for g in gs)
        t_hit = sum(cat in tr[("corpus", g["id"])]["cats"] for g in gs) if cat != "clinical" else None
        rows.append([cat, len(gs), pct(r_hit, len(gs)), "n/a (no label)" if t_hit is None else pct(t_hit, len(gs))])
    md += [table(["category", "samples", "regex", "tracer"], rows), ""]

    # 3. tracer span quality on the phi bucket (regex reports lines, not spans)
    md += ["## PII-Tracer span quality (phi bucket, identifier spans)", ""]
    rows = []
    phi = [g for g in gold if g["bucket"] == "phi"]
    for cat in ID_CATS:
        gold_spans = [(g, s) for g in phi for s in g["spans"] if s["cat"] == cat]
        found = sum(any(p["cat"] == cat and p["start"] < s["end"] and s["start"] < p["end"]
                        for p in tr[("corpus", g["id"])]["spans"]) for g, s in gold_spans)
        any_cat = sum(any(p["start"] < s["end"] and s["start"] < p["end"]
                          for p in tr[("corpus", g["id"])]["spans"]) for g, s in gold_spans)
        rows.append([cat, len(gold_spans), pct(found, len(gold_spans)), pct(any_cat, len(gold_spans))])
    md += [table(["category", "gold spans", "found, right label", "found, any label"], rows), ""]
    pred = [(g, p) for g in phi for p in tr[("corpus", g["id"])]["spans"]]
    hit = sum(any(p["start"] < s["end"] and s["start"] < p["end"] for s in g["spans"]) for g, p in pred)
    md += [f"Predicted spans overlapping a gold span (any category, clinical included): {pct(hit, len(pred))}.", ""]

    # 4. per shape: where each detector misses
    md += ["## Per template shape", ""]
    rows = []
    shapes = collections.OrderedDict()
    for g in gold:
        shapes.setdefault((g["bucket"], g["shape"], g["kind"]), []).append(g)
    for (bucket, shape, kind), gs in shapes.items():
        rx_cls = collections.Counter(c for g in gs for c in rx[("corpus", g["id"])]["classes"])
        tr_lab = collections.Counter(p["label"] for g in gs for p in tr[("corpus", g["id"])]["spans"])
        rows.append([bucket, shape, kind, len(gs)] + [pct(sum(detectors[n](g) for g in gs), len(gs)) for n in (names[0], names[1], names[3], names[4])]
                    + [", ".join(f"{k}:{v}" for k, v in rx_cls.most_common()) or "-",
                       ", ".join(f"{k}:{v}" for k, v in tr_lab.most_common()) or "-"])
    md += [table(["bucket", "shape", "kind", "n", "regex", "tracer raw", "tracer pre, sel", "combined", "regex classes", "tracer raw labels"],
                 rows), ""]

    # 4b. confidence threshold x chunking sweep for the selected labels
    def sel_hit(spans, tau):
        return any(x["label"] in SELECTED and x["conf"] >= tau for x in spans)

    taus = [0.0, 0.5, 0.7, 0.8, 0.9, 0.95]
    md += ["## Confidence and chunking sweep (pre, selected labels)", "",
           "Span confidence is the mean of 1 - P(O) over the span's tokens. whole: one window per sample. "
           "para: one window per blank-line paragraph, capped at 1200 characters.", ""]
    rows = []
    for mode in ["pre_spans", "para_spans"]:
        for tau in taus:
            row = [mode.split("_")[0].replace("pre", "whole"), tau]
            for bucket in ["phi", "clean"]:
                gs = [g for g in gold if g["bucket"] == bucket]
                alone = sum(sel_hit(t(g)[mode], tau) for g in gs)
                comb = sum(r(g) or sel_hit(t(g)[mode], tau) for g in gs)
                row += [pct(alone, len(gs)), pct(comb, len(gs))]
            fx = [(fid, rr) for (suite, fid), rr in rx.items() if suite == "fixtures" and fid.startswith("clean-")]
            row.append(sum(rr["flagged"] or sel_hit(tr[("fixtures", fid)][mode], tau) for fid, rr in fx))
            rows.append(row)
    md += [table(["chunks", "tau", "phi: tracer", "phi: combined", "clean: tracer", "clean: combined",
                  "clean fixtures flagged (combined, of 8)"], rows), ""]

    # which shapes still flag (clean) or miss (phi) at each mode, tau 0.8
    md += ["### Shapes at tau 0.8", ""]
    rows = []
    for (bucket, shape, kind), gs in shapes.items():
        if bucket == "clinical-only":
            continue
        cells = [pct(sum(sel_hit(t(g)[m], 0.8) for g in gs), len(gs)) for m in ("pre_spans", "para_spans")]
        confs = sorted(x["conf"] for g in gs for x in t(g)["pre_spans"] if x["label"] in SELECTED)
        rows.append([bucket, shape, len(gs)] + cells + [f"{confs[0]:.2f}-{confs[-1]:.2f}" if confs else "-"])
    md += [table(["bucket", "shape", "n", "whole", "para", "selected conf range (whole)"], rows), ""]

    # 5. existing fixture corpus
    md += ["## Repo fixtures (tests/fixtures)", "",
           "Expected verdict comes from the file name. Regex uses diff profile for .diff and prose for .md, "
           "an approximation of the bats args. Tracer sees the raw file.", ""]
    rows = []
    for (suite, fid), rr in sorted(rx.items()):
        if suite != "fixtures":
            continue
        want = "flag" if fid.startswith("dirty-") else "clean" if fid.startswith("clean-") else "edge"
        tf = tr[("fixtures", fid)]
        sel = sorted(SELECTED & set(tf["pre_labels"]))
        rows.append([fid, want, "flag" if rr["flagged"] else "clean", "flag" if tf["flagged"] else "clean",
                     ", ".join(sorted({p["label"] for p in tf["spans"]})) or "-",
                     ", ".join(sel) or "clean", "flag" if rr["flagged"] or sel else "clean"])
    md += [table(["fixture", "expected", "regex", "tracer raw", "raw labels", "tracer pre, sel", "combined"], rows), ""]

    # 6. cost
    md += ["## PII-Tracer cost", "",
           f"device {tmeta['device']}, model load {tmeta['load_s']} s, per sample median {tmeta['ms_median']} ms, "
           f"p95 {tmeta['ms_p95']} ms, paragraph mode median {tmeta['para_ms_median']} ms, peak RSS {tmeta['rss_gb']} GB.", ""]

    pathlib.Path(out_md).write_text("\n".join(md))
    print(f"wrote {out_md}", file=sys.stderr)


if __name__ == "__main__":
    a = sys.argv[1:]
    main(*a[:4])
