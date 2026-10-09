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

// The script runs grep -E in the C locale, which matches bytes. To agree
// with it, the mod matches the UTF-8 bytes of text and patterns alike, one
// byte per character, so ".", ranges, and lengths count what grep counts.
export const toBytes = (text: string): string => {
  let out = ''
  for (const byte of new TextEncoder().encode(text)) out += String.fromCharCode(byte)
  return out
}

const POSIX_CLASSES: Record<string, string> = {
  space: '\\t\\n\\v\\f\\r ',
  blank: '\\t ',
  digit: '0-9',
  alpha: 'A-Za-z',
  alnum: 'A-Za-z0-9',
  upper: 'A-Z',
  lower: 'a-z',
  xdigit: '0-9A-Fa-f',
}

// An extended regex as grep reads it in the C locale, spelled for
// JavaScript: \s and \S as ASCII whitespace; inside a bracket expression a
// backslash is literal, a leading ] is a member, and the POSIX classes above
// expand. A construct with no faithful spelling throws.
export const toGrepRegex = (source: string): string => {
  let out = ''
  let i = 0
  while (i < source.length) {
    const ch = source[i] ?? ''
    if (ch === '\\' && i + 1 < source.length) {
      const after = source[i + 1] ?? ''
      out += after === 's' ? '[\\t\\n\\v\\f\\r ]' : after === 'S' ? '[^\\t\\n\\v\\f\\r ]' : ch + after
      i += 2
      continue
    }
    if (ch !== '[') {
      out += ch
      i += 1
      continue
    }
    let j = i + 1
    let body = ''
    if (source[j] === '^') {
      body += '^'
      j += 1
    }
    if (source[j] === ']') {
      body += '\\]'
      j += 1
    }
    for (;;) {
      const c = source[j]
      if (c === undefined) throw new Error('unterminated bracket expression')
      if (c === ']') break
      if (c === '[' && source[j + 1] === ':') {
        const close = source.indexOf(':]', j + 2)
        const expansion = close < 0 ? undefined : POSIX_CLASSES[source.slice(j + 2, close)]
        if (expansion === undefined) throw new Error('unsupported bracket class')
        body += expansion
        j = close + 2
        continue
      }
      if (c === '[' && (source[j + 1] === '.' || source[j + 1] === '=')) throw new Error('unsupported collating element')
      body += c === '\\' ? '\\\\' : c
      j += 1
    }
    out += `[${body}]`
    i = j + 1
  }
  return toBytes(out)
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
  // An allowlist entry with no faithful spelling is left out: one fewer
  // exemption can only make the scan stricter than the script's.
  const allow = (options.allow ?? []).flatMap(entry => {
    try {
      return [new RegExp(toGrepRegex(entry))]
    } catch {
      return []
    }
  })

  // grep counts lines; a trailing newline ends the last line, it adds none.
  let lines = toBytes(text).split('\n')
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
