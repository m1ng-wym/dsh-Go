#!/usr/bin/env node
// D1-01 L4：在 iPhone 17 Pro 模拟器上用**真实引擎**驱动「安装运行环境」。
//
//   node tooling/ios/engine-smoke/d1-01-install-check.mjs \
//     --simulator 1D9F8C91-5739-47B2-BDD0-0FC7207166F3 \
//     --app app/build/ios/iphonesimulator/Runner.app \
//     --report reports/wave1/t7-d1-01-l4.json [--shots reports/wave1]
//
// 被测包用 `-t lib/dev/runtime_probe_main.dart` 构建（分支自带的开发入口，走与正式
// App 相同的 `dsh/runtime` 通道真实安装/启动引擎），阶段打印到统一日志（`flutter:`
// 前缀，由 `log stream` 收集）：
//   [probe] phase notInstalled / installing / installed / starting / running
//   [probe] extract 10% (1s) …          （verify 与解压两段进度各从 0 走到 100）
//   [probe] installed in 15s
//   [probe] running at … after …ms
//
// 覆盖：
//   D1-01-AC1：全新安装 → 进度 → `installing` → `installed` → 可启动；
//   D1-01-AC2：安装中途 `simctl terminate`（等价杀 App）→ 再次启动 → 断点续装完成
//               （installing.json 存在 → 续装后消失、installed.json 出现、
//               已解压文件复用、续装明显快于全新安装）。
//
// 失败以非 0 退出；结果打印到 stdout 并写 --report。

import { execFileSync, spawn } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { parseArgs } from 'node:util';

const { values } = parseArgs({
  options: Object.fromEntries(['simulator', 'app', 'report', 'shots'].map((name) => [name, { type: 'string' }])),
});
if (!values.simulator || !values.app) {
  console.error('usage: d1-01-install-check.mjs --simulator <udid> --app <Runner.app> [--report <json>] [--shots <dir>]');
  process.exit(2);
}
const bundleId = 'io.github.ccch1mneyyy.dshgo';
const reportFile = values.report ?? join(process.cwd(), 't7-d1-01-l4.json');
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

const scratch = mkdtempSync(join(tmpdir(), 'dsh-d1-01-'));
const dataContainer = () => simctl('get_app_container', values.simulator, bundleId, 'data').trim();
const runtimeBase = () => join(dataContainer(), 'Library', 'Application Support', 'dsh-runtime');
const journalPath = () => join(runtimeBase(), 'installing.json');
const installedPath = () => join(runtimeBase(), 'installed.json');
function treeFiles() {
  const tree = join(runtimeBase(), 'tree');
  if (!existsSync(tree)) return 0;
  const printed = execFileSync('/bin/sh', ['-c', 'find "$1" -type f | wc -l', 'sh', tree], { encoding: 'utf8' });
  return Number(printed.trim());
}

function screenshot(name) {
  const file = join(shots, name);
  quietly(() => simctl('io', values.simulator, 'screenshot', file));
  return existsSync(file) ? file : null;
}

/// A running app: a `log stream` that collects its `[probe]` lines, and the pid.
function launch(tag) {
  const logFile = join(scratch, `${tag}.log`);
  const stream = spawn(
    'xcrun',
    ['simctl', 'spawn', values.simulator, 'log', 'stream', '--style', 'compact',
      '--predicate', 'process == "Runner" AND eventMessage CONTAINS "[probe]"'],
    { stdio: ['ignore', 'pipe', 'pipe'] },
  );
  const sink = [];
  stream.stdout.on('data', (chunk) => sink.push(chunk));
  stream.stderr.on('data', () => {});
  const printed = simctl('launch', '--terminate-running-process', values.simulator, bundleId);
  const pid = Number(String(printed).trim().split(': ').pop());
  const text = () => {
    const live = Buffer.concat(sink).toString('utf8');
    return `${existsSync(logFile) ? readFileSync(logFile, 'utf8') : ''}${live}`;
  };
  return { pid, stream, text, logFile };
}

