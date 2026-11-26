import { afterAll, describe, expect, test } from 'bun:test';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// The committed schema and Swift are generated from src/protocol, never edited by hand: generating
// them again must reproduce them exactly.
const root = join(import.meta.dir, '..');

async function run(script: string, ...args: string[]) {
  const proc = Bun.spawn([process.execPath, 'run', script, ...args], { cwd: root, stdout: 'ignore', stderr: 'pipe' });
  const [err, code] = await Promise.all([new Response(proc.stderr).text(), proc.exited]);
  if (code !== 0) throw new Error(`${script} exited ${code}: ${err}`);
}

describe('generated artifacts', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'server-gen-'));
  afterAll(() => rmSync(dir, { recursive: true, force: true }));
  const schema = join(dir, 'server.schema.json');
  const swift = join(dir, 'Generated.swift');
  await run('scripts/gen-schema.ts', schema);
  await run('scripts/gen-swift.ts', schema, swift);
  const stale = 'is out of date with src/protocol: run `mise run gen` and commit the result';

  test('schema/server.schema.json matches src/protocol', () => {
    const committed = readFileSync(join(root, 'schema/server.schema.json'), 'utf8');
    expect(readFileSync(schema, 'utf8') === committed, `schema/server.schema.json ${stale}`).toBe(true);
  });

  test('SundownKit/Sources/ServerProtocol/Generated.swift matches the schema', () => {
    const committed = readFileSync(join(root, '../SundownKit/Sources/ServerProtocol/Generated.swift'), 'utf8');
    expect(readFileSync(swift, 'utf8') === committed, `SundownKit/Sources/ServerProtocol/Generated.swift ${stale}`).toBe(true);
  });
});
