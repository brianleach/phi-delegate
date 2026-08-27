#!/usr/bin/env bash
# Review and merge (or reject) a worktree produced by delegate.sh without
# exposing delegate output to the orchestrator. Run with --help for usage.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
Usage: collect.sh <name> [--base <branch>] [--merge | --reject | --full-diff]

Modes:
  (default)    print diff --stat, the PHI scan of the diff, and the handoff
               (only if its scan is clean). Safe for the orchestrator.
  --merge      merge phi/<name> into the base branch and remove the worktree;
               pushes the base branch and deletes the remote branch when an
               origin exists (a rejected push only warns). Deletes the
               handoff, the spec file, any kept log, and the run records.
  --reject     discard the worktree, its branch, and its records (same
               deletions as --merge); closes an open PR and deletes the
               remote branch when possible
  --full-diff  print the complete diff. FOR HUMANS ONLY: the guard hook
               blocks this flag inside the orchestrator session because the
               diff may carry PHI.

Options:
  --base <branch>   override the recorded base branch
USAGE
  exit 1
}

secure_rm() {
  local f
  for f in "$@"; do
    [ -e "$f" ] || continue
    if command -v shred >/dev/null 2>&1; then
      shred -u "$f" 2>/dev/null || rm -f "$f"
    elif rm -P "$f" 2>/dev/null; then
      :
    else
      rm -f "$f"
    fi
  done
}

# Remove every PHI-bearing record for a task: the spec (Private input),
# the handoff, a kept transcript, and the bookkeeping files.
purge_records() {
  local spec_path
  if [ -f "$spec_record" ]; then
    spec_path="$(cat "$spec_record")"
    [ -f "$spec_path" ] && secure_rm "$spec_path"
  fi
  secure_rm "$handoff_file" "$log_file"
  rm -f "$base_file" "$spec_record"
}

name=""
mode="show"
base_override=""
while [ $# -gt 0 ]; do
  case "$1" in
    --merge) mode="merge"; shift ;;
    --reject) mode="reject"; shift ;;
    --full-diff) mode="full"; shift ;;
    --base)
      [ $# -ge 2 ] || usage
      base_override="$2"; shift 2 ;;
    -h | --help) usage ;;
    *)
      if [ -z "$name" ]; then name="$1"; shift; else echo "error: unexpected argument: $1" >&2; usage; fi ;;
  esac
done
[ -n "$name" ] || usage

name="$(printf '%s' "$name" | tr -c 'a-zA-Z0-9._-' '-' | sed 's/^-*//;s/-*$//')"
if [ -z "$name" ] || [ "$name" = "." ] || [ "$name" = ".." ]; then
  echo "error: invalid worktree name" >&2
  exit 1
fi

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"
state_dir="$repo_root/.phi-worktrees"
wt_dir="$state_dir/$name"
branch="phi/$name"
base_file="$state_dir/$name.base"
log_file="$state_dir/$name.log"
handoff_file="$state_dir/$name.handoff.md"
spec_record="$state_dir/$name.spec"

if [ "$mode" = "reject" ]; then
  git worktree prune
  if [ ! -d "$wt_dir" ] && ! git show-ref --verify --quiet "refs/heads/$branch" && [ ! -f "$base_file" ]; then
    echo "error: nothing to reject for '$name'" >&2
    exit 1
  fi
  echo "==> rejecting $name"
  if git remote get-url origin >/dev/null 2>&1; then
    if command -v gh >/dev/null 2>&1 && gh pr view "$branch" >/dev/null 2>&1; then
      gh pr close "$branch" --comment "Rejected via collect.sh --reject" || true
    fi
    git push origin --delete "$branch" >/dev/null 2>&1 || true
  fi
  [ -d "$wt_dir" ] && git worktree remove --force "$wt_dir"
  git show-ref --verify --quiet "refs/heads/$branch" && git branch -D "$branch" >/dev/null
  purge_records
  echo "done: worktree, branch, spec, handoff, and records removed"
  exit 0
fi

if [ ! -d "$wt_dir" ]; then
  echo "error: no such worktree for '$name'" >&2
  exit 1
fi

if [ -n "$base_override" ]; then
  base_branch="$base_override"
elif [ -f "$base_file" ]; then
  base_branch="$(cat "$base_file")"
else
  echo "error: no base branch recorded for '$name'; pass --base <branch>" >&2
  exit 1
fi
if ! git show-ref --verify --quiet "refs/heads/$base_branch"; then
  echo "error: base branch '$base_branch' does not exist; pass --base <branch>" >&2
  exit 1
fi

if [ "$mode" = "full" ]; then
  git diff "$base_branch...$branch"
  exit 0
fi

echo "==> $branch vs $base_branch"
echo
git diff --stat "$base_branch...$branch"
echo
diff_scan="$(git diff "$base_branch...$branch" | "$SCRIPT_DIR/phi-scan.sh" 2>&1 || true)"
echo "==> diff scan: $diff_scan"
echo
if [ -f "$handoff_file" ]; then
  if "$SCRIPT_DIR/phi-scan.sh" "$handoff_file" >/dev/null 2>&1; then
    echo "==> handoff (phi-scan clean):"
    echo
    cat "$handoff_file"
  else
    echo "==> handoff WITHHELD (phi-scan flagged it); a human must read it outside the orchestrator session."
  fi
else
  echo "==> no handoff was written by the delegate"
fi
echo

if [ "$mode" = "show" ]; then
  echo "a human reviews the full change on the PR or with: scripts/collect.sh $name --full-diff"
  echo "then: scripts/collect.sh $name --merge   |   scripts/collect.sh $name --reject"
  exit 0
fi

current_branch="$(git rev-parse --abbrev-ref HEAD)"
if [ "$current_branch" != "$base_branch" ]; then
  echo "error: on $current_branch but the worktree was based on $base_branch; check it out first" >&2
  exit 1
fi
echo "==> merging $branch into $base_branch"
git merge --no-ff -m "Merge delegated task $name (branch $branch)" "$branch"
if git remote get-url origin >/dev/null 2>&1; then
  if git push origin "$base_branch"; then
    git push origin --delete "$branch" >/dev/null 2>&1 || true
  else
    echo "WARNING: merged locally but pushing $base_branch was rejected; push it yourself." >&2
  fi
fi
git worktree remove --force "$wt_dir"
git branch -D "$branch" >/dev/null 2>&1 || true
purge_records
echo "==> merged; worktree, spec, handoff, and records removed"
