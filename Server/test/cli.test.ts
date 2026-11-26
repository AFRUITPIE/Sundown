import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import { spawn, type ChildProcess } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { createConnection, createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { PROTOCOL_VERSION } from '../src/protocol/index.ts';
import { Connection } from '../src/rpc/connection.ts';
import { SERVER_VERSION } from '../src/threads/LiveThread.ts';
import { versionInfo } from '../src/version.ts';

// The CLI as the app runs it, in its own processes. Every one gets a fresh HOME and SUNDOWN_SERVER_HOME,
// never the user's ~/.sundown or ~/.tether, and a stand-in `claude` that only reports its version.
// SUNDOWN_SERVER_TEST_BINARY runs them against a compiled binary instead of the source, as CI does.
const binary = process.env.SUNDOWN_SERVER_TEST_BINARY;
const command = binary ? [resolve(binary)] : [process.execPath, join(import.meta.dir, '..', 'src', 'cli.ts')];
const SLOW = { timeout: 30_000 };
const clientInfo = { name: 'test', version: '0' };

/** Daemons these tests may have started, stopped at the end whatever happened, and their homes. */
const pids = new Set<number>();
const homes: string[] = [];
afterAll(async () => {
  for (const pid of pids) if (alive(pid)) process.kill(pid, 'SIGTERM');
  await until('the daemons exit', () => ![...pids].some(alive)).catch(() => {});
  for (const dir of homes) rmSync(dir, { recursive: true, force: true });
});

function alive(pid: number) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function until(what: string, cond: () => boolean, timeoutMs = 15_000) {
  const deadline = Date.now() + timeoutMs;
  while (!cond()) {
    if (Date.now() > deadline) throw new Error(`timed out waiting until ${what}`);
    await Bun.sleep(25);
  }
}

/** A fresh home for the server, and the environment that points the CLI at it. */
function sandbox() {
  // Short, as a socket's path is limited to about 100 bytes.
  const dir = mkdtempSync(join(tmpdir(), 'td-'));
  homes.push(dir);
  const claude = join(dir, 'claude');
  writeFileSync(claude, '#!/bin/sh\necho "9.9.9 (Claude Code)"\n');
  chmodSync(claude, 0o755);
  const inherited = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('SUNDOWN_SERVER_') && !k.startsWith('TETHER_')));
  const env = { ...inherited, HOME: dir, SUNDOWN_SERVER_HOME: join(dir, 'home'), SUNDOWN_SERVER_CLAUDE_PATH: claude } as Record<string, string>;
  const home = env.SUNDOWN_SERVER_HOME!;
  return {
    env,
    claude,
    socket: join(home, 'server.sock'),
    pidFile: join(home, 'daemon.pid'),
    meta: () => JSON.parse(readFileSync(join(home, 'daemon.pid'), 'utf8')) as { pid: number; version: string },
  };
}

type Sandbox = ReturnType<typeof sandbox>;

/** `sundown-server <args>` in `box`, with what it writes and how it exits. */
function server(box: Sandbox, ...args: string[]) {
  const child = spawn(command[0]!, [...command.slice(1), ...args], { env: box.env, stdio: ['pipe', 'pipe', 'pipe'] });
  let stdout = '';
  let stderr = '';
  child.stdout!.on('data', (c) => (stdout += c));
  child.stderr!.on('data', (c) => (stderr += c));
  const exited = new Promise<number | null>((r) => child.on('exit', (code) => r(code)));
  return { child, exited, stdout: () => stdout, stderr: () => stderr };
}

function client(input: NodeJS.ReadableStream, output: NodeJS.WritableStream) {
  const c = new Connection(input as any, output as any, 'client');
  c.start({ onRequest: async () => ({}), onNotification: () => {}, onClose: () => {} });
  return c;
}

/** A client on a child's stdio, as the app talks to `sundown-server connect`. */
const stdioClient = (child: ChildProcess) => client(child.stdout!, child.stdin!);

function socketClient(path: string) {
  return new Promise<Connection>((resolve, reject) => {
    const s = createConnection(path);
    s.once('connect', () => resolve(client(s, s)));
    s.once('error', reject);
  });
}

async function initialize(c: Connection) {
  return c.request<any>('initialize', { clientInfo, protocolVersion: PROTOCOL_VERSION }, 'init');
}

/** `sundown-server daemon` in `box`, once it's listening. */
async function startDaemon(box: Sandbox) {
  const d = server(box, 'daemon');
  pids.add(d.child.pid!);
  await until('the daemon listens', () => existsSync(box.socket) && existsSync(box.pidFile));
  return d;
}

