#!/usr/bin/env node
// Test-only credential broker for the Phase 1 real-acceptance harness (T25).
//
// The real opencode-go key lives in ~/.dsh/.credentials.yaml (or the
// OPENCODE_GO_API_KEY env var). E2E drivers must not read that file directly:
// they ask this broker over loopback, once, with a per-process bearer token.
// The key never touches stdout, stderr, request logs, argv or the repo.
//
// Contract (docs/specs/phase1/test-plan.md §1.1, mocks.md §1):
//   * binds 127.0.0.1 on an ephemeral port, prints exactly one line
//     `BROKER {"port":N,"token":"<32 random bytes hex>"}`;
//   * GET /key  Authorization: Bearer <token> -> 200 {"key":"..."} exactly once,
//     repeats -> 410 Gone, missing/wrong token -> 401;
//   * key source: OPENCODE_GO_API_KEY env, else --credentials <yaml>
//     (default ~/.dsh/.credentials.yaml), reading `refs.OPENCODE_GO_API_KEY`;
//   * missing key / unreadable credentials -> exit 2 (never a skip, never 0);
//   * no dependencies beyond Node's standard library.
//
// Usage:
//   node credential_broker.mjs [--credentials <path>]
//   node credential_broker.mjs --self-test
//
// The broker prints the bearer token (not the key). The token guards one
// key fetch by the child process; it is useless once the run ends.

import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import fs from 'node:fs';
import { randomBytes, timingSafeEqual } from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';
import { parseArgs } from 'node:util';
import { fileURLToPath } from 'node:url';

const SELF = fileURLToPath(import.meta.url);
const KEY_REF = 'OPENCODE_GO_API_KEY';
const TAG = 'credential_broker:';

class CredentialError extends Error {}

// --------------------------------------------------------------------------- YAML

/**
 * Minimal reader for the one field we need: `refs.OPENCODE_GO_API_KEY`.
 * Handles the credentials file's block-map shape, quoted scalars and inline
 * comments; deliberately not a general YAML parser (no dependencies).
 */
export function parseCredentialsYaml(text) {
  const lines = text.split(/\r?\n/);
  let refsIndent = -1;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (line.trim() === '' || line.trimStart().startsWith('#')) continue;
    const indent = line.length - line.trimStart().length;
    if (refsIndent < 0) {
      if (indent === 0 && /^refs\s*:\s*(#.*)?$/.test(line.trim())) refsIndent = 0;
      continue;
    }
    // A new top-level key ends the refs block.
    if (indent === 0) break;
    const m = /^\s+OPENCODE_GO_API_KEY\s*:\s*(.*)$/.exec(line);
    if (!m) continue;
    const value = decodeScalar(m[1]);
    if (value !== '') return value;
  }
  return null;
}

function decodeScalar(raw) {
  let value = raw.trim();
  if (value.startsWith('"')) {
    let out = '';
    for (let i = 1; i < value.length; i++) {
      const ch = value[i];
      if (ch === '\\' && i + 1 < value.length) {
        const next = value[++i];
        out += next === 'n' ? '\n' : next === 't' ? '\t' : next;
      } else if (ch === '"') {
        return out;
      } else {
        out += ch;
      }
    }
    return out;
  }
  if (value.startsWith("'")) {
    let out = '';
    for (let i = 1; i < value.length; i++) {
      if (value[i] === "'" && value[i + 1] === "'") {
        out += "'";
        i++;
      } else if (value[i] === "'") {
        return out;
      } else {
        out += value[i];
      }
    }
    return out;
  }
  // Plain scalar: an unquoted ` #` starts a comment.
  const comment = value.search(/\s#/);
  if (comment >= 0) value = value.slice(0, comment);
  return value.trim();
}

function credentialsPath(arg) {
  return arg ?? path.join(os.homedir(), '.dsh', '.credentials.yaml');
}

/** Resolves the key from env or the credentials file. Never logs the value. */
export function resolveKey(env = process.env, credentialsFile = credentialsPath()) {
  const fromEnv = (env[KEY_REF] ?? '').trim();
  if (fromEnv !== '') return fromEnv;
  let text;
  try {
    text = fs.readFileSync(credentialsFile, 'utf8');
  } catch (e) {
    throw new CredentialError(
      `no ${KEY_REF} in the environment and the credentials file is unreadable: ${credentialsFile} (${e.code ?? 'error'})`,
    );
  }
  const key = parseCredentialsYaml(text);
  if (key == null) {
    throw new CredentialError(`the credentials file has no refs.${KEY_REF}: ${credentialsFile}`);
  }
  return key;
}

// --------------------------------------------------------------------------- server

function json(res, status, body) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(payload),
    'cache-control': 'no-store',
  });
  res.end(payload);
}

