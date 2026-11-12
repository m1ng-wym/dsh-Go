#!/usr/bin/env node
// T6 cold-start measurement on the iOS Simulator.
// Launches the real app N times (terminate -> launch), reads the unified log
// stream for the Dart startup trace's `[dsh-startup] first page` line, and
// records RSS after the page. With --idle-ms it keeps the last launch alive and
// samples RSS again after the idle window (the T6 idle-memory baseline uses
// 300000).
//
//   node tooling/ios/metrics/cold-launch.mjs \
//     --simulator <udid> --runs 5 --out cold-start.json
//   node tooling/ios/metrics/cold-launch.mjs \
//     --simulator <udid> --runs 1 --idle-ms 300000 --out idle-rss.json
import { execFileSync, spawn } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { parseArgs } from 'node:util';

const { values } = parseArgs({
  options: Object.fromEntries(
    ['simulator', 'bundle', 'runs', 'out', 'idle-ms', 'timeout-ms'].map((name) => [name, { type: 'string' }]),
  ),
});
const udid = values.simulator;
const bundle = values.bundle ?? 'io.github.ccch1mneyyy.dshgo';
const runs = Number(values.runs ?? 5);
const idleMs = Number(values['idle-ms'] ?? 0);
const timeoutMs = Number(values['timeout-ms'] ?? 20_000);
const out = values.out ?? 'cold-start.json';
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
const rss = (pid) =>
  pid == null ? null : quietly(() => Number(execFileSync('ps', ['-o', 'rss=', '-p', String(pid)], { encoding: 'utf8' }).trim()));

/** Simulator log JSON timestamps look like 2026-11-10T19:15:00.123456+0800. */
function parseTs(text) {
  if (!text) return NaN;
  const m = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})\.(\d+)([+-])(\d{2}):?(\d{2})$/.exec(text.trim());
  if (!m) return Date.parse(text);
  const [, y, mo, d, h, mi, sec, frac, sign, oh, om] = m;
  const ms = Number(frac.padEnd(3, '0').slice(0, 3));
  const utc = Date.UTC(Number(y), Number(mo) - 1, Number(d), Number(h), Number(mi), Number(sec), ms);
  const offset = (sign === '-' ? -1 : 1) * (Number(oh) * 60 + Number(om)) * 60_000;
  return utc - offset;
}
function median(numbers) {
  const sorted = [...numbers].sort((a, b) => a - b);
  if (!sorted.length) return null;
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

/** A log stream that is attached before we launch and dies with its process group. */
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
      'process == "Runner" AND eventMessage CONTAINS "[dsh-startup]"',
    ],
    { stdio: ['ignore', 'pipe', 'pipe'], detached: true },
  );
  const entries = [];
  let pending = '';
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
  const ready = new Promise((resolve) => {
    let done = false;
    const finish = () => {
      if (!done) {
        done = true;
        resolve();
      }
    };
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
let idleRssKb = null;
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
  const deadline = t0 + timeoutMs;
  let hit = null;
  while (pid != null && Date.now() < deadline) {
    hit = s.entries.find((entry) => String(entry.eventMessage ?? '').includes('first page'));
    if (hit) break;
    await sleep(25);
  }
  const receivedAt = Date.now();
  const ts = hit ? parseTs(hit.timestamp) : NaN;
  const logDelta = Number.isFinite(ts) ? ts - t0 : null;
  const wallDelta = hit ? receivedAt - t0 : null;
  await sleep(2500);
  const rssAfterPage = rss(pid);
  if (idleMs > 0 && run === runs) {
    await sleep(idleMs);
    idleRssKb = rss(pid);
  }
  const row = {
    run,
    pid,
    launchAttempts,
    launchedAt: new Date(t0).toISOString(),
    firstPageLoggedAt: hit?.timestamp ?? null,
    firstPageMs: logDelta,
    firstPageWallMs: wallDelta,
    rssKb: rssAfterPage,
    idleRssKb: idleMs > 0 && run === runs ? idleRssKb : null,
    stages: s.entries.map((e) => ({ ts: e.timestamp, message: e.eventMessage })),
  };
  results.push(row);
  console.log(
    `run ${run}: firstPage=${logDelta ?? 'MISS'}ms wall=${wallDelta ?? '?'}ms rss=${rssAfterPage ?? '?'}KB` +
      (idleMs > 0 && run === runs ? ` idleRss=${idleRssKb ?? '?'}KB` : '') + ` attempts=${launchAttempts} pid=${pid ?? '?'}`,
  );
  s.stop();
  await sleep(300);
}
const ms = results.map((r) => r.firstPageMs).filter((n) => typeof n === 'number');
const summary = {
  bundle,
  simulator: udid,
  runs,
  idleMs,
  valuesMs: ms,
  medianMs: median(ms),
  maxMs: ms.length ? Math.max(...ms) : null,
  minMs: ms.length ? Math.min(...ms) : null,
  missing: results.length - ms.length,
  rssKbAfterPage: results.map((r) => r.rssKb),
  idleRssKb,
  results,
};
writeFileSync(out, `${JSON.stringify(summary, null, 2)}\n`);
console.log(
  `median=${summary.medianMs}ms max=${summary.maxMs}ms min=${summary.minMs}ms missing=${summary.missing}` +
    (idleRssKb != null ? ` idleRss=${idleRssKb}KB` : ''),
);
if (summary.missing) process.exit(1);
