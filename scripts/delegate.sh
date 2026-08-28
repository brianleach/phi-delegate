#!/usr/bin/env bash
# Delegate a task spec to an isolated, ZDR-authenticated headless Claude
# Code session (claude -p via phi-claude.sh) in a git worktree of the
# current repo. Only PHI-screened output ever reaches stdout. Run with
# --help for usage.
set -euo pipefail

RUN_TIMEOUT_SECS="${PHI_DELEGATE_TIMEOUT_SECS:-1800}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/load-env.sh"

usage() {
  cat <<'USAGE'
Usage: delegate.sh <task-spec.md> [--model <anthropic-model-id>] [--name <worktree-name>] [--pr]

Delegate a task spec to an isolated headless Claude Code session that is
authenticated with the ZDR/BAA API key, in a git worktree of the current
repo. Nothing the delegate saw or wrote is printed here except a
PHI-scanned handoff summary and a diff --stat.

Behavior:
  - creates a worktree under .phi-worktrees/<name> on branch phi/<name>,
    branched off the current branch (directory mode 700)
  - copies the spec into the worktree as .phi-task.md and runs claude -p
    there via phi-claude.sh with a per-run CLAUDE_CONFIG_DIR that is
    deleted when the run ends (no session history survives)
  - the raw transcript is written to a temp file, checked for permission
    denials, then securely deleted. Set PHI_DELEGATE_KEEP_LOG=1 to keep it
    at .phi-worktrees/<name>.log (mode 600) for human debugging only
  - the delegate is told to write a PHI-free handoff to .phi-handoff.md;
    that file is moved to .phi-worktrees/<name>.handoff.md and run through
    phi-scan.sh. Clean: printed and kept until collect.sh merges or
    rejects. Flagged: deleted immediately, nothing is printed
  - auto-commits any changes the model left uncommitted, after removing
    .phi-task.md and .phi-handoff.md from the tree
  - records the spec path so collect.sh can delete it on merge/reject
  - with --pr: pushes phi/<name> to origin and opens a draft PR whose body
    is the scanned handoff (never the spec or the log)
  - prints a diff --stat against the base branch

Safe to run multiple times in parallel with distinct names.
USAGE
  exit 1
}

with_timeout() {
  local secs="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  else
    perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
  fi
}

# Best-effort secure delete. On APFS and SSDs an overwrite is not a
# guarantee of physical erasure, so treat full-disk encryption as the real
# control; this keeps the file from being trivially recoverable.
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

spec_file=""
model="$PHI_DELEGATE_MODEL"
name=""
pr_requested=0

while [ $# -gt 0 ]; do
  case "$1" in
    --model)
      [ $# -ge 2 ] || usage
      model="$2"
      shift 2
      ;;
    --name)
      [ $# -ge 2 ] || usage
      name="$2"
      shift 2
      ;;
    --pr)
      pr_requested=1
      shift
      ;;
    -h | --help)
      usage
      ;;
    *)
      if [ -z "$spec_file" ]; then
        spec_file="$1"
        shift
      else
        echo "error: unexpected argument: $1" >&2
        usage
      fi
      ;;
  esac
done

[ -n "$spec_file" ] || usage
if [ ! -f "$spec_file" ]; then
  echo "error: task spec not found: $spec_file" >&2
  exit 1
fi
spec_file="$(cd "$(dirname "$spec_file")" && pwd)/$(basename "$spec_file")"

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"
base_branch="$(git rev-parse --abbrev-ref HEAD)"
if [ "$base_branch" = "HEAD" ]; then
  echo "error: detached HEAD; check out a branch first" >&2
  exit 1
fi

if [ -z "$name" ]; then
  name="$(basename "$spec_file" .md)"
fi
name="$(printf '%s' "$name" | tr -c 'a-zA-Z0-9._-' '-' | sed 's/^-*//;s/-*$//')"
if [ -z "$name" ] || [ "$name" = "." ] || [ "$name" = ".." ]; then
  echo "error: could not derive a valid worktree name" >&2
  exit 1
fi
if ! git check-ref-format "refs/heads/phi/$name"; then
  echo "error: '$name' is not usable as a git branch name" >&2
  exit 1
fi

