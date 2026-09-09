#!/usr/bin/env bash
# Sweep leftover phi-delegate residue out of one or more repos without
# reading any of it: stray handoffs, task specs, worktrees, kept logs, and
# run records. Dry run by default; prints paths and counts, never contents.
# Run with --help for usage.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: cleanup.sh [<repo>...] [--all [<root>]] [--apply] [--branches] [--sessions]

Finds phi-delegate residue that a normal run should have removed but did
not (an interactive session that ended without deleting its handoff, a
delegate that was killed mid-run, a spec that was never collected):

  .phi-handoff*.md, .phi-task*.md   at the repo root
  .phi-tasks/                       task specs, including Private input
  .phi-worktrees/                   worktrees, handoffs, kept logs, records
  phi/<name> branches               only reported unless --branches; a
                                    branch counts as merged when it is an
                                    ancestor of HEAD or when GitHub shows
                                    a merged PR for it (squash merges)

With no repo arguments the current repo is swept.

Options:
  --all [<root>]  sweep every git repo directly under <root>
                  (default $HOME/code)
  --apply         delete what was found. Without it nothing is removed
  --branches      with --apply, also delete phi/* branches that are merged
                  (ancestor of HEAD, or a merged PR on GitHub). Unmerged
                  branches are always kept: they may hold the only copy of
                  a delegate's work. Reject them with collect.sh <name> --reject
  --no-github     do not ask GitHub about PR state; only the local
                  ancestor check decides what is merged
  --sessions      with --apply, also delete leftover delegate session state
                  under PHI_DELEGATE_CONFIG_DIR (default
                  $HOME/.phi-delegate/claude), which an interactive run
                  leaves behind. Without --apply it is only reported

Output is limited to file names and counts so the orchestrator session
may run it. File contents are never printed.
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

# Securely remove every regular file under a directory, then the tree.
secure_rm_tree() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  find "$dir" -type f -print0 | while IFS= read -r -d '' f; do secure_rm "$f"; done
  rm -rf "$dir"
}

repos=()
all_root=""
sweep_all=0
apply=0
branches=0
sessions=0
use_github=1

while [ $# -gt 0 ]; do
  case "$1" in
    --all)
      sweep_all=1
      if [ $# -gt 1 ] && [ "${2#-}" = "$2" ]; then all_root="$2"; shift; fi
      ;;
    --apply) apply=1 ;;
    --branches) branches=1 ;;
    --sessions) sessions=1 ;;
    --no-github) use_github=0 ;;
    -h | --help) usage ;;
    -*) echo "error: unknown option $1" >&2; usage ;;
    *) repos+=("$1") ;;
  esac
  shift
done

if [ "$sweep_all" -eq 1 ]; then
  all_root="${all_root:-$HOME/code}"
  [ -d "$all_root" ] || { echo "error: no such directory: $all_root" >&2; exit 1; }
  while IFS= read -r gitdir; do
    repos+=("$(dirname "$gitdir")")
  done < <(find "$all_root" -mindepth 2 -maxdepth 2 -name .git 2>/dev/null | sort)
fi
[ ${#repos[@]} -gt 0 ] || repos=(".")

found_total=0
removed_total=0

report() { # <label> <path>
  echo "  $1: $2"
  found_total=$((found_total + 1))
}

# Ask GitHub for the state of the PR opened from a branch. Prints
# "merged <n>", "closed <n>", "open <n>", or nothing when there is no PR,
# no gh, no origin, or the call fails (all treated as unknown).
github_pr_state() { # <root> <branch>
  local root="$1" branch="$2" out
  [ "$use_github" -eq 1 ] || return 0
  command -v gh >/dev/null 2>&1 || return 0
  git -C "$root" remote get-url origin >/dev/null 2>&1 || return 0
  out="$(cd "$root" && gh pr list --head "$branch" --state all --limit 1 \
    --json number,state 2>/dev/null)" || return 0
  case "$out" in
    *'"MERGED"'*) printf 'merged %s\n' "$(printf '%s' "$out" | sed -n 's/.*"number":\([0-9]*\).*/\1/p')" ;;
    *'"CLOSED"'*) printf 'closed %s\n' "$(printf '%s' "$out" | sed -n 's/.*"number":\([0-9]*\).*/\1/p')" ;;
    *'"OPEN"'*) printf 'open %s\n' "$(printf '%s' "$out" | sed -n 's/.*"number":\([0-9]*\).*/\1/p')" ;;
  esac
  return 0
}

