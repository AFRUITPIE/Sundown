import { spawn } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, openSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { createConnection, createServer, type Socket } from 'node:net';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { resolveClaude } from '../claude.ts';
import { PROTOCOL_VERSION } from '../protocol/index.ts';
import { Connection } from '../rpc/connection.ts';
import { ClientSession, LEGACY_UPGRADE_CLIENT, UPGRADE_CLIENT } from '../server/session.ts';
import { SERVER_VERSION } from '../threads/LiveThread.ts';
import { TaskStore } from '../threads/taskStore.ts';
import { ThreadManager } from '../threads/ThreadManager.ts';

/** The daemon's socket, pid, log and task states: `SUNDOWN_SERVER_HOME`, else `~/.sundown`. */
export const SERVER_HOME = process.env.SUNDOWN_SERVER_HOME ?? join(homedir(), '.sundown');
export const SOCKET_PATH = join(SERVER_HOME, 'server.sock');
const PID_PATH = join(SERVER_HOME, 'daemon.pid');
const LOG_PATH = join(SERVER_HOME, 'daemon.log');
/** Each chat's tasks as the daemon saw them (`TaskStore`). */
export const TASKS_DIR = join(SERVER_HOME, 'tasks');

/**
 * Where releases before the rename (as Tether) kept all that: `TETHER_HOME`, else `~/.tether`, with
 * the socket `tether.sock`. `connect` replaces a daemon still listening there and moves the home
 * over (`takeOverLegacyHome`). Only for the default home: one given explicitly (tests, development)
 * has no earlier release behind it.
 */
const LEGACY_HOME = process.env.SUNDOWN_SERVER_HOME ? undefined : (process.env.TETHER_HOME ?? join(homedir(), '.tether'));
const LEGACY_SOCKET = LEGACY_HOME && join(LEGACY_HOME, 'tether.sock');

type DaemonMeta = { pid: number; version: string; startedAt: number };

/**
 * Long-lived per-host server. Owns every live Claude query so turns keep
 * running while clients disconnect; clients attach via `sundown-server connect`.
 */
export async function runDaemon() {
  mkdirSync(SERVER_HOME, { recursive: true, mode: 0o700 });
  const log = (m: string) => process.stderr.write(`[sundown-server daemon ${new Date().toISOString()}] ${m}\n`);
  const claude = await resolveClaude();
  const mgr = new ThreadManager(claude, log, { taskStore: new TaskStore(TASKS_DIR) });
  const clients = new Set<ClientSession>();

  if (await isSocketLive()) {
    log('another daemon is already listening; exiting');
    process.exit(0);
  }
  rmSync(SOCKET_PATH, { force: true });

  const server = createServer((sock: Socket) => {
    const conn = new Connection(sock, sock, 'socket');
    const session = new ClientSession(conn, mgr, 'daemon', log);
    clients.add(session);
    sock.on('close', () => clients.delete(session));
    session.start();
  });
  server.listen(SOCKET_PATH, () => {
    chmodSync(SOCKET_PATH, 0o600);
    const meta: DaemonMeta = { pid: process.pid, version: SERVER_VERSION, startedAt: Date.now() };
    writeFileSync(PID_PATH, JSON.stringify(meta));
    log(`daemon ${SERVER_VERSION} listening on ${SOCKET_PATH}; claude ${claude.version} at ${claude.path}`);
  });

  const shutdown = (why: string) => {
    log(`shutting down: ${why}`);
    server.close();
    mgr.shutdown();
    rmSync(SOCKET_PATH, { force: true });
    try {
      const meta = JSON.parse(readFileSync(PID_PATH, 'utf8')) as DaemonMeta;
      if (meta.pid === process.pid) rmSync(PID_PATH, { force: true });
    } catch {}
    process.exit(0);
  };
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGHUP', () => {}); // survive the SSH session that spawned us
  mgr.onDrainRequest = () => shutdown('upgrade');
}

export function readDaemonMeta(): DaemonMeta | undefined {
  try {
    return JSON.parse(readFileSync(PID_PATH, 'utf8'));
  } catch {
    return undefined;
  }
}

function isSocketLive(path = SOCKET_PATH): Promise<boolean> {
  return new Promise((resolve) => {
    if (!existsSync(path)) return resolve(false);
    const s = createConnection(path);
    s.once('connect', () => {
      s.destroy();
      resolve(true);
    });
    s.once('error', () => resolve(false));
  });
}

/** Start a detached daemon from the current executable. */
export function spawnDaemon() {
  mkdirSync(SERVER_HOME, { recursive: true, mode: 0o700 });
  const out = openSync(LOG_PATH, 'a');
  const [exe, ...pre] = selfCommand() as [string, ...string[]];
  const child = spawn(exe, [...pre, 'daemon'], { detached: true, stdio: ['ignore', out, out], env: process.env });
  child.unref();
}

/** argv prefix that re-invokes this program: the compiled binary, or `bun src/cli.ts` in dev. */
export function selfCommand(): string[] {
  const script = process.argv[1];
  const isCompiled = !script || script.startsWith('/$bunfs/') || script === process.execPath;
  return isCompiled ? [process.execPath] : [process.execPath, script!];
}

