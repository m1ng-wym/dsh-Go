// Unit tests for the Phase 1 real-acceptance harness fixtures (T25).
//
// These spawn `test/fixtures/credential_broker.mjs` and talk to it over
// loopback. They never need the real opencode-go key: every test that expects
// a served key uses the fake key below (or a temp YAML with the same fake).
// The broker's own `--self-test` covers the spawn/401/410/missing-key paths
// end-to-end; this file pins the CLI contract that the E2E scripts rely on.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const BROKER = path.join(ROOT, 'test', 'fixtures', 'credential_broker.mjs');
const FAKE_KEY = 'sk-t25-fake-key-do-not-use-000000000000';

function startBroker({ args = [], env = {} } = {}) {
  const child = spawn(process.execPath, [BROKER, ...args], {
    cwd: ROOT,
    env: { ...process.env, ...env },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let out = '';
  let err = '';
  child.stdout.on('data', (d) => (out += d.toString()));
  child.stderr.on('data', (d) => (err += d.toString()));
  const ready = new Promise((resolve, reject) => {
    const deadline = setTimeout(() => reject(new Error(`broker did not print BROKER line\nstdout: ${out}\nstderr: ${err}`)), 15_000);
    const check = () => {
      const line = out.split('\n').find((l) => l.startsWith('BROKER '));
      if (!line) return false;
      clearTimeout(deadline);
      resolve(JSON.parse(line.slice('BROKER '.length)));
      return true;
    };
    if (check()) return;
    const timer = setInterval(() => {
      if (check() || child.exitCode !== null) {
        clearInterval(timer);
        if (child.exitCode !== null) {
          clearTimeout(deadline);
          reject(new Error(`broker exited ${child.exitCode}\nstdout: ${out}\nstderr: ${err}`));
        }
      }
    }, 25);
  });
  return {
    child,
    ready,
    get output() {
      return out;
    },
    get errors() {
      return err;
    },
    async stop() {
      if (child.exitCode === null) {
        child.kill('SIGTERM');
        await new Promise((r) => child.once('exit', r));
      }
    },
  };
}

function request(port, token) {
  return new Promise((resolve, reject) => {
    const headers = token == null ? {} : { authorization: `Bearer ${token}` };
    const req = http.get({ host: '127.0.0.1', port, path: '/key', headers, timeout: 5_000 }, (res) => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (d) => (body += d));
      res.on('end', () => resolve({ status: res.statusCode, body }));
    });
    req.on('timeout', () => req.destroy(new Error('request timeout')));
    req.on('error', reject);
  });
}

function lanIPv4() {
  for (const rows of Object.values(os.networkInterfaces())) {
    for (const row of rows ?? []) {
      if (row.family === 'IPv4' && !row.internal) return row.address;
    }
  }
  return null;
}

function canConnect(host, port, timeoutMs = 1_000) {
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

test('broker: missing/wrong token is 401, correct token serves the key once, then 410', async (t) => {
  const broker = startBroker({ env: { OPENCODE_GO_API_KEY: FAKE_KEY } });
  t.after(() => broker.stop());
  const { port, token } = await broker.ready;

  const missing = await request(port, null);
  assert.equal(missing.status, 401, missing.body);
  const wrong = await request(port, 'not-the-token');
  assert.equal(wrong.status, 401, wrong.body);
  assert.ok(!missing.body.includes(FAKE_KEY), '401 body must not leak the key');
  assert.ok(!wrong.body.includes(FAKE_KEY), '401 body must not leak the key');

  const first = await request(port, token);
  assert.equal(first.status, 200, first.body);
  assert.deepEqual(JSON.parse(first.body), { key: FAKE_KEY });

  const second = await request(port, token);
  assert.equal(second.status, 410, 'the key is one-shot; a repeat must be 410 Gone');
  assert.ok(!second.body.includes(FAKE_KEY));

  assert.ok(!broker.output.includes(FAKE_KEY), 'broker stdout must never contain the key');
  assert.ok(!broker.errors.includes(FAKE_KEY), 'broker stderr must never contain the key');
});

test('broker: reads refs.OPENCODE_GO_API_KEY from a credentials YAML', async (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 't25-broker-'));
  const file = path.join(dir, '.credentials.yaml');
  fs.writeFileSync(
    file,
    [
      'version: 1',
      'records:',
      '  client-connection/browser-session:',
      '    kind: secret',
      'refs:',
      `  OPENCODE_GO_API_KEY: "${FAKE_KEY}"`,
      '',
    ].join('\n'),
    { mode: 0o600 },
  );
  const broker = startBroker({ args: ['--credentials', file], env: { OPENCODE_GO_API_KEY: '' } });
  t.after(async () => {
    await broker.stop();
    fs.rmSync(dir, { recursive: true, force: true });
  });
  const { port, token } = await broker.ready;
  const res = await request(port, token);
  assert.equal(res.status, 200, res.body);
  assert.equal(JSON.parse(res.body).key, FAKE_KEY);
  assert.ok(!broker.output.includes(FAKE_KEY));
});

test('broker: missing key exits 2 (never skip/0) and names the reason', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 't25-broker-missing-'));
  const missing = path.join(dir, 'nope.yaml');
  try {
    const env = { ...process.env };
    delete env.OPENCODE_GO_API_KEY;
    const r = spawnSync(process.execPath, [BROKER, '--credentials', missing], {
      cwd: ROOT,
      env,
      encoding: 'utf8',
      timeout: 20_000,
    });
    assert.equal(r.status, 2, `stdout: ${r.stdout}\nstderr: ${r.stderr}`);
    assert.match(r.stderr, /credential|key/i);
    assert.doesNotMatch(r.stdout, /BROKER /, 'must not claim to be running without a key');
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('broker: binds 127.0.0.1 only', async (t) => {
  const broker = startBroker({ env: { OPENCODE_GO_API_KEY: FAKE_KEY } });
  t.after(() => broker.stop());
  const { port } = await broker.ready;
  assert.ok(broker.output.startsWith('BROKER '), 'stdout must be exactly one BROKER line');
  const lan = lanIPv4();
  if (lan == null) {
    // No non-loopback IPv4 to probe; the broker has no bind option besides
    // loopback and prints its port only after listening there.
    assert.doesNotMatch(broker.output, /0\.0\.0\.0/);
    return;
  }
  assert.equal(await canConnect(lan, port), false, `broker must not accept connections on ${lan}:${port}`);
});

test('broker: --self-test passes', () => {
  const r = spawnSync(process.execPath, [BROKER, '--self-test'], {
    cwd: ROOT,
    encoding: 'utf8',
    timeout: 120_000,
  });
  assert.equal(r.status, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stdout, /PASS/);
});
