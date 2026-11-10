#!/usr/bin/env node
// D1-02 / D1-04 L4：在 iPhone 17 Pro 模拟器上用**真实引擎**验证同一进程内的
// start → stop → start → restart，以及日志快照/失败诊断。
//
//   node tooling/ios/engine-smoke/d1-02-lifecycle-check.mjs \
//     --simulator 1D9F8C91-5739-47B2-BDD0-0FC7207166F3 \
//     --app app/build/ios/iphonesimulator/Runner.app \
//     --report reports/wave2/t8-t9-l4.json [--shots reports/wave2]
//
// 被测包由 `-t lib/dev/engine_lifecycle_probe_main.dart` 构建（专用生命周期入口，
// 不影响 D1-01 的 runtime_probe_main.dart）；probe 每次启动都执行一遍并打印：
//   [probe] status phase=… installed=… bundled=…
//   [probe] snapshot entries=… throughSeq=…
//   [probe] ring lines=…
//   [probe] start ms=… baseUrl=…
//   [probe] start-while-running ms=… phase=running
//   [probe] stop ms=… phase=installed
//   [probe] start-after-stop ms=…
//   [probe] restart ms=…
//   [probe] start-failure code=… message=…
//   [probe] failureLog lines=…
//   [probe] start-after-failure ms=…
//   [probe] LIFECYCLE PROBE OK
//
// 覆盖：
//   D1-02-AC1：start→running（baseUrl）、stop→installed；
//   D1-02-AC2：stop 后同一进程再 start、restart（pid 不变）；
//   D1-02-AC4：运行中重复 start 幂等（native 早返回，状态仍 running）；
//   D1-04-AC1：快照 entries/throughSeq、ring 上限（≤2000 行）、seq 单调且无重复；
//   D1-04-AC2：启动被拒时错误码/原因可读、failureLog 可读、之后仍能启动。
//
// 失败以非 0 退出；结果打印到 stdout 并写 --report。

import { execFileSync, spawn } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { parseArgs } from 'node:util';

const { values } = parseArgs({
  options: Object.fromEntries(['simulator', 'app', 'report', 'shots'].map((name) => [name, { type: 'string' }])),
});
if (!values.simulator || !values.app) {
  console.error('usage: d1-02-lifecycle-check.mjs --simulator <udid> --app <Runner.app> [--report <json>] [--shots <dir>]');
  process.exit(2);
}
const bundleId = 'io.github.ccch1mneyyy.dshgo';
const reportFile = values.report ?? join(process.cwd(), 't8-t9-l4.json');
const shots = values.shots ?? dirname(reportFile);
mkdirSync(dirname(reportFile), { recursive: true });
mkdirSync(shots, { recursive: true });