describe('sundown-server version', () => {
  test('prints the version, or with --json what a client probes a host for', async () => {
    const box = sandbox();
    const plain = server(box, 'version');
    expect(await plain.exited).toBe(0);
    expect(plain.stdout()).toBe(`${SERVER_VERSION}\n`);
    const json = server(box, 'version', '--json');
    expect(await json.exited).toBe(0);
    expect(JSON.parse(json.stdout())).toEqual(versionInfo());
  }, SLOW);
});

describe('sundown-server serve --stdio', () => {
  test('is the only serve mode', async () => {
    const run = server(sandbox(), 'serve');
    expect(await run.exited).toBe(2);
    expect(run.stdout()).toBe('');
    expect(run.stderr()).toContain('--stdio');
  }, SLOW);

  test('serves one client on stdio, keeps stdout to protocol lines, and exits when stdin closes', async () => {
    const box = sandbox();
    const run = server(box, 'serve', '--stdio');
    const c = stdioClient(run.child);
    const init = await initialize(c);
    expect(init.host.mode).toBe('stdio');
    expect(init.host.pid).toBe(run.child.pid);
    expect(init.claude).toEqual({ path: box.claude, version: '9.9.9' });
    expect(await c.request<any>('thread/list', {}, 'list')).toEqual({ threads: [] });
    run.child.stdin!.end();
    expect(await run.exited).toBe(0);
    const lines = run.stdout().trim().split('\n').map((l) => JSON.parse(l));
    expect(lines.map((l) => l.id)).toEqual(['init', 'list']);
    expect(run.stderr()).toContain('serving on stdio');
  }, SLOW);

  test("without SUNDOWN_SERVER_HOME neither reads nor writes the home's ~/.sundown", async () => {
    const box = sandbox();
    const home = box.env.HOME!;
    delete box.env.SUNDOWN_SERVER_HOME;
    box.env.CLAUDE_CONFIG_DIR = join(home, '.claude');
    // A chat with a background agent, and what a daemon kept of it in the real ~/.sundown.
    const sid = '6a1c4e2b-0000-4000-8000-000000000002';
    const project = join(home, '.claude', 'projects', '-home-me');
    mkdirSync(project, { recursive: true });
    const records = [
      { type: 'user', uuid: 'u1', parentUuid: null, message: { role: 'user', content: 'go' } },
      { type: 'assistant', uuid: 'a1', parentUuid: 'u1', message: { id: 'msg1', role: 'assistant', model: 'claude-test', content: [{ type: 'tool_use', id: 'agent1', name: 'Agent', input: { description: 'Look', run_in_background: true } }], stop_reason: 'tool_use' } },
      { type: 'user', uuid: 'r1', parentUuid: 'a1', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'agent1', content: 'Async agent launched successfully.\nagentId: t1' }] } },
    ].map((r, i) => ({ ...r, sessionId: sid, cwd: '/home/me', isSidechain: false, userType: 'external', timestamp: new Date(Date.parse('2026-10-06T10:00:00Z') + i * 1000).toISOString() }));
    writeFileSync(join(project, `${sid}.jsonl`), records.map((r) => JSON.stringify(r)).join('\n') + '\n');
    const tasks = join(home, '.sundown', 'tasks');
    mkdirSync(tasks, { recursive: true });
    const kept = JSON.stringify({ tasks: [{ id: 'agent1', toolUseId: 'agent1', taskId: 't1', kind: 'agent', title: 'Look', status: 'running', backgrounded: true, usage: { totalTokens: 500 } }] });
    writeFileSync(join(tasks, `${sid}.json`), kept);

    const run = server(box, 'serve', '--stdio');
    const c = stdioClient(run.child);
    await initialize(c);
    const read = await c.request<any>('thread/read', { threadId: sid, cwd: '/home/me' }, 'read');
    expect(read.tasks.map((t: any) => t.id)).toEqual(['agent1']);
    // What only the kept file says is not merged in.
    expect(read.tasks[0].usage).toBeUndefined();
    run.child.stdin!.end();
    expect(await run.exited).toBe(0);
    expect(readdirSync(join(home, '.sundown'))).toEqual(['tasks']);
    expect(readdirSync(tasks)).toEqual([`${sid}.json`]);
    expect(readFileSync(join(tasks, `${sid}.json`), 'utf8')).toBe(kept);
  }, SLOW);
});

