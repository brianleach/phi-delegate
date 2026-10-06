// Pure rules the mod's hooks apply, kept apart from `$` so tests reach them
// directly. guardReason mirrors scripts/guard-hook.sh, which stays registered
// as the fallback for clients where mods do not run.

// The calls that may name .phi-tasks/ from Bash: one plain run of a
// phi-delegate script (a path of plain characters, then plain or quoted
// arguments), or creating the folder. No globs, redirections, pipes, or
// chains, since any of those can read a sidecar without naming it.
const PLAIN_ARG = `(?:[^\\s;&|\`$<>(){}*?[\\]~\\\\'"]+|"[^"$\`\\\\]*"|'[^']*')`
const TASKS_ALLOWED = [
  new RegExp(
    `^\\s*(?:bash\\s+)?(?:[A-Za-z0-9_./~-]*/)?(?:delegate|interactive|collect|cleanup)\\.sh(?:\\s+${PLAIN_ARG})*\\s*$`,
  ),
  /^\s*mkdir\s+-p\s+\.phi-tasks\/?\s*$/,
]

export const guardReason = (
  payload: string,
  bashCommand?: string,
  tool?: string,
): string | undefined => {
  if (/\.phi-worktrees/.test(payload)) {
    return '.phi-worktrees/ holds delegate worktrees and raw transcripts that may contain PHI'
  }
  if (/\.phi-handoff|\.phi-task\.md/.test(payload)) {
    return 'delegate-side task and handoff copies live inside the worktree and may contain PHI'
  }
  if (/--full-diff/.test(payload)) {
    return 'collect.sh --full-diff prints delegate output verbatim and is reserved for the human'
  }
  if (/\.private\.md/.test(payload)) {
    return '*.private.md sidecars hold private input staged for a delegate'
  }
  // .phi-task with no s: a bracket glob (.phi-task[s]) still names it.
  if (/\.phi-task/.test(payload)) {
    const isPlain = bashCommand !== undefined && TASKS_ALLOWED.some(re => re.test(bashCommand))
    if (tool === 'Grep' || (bashCommand !== undefined && !isPlain)) {
      return '.phi-tasks/ holds private input sidecars; from Bash, name it only in a plain run of a phi-delegate script, and write specs with the Write tool'
    }
  }
  if (/\.phi-delegate\/claude/.test(payload)) {
    return 'the delegate CLAUDE_CONFIG_DIR holds its own session state'
  }
  if (bashCommand !== undefined && /collect\.sh\b[^;&|\n]*\s--merge\b/.test(bashCommand)) {
    return 'merging a delegate branch is the human approval step, done with the Merge button in the review pane (/phi-review)'
  }
  return undefined
}

// guard-hook.sh's developer exemption: calls whose session cwd is inside this
// plugin's own checkout, or file tool calls that name its resolved path. A
// Bash command naming the path is not exempt: running the scripts by their
// full path is how every session calls them. Not a security boundary; it
// assumes an honest orchestrator.
export const isSelfRepo = (
  repo: string | undefined,
  cwd: string | undefined,
  payload: string,
  isBash: boolean,
): boolean =>
  repo !== undefined &&
  ((cwd !== undefined && (cwd === repo || cwd.startsWith(`${repo}/`))) || (!isBash && payload.includes(repo)))

// One regex per line; blank and # lines ignored. A line that does not
// compile is skipped and reported by count, never by content.
export const compileSources = (lines: readonly string[]): { regexes: RegExp[]; invalid: number } => {
  const regexes: RegExp[] = []
  let invalid = 0
  for (const line of lines) {
    if (/^\s*(#|$)/.test(line)) continue
    try {
      regexes.push(new RegExp(line))
    } catch {
      invalid += 1
    }
  }
  return { regexes, invalid }
}

// delegate.sh's own name rule, so the pane and the script agree on <name>.
export const taskName = (spec: string, name?: string): string => {
  const base = name ?? (spec.split('/').pop() ?? '').replace(/\.md$/, '')
  return base.replace(/[^a-zA-Z0-9._-]/g, '-').replace(/^-+|-+$/g, '')
}