function finish(handle) {
  quietly(() => simctl('terminate', values.simulator, bundleId));
  quietly(() => handle.stream.kill('SIGTERM'));
  if (handle) writeFileSync(handle.logFile, handle.text());
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
  text.split('\n').filter((line) => line.includes('[probe]')).map((line) => line.slice(line.indexOf('[probe]') + 8).trim());
const phaseSequence = (text) => probeLines(text).map((line) => /^phase (\w+)/.exec(line)?.[1]).filter(Boolean);
const progress = (text) =>
  probeLines(text)
    .map((line) => /^extract (\d+)% \((\d+)s\)/.exec(line))
    .filter(Boolean)
    .map((match) => ({ percent: Number(match[1]), seconds: Number(match[2]) }));
const installSeconds = (text) =>
  probeLines(text).map((line) => /^installed in (\d+)s/.exec(line)?.[1]).filter(Boolean).map(Number);

const checks = [];
const failures = [];
function check(name, passed, detail = '') {
  checks.push({ name, passed, detail });
  if (!passed) failures.push(`${name}: ${detail}`);
  console.log(`${passed ? 'PASS' : 'FAIL'} ${name}${detail ? ` — ${detail}` : ''}`);
}

function freshInstall() {
  quietly(() => simctl('uninstall', values.simulator, bundleId));
  simctl('install', values.simulator, values.app);
  return dataContainer();
}

// ── AC1: 全新安装 → 进度 → installed → 可启动 ────────────────────────────────
async function ac1() {
  freshInstall();
  const app = launch('ac1');
  let during = null;
  let text;
  try {
    await waitFor(app, (t) => progress(t).length > 0, 120_000, 'first progress event while installing');
    during = screenshot('t7-d1-01-ac1-installing.png');
    text = await waitFor(
      app,
      (t) => installSeconds(t).length > 0 && phaseSequence(t).includes('installed'),
      240_000,
      'install reaches installed',
    );
  } catch (error) {
    check('ac1 install reaches installed', false, error.message.split('\n')[0]);
    finish(app);
    return { text: app.text(), during };
  }
  const phases = phaseSequence(text);
  const events = progress(text);
  check('ac1 phase notInstalled seen', phases.includes('notInstalled'), `phases=${phases.join('>')}`);
  check('ac1 phase installing seen', phases.includes('installing'), `phases=${phases.join('>')}`);
  check('ac1 progress events observed', events.length >= 4, `events=${events.length}`);
  check(
    'ac1 progress has a complete extract run',
    events.some((event) => event.percent === 100),
    `percents=${events.map((event) => event.percent).join(',')}`,
  );
  check('ac1 phase installed seen', phases.includes('installed'), `phases=${phases.join('>')}`);
  const seconds = installSeconds(text)[0];
  check('ac1 install completed', seconds !== undefined, `installed in ${seconds ?? '?'}s`);

  // D1-01-AC1 后半句：结束后可启动引擎（引擎细节归 D1-02）。
  try {
    text = await waitFor(app, (t) => /running at .* after \d+ms/.test(t), 240_000, 'engine starts after install');
    check('ac1 engine starts after install', true, /running at .* after \d+ms/.exec(text)?.[0] ?? '');
  } catch (error) {
    check('ac1 engine starts after install', false, error.message.split('\n')[0]);
  }
  const running = screenshot('t7-d1-01-ac1-running.png');
  finish(app);
  return { text, during, running, installSeconds: seconds };
}

// ── AC2: 安装中途被终止 → 再启动 → 断点续装 ──────────────────────────────────
async function ac2(freshSeconds) {
  for (let attempt = 1; attempt <= 3; attempt++) {
    freshInstall();
    const app = launch(`ac2-${attempt}`);
    try {
      // 等到解压阶段已经落盘一部分（第二段进度、≥3s、≥30%），随后 terminate。
      await waitFor(
        app,
        (t) => progress(t).some((event) => event.seconds >= 3 && event.percent >= 30),
        120_000,
        'extract progress >=30%',
      );
      const killedAt = progress(app.text()).filter((event, index, all) => event.seconds >= 3).at(-1)?.percent ?? 0;
      finish(app);
      await sleep(500);
      const journalBefore = existsSync(journalPath());
      const filesBefore = treeFiles();
      check(`ac2-${attempt} kill leaves a resumable journal`, journalBefore, `killed at extract ${killedAt}%`);
      check(
        `ac2-${attempt} interrupted install not reported installed`,
        !existsSync(installedPath()),
        `installed.json exists=${existsSync(installedPath())}`,
      );
      if (!journalBefore) continue;

      const resume = launch(`ac2-${attempt}-resume`);
      const resumed = await waitFor(
        resume,
        (t) => installSeconds(t).length > 0 && phaseSequence(t).includes('installed'),
        240_000,
        'resumed install reaches installed',
      );
      const resumeSeconds = installSeconds(resumed)[0];
      check(`ac2-${attempt} resume completes`, resumeSeconds !== undefined, `resume install ${resumeSeconds}s`);
      check(`ac2-${attempt} journal cleared after resume`, !existsSync(journalPath()), 'installing.json removed');
      check(`ac2-${attempt} installed record written`, existsSync(installedPath()), 'installed.json written');
      check(
        `ac2-${attempt} already-extracted files reused`,
        treeFiles() >= filesBefore && treeFiles() > 0,
        `tree files before=${filesBefore} after=${treeFiles()}`,
      );
      if (freshSeconds !== undefined && resumeSeconds !== undefined) {
        check(
          `ac2-${attempt} resume faster than a fresh install`,
          resumeSeconds < freshSeconds,
          `fresh=${freshSeconds}s resume=${resumeSeconds}s`,
        );
      }
      const shot = screenshot('t7-d1-01-ac2-resumed.png');
      finish(resume);
      return { attempt, killedAt, filesBefore, filesAfter: treeFiles(), resumeSeconds, shot, text: resumed };
    } catch (error) {
      check(`ac2-${attempt}`, false, error.message.split('\n')[0]);
      finish(app);
    }
  }
  return null;
}

// ── main ─────────────────────────────────────────────────────────────────────
try {
  console.log(`D1-01 L4 · app=${values.app} simulator=${values.simulator}`);
  quietly(() => simctl('bootstatus', values.simulator, '-b'));
  const first = await ac1();
  const resumed = await ac2(first.installSeconds);
  const summary = {
    capability: 'D1-01',
    ac1: {
      passed: checks.filter((c) => c.name.startsWith('ac1')).every((c) => c.passed),
      installSeconds: first.installSeconds,
      screenshots: [first.during, first.running].filter(Boolean),
    },
    ac2: resumed
      ? { passed: checks.filter((c) => c.name.startsWith('ac2')).every((c) => c.passed), ...resumed, text: undefined }
      : { passed: false },
    checks,
    failures,
  };
  writeFileSync(join(shots, 't7-d1-01-l4-probe.log'), [first.text, resumed?.text].filter(Boolean).join('\n---\n'));
  writeFileSync(reportFile, `${JSON.stringify(summary, null, 2)}\n`);
  console.log(`report: ${reportFile}`);
  if (failures.length) {
    console.error(`FAILED: ${failures.length} check(s)`);
    process.exit(1);
  }
  console.log('D1-01 L4 PASS');
} catch (error) {
  console.error(error);
  writeFileSync(reportFile, `${JSON.stringify({ capability: 'D1-01', error: String(error), checks, failures }, null, 2)}\n`);
  process.exit(1);
}
