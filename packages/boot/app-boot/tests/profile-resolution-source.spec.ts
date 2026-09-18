/** Source resolution runs through the shipping tsx ESM hook, not Vitest's paths plugin. */

import { mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { execa } from 'execa'
import { afterEach, describe, expect, it } from 'vitest'
import type { ProfileResolutionGeneration } from '../src/profile.ts'
import type { ProfileResolutionBehavior } from '../src/profile-resolution/resolver.ts'

const repoRoot = fileURLToPath(new URL('../../../../', import.meta.url))
const resolver = new URL('../src/profile-resolution/resolver.ts', import.meta.url).href
const roots: string[] = []

afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true })
})

function file(path: string, content: string): void {
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, content)
}

function fixture(source: boolean, artifacts: boolean, behavior: ProfileResolutionBehavior): {
  entry: string
  tsconfig: string
  expected: string
} {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'dsh-profile-source-')))
  roots.push(root)
  const library = join(root, 'workspace', 'library')
  const bridge = join(root, 'workspace', 'bridge')
  const bridgeLink = join(root, 'install', 'node_modules', 'resolution-bridge')
  const libraryLink = join(bridge, 'node_modules', 'resolution-lib')
  file(join(bridge, 'package.json'), JSON.stringify({ name: 'resolution-bridge', type: 'module' }))
  file(join(library, 'package.json'), JSON.stringify({
    name: 'resolution-lib',
    type: 'module',
    exports: { '.': './lib/index.js', './subpath': './lib/subpath.js' },
  }))
  for (const [plane, extension] of [['src', 'ts'], ...(artifacts ? [['lib', 'js']] : [])]) {
    file(join(library, `${plane}/index.${extension}`), 'export const token = Symbol("resolution-lib")\n')
    file(join(library, `${plane}/subpath.${extension}`), `export { token } from './index.${extension}'\nexport const url = import.meta.url\n`)
  }
  for (const [target, link] of [[bridge, bridgeLink], [library, libraryLink]] as const) {
    mkdirSync(dirname(link), { recursive: true })
    symlinkSync(target, link, process.platform === 'win32' ? 'junction' : 'dir')
  }
  const profile = join(root, 'profiles', 'test')
  if (behavior === 'verify') {
    const projected = join(root, 'profiles', 'node_modules', 'resolution-lib')
    mkdirSync(dirname(projected), { recursive: true })
    symlinkSync(library, projected, process.platform === 'win32' ? 'junction' : 'dir')
  }
  const profileEntry = join(profile, 'entry.mjs')
  file(profileEntry, 'export { token as rootToken } from "resolution-lib"\nexport { token, url } from "resolution-lib/subpath"\n')
  const generation: ProfileResolutionGeneration = {
    profilesDir: dirname(profile),
    profileDir: profile,
    localPackageNames: [],
    entries: [{
      name: 'resolution-lib', packageDir: libraryLink,
      declarer: join(bridgeLink, 'package.json'), version: undefined, scope: 'installation',
    }],
  }
  const tsconfig = join(root, 'tsconfig.json')
  file(tsconfig, JSON.stringify({ compilerOptions: { paths: source ? {
    'resolution-lib': [join(library, 'src/index.ts')],
    'resolution-lib/*': [join(library, 'src/*.ts')],
  } : {} } }))
  const expected = pathToFileURL(join(library, source ? 'src/subpath.ts' : 'lib/subpath.js')).href
  const entry = join(root, 'probe.mjs')
  file(entry, `
import { installProfileResolution } from ${JSON.stringify(resolver)}
const direct = await import(${JSON.stringify(expected)})
const registration = installProfileResolution(${JSON.stringify(generation)}, ${JSON.stringify(behavior)})
try {
  const plugin = await import(${JSON.stringify(pathToFileURL(profileEntry).href)})
  console.log(JSON.stringify({ url: plugin.url, sameInstance: plugin.token === direct.token && plugin.rootToken === direct.token }))
} finally {
  registration.dispose()
}
`)
  return { entry, tsconfig, expected }
}

describe.each(['enforce', 'verify'] as const)('profile resolution with tsx/esm (%s)', (behavior) => {
  it.each([
    { plane: 'source', source: true, artifacts: true },
    { plane: 'source', source: true, artifacts: false },
    { plane: 'artifact', source: false, artifacts: true },
  ])('shares the $plane instance (artifacts: $artifacts)', async ({ source, artifacts }) => {
    const f = fixture(source, artifacts, behavior)
    const result = await execa(process.execPath, ['--import', 'tsx/esm', f.entry], {
      cwd: repoRoot,
      env: { TSX_TSCONFIG_PATH: f.tsconfig },
      timeout: 25_000,
      killSignal: 'SIGKILL',
      reject: false,
    })
    expect(result.timedOut).toBe(false)
    expect(result.signal).toBeUndefined()
    expect(result.exitCode, result.stderr).toBe(0)
    expect(JSON.parse(result.stdout)).toEqual({ url: f.expected, sameInstance: true })
  })
})
