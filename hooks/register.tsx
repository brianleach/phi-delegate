import { atom, read, update } from 'claude-code'
import type { EngineInterface, PluginOptions, Register } from 'claude-code'

import type { PhiDelegateReview } from '../types'
import { compileSources, guardReason, isSelfRepo, searchReason, taskName } from './guard'
import { PATTERNS_TSV } from './patterns.generated'
import { classNames, describe, parseAllow, parsePatterns, scan } from './scan'
import type { ScanProfile, ScanResult } from './scan'

const PANE = 'phi-review'
const DELEGATE_TOOL = 'mcp__phi-delegate__delegate'
const STAGE = 'Stage as private input'
const SEND = 'Send anyway (no PHI)'
const CANCEL = 'Cancel'
const NEW_TASK = 'New task'
// Origins a person typed; anything else that trips the scan is dropped unasked.
const TYPED_ORIGINS = new Set(['composer', 'bridge', 'sdk'])
// Every tool whose result the scrubber may read; scrub_scope narrows it.
const SCRUB_TOOLS = /^(Bash|BashOutput|TaskOutput|Read|Grep|mcp__.+)$/
const GUARD_OFF = 'Turn it off'
const GUARD_KEEP = 'Keep it on'
// A mod's own tool.call hooks nest, and a failure in an inner one is answered
// by the outermost one's .catch, which would replay the chain without the
// failed hook. So every gating catch here denies, whether or not next ran.
const CHECK_FAILED = 'phi-delegate: blocked, because a PHI check on this call failed. Any output was withheld.'
const DELEGATE_HINT =
  'If this data may hold PHI, write a PHI-free spec in .phi-tasks/ and run it with the delegate tool.'

const flagged = atom({ plugin: 'phi-delegate', key: 'flagged' } as const, 0)
const reviews = atom({ plugin: 'phi-delegate', key: 'reviews' } as const, [] as PhiDelegateReview[])
// /phi-guard's choice for this session, over the option and the environment.
const sessionGuard = atom({ plugin: 'phi-delegate', key: 'sessionGuard' } as const, 'default' as 'default' | 'on' | 'off')

const patterns = parsePatterns(PATTERNS_TSV)

type Config = {
  guardrail: 'auto' | 'on' | 'off'
  scanClasses: string[]
  allowFile: string
  allowInline: readonly string[]
  phiSources: readonly string[]
  scrubOutput: boolean
  scrubScope: 'data' | 'all'
  scrubCommands: readonly string[]
  scrubTools: readonly string[]
  scrubFiles: readonly string[]
}

// Set by register and read by the hooks. Module state starts over on every
// load, an options change included, so each cache is per load.
let config: Config = {
  guardrail: 'auto',
  scanClasses: [],
  allowFile: '',
  allowInline: [],
  phiSources: [],
  scrubOutput: true,
  scrubScope: 'data',
  scrubCommands: [],
  scrubTools: [],
  scrubFiles: [],
}
let covered: Promise<boolean> | undefined
let baseState: Promise<GuardState> | undefined
let scrubRules: { commands: RegExp[]; tools: RegExp[]; files: RegExp[]; invalid: number } | undefined
let root: Promise<string> | undefined
let selfRepo: Promise<string | undefined> | undefined
let allow: Promise<string[]> | undefined

const readConfig = (options: PluginOptions): Config => ({
  guardrail: options.guardrail === 'on' || options.guardrail === 'off' ? options.guardrail : 'auto',
  scanClasses: [
    ...classNames(patterns, 'identifier'),
    ...(options.prompt_keyword_classes === true ? classNames(patterns, 'keyword') : []),
  ],
  allowFile: typeof options.allowlist_file === 'string' ? options.allowlist_file : '',
  allowInline: Array.isArray(options.allowlist) ? options.allowlist : [],
  phiSources: Array.isArray(options.phi_sources) ? options.phi_sources : [],
  scrubOutput: options.scrub_tool_output !== false,
  scrubScope: options.scrub_scope === 'all' ? 'all' : 'data',
  scrubCommands: Array.isArray(options.scrub_commands) ? options.scrub_commands : [],
  scrubTools: Array.isArray(options.scrub_tools) ? options.scrub_tools : [],
  scrubFiles: Array.isArray(options.scrub_files) ? options.scrub_files : [],
})

