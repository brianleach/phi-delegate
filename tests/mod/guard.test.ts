import { expect, test } from 'claude-code/testing'

import { compileSources, guardReason, isSelfRepo, taskName } from '../../hooks/guard'

test('guard reasons match guard-hook.sh, plus sidecars and merges', () => {
  expect(guardReason('{"file_path":"src/app.rb"}')).toBeUndefined()
  expect(guardReason('{"command":"scripts/collect.sh x --merge"}', 'scripts/collect.sh x --merge')).toMatch(/review pane/)
  expect(guardReason('{"command":"scripts/collect.sh x"}', 'scripts/collect.sh x')).toBeUndefined()
  expect(guardReason('{"command":"git merge main"}', 'git merge main')).toBeUndefined()
  // --merge is a Bash rule only: a spec that mentions it may still be written
  expect(guardReason('{"content":"then collect.sh x --merge"}')).toBeUndefined()
})

test('the self-repo exemption covers the cwd and the resolved path only', () => {
  expect(isSelfRepo('/src/phi-delegate', '/src/phi-delegate/scripts', '{}')).toBe(true)
  expect(isSelfRepo('/src/phi-delegate', '/work', '{"file_path":"/src/phi-delegate/x"}')).toBe(true)
  expect(isSelfRepo('/src/phi-delegate', '/src/phi-delegate-other', '{}')).toBe(false)
  expect(isSelfRepo(undefined, '/src/phi-delegate', '{}')).toBe(false)
})

test('source patterns skip comments and count the ones that do not compile', () => {
  const { regexes, invalid } = compileSources(['# comment', '', '\\bsnowsql\\b', '(open'])
  expect(regexes).toHaveLength(1)
  expect(invalid).toBe(1)
})

test('task names follow delegate.sh', () => {
  expect(taskName('.phi-tasks/01-fix dupes.md')).toBe('01-fix-dupes')
  expect(taskName('.phi-tasks/01-fix.md', '-x/y-')).toBe('x-y')
})
