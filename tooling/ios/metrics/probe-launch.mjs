#!/usr/bin/env node
// T6 consecutive-launch measurement on the iOS Simulator.
// Launches the dev runtime probe N times (terminate -> launch), reads the
// unified log stream for `running at ... after Nms`, records RSS, and fails
// when any run does not reach running. The app must be built from
// lib/dev/runtime_probe_main.dart.
//
//   node tooling/ios/metrics/probe-launch.mjs \
//     --simulator <udid> --runs 20 --out probe-launch.json
import { execFileSync, spawn } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { parseArgs } from 'node:util';

const { values } = parseArgs({
  options: Object.fromEntries(
    ['simulator', 'bundle', 'runs', 'out', 'label', 'timeout-ms'].map((name) => [name, { type: 'string' }]),
  ),
});
const udid = values.simulator;
const bundle = values.bundle ?? 'io.github.ccch1mneyyy.dshgo';
const runs = Number(values.runs ?? 1);
const timeoutMs = Number(values['timeout-ms'] ?? 60_000);
const out = values.out ?? 'probe-launch.json';
const label = values.label ?? '';
mkdirSync(dirname(out), { recursive: true });
const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
const simctl = (...args) =>
  execFileSync('xcrun', ['simctl', ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 120_000 });
const quietly = (fn) => {
  try {
    return fn();
  } catch {
    return null;
  }
};
function median(numbers) {
  const s = [...numbers].sort((a, b) => a - b);
  if (!s.length) return null;
  const mid = Math.floor(s.length / 2);
  return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}

function startStream() {
  const stream = spawn(
    'xcrun',
    [
      'simctl',
      'spawn',
      udid,
      'log',
      'stream',
      '--style',
      'ndjson',
      '--predicate',
      'process == "Runner" AND eventMessage CONTAINS "[probe]"',
    ],
    { stdio: ['ignore', 'pipe', 'pipe'], detached: true },
  );
  const entries = [];
  let pending = '';
  const ready = new Promise((resolve) => {
    let done = false;
    const finish = () => {
      if (!done) {
        done = true;
        resolve();
      }
    };
    stream.stdout.on('data', (chunk) => {
      pending += chunk.toString('utf8');
      let at;
      while ((at = pending.indexOf('\n')) >= 0) {
        const line = pending.slice(0, at).trim();
        pending = pending.slice(at + 1);
        if (!line.startsWith('{')) continue;
        try {
          entries.push(JSON.parse(line));
        } catch {
          /* partial */
        }
      }
    });
    stream.stderr.on('data', () => {});
    setTimeout(finish, 900);
  });
  const stop = () => {
    try {
      process.kill(-stream.pid, 'SIGTERM');
    } catch {
      quietly(() => stream.kill('SIGTERM'));
    }
  };
  return { stream, entries, ready, stop };
}

const results = [];
for (let run = 1; run <= runs; run += 1) {
  quietly(() => simctl('terminate', udid, bundle));
  await sleep(700);
  const s = startStream();
  await s.ready;
  await sleep(500);
  const t0 = Date.now();
  let pid = null;
  let launchAttempts = 0;
  for (; launchAttempts < 5 && pid == null; launchAttempts += 1) {
    try {
      pid = Number(simctl('launch', udid, bundle).trim().split(': ').pop());
    } catch {
      if (launchAttempts < 4) await sleep(2000);
    }
  }
  let running = null;
  let text = '';
  if (pid != null) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      text = s.entries.map((e) => String(e.eventMessage ?? '')).join('\n');
      running = /running at (\S+) after (\d+)ms/.exec(text);
      if (running) break;
      await sleep(100);
    }
  }
  const at = Date.now();
  await sleep(1500);
  const rssKb = pid == null ? null : quietly(() =>
    Number(execFileSync('ps', ['-o', 'rss=', '-p', String(pid)], { encoding: 'utf8' }).trim()));
  const lines = s.entries.map((e) => ({ ts: e.timestamp, message: e.eventMessage }));
  const row = {
    run,
    pid,
    launchAttempts,
    launchedAt: new Date(t0).toISOString(),
    engineStartMs: running ? Number(running[2]) : null,
    runningUrl: running ? running[1] : null,
    launchToRunningMs: running ? at - t0 : null,
    rssKb,
    lines,
  };
  results.push(row);
  console.log(
    `run ${run}: engineStart=${row.engineStartMs ?? 'MISS'}ms launchToRunning=${row.launchToRunningMs ?? '?'}ms ` +
      `rss=${row.rssKb ?? '?'}KB attempts=${row.launchAttempts} pid=${row.pid ?? '?'}`,
  );
  s.stop();
  await sleep(300);
}
const starts = results.map((r) => r.engineStartMs).filter((n) => typeof n === 'number');
const summary = {
  label,
  simulator: udid,
  runs,
  engineStartMs: starts,
  medianEngineStartMs: median(starts),
  maxEngineStartMs: starts.length ? Math.max(...starts) : null,
  failures: results.filter((r) => r.engineStartMs == null).map((r) => r.run),
  results,
};
writeFileSync(out, `${JSON.stringify(summary, null, 2)}\n`);
console.log(`median=${summary.medianEngineStartMs}ms max=${summary.maxEngineStartMs}ms failures=${JSON.stringify(summary.failures)}`);
if (summary.failures.length) process.exit(1);