// covered: inside the covered delegate (phi-claude.sh sets the marker, and
// managed mods load there too), where everything stands down. on: active.
// off: turned off on purpose (/phi-guard, the option, or the environment),
// shown on the status line. auto-off: the default for a skill-only install.sh
// setup, whose symlink in the skills folder is what loads this plugin, so
// pulling a release never turns the guardrail on for someone who did not ask.
type GuardState = 'covered' | 'on' | 'off' | 'auto-off'

async function isCovered($: EngineInterface): Promise<boolean> {
  covered ??= $.env.get('PHI_DELEGATE_SESSION').then(value => value === '1')
  return covered
}

// Without /phi-guard: PHI_DELEGATE_GUARDRAIL=on|off, then the option, then
// auto. Read once per load; an option change reloads the module.
async function startingState($: EngineInterface): Promise<GuardState> {
  baseState ??= (async (): Promise<GuardState> => {
    const forced = await $.env.get('PHI_DELEGATE_GUARDRAIL')
    if (forced === 'on' || forced === 'off') return forced
    if (config.guardrail !== 'auto') return config.guardrail
    const configDir = (await $.env.get('CLAUDE_CONFIG_DIR')) ?? `${(await $.env.get('HOME')) ?? ''}/.claude`
    return (await $.fs.exists(`${configDir}/skills/phi-delegate`)) ? 'auto-off' : 'on'
  })()
  return baseState
}

async function guardState($: EngineInterface): Promise<GuardState> {
  if (await isCovered($)) return 'covered'
  const chosen = await read($, sessionGuard)
  return chosen === 'default' ? startingState($) : chosen
}

async function isOff($: EngineInterface): Promise<boolean> {
  return (await guardState($)) !== 'on'
}

async function repoRoot($: EngineInterface): Promise<string> {
  root ??= (async () => {
    const cwd = await $.session.cwd()
    const git = await $.process.run(['git', 'rev-parse', '--show-toplevel'], { cwd })
    return git.exitCode === 0 ? git.stdout.trim() : cwd
  })()
  return root
}

// Whether this repo has delegate state a recursive search would walk into.
async function holdsQuarantine($: EngineInterface): Promise<boolean> {
  const repo = await repoRoot($)
  return (await $.fs.exists(`${repo}/.phi-tasks`)) || (await $.fs.exists(`${repo}/.phi-worktrees`))
}

async function realPath($: EngineInterface, path: string): Promise<string | undefined> {
  const stat = await $.fs.stat(path, { resolve: true }).catch(() => undefined)
  return stat?.realPath
}

async function allowEntries($: EngineInterface): Promise<string[]> {
  const file = config.allowFile
  allow ??= (
    file === ''
      ? Promise.resolve([])
      : $.fs.read(file).then(parseAllow, () => {
          $.ui.log(`phi-delegate: allowlist ${file} could not be read; scanning without it`, { to: 'debug' })
          return []
        })
  ).then(entries => [...entries, ...parseAllow(config.allowInline.join('\n'))])
  return allow
}

async function scanText($: EngineInterface, text: string, profile: ScanProfile): Promise<ScanResult> {
  return scan(patterns, text, { profile, only: config.scanClasses, allow: await allowEntries($) })
}

async function flag($: EngineInterface): Promise<void> {
  const n = await update($, flagged, count => count + 1)
  $.ui.status(`PHI shield on · ${n} flagged`)
}

async function setReview($: EngineInterface, review: PhiDelegateReview): Promise<void> {
  await update($, reviews, list => [...list.filter(r => r.name !== review.name), review])
}

// Anything a script printed is shown whole when clean, else counts only.
async function screened($: EngineInterface, text: string): Promise<string> {
  const result = await scanText($, text, 'default')
  if (result.total === 0) return text
  await flag($)
  return `Output withheld: it matched PHI patterns (${describe(result)}). A human can run the same command in their own terminal.`
}

