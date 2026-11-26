// Builds the npm package into npm/: one file that runs under Node 18 or later, with nothing to
// install beside it and no install scripts. Hosts run it as `npx -y tether-server@<version> connect`
// (the app pins the version), or install it with `npm install -g tether-server`.
//
// Everything is bundled, the Agent SDK included, as the compiled binaries do. The SDK's platform
// packages are left out: each is a Claude Code of its own (about 200 MB), and the server always runs
// the host's `claude`. Not minified, so what npm serves can be read.
//
// `--dev` stamps the version as `<package.json version>-dev.<time>`, as `mise run compile -- --dev`
// does, so a running daemon moves onto it.
import { $ } from 'bun';
import { chmodSync, copyFileSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';

const pkg = await Bun.file(new URL('../package.json', import.meta.url)).json();
const dev = process.argv.includes('--dev');
const version = dev ? `${pkg.version}-dev.${new Date().toISOString().replace(/\D/g, '').slice(0, 14)}` : pkg.version;
const out = 'npm';

rmSync(out, { recursive: true, force: true });
mkdirSync(out);
await $`bun build src/cli.ts --target=node --format=esm --outfile ${out}/cli.js --external '@anthropic-ai/claude-agent-sdk-*' --define SERVER_BUILD_VERSION=${JSON.stringify(version)}`.quiet();

// Node, not Bun, runs it: the source's own shebang names bun.
const js = readFileSync(`${out}/cli.js`, 'utf8').replace(/^#!.*\n/, '');
writeFileSync(`${out}/cli.js`, `#!/usr/bin/env node\n${js}`);
chmodSync(`${out}/cli.js`, 0o755);

writeFileSync(`${out}/package.json`, `${JSON.stringify({
  name: pkg.name,
  version,
  description: 'The Sundown server: runs Claude Code sessions on a host for the Sundown app, through the Claude Agent SDK.',
  license: pkg.license,
  type: 'module',
  bin: { 'sundown-server': 'cli.js' },
  files: ['cli.js', 'LICENSE'],
  engines: { node: '>=18' },
  repository: { type: 'git', url: 'git+https://github.com/AFRUITPIE/Sundown.git', directory: 'Server' },
  homepage: 'https://github.com/AFRUITPIE/Sundown/tree/main/Server#readme',
  bugs: 'https://github.com/AFRUITPIE/Sundown/issues',
  keywords: ['claude', 'claude-code', 'agent-sdk', 'sundown'],
  // Bundled at build time; nothing for npm to fetch. The SDK's version is reported by `sundown-server version --json`.
  agentSdkVersion: pkg.dependencies['@anthropic-ai/claude-agent-sdk'],
  publishConfig: { access: 'public', provenance: true },
}, null, 2)}\n`);
copyFileSync('README.md', `${out}/README.md`);
copyFileSync('LICENSE', `${out}/LICENSE`);

const size = (Bun.file(`${out}/cli.js`).size / 1e6).toFixed(1);
console.log(`${out}/cli.js (${size} MB), ${pkg.name}@${version}`);