const simctl = (...args) =>
  execFileSync('xcrun', ['simctl', ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
const quietly = (work) => {
  try {
    return work();
  } catch {
    return null;
  }
};
const sleep = (ms) => new Promise((done) => setTimeout(done, ms));

const scratch = mkdtempSync(join(tmpdir(), 'dsh-d1-02-'));

function screenshot(name) {
  const file = join(shots, name);
  quietly(() => simctl('io', values.simulator, 'screenshot', file));
  return existsSync(file) ? file : null;
}

/// 一个运行中的 App：`log stream` 收集 `[probe]` 行；进程 pid 由 simctl 返回。
function launch(tag) {
  const logFile = join(scratch, `${tag}.log`);
  const stream = spawn(
    'xcrun',
    [
      'simctl',
      'spawn',
      values.simulator,
      'log',
      'stream',
      '--style',
      'compact',
      '--predicate',
      'process == "Runner" AND eventMessage CONTAINS "[probe]"',
    ],
    { stdio: ['ignore', 'pipe', 'pipe'] },
  );
  const sink = [];
  stream.stdout.on('data', (chunk) => sink.push(chunk));
  stream.stderr.on('data', () => {});
  const printed = simctl('launch', '--terminate-running-process', values.simulator, bundleId);
  const pid = Number(String(printed).trim().split(': ').pop());
  const text = () => Buffer.concat(sink).toString('utf8');
  return { pid, stream, text, logFile };
}

function finish(handle) {
  quietly(() => simctl('terminate', values.simulator, bundleId));
  quietly(() => handle.stream.kill('SIGTERM'));
  writeFileSync(handle.logFile, handle.text());
}

async function waitFor(handle, predicate, limitMs, what) {
  const deadline = Date.now() + limitMs;
  for (;;) {
    // A real event-loop turn: the `log stream` child is a pipe, so its stdout is
    // only read while the loop runs.
    await sleep(150);
    const text = handle.text();
    if (predicate(text)) return text;
    if (Date.now() > deadline) {
      throw new Error(`${what}: not seen within ${Math.round(limitMs / 1000)}s; tail=${text.slice(-1200)}`);
    }
  }
}

const probeLines = (text) =>
  text
    .split('\n')
    .filter((line) => line.includes('[probe]'))
    .map((line) => line.slice(line.indexOf('[probe]') + 8).trim());
const line = (text, pattern) => probeLines(text).map((l) => pattern.exec(l)).find(Boolean) ?? null;
const number = (text, pattern, group = 1) => {
  const match = line(text, pattern);
  return match ? Number(match[group]) : null;
};

const checks = [];
const failures = [];
function check(name, passed, detail = '') {
  checks.push({ name, passed, detail });
  if (!passed) failures.push(`${name}: ${detail}`);
  console.log(`${passed ? 'PASS' : 'FAIL'} ${name}${detail ? ` — ${detail}` : ''}`);
}

// ── main ─────────────────────────────────────────────────────────────────────
try {
  console.log(`D1-02/D1-04 L4 · app=${values.app} simulator=${values.simulator}`);
  quietly(() => simctl('bootstatus', values.simulator, '-b'));
  quietly(() => simctl('terminate', values.simulator, bundleId));
  simctl('install', values.simulator, values.app);

  const app = launch('lifecycle');
  let text = '';
  try {
    text = await waitFor(app, (t) => /LIFECYCLE PROBE OK|PROBE FAILED/.test(t), 300_000, 'lifecycle probe result');
  } catch (error) {
    check('lifecycle probe completes', false, error.message.split('\n')[0]);
  }
  const ok = /LIFECYCLE PROBE OK/.test(text);
  check('lifecycle probe completes', ok, ok ? 'LIFECYCLE PROBE OK' : (line(text, /PROBE FAILED: (.*)/)?.[1] ?? 'no result'));

  const shot = screenshot('t8-d1-02-running.png');
  const body = probeLines(text).join('\n');
  const pidFirst = Number(/pid=(\d+) first/.exec(text)?.[1] ?? NaN);
  const pidLast = Number(/pid=(\d+) last/.exec(text)?.[1] ?? NaN);
  finish(app);

  // D1-02-AC1
  const startMs = number(text, /^start ms=(\d+) baseUrl=/);
  check('D1-02-AC1 start reaches running', startMs !== null, `start ${startMs}ms`);
  check(
    'D1-02-AC1 running exposes a baseUrl',
    /^start ms=\d+ baseUrl=\S+ token=true$/m.test(body),
    line(text, /^start ms=\d+ baseUrl=.*/)?.[0] ?? '',
  );
  const stopMs = number(text, /^stop ms=(\d+) phase=installed/);
  check('D1-02-AC1 stop reaches installed', stopMs !== null, `stop ${stopMs}ms`);
  check(
    'D1-02-AC1 stop is under the frozen 3s threshold',
    stopMs !== null && stopMs < 3000,
    `stop ${stopMs}ms`,
  );

  // D1-02-AC2
  const afterStopMs = number(text, /^start-after-stop ms=(\d+)/);
  check('D1-02-AC2 start after stop reaches running', afterStopMs !== null, `start ${afterStopMs}ms`);
  const restartMs = number(text, /^restart ms=(\d+)/);
  check('D1-02-AC2 restart (stop+start) reaches running', restartMs !== null, `restart ${restartMs}ms`);
  check(
    'D1-02-AC2 no relaunch: same app pid across the lifecycle',
    Number.isInteger(pidFirst) && pidFirst === pidLast,
    `pid first=${pidFirst} last=${pidLast}`,
  );

  // D1-02-AC4 (native side)
  check(
    'D1-02-AC4 start while running stays running',
    /^start-while-running ms=\d+ phase=running$/m.test(body),
    line(text, /^start-while-running .*/)?.[0] ?? '',
  );

  // D1-04-AC1
  const entries = number(text, /^snapshot entries=(\d+) labelled=(\d+) throughSeq=(\d+)/);
  const labelled = number(text, /^snapshot entries=(\d+) labelled=(\d+) throughSeq=(\d+)/, 2);
  const through = number(text, /^snapshot entries=(\d+) labelled=(\d+) throughSeq=(\d+)/, 3);
  check(
    'D1-04-AC1 snapshot has seq/stream/line entries',
    entries !== null && entries > 0 && labelled === entries,
    `entries=${entries} labelled=${labelled}`,
  );
  check(
    'D1-04-AC1 snapshot reports throughSeq',
    through !== null && entries !== null && through >= entries,
    `throughSeq=${through} entries=${entries}`,
  );
  const ring = number(text, /^ring lines=(\d+)/);
  check('D1-04-AC1 ring buffer is capped at 2000', ring !== null && ring > 0 && ring <= 2000, `ring lines=${ring}`);
  check(
    'D1-04-AC1 event seq is monotonic with no duplicates',
    /seqs=\d+ monotonic=true duplicates=0/.test(body),
    line(text, /^events .*/)?.[0] ?? '',
  );

  // D1-04-AC2
  check(
    'D1-04-AC2 rejected start reports a stable code and reason',
    /^start-failure code=ios_invalid_env message=\S+/m.test(body) &&
      /^start-failure-mode code=ios_unsupported message=\S+/m.test(body),
    [line(text, /^start-failure .*/)?.[0], line(text, /^start-failure-mode .*/)?.[0]].filter(Boolean).join(' | '),
  );
  check(
    'D1-04-AC2 last failure and log stay readable while the engine is down',
    /^failureLog lines=\d+ snapshot=[1-9]\d*$/m.test(body),
    line(text, /^failureLog lines=.*/)?.[0] ?? '',
  );
  const afterFailure = number(text, /^start-after-failure ms=(\d+)/);
  check('D1-04-AC2 engine restarts after a failed start', afterFailure !== null, `start ${afterFailure}ms`);

  const summary = {
    capability: 'D1-02/D1-04',
    simulator: values.simulator,
    app: values.app,
    startedAt: new Date().toISOString(),
    passed: failures.length === 0,
    metrics: {
      startMs,
      stopMs,
      startAfterStopMs: afterStopMs,
      restartMs,
      afterFailureMs: afterFailure,
      snapshotEntries: entries,
      snapshotThroughSeq: through,
      ringLines: ring,
      pidFirst,
      pidLast,
    },
    checks,
    failures,
    screenshot: shot,
    probeLines: probeLines(text),
  };
  writeFileSync(reportFile, `${JSON.stringify(summary, null, 2)}\n`);
  console.log(`\n${failures.length === 0 ? 'ALL CHECKS PASS' : `${failures.length} CHECK(S) FAILED`}`);
  if (failures.length) {
    for (const failure of failures) console.error(`- ${failure}`);
    process.exit(1);
  }
} catch (error) {
  console.error(error.stack ?? String(error));
  writeFileSync(reportFile, `${JSON.stringify({ capability: 'D1-02/D1-04', passed: false, error: String(error), checks }, null, 2)}\n`);
  process.exit(1);
}
