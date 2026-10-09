import { expect, mock, test } from 'claude-code/testing'

// Synthetic values only. The SSN-shaped value is the one the bats fixtures use.
const SSN = '987-65-4320'
const ROOT = '/work/repo'

type Stubs = {
  answers?: string[]
  env?: Record<string, string>
  toolText?: string
  toolResult?: unknown
  failPrepare?: boolean
  unreadable?: string[]
  quarantine?: boolean
  failEnv?: boolean
  files?: Record<string, string>
  failCwd?: boolean
  failRun?: boolean
  failSpawn?: boolean
  spawnText?: string[]
}

type Seen = {
  asked: string[]
  writes: { path: string; text: string }[]
  submitted: string[]
  runs: string[][]
  ranTools: string[]
  opened: string[]
  statuses: (string | undefined)[]
}

// Every $ call the mod makes in these tests, answered in Claude Code's place.
const stub = (on: any, s: Stubs = {}): Seen => {
  const seen: Seen = { asked: [], writes: [], submitted: [], runs: [], ranTools: [], opened: [], statuses: [] }
  const answers = [...(s.answers ?? [])]
  if (s.failEnv === true) on('env.get', () => ({ deny: 'unavailable' }))
  else mock.env(on, s.env ?? {})
  mock.clock(on, { now: 1_700_000_000_000 })
  on('session.cwd', () => (s.failCwd === true ? { deny: 'no cwd' } : { value: ROOT }))
  on('fs.stat', ($: unknown, e: any) => ({ value: { kind: 'directory', size: 0, mtimeMs: 0, isLink: false, realPath: e.path } }))
  on('fs.exists', ($: unknown, e: any) => ({
    value:
      [...Object.keys(s.files ?? {}), ...(s.unreadable ?? [])].some(path => e.path.endsWith(path)) ||
      (s.quarantine === true && /\/\.phi-(?:tasks|worktrees)$/.test(e.path)),
  }))
  on('fs.read', ($: unknown, e: any) => {
    if ((s.unreadable ?? []).some(path => e.path.endsWith(path))) return { deny: 'EACCES' }
    const hit = Object.entries(s.files ?? {}).find(([path]) => e.path.endsWith(path))
    return hit === undefined ? { deny: 'ENOENT' } : { value: hit[1] }
  })
  on('fs.list', () => ({ value: [] }))
  on('fs.write', ($: unknown, e: any) => {
    seen.writes.push({ path: e.path, text: e.text })
    return { value: undefined }
  })
  on('process.run', ($: unknown, e: any) => {
    seen.runs.push([...e.argv])
    if (s.failRun === true) return { deny: 'cannot start' }
    if (s.failPrepare === true && String(e.argv[0]).endsWith('/scripts/prepare-sidecar.sh')) {
      return { value: { exitCode: 1, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
    }
    const stdout = e.argv[0] === 'git' ? `${ROOT}\n` : ''
    return { value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('process.spawn', async function* () {
    if (s.failSpawn === true) throw new Error('cannot start')
    for (const text of s.spawnText ?? []) yield { stream: 'stdout', text }
    return { value: { code: 0, signal: null } }
  })
  on('ui.status', ($: unknown, e: any) => {
    seen.statuses.push(e.text)
    return { value: undefined }
  })
  for (const name of ['ui.log', 'ui.toast', 'tool.register', 'command.register']) {
    on(name, () => ({ value: undefined }))
  }
  on('ui.open', ($: unknown, e: any) => {
    seen.opened.push(e.id)
    return { value: { isPlaced: true } }
  })
  on('prompt.submit', ($: unknown, e: any) => {
    seen.submitted.push(e.text)
    return { text: e.text }
  })
  on('tool.call', ($: unknown, e: any) => {
    if (e.tool === 'AskUserQuestion') {
      const question = e.questions[0].question
      seen.asked.push(question)
      const answer = answers.shift()
      return answer === undefined ? { deny: 'dismissed' } : { result: { answers: { [question]: answer } } }
    }
    seen.ranTools.push(e.tool)
    if (s.toolResult !== undefined) return { result: s.toolResult }
    return { result: s.toolText ?? 'ok', text: s.toolText ?? 'ok' }
  })
  return seen
}

const submit = ($: any, text: string, kind = 'composer') => $.prompt.submit({ text, origin: { kind }, wait: false })

// Stand-down

test('inside a covered delegate session nothing scans or blocks', async ($, on) => {
  const seen = stub(on, { env: { PHI_DELEGATE_SESSION: '1' }, toolText: `ssn ${SSN}` })
  expect(await $.tool.call({ tool: 'Read', file_path: '.phi-task.md' })).toMatchObject({ result: `ssn ${SSN}` })
  expect(await $.tool.call({ tool: 'Bash', command: 'cat .phi-worktrees/x.log' })).toMatchObject({ result: `ssn ${SSN}` })
  expect(await submit($, `patient ${SSN}`)).toEqual({ text: `patient ${SSN}` })
  expect(seen.asked).toEqual([])
})

// Guard denials

test('each guard rule denies, by reason, without the matched path being read', async ($, on) => {
  const seen = stub(on)
  const denied = async (input: any) => (await $.tool.call(input)).deny ?? ''
  expect(await denied({ tool: 'Read', file_path: `${ROOT}/.phi-worktrees/x.log` })).toMatch(/holds delegate worktrees/)
  expect(await denied({ tool: 'Bash', command: 'cat .phi-handoff.md' })).toMatch(/handoff copies/)
  expect(await denied({ tool: 'Bash', command: 'scripts/collect.sh x --full-diff' })).toMatch(/reserved for the human/)
  expect(await denied({ tool: 'Read', file_path: `${ROOT}/.phi-tasks/01-x.private.md` })).toMatch(/private input staged/)
  expect(await denied({ tool: 'Bash', command: 'ls ~/.phi-delegate/claude' })).toMatch(/CLAUDE_CONFIG_DIR/)
  expect(await denied({ tool: 'Bash', command: 'scripts/collect.sh x --merge' })).toMatch(/Merge button in the review pane/)
  expect(seen.ranTools).toEqual([])
  expect(await $.tool.call({ tool: 'Bash', command: 'scripts/collect.sh x' })).toMatchObject({ result: 'ok' })
  expect(await $.tool.call({ tool: 'Bash', command: 'scripts/collect.sh x --reject' })).toMatchObject({ result: 'ok' })
})

test('the guard fails closed when it cannot run', async ($, on) => {
  const seen = stub(on, { failCwd: true })
  expect((await $.tool.call({ tool: 'Read', file_path: 'README.md' })).deny).toMatch(/PHI check on this call failed/)
  expect(seen.ranTools).toEqual([])
})

// PHI-source commands

test('a configured or per-repo PHI source command is denied with a delegate instruction', async ($, on) => {
  const seen = stub(on, { files: { '/.phi-sources': '# repo sources\n\\bclinic-prod-db\\b\n' } })
  expect((await $.tool.call({ tool: 'Bash', command: 'snowsql -q "select 1"' })).deny).toMatch(/delegate tool/)
  expect((await $.tool.call({ tool: 'Bash', command: 'psql "$CLINIC_PROD_URL" -c "select 1"' })).deny).toMatch(/PHI source/)
  expect((await $.tool.call({ tool: 'Bash', command: 'mysql -h clinic-prod-db' })).deny).toMatch(/PHI source/)
  expect(seen.ranTools).toEqual([])
  expect(await $.tool.call({ tool: 'Bash', command: 'psql "$LOCAL_URL"' })).toMatchObject({ result: 'ok' })
})

test('the PHI source check fails closed', async ($, on) => {
  const seen = stub(on, { failRun: true })
  expect((await $.tool.call({ tool: 'Bash', command: 'ls' })).deny).toMatch(/PHI check on this call failed/)
  expect(seen.ranTools).toEqual([])
})

// Output scrubbing

test('a flagged Bash result is replaced by a counts-only record', { options: { scrub_scope: 'all' } }, async ($, on) => {
  stub(on, { toolText: `row 1 ${SSN}` })
  const out: any = await $.tool.call({ tool: 'Bash', command: 'cat export.csv' })
  expect(out.result.stdout).toMatch(/output withheld.*ssn-shaped 1/)
  expect(JSON.stringify(out)).not.toContain('987-65')
})

test('flagged Read, Grep, and MCP results become a deny; clean ones pass', { options: { scrub_scope: 'all' } }, async ($, on) => {
  stub(on, { toolText: `email someone@example.invalid` })
  for (const input of [
    { tool: 'Read', file_path: 'notes.txt' },
    { tool: 'Grep', pattern: 'x' },
    { tool: 'mcp__db__query', sql: 'select 1' },
  ] as any[]) {
    const out: any = await $.tool.call(input)
    expect(out.deny).toMatch(/email-address 1/)
    expect(JSON.stringify(out)).not.toContain('someone@')
  }
})

test('clean output and unscrubbed tools pass untouched', async ($, on) => {
  stub(on, { toolText: 'all good' })
  expect(await $.tool.call({ tool: 'Read', file_path: 'notes.txt' })).toMatchObject({ result: 'all good' })
})

test('scrubbing can be turned off', { options: { scrub_tool_output: false } }, async ($, on) => {
  stub(on, { toolText: `ssn ${SSN}` })
  expect(await $.tool.call({ tool: 'Read', file_path: 'notes.txt' })).toMatchObject({ result: `ssn ${SSN}` })
})

test('an allowlist entry grep and JavaScript read differently is left out, never loosening', { options: { scrub_scope: 'all', allowlist_file: '/etc/allow' } }, async ($, on) => {
  stub(on, { toolText: `ssn ${SSN}`, files: { '/etc/allow': '(unclosed\n[[:punct:]]\n' } })
  const out: any = await $.tool.call({ tool: 'Read', file_path: 'notes.txt' })
  expect(out.deny).toMatch(/ssn-shaped 1/)
  expect(JSON.stringify(out)).not.toContain('987-65')
})

test('the scrubber fails closed when it cannot run', { options: { scrub_scope: 'all' } }, async ($, on) => {
  const seen = stub(on, { failEnv: true, toolText: `ssn ${SSN}` })
  const out: any = await $.tool.call({ tool: 'mcp__db__query', sql: 'select 1' })
  expect(out.deny).toMatch(/PHI check on this call failed/)
  expect(JSON.stringify(out)).not.toContain('987-65')
  expect(seen.ranTools).toEqual([])
})

// Prompt interception

test('a clean prompt goes through without a question', async ($, on) => {
  const seen = stub(on)
  expect(await submit($, 'add a retry to the upload job')).toEqual({ text: 'add a retry to the upload job' })
  expect(seen.asked).toEqual([])
})

test('Cancel drops a flagged prompt', async ($, on) => {
  const seen = stub(on, { answers: ['Cancel'] })
  const out: any = await submit($, `look up ${SSN}`)
  expect(out.drop).toMatch(/cancelled/)
  expect(seen.submitted).toEqual([])
  expect(seen.asked[0]).toMatch(/ssn-shaped 1/)
  expect(seen.asked[0]).not.toContain('987-65')
})

test('Send anyway lets a flagged prompt through', async ($, on) => {
  stub(on, { answers: ['Send anyway (no PHI)'] })
  expect(await submit($, `use the format ${SSN}`)).toEqual({ text: `use the format ${SSN}` })
})

test('a dismissed question drops the prompt (fail closed)', async ($, on) => {
  stub(on, { answers: [] })
  const out: any = await submit($, `look up ${SSN}`)
  expect(out.drop).toMatch(/ssn-shaped 1; text withheld\) and got no answer/)
  expect(out.drop).not.toContain('987-65')
})

test('free text under Other is not an answer to send', async ($, on) => {
  stub(on, { answers: ['sure'] })
  expect(((await submit($, `look up ${SSN}`)) as any).drop).toMatch(/cancelled/)
})

test('Stage writes the sidecar and the model reads only the task name', async ($, on) => {
  const seen = stub(on, { answers: ['Stage as private input', 'New task'] })
  const out: any = await submit($, `fix the record for ${SSN}`)
  expect(out.text).toMatch(/staged private input for task staged-[a-z0-9]+/)
  expect(out.text).not.toContain('987-65')
  expect(seen.submitted).toHaveLength(1)
  expect(seen.submitted[0]).not.toContain('987-65')
  expect(seen.writes).toHaveLength(1)
  expect(seen.writes[0]?.path).toMatch(new RegExp(`^${ROOT}/\\.phi-tasks/staged-[a-z0-9]+\\.private\\.md$`))
  expect(seen.writes[0]?.text).toBe(`fix the record for ${SSN}\n`)
  const prepare = seen.runs.find(argv => String(argv[0]).endsWith('/scripts/prepare-sidecar.sh'))
  expect(prepare?.slice(1)).toEqual([ROOT, seen.writes[0]?.path.split('/').pop()?.replace(/\.private\.md$/, '')])
})

test('Cancel at the task question drops the prompt and writes nothing', async ($, on) => {
  const seen = stub(on, { answers: ['Stage as private input', 'Cancel'] })
  expect(((await submit($, `fix the record for ${SSN}`)) as any).drop).toMatch(/cancelled/)
  expect(seen.writes).toEqual([])
  expect(seen.submitted).toEqual([])
})

test('a staged name typed under Other is used when clean, replaced when not', async ($, on) => {
  const seen = stub(on, { answers: ['Stage as private input', '02-fix visit', 'Stage as private input', `x ${SSN}`] })
  await submit($, `record ${SSN}`)
  expect(seen.writes[0]?.path).toBe(`${ROOT}/.phi-tasks/02-fix-visit.private.md`)
  await submit($, `record ${SSN}`)
  expect(seen.writes[1]?.path).not.toContain('987')
})

test('messages nobody typed are held back unasked', async ($, on) => {
  const seen = stub(on)
  expect(((await submit($, `task output ${SSN}`, 'task-notification')) as any).drop).toMatch(/held back/)
  expect(seen.asked).toEqual([])
})

test('keyword classes are opt-in for prompts', async ($, on) => {
  stub(on)
  expect(await submit($, 'add a dob column to the patients schema')).toEqual({ text: 'add a dob column to the patients schema' })
})

test('with keyword classes on, schema words are flagged', { options: { prompt_keyword_classes: true } }, async ($, on) => {
  const seen = stub(on, { answers: ['Cancel'] })
  await submit($, 'add a dob column to the patients schema')
  expect(seen.asked[0]).toMatch(/dob-keyword 1/)
})

// The delegate tool

test('delegate output is re-scanned before the model sees it', async ($, on) => {
  const seen = stub(on, { spawnText: ['==> handoff (phi-scan clean):\n', `updated the row for ${SSN}\n`] })
  const out: any = await $.tool.call({ tool: 'mcp__phi-delegate__delegate', spec: '.phi-tasks/01-fix.md' })
  expect(out.result).toMatch(/Output withheld.*ssn-shaped 1/)
  expect(out.result).not.toContain('987-65')
  expect(seen.opened).toEqual(['phi-review'])
})

test('clean delegate output is returned with the review pane note', async ($, on) => {
  const seen = stub(on, { spawnText: ['==> diff --stat vs main:\n', ' seed.txt | 1 +\n'] })
  const out: any = await $.tool.call({ tool: 'mcp__phi-delegate__delegate', spec: '.phi-tasks/01-fix.md', pr: true })
  expect(out.result).toContain('seed.txt | 1 +')
  expect(out.result).toMatch(/Do not merge or reject yourself/)
  expect(seen.opened).toEqual(['phi-review'])
})

test('the delegate tool refuses a sidecar as its spec', async ($, on) => {
  stub(on)
  const out: any = await $.tool.call({ tool: 'mcp__phi-delegate__delegate', spec: '.phi-tasks/01-fix.private.md' })
  expect(out.deny).toMatch(/not a \.private\.md sidecar/)
})

test('the delegate tool is allowed without the Bash classifier', async ($, on) => {
  stub(on)
  on('tool.check', () => ({ decision: 'ask' }))
  expect(await $.tool.check({ tool: 'mcp__phi-delegate__delegate', input: { spec: '.phi-tasks/01-fix.md' } })).toMatchObject({
    decision: 'allow',
  })
})

test('the delegate tool check fails closed', async ($, on) => {
  stub(on, { failEnv: true })
  on('tool.check', () => ({ decision: 'allow' }))
  const out = await $.tool.check({ tool: 'mcp__phi-delegate__delegate', input: { spec: '.phi-tasks/01-fix.md' } })
  expect(out).toMatchObject({ decision: 'deny' })
  expect(out.reason).toMatch(/PHI check on this call failed/)
})

test('a delegate run that fails is denied, never passed through', async ($, on) => {
  stub(on, { failSpawn: true })
  const out: any = await $.tool.call({ tool: 'mcp__phi-delegate__delegate', spec: '.phi-tasks/01-fix.md' })
  expect(out.deny).toMatch(/PHI check on this call failed/)
})

// The review pane

const PANE = {
  plugin: 'phi-delegate',
  component: 'Pane',
  requestId: 'phi-review',
  viewport: { columns: 140, rows: 40 },
  props: {
    title: 'phi-delegate review',
    isFocused: true,
    bodyColumns: 100,
    placement: 'inline',
    scroll: { offset: 0, bodyRows: 30 },
    view: {},
  },
} as const

test('the pane buttons run collect.sh; the model has no way to press them', async ($, on) => {
  const seen = stub(on, { spawnText: [' seed.txt | 1 +\n'] })
  await $.tool.call({ tool: 'mcp__phi-delegate__delegate', spec: '.phi-tasks/01-fix.md' })
  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect(await ui.find({ type: 'Text', text: /01-fix · ready/ })).toBeDefined()
    expect(await ui.find({ key: 'merge-01-fix' })).toBeDefined()
    await ui.unmount()
  }
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await ui.press({ key: 'pr-01-fix' })
  await ui.press({ key: 'merge-01-fix' })
  const collects = seen.runs.filter(argv => argv[0]?.endsWith('/scripts/collect.sh'))
  expect(collects.map(argv => argv.slice(1))).toEqual([
    ['01-fix', '--pr'],
    ['01-fix', '--merge'],
  ])
  expect(await ui.find({ type: 'Text', text: /01-fix · merged/ })).toBeDefined()
  expect(await ui.find({ key: 'merge-01-fix' })).toBeUndefined()
})

test('Reject runs collect.sh --reject', async ($, on) => {
  const seen = stub(on, { spawnText: ['done\n'] })
  await $.tool.call({ tool: 'mcp__phi-delegate__delegate', spec: '.phi-tasks/02-x.md', name: '02-x' })
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await ui.press({ key: 'reject-02-x' })
  expect(seen.runs.filter(argv => argv[0]?.endsWith('/scripts/collect.sh')).map(argv => argv[2])).toEqual(['--reject'])
  expect(await ui.find({ type: 'Text', text: /02-x · rejected/ })).toBeDefined()
})

// Regressions from the PR review

test('staging fails closed when the sidecar cannot be prepared or excluded', async ($, on) => {
  const seen = stub(on, { answers: ['Stage as private input', 'New task'], failPrepare: true })
  expect(((await submit($, `fix the record for ${SSN}`)) as any).drop).toMatch(/PHI check failed/)
  expect(seen.writes).toEqual([])
  expect(seen.submitted).toEqual([])
})

test('a trailer-shaped line in ordinary command output is scanned', { options: { scrub_scope: 'all' } }, async ($, on) => {
  stub(on, { toolText: `Author: ${SSN}\n` })
  const out: any = await $.tool.call({ tool: 'Bash', command: 'cat notes.txt' })
  expect(out.result.stdout).toMatch(/ssn-shaped 1/)
})

test('git history output keeps the diff profile, so author emails do not count', { options: { scrub_scope: 'all' } }, async ($, on) => {
  stub(on, { toolText: 'commit 1a2b3c4\nAuthor: Sample Dev <sample.dev@example.invalid>\n' })
  const out: any = await $.tool.call({ tool: 'Bash', command: 'git log -1' })
  expect(out.result).toContain('sample.dev@example.invalid')
  const chained: any = await $.tool.call({ tool: 'Bash', command: 'git log -1 && cat notes.txt' })
  expect(chained.result.stdout).toMatch(/email-address 1/)
})

test('every string in a result record is scanned, newlines intact', { options: { scrub_scope: 'all' } }, async ($, on) => {
  stub(on, { toolResult: { stdout: `\n${SSN}\n`, stderr: '' } })
  const out: any = await $.tool.call({ tool: 'Bash', command: 'cat export.csv' })
  expect(out.result.stdout).toMatch(/ssn-shaped/)
  expect(JSON.stringify(out)).not.toContain('987-65')
})

test('.phi-tasks is reachable from Bash only through a plain script run', async ($, on) => {
  const seen = stub(on)
  for (const command of ['cat .phi-tasks/*', 'cat .phi-tasks/01-x.pri*', 'ls .phi-tasks', 'scripts/delegate.sh .phi-tasks/01.md; cat .phi-tasks/*']) {
    expect((await $.tool.call({ tool: 'Bash', command })).deny ?? '').toMatch(/private input sidecars/)
  }
  expect((await $.tool.call({ tool: 'Grep', pattern: 'x', path: '.phi-tasks' } as any)).deny ?? '').toMatch(/private input sidecars/)
  expect(seen.ranTools).toEqual([])
  for (const command of ['scripts/delegate.sh .phi-tasks/01-x.md --pr', 'mkdir -p .phi-tasks']) {
    expect(await $.tool.call({ tool: 'Bash', command })).toMatchObject({ result: 'ok' })
  }
  expect(await $.tool.call({ tool: 'Write', file_path: '.phi-tasks/01-x.md', content: 'spec' })).toMatchObject({ result: 'ok' })
})

// Regressions from the second PR review

test('git show of a file is scanned whole, not as history', { options: { scrub_scope: 'all' } }, async ($, on) => {
  stub(on, { toolText: `Author: ${SSN}\n` })
  const out: any = await $.tool.call({ tool: 'Bash', command: 'git show HEAD:notes.txt' })
  expect(out.result.stdout).toMatch(/ssn-shaped 1/)
  const shown: any = await $.tool.call({ tool: 'Bash', command: 'git show HEAD' })
  expect(shown.result.stdout).toMatch(/ssn-shaped 1/)
})

test('numbers and keys in a result record are scanned', { options: { scrub_scope: 'all' } }, async ($, on) => {
  stub(on, { toolResult: { patient_id: 123456789, 'someone@example.invalid': 'active' } })
  const out: any = await $.tool.call({ tool: 'mcp__db__query', sql: 'select 1' })
  expect(out.deny).toMatch(/email-address 1/)
  expect(out.deny).toMatch(/long-digit-run 1/)
})

test('a .phi-sources file that cannot be read denies the command', async ($, on) => {
  const seen = stub(on, { unreadable: ['/.phi-sources'] })
  expect((await $.tool.call({ tool: 'Bash', command: 'mysql -h clinic-prod-db' })).deny).toMatch(/PHI check on this call failed/)
  expect(seen.ranTools).toEqual([])
})

test('bracket globs and prefix tricks on .phi-tasks are denied; quoted args are not', async ($, on) => {
  const seen = stub(on)
  for (const command of ['cat .phi-task[s]/*', 'cat<.phi-tasks/01.pri*;scripts/delegate.sh', 'scripts/delegate.sh $(cat .phi-tasks/x)']) {
    expect((await $.tool.call({ tool: 'Bash', command })).deny ?? '').toMatch(/private input sidecars/)
  }
  expect(seen.ranTools).toEqual([])
  for (const command of ['scripts/delegate.sh ".phi-tasks/01-fix visit.md" --pr', "scripts/delegate.sh '.phi-tasks/01-fix visit.md'"]) {
    expect(await $.tool.call({ tool: 'Bash', command })).toMatchObject({ result: 'ok' })
  }
})

// Regressions from the third PR review

test('a merge commit shown as a combined diff is scanned inside its hunks', { options: { scrub_scope: 'all' } }, async ($, on) => {
  stub(on, {
    toolText: `commit 1a2b3c4d5e6f\nMerge: 1111111 2222222\nAuthor: Sample Dev <sample.dev@example.invalid>\n\ndiff --cc notes.md\n@@@ -1,2 -1,2 +1,2 @@@\n    Author: ${SSN}\n`,
  })
  const out: any = await $.tool.call({ tool: 'Bash', command: 'git show HEAD' })
  expect(out.result.stdout).toMatch(/ssn-shaped 1/)
  expect(out.result.stdout).not.toMatch(/email-address/)
})

test('in a repo with delegate state, recursive grep must exclude it', async ($, on) => {
  const seen = stub(on, { quarantine: true })
  for (const command of ['grep -R -n patient .', 'grep -rn foo src', 'rg -uu patient', 'ls && grep -nr x .']) {
    expect((await $.tool.call({ tool: 'Bash', command })).deny ?? '').toMatch(/would read \.phi-tasks/)
  }
  expect(seen.ranTools).toEqual([])
  for (const command of ['rg patient', 'git grep -n patient', 'grep -n x notes.txt', "grep -rn x . --exclude-dir='.phi-*'"]) {
    expect(await $.tool.call({ tool: 'Bash', command })).toMatchObject({ result: 'ok' })
  }
})

test('in a repo with no delegate state, recursive grep is untouched', async ($, on) => {
  stub(on)
  expect(await $.tool.call({ tool: 'Bash', command: 'grep -R -n patient .' })).toMatchObject({ result: 'ok' })
})

// Regressions from the third PR review, round two

test('a PHI source pattern that does not compile blocks Bash, by count only', async ($, on) => {
  const seen = stub(on, { files: { '/.phi-sources': '\\bclinic-prod-db\\b(\n' } })
  const out: any = await $.tool.call({ tool: 'Bash', command: 'mysql -h clinic-prod-db' })
  expect(out.deny).toMatch(/1 PHI source pattern\(s\) do not compile/)
  expect(out.deny).not.toContain('clinic-prod-db')
  expect(seen.ranTools).toEqual([])
})

test('a typed task name is scanned before cleanup, so an email cannot slip through', async ($, on) => {
  const seen = stub(on, { answers: ['Stage as private input', 'someone@example.invalid'] })
  const out: any = await submit($, `fix the record for ${SSN}`)
  expect(out.text).toMatch(/task staged-[a-z0-9]+/)
  expect(out.text).not.toMatch(/someone/)
  expect(seen.writes[0]?.path).toMatch(/staged-[a-z0-9]+\.private\.md$/)
})

test('a quoted script path naming .phi-tasks is allowed; an expanded one is not', async ($, on) => {
  stub(on)
  for (const command of ['bash "/opt/phi delegate/scripts/delegate.sh" ".phi-tasks/01-fix.md" --pr', "bash '/opt/x/scripts/delegate.sh' .phi-tasks/01.md"]) {
    expect(await $.tool.call({ tool: 'Bash', command })).toMatchObject({ result: 'ok' })
  }
  expect((await $.tool.call({ tool: 'Bash', command: 'bash "$HOME/scripts/delegate.sh" .phi-tasks/01.md' })).deny ?? '').toMatch(/private input sidecars/)
})

// The guardrail switch: opt-in for a skill-only install.sh setup

const SKILL_LINK = { '/home/u/.claude/skills/phi-delegate': '' }

const isGuarded = async ($: any) =>
  ((await $.tool.call({ tool: 'Read', file_path: '.phi-worktrees/x.log' })).deny ?? '').includes('guard: blocked')

test('auto: a skill-only install keeps the guardrail off, as before this release', async ($, on) => {
  const seen = stub(on, { env: { HOME: '/home/u' }, files: SKILL_LINK, toolText: `ssn ${SSN}` })
  expect(await isGuarded($)).toBe(false)
  expect(await $.tool.call({ tool: 'Bash', command: 'cat export.csv' })).toMatchObject({ result: `ssn ${SSN}` })
  expect(await submit($, `look up ${SSN}`)).toEqual({ text: `look up ${SSN}` })
  expect(seen.asked).toEqual([])
  expect(((await $.tool.call({ tool: 'mcp__phi-delegate__delegate', spec: '.phi-tasks/01.md' })) as any).deny).toMatch(/guardrail is off/)
})

test('auto: with no skills-folder link the guardrail is on', async ($, on) => {
  stub(on, { env: { HOME: '/home/u' } })
  expect(await isGuarded($)).toBe(true)
})

test('auto honors CLAUDE_CONFIG_DIR when looking for the skills-folder link', async ($, on) => {
  stub(on, { env: { HOME: '/home/u', CLAUDE_CONFIG_DIR: '/cfg' }, files: { '/cfg/skills/phi-delegate': '' } })
  expect(await isGuarded($)).toBe(false)
})

test('the guardrail option turns it on for a skill-only install', { options: { guardrail: 'on' } }, async ($, on) => {
  stub(on, { env: { HOME: '/home/u' }, files: SKILL_LINK })
  expect(await isGuarded($)).toBe(true)
})

test('the guardrail option turns it off anywhere', { options: { guardrail: 'off' } }, async ($, on) => {
  stub(on, { env: { HOME: '/home/u' } })
  expect(await isGuarded($)).toBe(false)
})

test('PHI_DELEGATE_GUARDRAIL overrides the option either way', { options: { guardrail: 'off' } }, async ($, on) => {
  stub(on, { env: { HOME: '/home/u', PHI_DELEGATE_GUARDRAIL: 'on' }, files: SKILL_LINK })
  expect(await isGuarded($)).toBe(true)
})

test('PHI_DELEGATE_GUARDRAIL=off turns it off where auto would be on', async ($, on) => {
  stub(on, { env: { HOME: '/home/u', PHI_DELEGATE_GUARDRAIL: 'off' } })
  expect(await isGuarded($)).toBe(false)
})

test('inside the covered delegate it stays off even when forced on', async ($, on) => {
  stub(on, { env: { PHI_DELEGATE_SESSION: '1', PHI_DELEGATE_GUARDRAIL: 'on' } })
  expect(await isGuarded($)).toBe(false)
})

// Scrub scope: data by default, from the CI-triage feedback

test('data scope leaves gh, git, cat, and browser tools alone', async ($, on) => {
  stub(on, { toolText: 'run 37660736649 at 2026-10-07 and someone@example.invalid' })
  for (const input of [
    { tool: 'Bash', command: 'gh run view 37660736649 --json jobs' },
    { tool: 'Bash', command: 'git show HEAD:e2e/login.yaml' },
    { tool: 'Bash', command: 'cat notes/memory.md' },
    { tool: 'Read', file_path: 'notes/memory.md' },
    { tool: 'mcp__claude-in-chrome__tabs_context_mcp' },
  ] as any[]) {
    expect(await $.tool.call(input)).toMatchObject({ text: 'run 37660736649 at 2026-10-07 and someone@example.invalid' })
  }
})

test('data scope scrubs data commands, data files, data tools, and background output', async ($, on) => {
  stub(on, { toolText: `ssn ${SSN}` })
  expect(((await $.tool.call({ tool: 'Bash', command: 'psql "$DB" -c "select 1"' })) as any).result.stdout).toMatch(/withheld/)
  expect(((await $.tool.call({ tool: 'Bash', command: 'bin/rails runner "puts 1"' })) as any).result.stdout).toMatch(/withheld/)
  expect(((await $.tool.call({ tool: 'Read', file_path: 'exports/visits.CSV' })) as any).deny).toMatch(/withheld/)
  expect(((await $.tool.call({ tool: 'mcp__sentry__search_issues', query: 'x' } as any)) as any).deny).toMatch(/withheld/)
  expect(((await $.tool.call({ tool: 'BashOutput', bash_id: 'b1' } as any)) as any).deny).toMatch(/withheld/)
})

test('the scope lists are configurable', { options: { scrub_commands: ['\\bmy-export\\b'], scrub_tools: [], scrub_files: [] } }, async ($, on) => {
  stub(on, { toolText: `ssn ${SSN}` })
  expect(((await $.tool.call({ tool: 'Bash', command: 'my-export --today' })) as any).result.stdout).toMatch(/withheld/)
  expect(await $.tool.call({ tool: 'Bash', command: 'psql -c "select 1"' })).toMatchObject({ text: `ssn ${SSN}` })
  expect(await $.tool.call({ tool: 'mcp__sentry__search_issues', query: 'x' } as any)).toMatchObject({ text: `ssn ${SSN}` })
})

test('a scope rule that does not compile widens the scope to every tool', { options: { scrub_tools: ['(open'] } }, async ($, on) => {
  stub(on, { toolText: `ssn ${SSN}` })
  expect(((await $.tool.call({ tool: 'Bash', command: 'cat notes.txt' })) as any).result.stdout).toMatch(/withheld/)
})

test('a configured PHI source also counts as a data command', { options: { phi_sources: ['\\bclinic-db\\b'] } }, async ($, on) => {
  stub(on, { toolText: `ssn ${SSN}` })
  // Denied before it runs, so nothing reaches the scrubber at all.
  expect(((await $.tool.call({ tool: 'Bash', command: 'clinic-db dump' })) as any).deny).toMatch(/PHI source/)
})

test('a CI-run prompt with a GitHub URL and a timestamp is not flagged', async ($, on) => {
  const seen = stub(on)
  const text = 'Smoke is red, see https://github.com/example-org/example-app/actions/runs/37660736649 (failed 2026-10-07 19:04)'
  expect(await submit($, text)).toEqual({ text })
  expect(seen.asked).toEqual([])
})

test('the inline allowlist joins the allowlist file', { options: { allowlist: ['@example\\.invalid'] } }, async ($, on) => {
  const seen = stub(on)
  expect(await submit($, 'ping test.user@example.invalid about the flaky test')).toEqual({ text: 'ping test.user@example.invalid about the flaky test' })
  await submit($, 'ping someone@elsewhere.example about it')
  expect(seen.asked).toHaveLength(1)
})

// /phi-guard

test('/phi-guard off asks the person, and only their yes turns it off', async ($, on) => {
  const seen = stub(on, { answers: ['Keep it on', 'Turn it off'] })
  expect((await $.command.run({ command: 'phi-guard', args: 'off' } as any)).text).toMatch(/kept on/)
  expect(await isGuarded($)).toBe(true)
  expect((await $.command.run({ command: 'phi-guard', args: 'off' } as any)).text).toMatch(/off for this session/)
  expect(await isGuarded($)).toBe(false)
  expect(seen.asked).toHaveLength(2)
  expect((await $.command.run({ command: 'phi-guard', args: 'on' } as any)).text).toMatch(/on for this session/)
  expect(await isGuarded($)).toBe(true)
})

test('/phi-guard off with nobody to ask stays on', async ($, on) => {
  stub(on, { answers: [] })
  expect((await $.command.run({ command: 'phi-guard', args: 'off' } as any)).text).toMatch(/kept on/)
  expect(await isGuarded($)).toBe(true)
})

test('/phi-guard on turns on a skill-only install for the session', async ($, on) => {
  stub(on, { env: { HOME: '/home/u' }, files: SKILL_LINK })
  expect(await isGuarded($)).toBe(false)
  expect((await $.command.run({ command: 'phi-guard', args: '' } as any)).text).toMatch(/skill-only install/)
  await $.command.run({ command: 'phi-guard', args: 'on' } as any)
  expect(await isGuarded($)).toBe(true)
})

const startSession = async ($: any, on: any) => {
  on('session.start', () => ({ cwd: '/work/repo' }))
  await $.session.start({ surface: 'terminal', isInteractive: true, cwd: '/work/repo' })
}

test('an explicitly off guardrail says so on the status line', { options: { guardrail: 'off' } }, async ($, on) => {
  const seen = stub(on, { env: { HOME: '/home/u' } })
  await startSession($, on)
  expect(seen.statuses).toEqual(['PHI shield off'])
})

test('an auto-off skill-only install shows no status line', async ($, on) => {
  const seen = stub(on, { env: { HOME: '/home/u' }, files: SKILL_LINK })
  await startSession($, on)
  expect(seen.statuses).toEqual([])
})

test('an active guardrail shows the shield on', async ($, on) => {
  const seen = stub(on, { env: { HOME: '/home/u' } })
  await startSession($, on)
  expect(seen.statuses).toEqual(['PHI shield on · 0 flagged'])
})