function authorized(header, token) {
  const m = typeof header === 'string' ? /^Bearer\s+(\S+)\s*$/i.exec(header) : null;
  if (!m) return false;
  const got = Buffer.from(m[1]);
  const want = Buffer.from(token);
  return got.length === want.length && timingSafeEqual(got, want);
}

export function startBroker(key) {
  const token = randomBytes(32).toString('hex');
  let served = false;
  const server = http.createServer((req, res) => {
    try {
      if (req.method !== 'GET') {
        json(res, 405, { error: 'method_not_allowed' });
        return;
      }
      const url = new URL(req.url ?? '/', 'http://127.0.0.1');
      if (url.pathname !== '/key') {
        json(res, 404, { error: 'not_found' });
        return;
      }
      if (!authorized(req.headers.authorization, token)) {
        res.setHeader('www-authenticate', 'Bearer');
        json(res, 401, { error: 'unauthorized' });
        return;
      }
      if (served) {
        json(res, 410, { error: 'gone', detail: 'the key is handed out once per broker process' });
        return;
      }
      served = true;
      json(res, 200, { key });
    } catch {
      if (!res.headersSent) json(res, 500, { error: 'internal' });
      else res.destroy();
    }
  });
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      server.off('error', reject);
      const { port } = server.address();
      resolve({ server, port, token, key });
    });
  });
}

function announce(port, token) {
  process.stdout.write(`BROKER ${JSON.stringify({ port, token })}\n`);
}

async function main(argv) {
  const { values } = parseArgs({
    args: argv,
    options: {
      credentials: { type: 'string' },
      'self-test': { type: 'boolean', default: false },
    },
    allowPositionals: false,
  });
  if (values['self-test']) return selfTest();

  let key;
  try {
    key = resolveKey(process.env, credentialsPath(values.credentials));
  } catch (e) {
    process.stderr.write(`${TAG} ${e.message}\n`);
    process.stderr.write(`${TAG} set ${KEY_REF} or pass --credentials <path>; refusing to run without a key\n`);
    return 2;
  }

  let broker;
  try {
    broker = await startBroker(key);
  } catch (e) {
    process.stderr.write(`${TAG} cannot listen on 127.0.0.1: ${e.message}\n`);
    return 1;
  }
  const shutdown = () => {
    broker.server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 1_000).unref();
  };
  process.once('SIGTERM', shutdown);
  process.once('SIGINT', shutdown);
  announce(broker.port, broker.token);
  return new Promise(() => {});
}

// --------------------------------------------------------------------------- self-test

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function lanIPv4() {
  for (const rows of Object.values(os.networkInterfaces())) {
    for (const row of rows ?? []) {
      if (row.family === 'IPv4' && !row.internal) return row.address;
    }
  }
  return null;
}

function canConnect(host, port, timeoutMs = 800) {
  return new Promise((resolve) => {
    const socket = net.connect({ host, port });
    const done = (result) => {
      socket.destroy();
      resolve(result);
    };
    socket.setTimeout(timeoutMs, () => done(false));
    socket.once('connect', () => done(true));
    socket.once('error', () => done(false));
  });
}

function get(port, token) {
  return new Promise((resolve, reject) => {
    const headers = token == null ? {} : { authorization: `Bearer ${token}` };
    const req = http.get({ host: '127.0.0.1', port, path: '/key', headers, timeout: 3_000 }, (res) => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (d) => (body += d));
      res.on('end', () => resolve({ status: res.statusCode, body }));
    });
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', reject);
  });
}