state_dir="$repo_root/.phi-worktrees"
wt_dir="$state_dir/$name"
branch="phi/$name"
handoff_file="$state_dir/$name.handoff.md"
keep_log="${PHI_DELEGATE_KEEP_LOG:-0}"
if [ "$keep_log" = "1" ]; then
  log_file="$state_dir/$name.log"
else
  log_file="$(mktemp "${TMPDIR:-/tmp}/phi-delegate-log.XXXXXX")"
fi
run_config_dir="$PHI_DELEGATE_CONFIG_DIR/run-$name-$$"
# shellcheck disable=SC2329,SC2317  # invoked via trap; code differs by shellcheck version
cleanup() {
  rm -rf "$run_config_dir"
  if [ "$keep_log" != "1" ]; then secure_rm "$log_file"; fi
}
trap cleanup EXIT

if [ -e "$wt_dir" ]; then
  echo "error: worktree already exists: $wt_dir (collect or reject it first)" >&2
  exit 1
fi
if git show-ref --verify --quiet "refs/heads/$branch"; then
  echo "error: branch $branch already exists; recover with: scripts/collect.sh $name --reject" >&2
  exit 1
fi

mkdir -p "$state_dir"
chmod 700 "$state_dir"

exclude_file="$(git rev-parse --git-common-dir)/info/exclude"
for pattern in ".phi-worktrees/" ".phi-tasks/"; do
  grep -qxF "$pattern" "$exclude_file" 2>/dev/null || echo "$pattern" >>"$exclude_file"
done

echo "==> creating worktree on branch $branch (base: $base_branch)"
git worktree add -b "$branch" "$wt_dir" "$base_branch" >/dev/null
printf '%s\n' "$base_branch" >"$state_dir/$name.base"
printf '%s\n' "$spec_file" >"$state_dir/$name.spec"
chmod 600 "$state_dir/$name.spec"

cp "$spec_file" "$wt_dir/.phi-task.md"
chmod 600 "$wt_dir/.phi-task.md"

prompt="Read the file .phi-task.md in the current directory and complete the task it describes. Do not modify or delete .phi-task.md.

