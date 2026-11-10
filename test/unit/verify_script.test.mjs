// Regression tests for scripts/verify.sh (T4-fix task-19).
//
// These are deliberately thin: the heavy self-checks (fail-on-skip, layout
// detection, dry-run reporting) live in `scripts/verify.sh --self-test`; this
// file only proves the entry point exists, runs, and keeps the CLI contract.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const SCRIPT = path.join(ROOT, 'scripts', 'verify.sh');

function run(args, env = {}) {
  return spawnSync('bash', [SCRIPT, ...args], {
    cwd: ROOT,
    encoding: 'utf8',
    env: { ...process.env, ...env },
    timeout: 120_000,
  });
}

test('verify.sh --list lists all tiers and exits 0', () => {
  const r = run(['--list']);
  assert.equal(r.status, 0, r.stderr);
  for (const tier of ['[static]', '[fast]', '[full]']) {
    assert.ok(r.stdout.includes(tier), `missing ${tier} in --list output`);
  }
});

test('verify.sh --dry-run reports guard status without executing', () => {
  const r = run(['--static', '--dry-run']);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /dry-run/);
  assert.match(r.stdout, /summary: pass=0 fail=0 skip=0/);
});

test('verify.sh --self-test proves fail-on-skip and layout detection', () => {
  const r = run(['--self-test']);
  assert.equal(r.status, 0, `${r.stdout}\n${r.stderr}`);
  assert.match(r.stdout, /PASS self-test: --static fails on skip/);
  assert.match(r.stdout, /PASS self-test: legacy layout auto-detection/);
});

test('verify.sh --static fails on skip when toolchain is missing', () => {
  // Restricted PATH: node/python3 available, flutter/dart deliberately absent.
  const nodeDir = path.dirname(process.execPath);
  const pathOnly = `${nodeDir}:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin`;
  const r = spawnSync('bash', [SCRIPT, '--static'], {
    cwd: ROOT,
    encoding: 'utf8',
    env: { PATH: pathOnly, HOME: process.env.HOME ?? '' },
    timeout: 120_000,
  });
  assert.notEqual(r.status, 0, 'static must not exit 0 while checks are skipped');
  assert.match(r.stdout, /skipped:/);
});
