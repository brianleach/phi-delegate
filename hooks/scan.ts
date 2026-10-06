// The mod's port of scripts/phi-scan.sh. Both read scripts/phi-patterns.tsv;
// the parity test holds them to identical per-class counts on every fixture.
// Like the script, it counts matching lines and never returns their text.

export type ScanProfile = 'default' | 'diff' | 'prose'

export type ScanOptions = {
  profile?: ScanProfile
  only?: readonly string[]
  skip?: readonly string[]
  // Allowlist entries, one extended regex each; blank and # lines ignored.
  allow?: readonly string[]
}

export type ScanCount = { name: string; lines: number }

export type ScanResult = { total: number; counts: ScanCount[] }

type Rule = { name: string; regex: RegExp; tags: string[]; repl: string }

export type Patterns = {
  classes: Rule[]
  masks: Rule[]
  drops: Rule[]
  hunkStart?: Rule
  hunkEnd?: Rule
}

// grep -E in the C locale reads \s and \S as ASCII whitespace; JavaScript's
// also take Unicode spaces such as a no-break space. Outside a bracket
// expression, spell them as grep reads them so both scanners agree.
export const toGrepRegex = (source: string): string => {
  let out = ''
  let inBracket = false
  for (let i = 0; i < source.length; i += 1) {
    const ch = source[i]
    const after = source[i + 1]
    if (ch === '\\' && after !== undefined) {
      if (!inBracket && after === 's') out += '[\\t\\n\\v\\f\\r ]'
      else if (!inBracket && after === 'S') out += '[^\\t\\n\\v\\f\\r ]'
      else out += ch + after
      i += 1
      continue
    }
    if (ch === '[' && !inBracket) inBracket = true
    else if (ch === ']' && inBracket) inBracket = false
    out += ch
  }
  return out
}

export const parsePatterns = (tsv: string): Patterns => {
  const patterns: Patterns = { classes: [], masks: [], drops: [] }
  for (const line of tsv.split('\n')) {
    const [kind, name, flags, tags, regex, repl] = line.split('\t')
    if (name === undefined || regex === undefined) continue
    // Applied to one line at a time, as sed and grep -E read them. No "m"
    // flag: in JavaScript it would also anchor ^ after a carriage return.
    const rule: Rule = {
      name,
      regex: new RegExp(toGrepRegex(regex), `g${flags === 'i' ? 'i' : ''}`),
      tags: tags === '-' || tags === undefined ? [] : tags.split(','),
      repl: (repl ?? '').replace(/\\(\d)/g, '$$$1'),
    }
    if (kind === 'class') patterns.classes.push(rule)
    else if (kind === 'mask') patterns.masks.push(rule)
    else if (kind === 'drop') patterns.drops.push(rule)
    else if (kind === 'hunk' && name === 'start') patterns.hunkStart = rule
    else if (kind === 'hunk' && name === 'end') patterns.hunkEnd = rule
  }
  return patterns
}

export const classNames = (p: Patterns, tag?: string): string[] =>
  p.classes.filter(c => tag === undefined || c.tags.includes(tag)).map(c => c.name)

const testLine = (re: RegExp, line: string): boolean => {
  re.lastIndex = 0
  return re.test(line)
}

export const parseAllow = (text: string): string[] =>
  text.split('\n').filter(line => !/^\s*(#|$)/.test(line))

export const scan = (p: Patterns, text: string, options: ScanOptions = {}): ScanResult => {
  const profile = options.profile ?? 'default'
  const skip = new Set(options.skip ?? [])
  if (profile === 'prose') for (const name of classNames(p, 'prose-skip')) skip.add(name)
  const only = options.only === undefined ? undefined : new Set(options.only)
  const allow = (options.allow ?? []).map(entry => new RegExp(toGrepRegex(entry)))

  // grep counts lines; a trailing newline ends the last line, it adds none.
  let lines = text.split('\n')
  if (lines.length > 0 && lines[lines.length - 1] === '') lines.pop()
  lines = lines.map(line => p.masks.reduce((out, mask) => out.replace(mask.regex, mask.repl), line))
  if (profile === 'diff') {
    // As the script does: drop rules reach only lines outside a hunk, which
    // runs from an @@ line to the next diff --git or commit header.
    const { hunkStart, hunkEnd } = p
    if (hunkStart === undefined || hunkEnd === undefined) throw new Error('pattern file has no hunk rows')
    let inHunk = false
    lines = lines.filter(line => {
      if (testLine(hunkEnd.regex, line)) inHunk = false
      if (testLine(hunkStart.regex, line)) inHunk = true
      else if (inHunk) return true
      return !p.drops.some(drop => testLine(drop.regex, line))
    })
  }

  const counts: ScanCount[] = []
  let total = 0
  for (const rule of p.classes) {
    if (only !== undefined && !only.has(rule.name)) continue
    if (skip.has(rule.name)) continue
    const n = lines.filter(
      line => testLine(rule.regex, line) && !allow.some(re => re.test(line)),
    ).length
    if (n > 0) {
      counts.push({ name: rule.name, lines: n })
      total += n
    }
  }
  return { total, counts }
}

// Class names and line counts on one line, for notices and drop reasons.
export const describe = (result: ScanResult): string =>
  result.total === 0
    ? 'phi-scan: clean'
    : `${result.counts.map(c => `${c.name} ${c.lines}`).join(', ')}; text withheld`