You are running in a HIPAA-covered, zero-data-retention session. The person who reviews your work is NOT covered and will only see the file .phi-handoff.md that you write, plus file names from git diff --stat. Before you finish, write .phi-handoff.md in the current directory containing: what you changed and why, which files you touched, the exact verification commands you ran and whether they passed, and any open questions. It MUST NOT contain protected health information or personal identifiers of any kind: no names, dates of birth, record or member IDs, addresses, phone numbers, emails, diagnoses, or literal database row values. Describe data in the aggregate (\"3 rows updated\", \"the patient record referenced in the task\") instead. Do not commit .phi-task.md or .phi-handoff.md. Do not write PHI into source files, fixtures, seeds, tests, or commit messages."

touch "$log_file"
chmod 600 "$log_file"
mkdir -p "$run_config_dir"
chmod 700 "$run_config_dir"

echo "==> running isolated claude -p (model: $model, timeout: ${RUN_TIMEOUT_SECS}s)"
if [ "$keep_log" = "1" ]; then
  echo "==> PHI_DELEGATE_KEEP_LOG=1: raw transcript kept at .phi-worktrees/$name.log (never read it from the orchestrator session)"
else
  echo "==> raw transcript and delegate session state are deleted when the run ends"
fi

run_status=0
(
  cd "$wt_dir"
  PHI_DELEGATE_CONFIG_DIR="$run_config_dir" \
    with_timeout "$RUN_TIMEOUT_SECS" "$SCRIPT_DIR/phi-claude.sh" "$model" \
    -p --permission-mode acceptEdits --allowedTools Bash \
    --no-session-persistence \
    --output-format stream-json --verbose \
    "$prompt"
) <"/dev/null" >"$log_file" 2>&1 || run_status=$?

if [ "$run_status" -ne 0 ]; then
  echo "WARNING: claude exited with status $run_status (timeout or error)." >&2
fi

denial_count="$(grep -cE "Claude requested permissions|Permission to use .* has been denied|was blocked by a deny rule|doesn.t want to proceed with this tool use" "$log_file" 2>/dev/null || true)"
if [ "${denial_count:-0}" -gt 0 ]; then
  # Name the denied tools (never their arguments or output) so the
  # orchestrator can fix the spec or the allowlist instead of guessing.
  denied_tools="$(grep -oE "Permission to use [A-Za-z_]+" "$log_file" 2>/dev/null \
    | awk '{print $4}' | sort | uniq -c | awk '{printf "%s x%s ", $2, $1}' || true)"
  echo "WARNING: $denial_count permission denial(s) occurred during the delegate run.${denied_tools:+ Tools: $denied_tools}" >&2
fi

# Pull the handoff out of the tree and quarantine-scan it before anything
# else can display it.
handoff_clean=0
if [ -f "$wt_dir/.phi-handoff.md" ]; then
  mv "$wt_dir/.phi-handoff.md" "$handoff_file"
  chmod 600 "$handoff_file"
  if scan_out="$("$SCRIPT_DIR/phi-scan.sh" "$handoff_file" 2>&1)"; then
    handoff_clean=1
  else
    secure_rm "$handoff_file"
  fi
else
  scan_out="(delegate did not write a handoff)"
fi
rm -f "$wt_dir/.phi-task.md" "$wt_dir/.phi-handoff.md"

if [ -n "$(git -C "$wt_dir" status --porcelain)" ]; then
  git -C "$wt_dir" add -A
  git -C "$wt_dir" commit -q -m "phi-delegate: $name (auto-commit of delegated work)"
fi

# The committed diff is also scanned so the reviewer knows whether the
# branch itself carries PHI-shaped content before anyone opens it.
diff_scan="$(git -C "$wt_dir" diff "$base_branch...$branch" | "$SCRIPT_DIR/phi-scan.sh" 2>&1 || true)"

if [ "$pr_requested" -eq 1 ]; then
  if [ "$(git -C "$wt_dir" rev-list --count "$base_branch..$branch")" -eq 0 ]; then
    echo "==> --pr requested but $branch has no commits beyond $base_branch; skipping PR creation"
  elif ! git -C "$wt_dir" remote get-url origin >/dev/null 2>&1; then
    echo "WARNING: --pr requested but this repo has no origin remote; skipping PR creation." >&2
  elif ! command -v gh >/dev/null 2>&1; then
    echo "WARNING: --pr requested but gh is not on PATH; skipping PR creation." >&2
  else
    pr_body="$(mktemp "${TMPDIR:-/tmp}/phi-delegate-pr.XXXXXX")"
    {
      printf '## Delegate handoff\n\n'
      if [ "$handoff_clean" -eq 1 ]; then
        cat "$handoff_file"
      else
        printf '_Handoff withheld: %s_\n' "$(printf '%s' "$scan_out" | tail -n 1)"
      fi
      # shellcheck disable=SC2016
      printf '\n\n## Diff scan\n\n```\n%s\n```\n' "$diff_scan"
    } >"$pr_body"
    if (cd "$wt_dir" && git push -u origin "$branch"); then
      if pr_url="$(cd "$wt_dir" && gh pr create --draft --base "$base_branch" --head "$branch" \
        --title "phi-delegate: $name" --body-file "$pr_body")"; then
        echo "==> draft PR: $pr_url"
      else
        echo "WARNING: gh pr create failed; branch $branch is pushed, open the PR by hand." >&2
      fi
    else
      echo "WARNING: git push -u origin $branch failed; skipping PR creation." >&2
    fi
    rm -f "$pr_body"
  fi
fi

echo
echo "==> diff --stat vs $base_branch:"
diff_stat="$(git -C "$wt_dir" diff --stat "$base_branch...$branch" || true)"
if [ -n "$diff_stat" ]; then printf '%s\n' "$diff_stat"; else echo "(no changes were made)"; fi
echo
echo "==> diff scan: $diff_scan"
echo
if [ "$handoff_clean" -eq 1 ]; then
  echo "==> handoff (phi-scan clean):"
  echo
  cat "$handoff_file"
else
  echo "==> handoff WITHHELD and deleted: $scan_out"
  echo "    The work is on branch $branch for human review. To get a summary, reject and re-delegate"
  echo "    with revision feedback telling the delegate to keep identifiers out of the handoff."
fi
echo
echo "next: scripts/collect.sh $name           # stat + scan, then --merge"
echo "      scripts/collect.sh $name --reject  # discard"
exit "$run_status"