// The review pane's buttons. A press is the person's own act; the model has
// no way to raise one, which is what makes Merge the approval gate.
async function runCollect(
  $: EngineInterface,
  review: PhiDelegateReview,
  mode: '--merge' | '--reject' | '--pr',
): Promise<void> {
  await setReview($, { ...review, status: 'running' })
  const ran = await $.process.run([`${$.plugin.root}/scripts/collect.sh`, review.name, mode], {
    cwd: await repoRoot($),
    timeoutMs: 600_000,
  })
  const shown = await screened($, `${ran.stdout}${ran.stderr}`)
  const status = ran.exitCode !== 0 || mode === '--pr' ? 'ready' : mode === '--merge' ? 'merged' : 'rejected'
  await setReview($, { name: review.name, status, output: `${review.output}\n\n${shown}` })
  $.ui.toast(`${review.name}: collect.sh ${mode} ${ran.exitCode === 0 ? 'done' : 'failed'}`)
}

async function stagePrivateInput($: EngineInterface, text: string): Promise<string | undefined> {
  const repo = await repoRoot($)
  const dir = `${repo}/.phi-tasks`
  const specs = (await $.fs.list(dir).catch(() => []))
    .map(entry => entry.name)
    .filter(name => name.endsWith('.md') && !name.endsWith('.private.md'))
    .map(name => name.replace(/\.md$/, ''))
    .slice(-3)
  const picked = await $.ui.ask('Which task is this private input for?', {
    header: 'Task',
    options: specs.length > 0 ? [...specs, NEW_TASK] : [NEW_TASK, CANCEL],
  })
  if (picked === CANCEL) return undefined
  // A typed name reaches the model, so it must itself be clean, checked as
  // typed: cleanup would turn an email's @ into a dash and hide it.
  const isClean = picked !== NEW_TASK && (await scanText($, picked, 'default')).total === 0
  let name = isClean ? taskName(picked, picked) : ''
  if (name === '') {
    name = `staged-${(await $.clock.now()).toString(36)}`
  }
  const file = `${dir}/${name}.private.md`
  // $.fs.write takes no mode, so the script creates the file 600 (its folder
  // 700, refusing symlinks, excluded from git) before any text lands in it.
  const prepared = await $.process.run([`${$.plugin.root}/scripts/prepare-sidecar.sh`, repo, name], { cwd: repo })
  if (prepared.exitCode !== 0) throw new Error('could not prepare the private input sidecar')
  const existing = await $.fs.read(file).catch(() => '')
  await $.fs.write(file, existing === '' ? `${text}\n` : `${existing}\n${text}\n`)
  return name
}

// Every string, number, and key in a tool's record, for a result with no
// text: unlike its JSON, a newline inside still separates lines.
function stringsOf(value: unknown): string[] {
  if (typeof value === 'string') return [value]
  if (typeof value === 'number' || typeof value === 'bigint') return [String(value)]
  if (Array.isArray(value)) return value.flatMap(stringsOf)
  if (value !== null && typeof value === 'object') {
    return Object.entries(value).flatMap(([key, inner]) => [key, ...stringsOf(inner)])
  }
  return []
}