sweep_repo() {
  local repo="$1" root
  root="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || {
    echo "skip: not a git repo: $repo"
    return 0
  }
  local before="$found_total"
  echo "==> $root"

  # Root-level handoff and task copies (interactive runs, killed delegates).
  local f
  for f in "$root"/.phi-handoff*.md "$root"/.phi-task*.md; do
    [ -e "$f" ] || continue
    report "handoff/task copy" "${f#"$root"/}"
    if [ "$apply" -eq 1 ]; then secure_rm "$f"; removed_total=$((removed_total + 1)); fi
  done

  # Task specs, which may hold a filled Private input section.
  if [ -d "$root/.phi-tasks" ]; then
    local n
    n="$(find "$root/.phi-tasks" -type f | wc -l | tr -d ' ')"
    report "task specs" ".phi-tasks/ ($n files)"
    if [ "$apply" -eq 1 ]; then secure_rm_tree "$root/.phi-tasks"; removed_total=$((removed_total + 1)); fi
  fi

  # Delegate state: worktrees, handoffs, kept logs, run records.
  if [ -d "$root/.phi-worktrees" ]; then
    local d
    for d in "$root"/.phi-worktrees/*/; do
      [ -d "$d" ] || continue
      report "worktree" "${d#"$root"/}"
      if [ "$apply" -eq 1 ]; then
        git -C "$root" worktree remove --force "$d" >/dev/null 2>&1 || true
        secure_rm_tree "$d"
        removed_total=$((removed_total + 1))
      fi
    done
    for f in "$root"/.phi-worktrees/*.handoff.md "$root"/.phi-worktrees/*.log \
      "$root"/.phi-worktrees/*.base "$root"/.phi-worktrees/*.spec; do
      [ -e "$f" ] || continue
      report "run record" "${f#"$root"/}"
      if [ "$apply" -eq 1 ]; then secure_rm "$f"; removed_total=$((removed_total + 1)); fi
    done
    if [ "$apply" -eq 1 ]; then
      secure_rm_tree "$root/.phi-worktrees"
      git -C "$root" worktree prune >/dev/null 2>&1 || true
    fi
  fi

  # Branches: report all, delete only merged ones and only when asked.
  # Merged means an ancestor of HEAD, or a PR GitHub reports as merged
  # (squash and rebase merges leave the local branch as a non-ancestor).
  local b label merged pr
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    merged=0
    label=""
    if git -C "$root" merge-base --is-ancestor "$b" HEAD 2>/dev/null; then
      merged=1
      label="branch (merged)"
    else
      pr="$(github_pr_state "$root" "$b")"
      case "$pr" in
        merged\ *) merged=1; label="branch (merged via PR #${pr#merged })" ;;
        closed\ *) label="branch (PR #${pr#closed } closed without merge, kept)" ;;
        open\ *) label="branch (PR #${pr#open } still open, kept)" ;;
        *) label="branch (UNMERGED, kept)" ;;
      esac
    fi
    report "$label" "$b"
    if [ "$merged" -eq 1 ] && [ "$apply" -eq 1 ] && [ "$branches" -eq 1 ]; then
      git -C "$root" branch -D "$b" >/dev/null 2>&1 && removed_total=$((removed_total + 1))
    fi
  done < <(git -C "$root" for-each-ref --format='%(refname:short)' 'refs/heads/phi/' 2>/dev/null)

  [ "$found_total" -eq "$before" ] && echo "  clean"
  return 0
}

for r in "${repos[@]}"; do
  sweep_repo "$r"
done

# Delegate session state outside any repo.
cfg="${PHI_DELEGATE_CONFIG_DIR:-$HOME/.phi-delegate/claude}"
if [ -d "$cfg" ] && [ -n "$(ls -A "$cfg" 2>/dev/null)" ]; then
  echo "==> delegate session state"
  report "config dir" "$cfg ($(find "$cfg" -type f | wc -l | tr -d ' ') files)"
  if [ "$apply" -eq 1 ] && [ "$sessions" -eq 1 ]; then
    secure_rm_tree "$cfg"
    mkdir -p "$cfg"
    removed_total=$((removed_total + 1))
  elif [ "$apply" -eq 1 ]; then
    echo "  kept (pass --sessions to delete)"
  fi
fi

echo
if [ "$apply" -eq 1 ]; then
  echo "removed $removed_total of $found_total items"
else
  echo "found $found_total items (dry run; pass --apply to delete)"
fi
