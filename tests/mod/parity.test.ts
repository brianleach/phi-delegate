import { expect, test } from 'claude-code/testing'

import { PATTERNS_TSV } from '../../hooks/patterns.generated'
import { parsePatterns, scan } from '../../hooks/scan'
import type { ScanOptions } from '../../hooks/scan'
import { ALLOW_ENTRIES, EDGE_ENTRIES, FIXTURES } from './parity.generated'

const patterns = parsePatterns(PATTERNS_TSV)

const VARIANTS: Record<string, ScanOptions> = {
  default: { profile: 'default' },
  diff: { profile: 'diff' },
  prose: { profile: 'prose' },
  diffAllow: { profile: 'diff', allow: ALLOW_ENTRIES },
  edgeAllow: { profile: 'default', allow: EDGE_ENTRIES },
}

const countsOf = (text: string, options: ScanOptions): Record<string, number> =>
  Object.fromEntries(scan(patterns, text, options).counts.map(c => [c.name, c.lines]))

test('every fixture gives phi-scan.sh per-class counts under every profile', () => {
  expect(FIXTURES.length).toBe(21)
  for (const fixture of FIXTURES) {
    for (const [variant, options] of Object.entries(VARIANTS)) {
      expect({ fixture: fixture.name, variant, counts: countsOf(fixture.text, options) }).toEqual({
        fixture: fixture.name,
        variant,
        counts: fixture.counts[variant],
      })
    }
  }
})

test('--only and --skip select classes the way the script does', () => {
  const ssn = FIXTURES.find(f => f.name === 'dirty-ssn.txt')
  expect(ssn).toBeDefined()
  expect(countsOf(ssn?.text ?? '', { only: ['email-address'] })).toEqual({})
  expect(Object.keys(countsOf(ssn?.text ?? '', { only: ['ssn-shaped'] }))).toEqual(['ssn-shaped'])
  expect(Object.keys(countsOf(ssn?.text ?? '', { skip: ['ssn-shaped'] }))).not.toContain('ssn-shaped')
})

test('arn and ecr ids are masked, a bare long digit run is not', () => {
  const masked = 'arn:aws:ecs:us-east-1:123456789012:task/x 123456789012.dkr.ecr.us-east-1.amazonaws.com/app'
  expect(countsOf(masked, {})).toEqual({})
  expect(countsOf('id 123456789012', {})).toEqual({ 'long-digit-run': 1 })
})