describe('sundown-server daemon', () => {
  const box = sandbox();
  let daemon: ReturnType<typeof server>;
  beforeAll(async () => {
    daemon = await startDaemon(box);
  }, SLOW);

  test('listens on a socket only its user can open', () => {
    expect(statSync(box.socket).mode & 0o777).toBe(0o600);
  });

  test('is reported by `sundown-server status`', async () => {
    const status = server(box, 'status');
    expect(await status.exited).toBe(0);
    expect(JSON.parse(status.stdout())).toMatchObject({ pid: daemon.child.pid, version: SERVER_VERSION, socket: box.socket });
  }, SLOW);

  test('serves clients through `sundown-server connect`, and outlives them', async () => {
    const connect = server(box, 'connect');
    const init = await initialize(stdioClient(connect.child));
    expect(init.host.mode).toBe('daemon');
    expect(init.host.pid).toBe(daemon.child.pid);
    expect(init.claude).toEqual({ path: box.claude, version: '9.9.9' });
    connect.child.stdin!.end();
    expect(await connect.exited).toBe(0);
    expect((await initialize(await socketClient(box.socket))).host.pid).toBe(daemon.child.pid);
  }, SLOW);

  test('a second one leaves the first serving', async () => {
    const second = server(box, 'daemon');
    expect(await second.exited).toBe(0);
    expect(second.stderr()).toContain('already listening');
    expect(box.meta().pid).toBe(daemon.child.pid!);
    expect((await initialize(await socketClient(box.socket))).host.pid).toBe(daemon.child.pid);
  }, SLOW);

  test('with nothing running, agrees to shut down, and removes its socket and pid file', async () => {
    const c = await socketClient(box.socket);
    await initialize(c);
    expect(await c.request<any>('host/requestShutdown', { reason: 'test' }, 's')).toEqual({ accepted: true });
    expect(await daemon.exited).toBe(0);
    expect(existsSync(box.socket)).toBe(false);
    expect(existsSync(box.pidFile)).toBe(false);
  }, SLOW);
});

describe('sundown-server connect', () => {
  test('starts a daemon when none is running', async () => {
    const box = sandbox();
    const connect = server(box, 'connect');
    const c = stdioClient(connect.child);
    const init = await initialize(c);
    const pid: number = init.host.pid;
    pids.add(pid);
    expect(init.host.mode).toBe('daemon');
    expect(pid).not.toBe(connect.child.pid);
    expect(box.meta()).toMatchObject({ pid, version: SERVER_VERSION });
    // Through the bridge: once the daemon goes, so does `connect`.
    expect(await c.request<any>('host/requestShutdown', {}, 's')).toEqual({ accepted: true });
    expect(await connect.exited).toBe(0);
    await until('the daemon exits', () => !alive(pid));
  }, SLOW);

  test('replaces an idle daemon of another version', async () => {
    const box = sandbox();
    const old = await startDaemon(box);
    // What an earlier release's daemon would have recorded.
    writeFileSync(box.pidFile, JSON.stringify({ ...box.meta(), version: '0.0.1' }));
    const connect = server(box, 'connect');
    const c = stdioClient(connect.child);
    const init = await initialize(c);
    pids.add(init.host.pid);
    expect(await old.exited).toBe(0);
    expect(init.host.pid).not.toBe(old.child.pid);
    expect(box.meta()).toMatchObject({ pid: init.host.pid, version: SERVER_VERSION });
    expect(connect.stderr()).toContain(`replacing daemon 0.0.1 with ${SERVER_VERSION}`);
    await c.request<any>('host/requestShutdown', {}, 's');
    expect(await connect.exited).toBe(0);
    await until('the daemon exits', () => !alive(init.host.pid));
  }, SLOW);
});

/**
 * A daemon of a release before the rename, as `connect` meets one: on `~/.tether/tether.sock`, with
 * its pid file and a chat's kept tasks beside it. It answers its own upgrade client's handshake,
 * then makes way, or not while `busy`; a client bridged to it gets its own `serverInfo`.
 */
function legacyDaemon(home: string, busy: boolean) {
  const dir = join(home, '.tether');
  mkdirSync(join(dir, 'tasks'), { recursive: true, mode: 0o700 });
  writeFileSync(join(dir, 'daemon.pid'), JSON.stringify({ pid: 1, version: '0.6.1', startedAt: 0 }));
  writeFileSync(join(dir, 'daemon.log'), 'what the old daemon logged\n');
  writeFileSync(join(dir, 'tasks', 'chat.json'), '{"tasks":[]}');
  const socket = join(dir, 'tether.sock');
  const clients: string[] = [];
  const srv = createServer((sock) => {
    const c = new Connection(sock, sock, 'legacy');
    c.start({
      onRequest: async (method, params: any) => {
        if (method === 'initialize') {
          clients.push(params.clientInfo.name);
          return { serverInfo: { name: 'tether', version: '0.6.1' }, protocolVersion: PROTOCOL_VERSION, host: { mode: 'daemon' } };
        }
        if (method === 'host/requestShutdown') {
          if (busy) return { accepted: false };
          setTimeout(() => srv.close(), 10);
          return { accepted: true };
        }
        return {};
      },
      onNotification: () => {},
      onClose: () => {},
    });
  });
  const listening = new Promise<void>((r) => srv.listen(socket, () => r()));
  return { dir, socket, clients, listening, close: () => srv.close() };
}

