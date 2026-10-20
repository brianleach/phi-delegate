"""Run scripts/phi-scan.sh on every corpus sample and on the repo's fixtures.

The profile mirrors delegate.sh and collect.sh: handoffs and tool output scan
on the default profile, diffs on --profile diff.

usage: run_regex.py REPO CORPUS OUT
"""

import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time

CLASS_TO_CAT = {
    "ssn-shaped": "id", "long-digit-run": "id", "identifier-keyword": "id",
    "phone-shaped": "phone", "email-address": "email",
    "date-shaped": "date", "iso-date": "date", "date-words": "date",
    "dob-keyword": "date",
    "patient-name-keyword": "person", "street-address": "address",
    "clinical-keyword": "clinical",
}
LINE = re.compile(r"^\s+(\S+)\s+(\d+) line\(s\)$")


def scan(script, path, profile):
    args = [script] + (["--profile", profile] if profile != "default" else []) + [path]
    # Regex only: a detector enabled in the developer's .env would mix model hits in.
    proc = subprocess.run(args, capture_output=True, text=True, env={**os.environ, "PHI_DELEGATE_DETECTOR": "off"})
    if proc.returncode not in (0, 1):
        raise RuntimeError(f"phi-scan exit {proc.returncode}: {proc.stderr.strip()}")
    classes = {}
    for line in proc.stdout.splitlines():
        m = LINE.match(line)
        if m:
            classes[m.group(1)] = int(m.group(2))
    return proc.returncode == 1, classes


def profile_for(kind_or_suffix):
    return {"diff": "diff", ".diff": "diff", ".md": "prose"}.get(kind_or_suffix, "default")


def main(repo, corpus, out):
    script = str(pathlib.Path(repo) / "scripts" / "phi-scan.sh")
    rows = [json.loads(l) for l in open(corpus)]
    results = []
    t0 = time.perf_counter()
    with tempfile.TemporaryDirectory() as td:
        for r in rows:
            p = pathlib.Path(td) / "sample.txt"
            p.write_text(r["text"] + "\n")
            flagged, classes = scan(script, str(p), profile_for(r["kind"]))
            results.append({"id": r["id"], "suite": "corpus", "flagged": flagged, "classes": classes,
                            "cats": sorted({CLASS_TO_CAT[c] for c in classes})})
    elapsed = time.perf_counter() - t0
    for fx in sorted((pathlib.Path(repo) / "tests" / "fixtures").iterdir()):
        flagged, classes = scan(script, str(fx), profile_for(fx.suffix))
        results.append({"id": fx.name, "suite": "fixtures", "flagged": flagged, "classes": classes,
                        "cats": sorted({CLASS_TO_CAT[c] for c in classes})})
    with open(out, "w") as f:
        for res in results:
            f.write(json.dumps(res) + "\n")
    print(f"regex: {len(rows)} samples in {elapsed:.1f}s ({1000 * elapsed / len(rows):.0f} ms/sample incl. process start)",
          file=sys.stderr)


if __name__ == "__main__":
    main(*sys.argv[1:4])