function startChild({ args = [], env = {} } = {}) {
  const child = spawn(process.execPath, [SELF, ...args], {
    env: { ...process.env, ...env },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let out = '';
  let err = '';
  child.stdout.on('data', (d) => (out += d.toString()));
  child.stderr.on('data', (d) => (err += d.toString()));
  const ready = new Promise((resolve, reject) => {
    const timer = setInterval(() => {
      const line = out.split('\n').find((l) => l.startsWith('BROKER '));
      if (line) {
        clearInterval(timer);
        resolve(JSON.parse(line.slice('BROKER '.length)));
      } else if (child.exitCode !== null) {
        clearInterval(timer);
        reject(new Error(`child exited ${child.exitCode}: ${err || out}`));
      }
    }, 20);
    setTimeout(() => {
      clearInterval(timer);
      reject(new Error(`child never announced a port: ${err || out}`));
    }, 10_000).unref();
  });
  const exited = () =>
    new Promise((resolve) => (child.exitCode !== null ? resolve(child.exitCode) : child.once('exit', resolve)));
  return { child, ready, exited, get stdout() { return out; }, get stderr() { return err; } };
}

function spawnBrokerSync(args, env) {
  const base = { ...process.env };
  delete base[KEY_REF];
  return spawnSync(process.execPath, [SELF, ...args], {
    env: { ...base, ...env },
    encoding: 'utf8',
    timeout: 20_000,
  });
}

async function selfTest() {
  const fakeKey = 'sk-t25-selftest-fake-0000000000000000';
  let checks = 0;
  let failures = 0;
  const ok = (name, cond, detail = '') => {
    checks++;
    if (cond) {
      process.stdout.write(`PASS self-test: ${name}\n`);
    } else {
      failures++;
      process.stderr.write(`FAIL self-test: ${name}${detail ? ` — ${detail}` : ''}\n`);
    }
  };
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'credential-broker-selftest-'));
  try {
    // 1. Live contract against a child broker with a fake key.
    const child = startChild({ env: { [KEY_REF]: fakeKey } });
    let broker;
    try {
      broker = await child.ready;
    } catch (e) {
      ok('broker starts and announces a port', false, e.message);
      broker = null;
    }
    if (broker) {
      ok('broker starts and announces a port', Number.isInteger(broker.port) && broker.port > 0);
      ok('broker announces a 32-byte hex token', /^[0-9a-f]{64}$/.test(broker.token ?? ''));
      ok('broker stdout is exactly one BROKER line', child.stdout.trim().split('\n').length === 1);

      const none = await get(broker.port, null);
      ok('missing token -> 401', none.status === 401, `got ${none.status}`);
      const wrong = await get(broker.port, 'b'.repeat(64));
      ok('wrong token -> 401', wrong.status === 401, `got ${wrong.status}`);
      const first = await get(broker.port, broker.token);
      ok('valid token -> 200 with the key', first.status === 200 && JSON.parse(first.body).key === fakeKey);
      const repeat = await get(broker.port, broker.token);
      ok('repeat fetch -> 410 Gone', repeat.status === 410, `got ${repeat.status}`);
      const repeatWrong = await get(broker.port, 'c'.repeat(64));
      ok('wrong token after serve -> 401 (not 410)', repeatWrong.status === 401, `got ${repeatWrong.status}`);

      // 2. Loopback only: no listener on a LAN address, and lsof (when present)
      //    shows the listening socket bound to 127.0.0.1.
      const lan = lanIPv4();
      if (lan != null) {
        ok(`broker does not accept connections on LAN address ${lan}`, (await canConnect(lan, broker.port)) === false);
      } else {
        ok('broker does not listen on ::1', (await canConnect('::1', broker.port)) === false);
      }
      const lsof = spawnSync('lsof', ['-nP', `-iTCP:${broker.port}`, '-sTCP:LISTEN'], { encoding: 'utf8' });
      if (lsof.status === 0 && lsof.stdout) {
        ok(
          'lsof shows the listener bound to 127.0.0.1',
          lsof.stdout.includes(`127.0.0.1:${broker.port}`) && !/0\.0\.0\.0:|\[::\]:|\*:\d/.test(lsof.stdout),
          lsof.stdout.trim(),
        );
      } else {
        ok('lsof listener evidence collected (or unavailable)', lan != null, 'no LAN address and no lsof output');
      }

      ok('broker stdout/stderr never contain the key (after serving)', !child.stdout.includes(fakeKey) && !child.stderr.includes(fakeKey));

      child.child.kill('SIGTERM');
      const code = await child.exited();
      ok('broker exits 0 on SIGTERM', code === 0, `exit ${code}`);

      // 3. YAML credential source (fake key, temp file).
      const yaml = path.join(tmp, '.credentials.yaml');
      fs.writeFileSync(
        yaml,
        ['version: 1', 'records:', '  client-connection/browser-session:', '    kind: secret', 'refs:', `  ${KEY_REF}: "${fakeKey}"`, ''].join('\n'),
        { mode: 0o600 },
      );
      const fromFile = startChild({ args: ['--credentials', yaml], env: { [KEY_REF]: '' } });
      try {
        const b = await fromFile.ready;
        const res = await get(b.port, b.token);
        ok('reads refs.OPENCODE_GO_API_KEY from YAML', res.status === 200 && JSON.parse(res.body).key === fakeKey);
        ok('YAML path never prints the key', !fromFile.stdout.includes(fakeKey) && !fromFile.stderr.includes(fakeKey));
      } catch (e) {
        ok('reads refs.OPENCODE_GO_API_KEY from YAML', false, e.message);
      } finally {
        fromFile.child.kill('SIGTERM');
        await fromFile.exited().catch(() => {});
      }

      // 4. Missing key / unreadable / malformed -> exit 2, never a skip.
      const absent = spawnBrokerSync(['--credentials', path.join(tmp, 'absent.yaml')], {});
      ok('missing credentials file -> exit 2', absent.status === 2, `exit ${absent.status}`);
      ok('missing-key failure names the reason on stderr', /credential|OPENCODE_GO_API_KEY/i.test(absent.stderr) && !absent.stdout.includes('BROKER'));

      const empty = path.join(tmp, 'empty.yaml');
      fs.writeFileSync(empty, 'version: 1\nrefs: {}\nrecords:\n');
      const noRef = spawnBrokerSync(['--credentials', empty], {});
      ok('credentials file without refs.OPENCODE_GO_API_KEY -> exit 2', noRef.status === 2, `exit ${noRef.status}`);

      if (typeof process.getuid === 'function' && process.getuid() !== 0) {
        const unreadable = path.join(tmp, 'unreadable.yaml');
        fs.writeFileSync(unreadable, `refs:\n  ${KEY_REF}: ${fakeKey}\n`);
        fs.chmodSync(unreadable, 0o000);
        const r = spawnBrokerSync(['--credentials', unreadable], {});
        ok('unreadable credentials file -> exit 2', r.status === 2, `exit ${r.status}`);
        fs.chmodSync(unreadable, 0o600);
      }

      // Always pass an explicit nonexistent file: the default path is the real
      // ~/.dsh/.credentials.yaml, and the self-test must never read it.
      const envKey = spawnBrokerSync(['--credentials', path.join(tmp, 'absent-default.yaml')], { [KEY_REF]: '' });
      ok('empty env key + absent credentials -> exit 2', envKey.status === 2, `exit ${envKey.status}`);
    } else {
      child.child.kill('SIGKILL');
    }
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }

  if (failures > 0) {
    process.stderr.write(`self-test: FAIL (${failures}/${checks} checks)\n`);
    return 1;
  }
  process.stdout.write(`self-test: PASS (${checks} checks)\n`);
  return 0;
}

// --------------------------------------------------------------------------- entry

const isMain = process.argv[1] != null && path.resolve(process.argv[1]) === path.resolve(SELF);
if (isMain) {
  main(process.argv.slice(2))
    .then((code) => process.exit(code))
    .catch((e) => {
      process.stderr.write(`${TAG} ${e?.stack ?? e}\n`);
      process.exit(1);
    });
}