function openSocket(path: string): Promise<Socket> {
  return new Promise<Socket>((resolve, reject) => {
    const s = createConnection(path);
    s.once('connect', () => resolve(s));
    s.once('error', reject);
  });
}

async function connectSocket(timeoutMs: number): Promise<Socket> {
  const deadline = Date.now() + timeoutMs;
  let spawned = false;
  for (;;) {
    try {
      return await openSocket(SOCKET_PATH);
    } catch (e) {
      if (!spawned) {
        spawnDaemon();
        spawned = true;
      }
      if (Date.now() > deadline) throw e;
      await sleep(100);
    }
  }
}

/**
 * stdio ⇄ daemon socket bridge. What the app runs (locally or over SSH).
 * Upgrades: if the running daemon is an older version and has nothing running,
 * it is asked to exit and a new one is spawned; otherwise the old one is used.
 */
export async function runConnect() {
  // A daemon of a release before the rename, still busy, keeps serving: its chats stay reachable,
  // and it exits by itself once idle (it was asked to), so a later `connect` moves on.
  if (LEGACY_SOCKET && !(await takeOverLegacyHome(LEGACY_SOCKET))) {
    // Gone in the moment since (it had just gone idle): the home moves on the next `connect`.
    const old = await openSocket(LEGACY_SOCKET).catch(() => undefined);
    if (old) return bridge(old);
  }
  const meta = readDaemonMeta();
  if (meta && meta.version !== SERVER_VERSION) await tryUpgrade(SOCKET_PATH, UPGRADE_CLIENT, meta.version);
  bridge(await connectSocket(15_000));
}

function bridge(sock: Socket) {
  process.stdin.pipe(sock);
  sock.pipe(process.stdout);
  sock.on('close', () => process.exit(0));
  process.stdin.on('end', () => sock.end());
}

/**
 * Asks the daemon on `socket` to make way, as `client` (the name that daemon's release looks for).
 * True once it has gone; false when it's busy, and will exit by itself once idle.
 */
async function tryUpgrade(socket: string, client: string, version: string): Promise<boolean> {
  try {
    const sock = await openSocket(socket);
    const conn = new Connection(sock, sock, 'upgrade');
    conn.start({ onRequest: async () => ({}), onNotification: () => {}, onClose: () => {} });
    await conn.request('initialize', { clientInfo: { name: client, version: SERVER_VERSION }, protocolVersion: PROTOCOL_VERSION }, 'u1');
    const r = (await conn.request('host/requestShutdown', { reason: `upgrade to ${SERVER_VERSION}` }, 'u2')) as {
      accepted: boolean;
    };
    conn.close();
    if (r.accepted) {
      process.stderr.write(`[sundown-server] replacing daemon ${version} with ${SERVER_VERSION}\n`);
      for (let i = 0; i < 50 && existsSync(socket); i++) await sleep(100);
      return true;
    }
    process.stderr.write(`[sundown-server] daemon ${version} is busy; will upgrade when idle\n`);
    return false;
  } catch {
    return !(await isSocketLive(socket));
  }
}

/**
 * Moves an earlier release's home (`LEGACY_HOME`) to this one's, replacing its daemon first. False
 * while that daemon is busy, which leaves everything where it is.
 *
 * With no home here yet, the old one is renamed: task states and log carry over. With both (an
 * older release's daemon started again since), its task states this home lacks are moved over and
 * its socket and pid file removed, so it's only looked at again for the log left in it.
 */
async function takeOverLegacyHome(socket: string): Promise<boolean> {
  const legacy = LEGACY_HOME!;
  if (!existsSync(legacy)) return true;
  if (await isSocketLive(socket)) {
    let version = 'from before the rename';
    try {
      version = (JSON.parse(readFileSync(join(legacy, 'daemon.pid'), 'utf8')) as DaemonMeta).version;
    } catch {}
    if (!(await tryUpgrade(socket, LEGACY_UPGRADE_CLIENT, version))) return false;
  }
  try {
    if (!existsSync(SERVER_HOME)) {
      renameSync(legacy, SERVER_HOME);
    } else {
      const from = join(legacy, 'tasks');
      if (existsSync(from)) {
        mkdirSync(TASKS_DIR, { recursive: true, mode: 0o700 });
        for (const f of readdirSync(from)) if (!existsSync(join(TASKS_DIR, f))) renameSync(join(from, f), join(TASKS_DIR, f));
      }
      rmSync(join(legacy, 'daemon.pid'), { force: true });
    }
    // The old daemon's socket and pid file, wherever they ended up: neither is this daemon's.
    rmSync(join(SERVER_HOME, 'tether.sock'), { force: true });
    rmSync(join(legacy, 'tether.sock'), { force: true });
    if (!existsSync(SOCKET_PATH)) rmSync(PID_PATH, { force: true });
  } catch (e) {
    // Another `connect` moving it at the same moment, most likely: this one carries on regardless.
    process.stderr.write(`[sundown-server] couldn't move ${legacy} to ${SERVER_HOME}: ${(e as Error).message}\n`);
  }
  return true;
}
