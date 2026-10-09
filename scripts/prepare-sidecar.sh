#!/usr/bin/env bash
# Prepare an empty private input sidecar for the mod to write into:
# <repo>/.phi-tasks/<name>.private.md, folder 700 and file 600, with
# .phi-tasks/ and .phi-worktrees/ in the repo's .git/info/exclude. The mod
# writes the text itself ($.fs.write takes no mode, so the file must exist
# with its mode first). Prints nothing on success; any failure exits
# nonzero so the mod stops the staging.
#
# usage: prepare-sidecar.sh <repo-root> <name>
set -euo pipefail

[ $# -eq 2 ] || { echo "usage: prepare-sidecar.sh <repo-root> <name>" >&2; exit 2; }
repo="$1" name="$2"
case "$name" in
  '' | . | .. | */* | *[!a-zA-Z0-9._-]*) echo "error: invalid task name" >&2; exit 2 ;;
esac

dir="$repo/.phi-tasks"
file="$dir/$name.private.md"
# A symlinked folder or file would put private input where the exclude
# below does not reach (a tracked folder, another repo).
if [ -L "$dir" ] || [ -L "$file" ]; then
  echo "error: .phi-tasks or the sidecar is a symlink; refusing to stage there" >&2
  exit 1
fi

common="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)"
mkdir -p "$common/info"
for p in .phi-worktrees/ .phi-tasks/; do
  grep -qxF "$p" "$common/info/exclude" 2>/dev/null || echo "$p" >>"$common/info/exclude"
done

umask 077
mkdir -p "$dir"
chmod 700 "$dir"
touch "$file"
chmod 600 "$file"