describe('connect after the rename', () => {
  /** A sandbox using the default homes, ~/.sundown and ~/.tether, under its own HOME. */
  function defaultHomes() {
    const box = sandbox();
    delete box.env.SUNDOWN_SERVER_HOME;
    const home = box.env.HOME!;
    const now = join(home, '.sundown');
    return { box, home, now, socket: join(now, 'server.sock'), pidFile: join(now, 'daemon.pid') };
  }

  test("replaces an idle daemon on ~/.tether and moves its home to ~/.sundown", async () => {
    const { box, home, now, socket, pidFile } = defaultHomes();
    const old = legacyDaemon(home, false);
    await old.listening;
    const connect = server(box, 'connect');
    const c = stdioClient(connect.child);
    const init = await initialize(c);
    pids.add(init.host.pid);
    expect(init.serverInfo.name).toBe('sundown-server');
    // Asked under the name the old release looks for.
    expect(old.clients).toEqual(['tether-upgrade']);
    expect(connect.stderr()).toContain(`replacing daemon 0.6.1 with ${SERVER_VERSION}`);
    expect(existsSync(old.dir)).toBe(false);
    expect(readFileSync(join(now, 'tasks', 'chat.json'), 'utf8')).toBe('{"tasks":[]}');
    expect(readFileSync(join(now, 'daemon.log'), 'utf8')).toStartWith('what the old daemon logged\n');
    expect(existsSync(join(now, 'tether.sock'))).toBe(false);
    expect(existsSync(socket)).toBe(true);
    expect(JSON.parse(readFileSync(pidFile, 'utf8'))).toMatchObject({ pid: init.host.pid, version: SERVER_VERSION });
    await c.request<any>('host/requestShutdown', {}, 's');
    expect(await connect.exited).toBe(0);
    await until('the daemon exits', () => !alive(init.host.pid));
  }, SLOW);

  test('bridges to a busy one, leaving its home alone, so its chats stay reachable', async () => {
    const { box, home, now } = defaultHomes();
    const old = legacyDaemon(home, true);
    await old.listening;
    const connect = server(box, 'connect');
    const c = stdioClient(connect.child);
    const init = await initialize(c);
    expect(init.serverInfo.name).toBe('tether');
    expect(old.clients).toEqual(['tether-upgrade', 'test']);
    expect(connect.stderr()).toContain('daemon 0.6.1 is busy; will upgrade when idle');
    expect(existsSync(now)).toBe(false);
    expect(readdirSync(old.dir).sort()).toEqual(['daemon.log', 'daemon.pid', 'tasks', 'tether.sock']);
    connect.child.stdin!.end();
    expect(await connect.exited).toBe(0);
    old.close();
  }, SLOW);

  test("with both homes, moves the old one's tasks this one lacks", async () => {
    const { box, home, now } = defaultHomes();
    const old = join(home, '.tether');
    mkdirSync(join(old, 'tasks'), { recursive: true });
    writeFileSync(join(old, 'tasks', 'a.json'), 'old a');
    writeFileSync(join(old, 'tasks', 'b.json'), 'old b');
    writeFileSync(join(old, 'daemon.pid'), JSON.stringify({ pid: 1, version: '0.6.1', startedAt: 0 }));
    mkdirSync(join(now, 'tasks'), { recursive: true });
    writeFileSync(join(now, 'tasks', 'a.json'), 'new a');
    const connect = server(box, 'connect');
    const c = stdioClient(connect.child);
    const init = await initialize(c);
    pids.add(init.host.pid);
    expect(readFileSync(join(now, 'tasks', 'a.json'), 'utf8')).toBe('new a');
    expect(readFileSync(join(now, 'tasks', 'b.json'), 'utf8')).toBe('old b');
    expect(existsSync(join(old, 'daemon.pid'))).toBe(false);
    await c.request<any>('host/requestShutdown', {}, 's');
    expect(await connect.exited).toBe(0);
    await until('the daemon exits', () => !alive(init.host.pid));
  }, SLOW);

  test('an explicit SUNDOWN_SERVER_HOME never looks at ~/.tether', async () => {
    const box = sandbox();
    const old = legacyDaemon(box.env.HOME!, false);
    await old.listening;
    const connect = server(box, 'connect');
    const c = stdioClient(connect.child);
    const init = await initialize(c);
    pids.add(init.host.pid);
    expect(old.clients).toEqual([]);
    expect(existsSync(join(old.dir, 'tether.sock'))).toBe(true);
    await c.request<any>('host/requestShutdown', {}, 's');
    expect(await connect.exited).toBe(0);
    await until('the daemon exits', () => !alive(init.host.pid));
    old.close();
  }, SLOW);
});
