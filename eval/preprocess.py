"""Python port of phi-scan.sh's preprocessing: mask rows always, plus hunk
tagging and drop rows under --profile diff. Reads the repo's
scripts/phi-patterns.tsv so it tracks pattern edits.

The only regex dialect gap in the current rows is the POSIX [:space:] class,
which Python spells \\s.
"""

import pathlib
import re


def _py(regex):
    return regex.replace("[:space:]", r"\s")


class Preprocessor:
    def __init__(self, repo):
        self.masks, self.drops = [], []
        self.hunk_start = self.hunk_end = None
        for line in (pathlib.Path(repo) / "scripts" / "phi-patterns.tsv").read_text().splitlines():
            if not line or line.startswith("#"):
                continue
            kind, name, flags, _tags, regex, *rest = line.split("\t")
            fl = re.I if flags == "i" else 0
            if kind == "mask":
                self.masks.append((re.compile(_py(regex), fl), rest[0]))
            elif kind == "drop":
                self.drops.append(re.compile(_py(regex), fl))
            elif kind == "hunk":
                pat = re.compile(_py(regex))
                if name == "start":
                    self.hunk_start = pat
                else:
                    self.hunk_end = pat

    def __call__(self, text, profile):
        for pat, repl in self.masks:
            text = pat.sub(repl, text)
        if profile != "diff":
            return text
        kept, inhunk = [], False
        for line in text.split("\n"):
            if self.hunk_end.search(line):
                inhunk = False
            if self.hunk_start.search(line):
                inhunk = True
                outside = True
            else:
                outside = not inhunk
            if outside and any(d.search(line) for d in self.drops):
                continue
            kept.append(line)
        return "\n".join(kept)