// Git's history output carries author metadata the diff profile drops; all
// other output is scanned whole, so a data line shaped like a trailer still
// counts. Both must hold: a single git log, show, or diff with no <rev>:<path>
// (which prints a file's raw contents), and output that opens as history.
const GIT_HISTORY = /^\s*git\s+(?:-C\s+[^\s:]+\s+)?(?:log|show|diff)\b[^;&|`$<>()\n:]*$/
const HISTORY_OUTPUT = /^(?:commit [0-9a-f]{7,}|diff --(?:git|cc|combined) )/

// Built once per load. A rule that does not compile widens the scope to
// every tool rather than narrowing it: the safe direction.
function scrubScope(): NonNullable<typeof scrubRules> {
  scrubRules ??= (() => {
    let invalid = 0
    const compile = (sources: readonly string[], flags = '') =>
      sources.flatMap(source => {
        try {
          return [new RegExp(source, flags)]
        } catch {
          invalid += 1
          return []
        }
      })
    return {
      commands: compile([...config.scrubCommands, ...config.phiSources]),
      tools: compile(config.scrubTools),
      files: compile(config.scrubFiles, 'i'),
      invalid,
    }
  })()
  return scrubRules
}

// What the scrubber reads. "all" is every tool SCRUB_TOOLS names. "data" is
// what can reach records: Bash commands that match scrub_commands (or a PHI
// source), Read of files that match scrub_files, tools that match
// scrub_tools, and background output, whose command is not known.
function isScrubbed(e: { tool: string; command?: unknown; file_path?: unknown }): boolean {
  const tool = String(e.tool)
  if (!config.scrubOutput || tool === DELEGATE_TOOL || !SCRUB_TOOLS.test(tool)) return false
  const scope = scrubScope()
  if (config.scrubScope === 'all' || scope.invalid > 0) return true
  if (tool === 'BashOutput' || tool === 'TaskOutput') return true
  if (tool === 'Bash') return typeof e.command === 'string' && scope.commands.some(re => re.test(e.command as string))
  if (tool === 'Read') return typeof e.file_path === 'string' && scope.files.some(re => re.test(e.file_path as string))
  return scope.tools.some(re => re.test(tool))
}

// Turns the guardrail on mid-session: the tool and command session.start
// registers only for an active guardrail, and the status line.
async function activate($: EngineInterface): Promise<void> {
  await $.tool.register({
    name: 'delegate',
    description:
      'Run a PHI-free task spec in the covered BAA/zero-data-retention delegate session (scripts/delegate.sh). ' +
      'Returns only the diff stat, the PHI scan verdicts, and the scanned handoff, then opens a review pane ' +
      'where the human merges, rejects, or opens a PR. Runs up to 30 minutes. Never merge yourself.',
    inputSchema: {
      type: 'object',
      properties: {
        spec: { type: 'string', description: 'Path to the spec, conventionally .phi-tasks/<nn>-<slug>.md' },
        name: { type: 'string', description: 'Worktree and branch name; defaults to the spec file name' },
        pr: { type: 'boolean', description: 'Push the branch and open a draft PR (needs gh and an origin)' },
      },
      required: ['spec'],
    },
  })
  await $.command.register({ name: 'phi-review', description: 'Open the phi-delegate review pane' })
  $.ui.status(`PHI shield on · ${await read($, flagged)} flagged`)
}

export const register: Register = (on, options) => {
  config = readConfig(options)
  covered = undefined
  baseState = undefined
  scrubRules = undefined
  root = undefined
  selfRepo = undefined
  allow = undefined

  on('session.start', async ($, e, next) => {
    const state = await guardState($)
    if (state === 'covered') return next(e)
    await $.command.register({
      name: 'phi-guard',
      description: 'Show the phi-delegate guardrail, or turn it on or off for this session',
      argumentHint: '[on|off]',
    })
    if (state === 'on') await activate($)
    else if (state === 'off') $.ui.status('PHI shield off')
    return next(e)
  })

  // Turning it off asks the person, so a model that runs the command cannot
  // switch the guardrail off by itself; turning it on needs no question.
  on('command.run', { command: 'phi-guard' }, async ($, e) => {
    const state = await guardState($)
    const wanted = e.args.trim()
    if (wanted === 'on') {
      if (state === 'on') return { text: 'phi-delegate guardrail: already on.' }
      await update($, sessionGuard, () => 'on')
      await activate($)
      return { text: 'phi-delegate guardrail: on for this session.' }
    }
    if (wanted === 'off') {
      if (state !== 'on') return { text: 'phi-delegate guardrail: already off.' }
      const answer = await $.ui
        .ask('Turn the PHI guardrail off for the rest of this session? Prompts, tool output, and commands stop being checked.', {
          header: 'PHI guard',
          options: [GUARD_OFF, GUARD_KEEP],
        })
        .catch(() => GUARD_KEEP)
      if (answer !== GUARD_OFF) return { text: 'phi-delegate guardrail: kept on.' }
      await update($, sessionGuard, () => 'off')
      $.ui.status('PHI shield off')
      return { text: 'phi-delegate guardrail: off for this session. /phi-guard on turns it back on.' }
    }
    const shown = state === 'on' ? 'on' : state === 'auto-off' ? 'off (skill-only install; set the guardrail option to on)' : 'off'
    return { text: `phi-delegate guardrail: ${shown}. Use /phi-guard on or /phi-guard off for this session.` }
  })

  on('command.run', { command: 'phi-review' }, async $ => {
    await $.ui.open({ id: PANE, title: 'phi-delegate review' })
    return { text: 'phi-delegate review pane opened.' }
  })

  // The guard-hook.sh port: quarantined paths, --full-diff, sidecars, the
  // delegate config dir, and merging, which only the review pane does.
  on('tool.call', { tool: /^(Read|Edit|Write|Bash|Grep|Glob|MultiEdit|NotebookEdit)$/ }, async ($, e, next) => {
    if (await isOff($)) return next(e)
    const payload = JSON.stringify(e)
    selfRepo ??= realPath($, $.plugin.root)
    const cwd = await realPath($, await $.session.cwd())
    if (isSelfRepo(await selfRepo, cwd, payload, e.tool === 'Bash')) return next(e)
    const reason =
      guardReason(payload, e.tool === 'Bash' ? e.command : undefined, String(e.tool)) ??
      (e.tool === 'Bash' && (await holdsQuarantine($)) ? searchReason(e.command) : undefined)
    if (reason === undefined) return next(e)
    await flag($)
    return {
      deny: `phi-delegate guard: blocked. ${reason}. Read the scanned handoff with scripts/collect.sh <name> instead, or ask the human to inspect it outside this session.`,
    }
  }).catch(() => ({ deny: CHECK_FAILED }))

  // Commands that reach a known PHI source go to the delegate instead.
  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    if (await isOff($)) return next(e)
    // Only a missing file means no repo patterns; a file that is there but
    // cannot be read fails the check, and the call is denied.
    const sourcesFile = `${await repoRoot($)}/.phi-sources`
    const repoFile = (await $.fs.exists(sourcesFile)) ? await $.fs.read(sourcesFile) : ''
    const { regexes, invalid } = compileSources([...config.phiSources, ...repoFile.split('\n')])
    // A pattern that does not compile is protection that silently went
    // missing, so Bash stays denied until it is fixed.
    if (invalid > 0) {
      return {
        deny: `phi-delegate: ${invalid} PHI source pattern(s) do not compile, so Bash is blocked until they are fixed (the phi_sources option or .phi-sources at the repo root).`,
      }
    }
    if (!regexes.some(re => re.test(e.command))) return next(e)
    await flag($)
    return {
      deny: 'phi-delegate: this command matches a configured PHI source, so it cannot run in this session. Write a PHI-free spec in .phi-tasks/ that says what to query and how, then run it with the delegate tool.',
    }
  }).catch(() => ({ deny: CHECK_FAILED }))

  // Last line of defense, for the tools isScrubbed names: a result that
  // matches is replaced before the model reads it. Bash keeps its record
  // shape; every other tool's becomes a deny.
  on('tool.call', { tool: SCRUB_TOOLS }, async ($, e, next) => {
    const tool = String(e.tool)
    if (!isScrubbed(e) || (await isOff($))) return next(e)
    const ran = await next(e)
    if (ran.deny !== undefined) return ran
    const text = ran.text ?? stringsOf(ran.result).join('\n')
    const isHistory = e.tool === 'Bash' && GIT_HISTORY.test(e.command) && HISTORY_OUTPUT.test(text)
    const profile = isHistory ? 'diff' : 'default'
    const result = await scanText($, text, profile)
    if (result.total === 0) return ran
    await flag($)
    const notice = `phi-delegate: ${tool} output withheld, it matched PHI patterns (${describe(result)}). ${DELEGATE_HINT}`
    return tool === 'Bash' ? { result: { stdout: notice, stderr: '', interrupted: false } } : { deny: notice }
  }).catch(() => ({ deny: CHECK_FAILED }))

  // The delegate tool. delegate.sh can run 30 minutes, past $.process.run's
  // ten, so it is spawned; interrupting the turn ends the child.
  on('tool.call', { tool: DELEGATE_TOOL }, async ($, e, next) => {
    if (await isOff($)) return { deny: 'The delegate tool is not available: the phi-delegate guardrail is off in this session.' }
    const spec = typeof e.spec === 'string' ? e.spec : ''
    if (!spec.endsWith('.md') || spec.endsWith('.private.md') || spec.includes('\0')) {
      return { deny: 'delegate: spec must be the path of a .md task spec, not a .private.md sidecar.' }
    }
    const name = taskName(spec, typeof e.name === 'string' && e.name !== '' ? e.name : undefined)
    const argv = [`${$.plugin.root}/scripts/delegate.sh`, spec, '--name', name, ...(e.pr === true ? ['--pr'] : [])]
    await setReview($, { name, status: 'running', output: '' })
    $.ui.status(`PHI shield on · delegate ${name} running`)
    const child = $.process.spawn({ argv, cwd: await repoRoot($) })
    let out = ''
    let step = await child.next()
    while (step.done !== true) {
      out += step.value.text
      step = await child.next()
    }
    const shown = await screened($, out)
    await setReview($, { name, status: step.value.code === 0 ? 'ready' : 'failed', output: shown })
    $.ui.status(`PHI shield on · ${await read($, flagged)} flagged`)
    await $.ui.open({ id: PANE, title: 'phi-delegate review' })
    return {
      result: `${shown}\n\nThe review pane (/phi-review) is open for the human, with Merge, Reject, and Open PR buttons. Do not merge or reject yourself.`,
    }
  }).catch(() => ({ deny: CHECK_FAILED }))

  // The tool's own calls need no Bash classifier: its argv is fixed.
  on('tool.check', { tool: DELEGATE_TOOL }, async ($, e, next) =>
    (await isOff($)) ? next(e) : { decision: 'allow' },
  ).catch(() => ({ decision: 'deny', reason: CHECK_FAILED }))

  // Prompts scan the identifier-shaped classes; keyword classes are opt-in
  // because schema talk trips them.
  on('prompt.submit', async ($, e, next) => {
    if (await isOff($)) return next(e)
    const result = await scanText($, [e.text, ...(e.context ?? [])].join('\n'), 'default')
    if (result.total === 0) return next(e)
    await flag($)
    const what = describe(result)
    if (!TYPED_ORIGINS.has(e.origin.kind)) {
      return { drop: `phi-delegate: a ${e.origin.kind} message was held back because it matched PHI patterns (${what}).` }
    }
    // Dismissed, or nobody to ask (a headless run): the prompt does not go.
    const answer = await $.ui
      .ask(`This prompt matched PHI patterns (${what}). What should happen to it?`, {
        header: 'PHI',
        options: [STAGE, SEND, CANCEL],
      })
      .catch(() => undefined)
    if (answer === undefined) {
      return { drop: `phi-delegate: the prompt matched PHI patterns (${what}) and got no answer, so it was not sent.` }
    }
    if (answer === SEND) return next(e)
    const name = answer === STAGE ? await stagePrivateInput($, e.text) : undefined
    if (name === undefined) return { drop: 'phi-delegate: prompt cancelled; it was not sent to the model.' }
    // The prompt is replaced, not passed on: the model reads only this note.
    $.ui.toast(`Staged as private input for ${name}; the model was told only the task name.`)
    return next({
      ...e,
      text: `phi-delegate: I staged private input for task ${name} (my prompt was withheld because it matched PHI patterns). Write the PHI-free spec at .phi-tasks/${name}.md and run it with the delegate tool; the delegate receives the private input as the spec's Private input section. Never read .phi-tasks/${name}.private.md.`,
      context: [],
    })
  }).catch(() => ({ drop: 'phi-delegate: the PHI check failed, so the prompt was not sent.' }))

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button, Code } = $.ui.resolve(e)
    const list = await read($, reviews)
    return (
      <Box flexDirection="column" gap={1}>
        {list.length === 0 && <Text dimColor>No delegate runs this session.</Text>}
        {list.map(review => (
          <Box key={`review-${review.name}`} flexDirection="column">
            <Text bold>
              {review.name} · {review.status}
            </Text>
            {review.output !== '' && <Code source={review.output.slice(-9_000)} language="text" />}
            {review.status === 'ready' && (
              <Text dimColor>
                Review the full diff on the PR, or in your own terminal: scripts/collect.sh {review.name} --full-diff
              </Text>
            )}
            {(review.status === 'ready' || review.status === 'failed') && (
              <Box gap={1}>
                {review.status === 'ready' && (
                  <Button
                    key={`merge-${review.name}`}
                    label="Merge"
                    variant="primary"
                    onPress={() => void runCollect($, review, '--merge')}
                  />
                )}
                <Button key={`reject-${review.name}`} label="Reject" onPress={() => void runCollect($, review, '--reject')} />
                <Button key={`pr-${review.name}`} label="Open PR" onPress={() => void runCollect($, review, '--pr')} />
              </Box>
            )}
          </Box>
        ))}
      </Box>
    )
  })
}
