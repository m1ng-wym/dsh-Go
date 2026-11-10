#!/usr/bin/env node
// Mock OpenAI-compatible model server for DSH Go iOS Phase 1 tests.
//
// Contract & conventions: see docs/specs/phase1/mocks.md.
// Design goals:
//   - deterministic, no real API key, listens on 127.0.0.1 only;
//   - four required scenarios: stream / tool / approval / error (+ thinking, slow, error_stream);
//   - every request is logged (JSONL) so tests can assert model & message content;
//   - `--self-test` works without the repo, no network, exits 0/1 (used by scripts/verify.sh --static).
//
// Usage:
//   node mock_model_server.mjs [--port 3901] [--host 127.0.0.1] [--log <path>]
//   node mock_model_server.mjs --self-test
//   MOCK_MODEL_PORT=0 node mock_model_server.mjs            # ephemeral port
//
// Scenario selection (highest wins):
//   1. header `x-mock-scenario: <name>`
//   2. model name suffix: `mock-phase1-model:<name>`
//   3. body field `mock_scenario`
//   4. default `stream`
// Optional: header/body `x-mock-delay-ms` / `mock_delay_ms` overrides inter-chunk delay.

import http from 'node:http';
import { pathToFileURL } from 'node:url';
import { appendFileSync } from 'node:fs';
import { parseArgs } from 'node:util';

const SCENARIOS = Object.freeze([
  'stream', 'thinking', 'tool', 'approval', 'question', 'error_http', 'error_stream', 'slow',
]);
const DEFAULT_TEXT = '你好，我是 Phase 1 的 mock 模型。这是一段用于流式验收的合成文本。';
const MOCK_MODEL_ID = 'mock-phase1-model';
const DEFAULT_DELAY_MS = 25;   // regular scenarios: small, keeps tests fast
const SLOW_DELAY_MS = 1000;    // `slow` scenario default (used for stop/steer/queue tests)

// --------------------------------------------------------------------------- logs

const state = {
  log: [],                 // in-memory request log (per process)
  nextScenario: null,      // set by POST /__mock/scenario (for engines that cannot send headers)
  requests: 0,
};

function record(entry) {
  state.log.push(entry);
  if (state.log.length > 500) state.log.shift();
  if (process.env.MOCK_MODEL_LOG) {
    try { appendFileSync(process.env.MOCK_MODEL_LOG, JSON.stringify(entry) + '\n'); } catch { /* log file is best-effort */ }
  }
}

// --------------------------------------------------------------------------- scenarios

function resolveScenario(req, body) {
  const header = req.headers['x-mock-scenario'];
  if (typeof header === 'string' && SCENARIOS.includes(header)) return header;
  const model = typeof body?.model === 'string' ? body.model : '';
  const suffix = model.includes(':') ? model.split(':').pop() : '';
  if (SCENARIOS.includes(suffix)) return suffix;
  if (typeof body?.mock_scenario === 'string' && SCENARIOS.includes(body.mock_scenario)) return body.mock_scenario;
  if (state.nextScenario) { const s = state.nextScenario; state.nextScenario = null; return s; }
  return 'stream';
}

function resolveDelay(req, body, scenario) {
  const fromHeader = Number.parseInt(String(req.headers['x-mock-delay-ms'] ?? ''), 10);
  const fromBody = Number.parseInt(String(body?.mock_delay_ms ?? ''), 10);
  if (Number.isFinite(fromHeader) && fromHeader >= 0) return fromHeader;
  if (Number.isFinite(fromBody) && fromBody >= 0) return fromBody;
  return scenario === 'slow' ? SLOW_DELAY_MS : DEFAULT_DELAY_MS;
}

function chunkBase() {
  return {
    id: 'chatcmpl-mock-' + (state.requests + 1),
    object: 'chat.completion.chunk',
    created: Math.floor(Date.now() / 1000),
    model: MOCK_MODEL_ID,
  };
}

function deltaChunk(delta, finish = null) {
  return { ...chunkBase(), choices: [{ index: 0, delta, finish_reason: finish }] };
}

// Returns an array of {kind:'chunk', chunk} | {kind:'raw', data} entries for SSE.
function scenarioEvents(scenario, body) {
  const delayDefault = null; // per-request delay handled by caller
  const toolArgs = body?.mock_tool_args && typeof body.mock_tool_args === 'object'
    ? JSON.stringify(body.mock_tool_args) : null;
  switch (scenario) {
    case 'stream': {
      const parts = ['你好', '，我是 ', 'Phase 1 ', '的 mock ', '模型。'];
      return parts.map((part) => ({ kind: 'chunk', chunk: deltaChunk({ content: part }) }))
        .concat([{ kind: 'chunk', chunk: deltaChunk({}, 'stop') }]);
    }
    case 'thinking': {
      return [
        { kind: 'chunk', chunk: deltaChunk({ reasoning_content: '思考：先读取用户的问题，再给出简短回答。' }) },
        { kind: 'chunk', chunk: deltaChunk({ content: '这是思考之后的正式回答。' }) },
        { kind: 'chunk', chunk: deltaChunk({}, 'stop') },
      ];
    }
    case 'tool': {
      return [
        { kind: 'chunk', chunk: deltaChunk({ content: '我来运行一个命令。' }) },
        { kind: 'chunk', chunk: deltaChunk({
          tool_calls: [{
            index: 0, id: 'call_mock_tool_1', type: 'function',
            function: { name: 'bash', arguments: toolArgs ?? JSON.stringify({ command: 'echo mock-tool-ok' }) },
          }],
        }) },
        { kind: 'chunk', chunk: deltaChunk({}, 'tool_calls') },
      ];
    }
    case 'approval': {
      // Emits a tool call that the real engine will gate behind an approval card.
      // The mock does NOT decide approval — that stays production code (mocks.md §2.2).
      return [
        { kind: 'chunk', chunk: deltaChunk({ content: '我需要写一个工作区文件，请审批。' }) },
        { kind: 'chunk', chunk: deltaChunk({
          tool_calls: [{
            index: 0, id: 'call_mock_approval_1', type: 'function',
            function: {
              name: 'write',
              arguments: toolArgs ?? JSON.stringify({ path: 'mock-hello.md', content: 'hello from mock' }),
            },
          }],
        }) },
        { kind: 'chunk', chunk: deltaChunk({}, 'tool_calls') },
      ];
    }
    case 'question': {
      // TODO-VERIFY(mocks.md §7): questions are produced by the engine, not by a model tool call.
      // Until verified this scenario only emits a text marker so tests can assert the path.
      return [
        { kind: 'chunk', chunk: deltaChunk({ content: '[mock-question] 提问触发待核验（D3-07 TODO-VERIFY）' }) },
        { kind: 'chunk', chunk: deltaChunk({}, 'stop') },
      ];
    }
    case 'error_stream': {
      return [
        { kind: 'chunk', chunk: deltaChunk({ content: '我先输出一半，然后出错。' }) },
        { kind: 'raw', data: JSON.stringify({ error: { message: 'mock stream error', type: 'mock_error', code: 'mock_stream_error' } }) },
      ];
    }
    case 'slow': {
      const parts = ['慢速', '响应', '，用于', '停止与', '插话', '测试。'];
      return parts.map((part) => ({ kind: 'chunk', chunk: deltaChunk({ content: part }) }))
        .concat([{ kind: 'chunk', chunk: deltaChunk({}, 'stop') }]);
    }
    case 'error_http':
      return []; // handled before streaming
    default:
      return [{ kind: 'chunk', chunk: deltaChunk({ content: DEFAULT_TEXT }) }, { kind: 'chunk', chunk: deltaChunk({}, 'stop') }];
  }
}

function nonStreamMessage(scenario, body) {
  const toolArgs = body?.mock_tool_args && typeof body.mock_tool_args === 'object'
    ? JSON.stringify(body.mock_tool_args) : null;
  const base = {
    id: 'chatcmpl-mock-' + (state.requests + 1),
    object: 'chat.completion',
    created: Math.floor(Date.now() / 1000),
    model: MOCK_MODEL_ID,
  };
  if (scenario === 'tool' || scenario === 'approval') {
    const isApproval = scenario === 'approval';
    return {
      ...base,
      choices: [{
        index: 0, finish_reason: 'tool_calls',
        message: {
          role: 'assistant', content: isApproval ? '我需要写一个工作区文件，请审批。' : '我来运行一个命令。',
          tool_calls: [{
            id: isApproval ? 'call_mock_approval_1' : 'call_mock_tool_1',
            type: 'function',
            function: {
              name: isApproval ? 'write' : 'bash',
              arguments: toolArgs ?? (isApproval
                ? JSON.stringify({ path: 'mock-hello.md', content: 'hello from mock' })
                : JSON.stringify({ command: 'echo mock-tool-ok' })),
            },
          }],
        },
      }],
    };
  }
  return { ...base, choices: [{ index: 0, finish_reason: 'stop', message: { role: 'assistant', content: DEFAULT_TEXT } }] };
}

// Minimal OpenAI *Responses* shape, reusing the same scenario semantics as chat.
// TODO-VERIFY(mocks.md §7): confirm which API flavor DSH 0.2.2 channels use for
// `responses` protocol; the scenario control plane (headers/__mock/scenario) is identical.
function responsesBase() {
  return { id: 'resp_mock_' + (state.requests + 1), object: 'response', created_at: Math.floor(Date.now() / 1000), model: MOCK_MODEL_ID };
}

function nonStreamResponses(scenario, body) {
  const toolArgs = body?.mock_tool_args && typeof body.mock_tool_args === 'object'
    ? JSON.stringify(body.mock_tool_args) : null;
  if (scenario === 'tool' || scenario === 'approval') {
    const isApproval = scenario === 'approval';
    return {
      ...responsesBase(), status: 'completed',
      output: [{
        type: 'function_call', id: isApproval ? 'call_mock_approval_1' : 'call_mock_tool_1',
        name: isApproval ? 'write' : 'bash',
        arguments: toolArgs ?? (isApproval
          ? JSON.stringify({ path: 'mock-hello.md', content: 'hello from mock' })
          : JSON.stringify({ command: 'echo mock-tool-ok' })),
      }],
    };
  }
  return {
    ...responsesBase(), status: 'completed',
    output: [{ type: 'message', role: 'assistant', content: [{ type: 'output_text', text: DEFAULT_TEXT }] }],
    output_text: DEFAULT_TEXT,
  };
}

function responsesEvents(scenario, body) {
  const created = { type: 'response.created', response: { ...responsesBase(), status: 'in_progress' } };
  if (scenario === 'error_stream') {
    return [created,
      { type: 'response.output_text.delta', delta: '我先输出一半，然后出错。' },
      { type: 'error', error: { message: 'mock stream error', type: 'mock_error', code: 'mock_stream_error' } }];
  }
  if (scenario === 'tool' || scenario === 'approval') {
    const isApproval = scenario === 'approval';
    const toolArgs = body?.mock_tool_args && typeof body.mock_tool_args === 'object'
      ? JSON.stringify(body.mock_tool_args) : null;
    return [created,
      { type: 'response.output_text.delta', delta: isApproval ? '我需要写一个工作区文件，请审批。' : '我来运行一个命令。' },
      { type: 'response.output_item.added', item: {
        type: 'function_call', id: isApproval ? 'call_mock_approval_1' : 'call_mock_tool_1',
        name: isApproval ? 'write' : 'bash',
        arguments: toolArgs ?? (isApproval
          ? JSON.stringify({ path: 'mock-hello.md', content: 'hello from mock' })
          : JSON.stringify({ command: 'echo mock-tool-ok' })),
      } },
      { type: 'response.completed', response: { ...responsesBase(), status: 'completed' } }];
  }
  const parts = scenario === 'slow'
    ? ['慢速', '响应', '，用于', '停止与', '插话', '测试。']
    : (scenario === 'thinking'
      ? ['思考之后的正式回答。']
      : ['你好', '，我是 ', 'Phase 1 ', '的 mock ', '模型。']);
  return [created,
    ...parts.map((delta) => ({ type: 'response.output_text.delta', delta })),
    { type: 'response.completed', response: { ...responsesBase(), status: 'completed' } }];
}

// --------------------------------------------------------------------------- http helpers

function sendJson(res, status, obj, extraHeaders = {}) {
  const body = JSON.stringify(obj);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(body),
    ...extraHeaders,
  });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > 2 * 1024 * 1024) { reject(new Error('body too large')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

const delay = (ms) => new Promise((r) => setTimeout(r, ms));

// --------------------------------------------------------------------------- handler

async function handle(req, res) {
  const url = new URL(req.url ?? '/', 'http://127.0.0.1');
  const method = req.method ?? 'GET';

  if (method === 'GET' && url.pathname === '/healthz') {
    return sendJson(res, 200, { ok: true, model: MOCK_MODEL_ID, scenarios: SCENARIOS });
  }
  if (method === 'GET' && url.pathname === '/__mock/config') {
    return sendJson(res, 200, {
      model: MOCK_MODEL_ID,
      scenarios: SCENARIOS,
      defaultDelayMs: DEFAULT_DELAY_MS,
      slowDelayMs: SLOW_DELAY_MS,
      override: 'x-mock-delay-ms header or mock_delay_ms body field (>=0)',
    });
  }
  if (method === 'GET' && url.pathname === '/v1/models') {
    return sendJson(res, 200, {
      object: 'list',
      data: SCENARIOS.map((s) => ({
        id: s === 'stream' ? MOCK_MODEL_ID : `${MOCK_MODEL_ID}:${s}`,
        object: 'model', created: 0, owned_by: 'mock',
      })),
    });
  }
  if (method === 'GET' && url.pathname === '/__mock/log') return sendJson(res, 200, { log: state.log });
  if (method === 'POST' && url.pathname === '/__mock/reset') { state.log = []; state.nextScenario = null; return sendJson(res, 200, { ok: true }); }
  if (method === 'POST' && url.pathname === '/__mock/scenario') {
    let body = {};
    try { body = JSON.parse(await readBody(req)); } catch { /* ignore */ }
    const name = body?.scenario;
    if (!SCENARIOS.includes(name)) return sendJson(res, 400, { error: { message: `unknown scenario: ${name}`, code: 'mock_bad_scenario' } });
    state.nextScenario = name;
    return sendJson(res, 200, { ok: true, next: name });
  }

  const isChat = method === 'POST' && url.pathname === '/v1/chat/completions';
  const isResponses = method === 'POST' && url.pathname === '/v1/responses';
  if (!isChat && !isResponses) return sendJson(res, 404, { error: { message: 'not found', code: 'mock_not_found' } });

  let body;
  try { body = JSON.parse(await readBody(req)); } catch { return sendJson(res, 400, { error: { message: 'invalid json', code: 'mock_bad_json' } }); }

  const scenario = resolveScenario(req, body);
  const delayMs = resolveDelay(req, body, scenario);
  const stream = body?.stream === true;
  const messages = Array.isArray(body?.messages) ? body.messages : [];
  const lastUser = [...messages].reverse().find((m) => m?.role === 'user');
  const lastUserText = typeof lastUser?.content === 'string'
    ? lastUser.content
    : JSON.stringify(lastUser?.content ?? '').slice(0, 400);

  state.requests += 1;
  const entry = {
    ts: new Date().toISOString(),
    requests: state.requests,
    path: url.pathname,
    scenario,
    model: typeof body?.model === 'string' ? body.model : null,
    stream,
    messages: messages.length,
    tools: Array.isArray(body?.tools) ? body.tools.length : 0,
    last_user: String(lastUserText).slice(0, 200),
    response: '',
    status: 200,
  };

  if (scenario === 'error_http') {
    entry.response = 'http_error'; entry.status = 500;
    record(entry);
    return sendJson(res, 500, { error: { message: 'mock upstream error', type: 'mock_error', code: 'mock_http_error' } });
  }

  if (!stream) {
    entry.response = scenario === 'tool' || scenario === 'approval' ? 'tool_call' : 'text';
    record(entry);
    return sendJson(res, 200, isResponses ? nonStreamResponses(scenario, body) : nonStreamMessage(scenario, body));
  }

  // SSE streaming.
  res.writeHead(200, {
    'content-type': 'text/event-stream; charset=utf-8',
    'cache-control': 'no-cache',
    'connection': 'keep-alive',
    'x-accel-buffering': 'no',
  });
  const sendData = (data) => res.write(`data: ${data}\n\n`);
  const events = isResponses ? responsesEvents(scenario, body) : scenarioEvents(scenario, body);
  entry.response = scenario === 'approval' || scenario === 'tool' ? 'tool_call' : (scenario === 'error_stream' ? 'error_after_chunk' : 'text');
  record(entry);
  try {
    for (const ev of events) {
      if (res.writableEnded) break;
      if (ev.kind === 'chunk') sendData(JSON.stringify(ev.chunk));
      else if (ev.data !== undefined) sendData(ev.data);
      else sendData(JSON.stringify(ev));
      if (delayMs > 0) await delay(delayMs);
    }
    if (!res.writableEnded) sendData('[DONE]');
  } finally {
    if (!res.writableEnded) res.end();
  }
}

// --------------------------------------------------------------------------- server

export function createMockModelServer(logger = console) {
  const server = http.createServer((req, res) => {
    handle(req, res).catch((error) => {
      logger.error?.('[mock-model] handler error:', error);
      if (!res.writableEnded) sendJson(res, 500, { error: { message: 'mock internal error', code: 'mock_internal' } });
    });
  });
  return server;
}

function start(port, host, logger = console) {
  const server = createMockModelServer(logger);
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, host, () => {
      const address = server.address();
      const actual = typeof address === 'object' && address ? address.port : port;
      logger.log?.(`[mock-model] listening on http://${host}:${actual} (model=${MOCK_MODEL_ID})`);
      logger.log?.('[mock-model] scenarios: ' + SCENARIOS.join(', '));
      resolve({ server, port: actual });
    });
  });
}

// --------------------------------------------------------------------------- self-test

async function selfTest() {
  const { server, port } = await start(0, '127.0.0.1', { log: () => {}, error: () => {} });
  const base = `http://127.0.0.1:${port}`;
  const checks = [];
  const assert = (name, cond, detail = '') => checks.push({ name, ok: Boolean(cond), detail });

  try {
    const health = await (await fetch(`${base}/healthz`)).json();
    assert('healthz ok', health.ok === true && Array.isArray(health.scenarios));

    const models = await (await fetch(`${base}/v1/models`)).json();
    assert('models list has mock model', models.data?.some((m) => m.id === MOCK_MODEL_ID));

    // stream scenario (SSE)
    let res = await fetch(`${base}/v1/chat/completions`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-mock-scenario': 'stream', 'x-mock-delay-ms': '0' },
      body: JSON.stringify({ model: MOCK_MODEL_ID, stream: true, messages: [{ role: 'user', content: 'hi' }] }),
    });
    let text = await res.text();
    assert('stream status 200', res.status === 200);
    assert('stream has content deltas', text.includes('"content"') && text.includes('data: [DONE]'), text.slice(0, 120));

    // tool scenario
    res = await fetch(`${base}/v1/chat/completions`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-mock-scenario': 'tool', 'x-mock-delay-ms': '0' },
      body: JSON.stringify({ model: MOCK_MODEL_ID, stream: true, messages: [{ role: 'user', content: 'run' }] }),
    });
    text = await res.text();
    assert('tool scenario emits tool_calls', text.includes('tool_calls') && text.includes('"name":"bash"'), text.slice(0, 160));

    // approval scenario
    res = await fetch(`${base}/v1/chat/completions`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-mock-scenario': 'approval', 'x-mock-delay-ms': '0' },
      body: JSON.stringify({ model: MOCK_MODEL_ID, stream: true, messages: [] }),
    });
    text = await res.text();
    assert('approval scenario emits write tool call', text.includes('"name":"write"') && text.includes('mock-hello.md'), text.slice(0, 160));

    // error_http
    res = await fetch(`${base}/v1/chat/completions`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-mock-scenario': 'error_http' },
      body: JSON.stringify({ model: MOCK_MODEL_ID, stream: true, messages: [] }),
    });
    const errorJson = await res.json();
    assert('error_http returns 500 + error json', res.status === 500 && errorJson.error?.code === 'mock_http_error');

    // error_stream
    res = await fetch(`${base}/v1/chat/completions`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-mock-scenario': 'error_stream', 'x-mock-delay-ms': '0' },
      body: JSON.stringify({ model: MOCK_MODEL_ID, stream: true, messages: [] }),
    });
    text = await res.text();
    assert('error_stream has partial content then error', text.includes('我先输出一半') && text.includes('mock_stream_error'), text.slice(0, 160));

    // model suffix selection + request log
    await fetch(`${base}/v1/chat/completions`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-mock-delay-ms': '0' },
      body: JSON.stringify({ model: `${MOCK_MODEL_ID}:thinking`, stream: true, messages: [{ role: 'user', content: 'think' }] }),
    });
    const log = await (await fetch(`${base}/__mock/log`)).json();
    assert('request log records scenario', log.log?.some((e) => e.scenario === 'thinking'), JSON.stringify(log.log?.slice(-1)));

    // config endpoint: slow scenario default delay must be 1000ms
    const config = await (await fetch(`${base}/__mock/config`)).json();
    assert('config slowDelayMs=1000', config.slowDelayMs === 1000, JSON.stringify(config));
    assert('config defaultDelayMs=25', config.defaultDelayMs === 25, JSON.stringify(config));

    // thinking scenario
    res = await fetch(`${base}/v1/chat/completions`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-mock-scenario': 'thinking', 'x-mock-delay-ms': '0' },
      body: JSON.stringify({ model: MOCK_MODEL_ID, stream: true, messages: [] }),
    });
    text = await res.text();
    assert('thinking scenario emits reasoning_content', text.includes('reasoning_content'), text.slice(0, 160));

    // question scenario (mock cannot produce engine-level questions; text marker is the documented contract)
    res = await fetch(`${base}/v1/chat/completions`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-mock-scenario': 'question', 'x-mock-delay-ms': '0' },
      body: JSON.stringify({ model: MOCK_MODEL_ID, stream: true, messages: [] }),
    });
    text = await res.text();
    assert('question scenario emits marker', text.includes('[mock-question]'), text.slice(0, 160));

    // slow scenario honours override and is the delay-driven path
    const slowStart = Date.now();
    res = await fetch(`${base}/v1/chat/completions`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-mock-scenario': 'slow', 'x-mock-delay-ms': '120' },
      body: JSON.stringify({ model: MOCK_MODEL_ID, stream: true, messages: [] }),
    });
    text = await res.text();
    const slowMs = Date.now() - slowStart;
    assert('slow scenario delays chunks (>=300ms at 120ms override)', slowMs >= 300 && text.includes('慢速'), `elapsed=${slowMs}`);

    // /v1/responses shape (non-stream + stream) mirrors chat scenarios
    res = await fetch(`${base}/v1/responses`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-mock-scenario': 'tool' },
      body: JSON.stringify({ model: MOCK_MODEL_ID, stream: false, messages: [] }),
    });
    const respJson = await res.json();
    assert('responses non-stream has response shape', respJson.object === 'response' && respJson.output?.[0]?.type === 'function_call', JSON.stringify(respJson).slice(0, 160));

    res = await fetch(`${base}/v1/responses`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-mock-scenario': 'stream', 'x-mock-delay-ms': '0' },
      body: JSON.stringify({ model: MOCK_MODEL_ID, stream: true, messages: [] }),
    });
    text = await res.text();
    assert('responses stream emits responses events', text.includes('response.output_text.delta') && text.includes('response.completed'), text.slice(0, 160));

    const failed = checks.filter((c) => !c.ok);
    for (const c of checks) console.log(`${c.ok ? 'PASS' : 'FAIL'} ${c.name}${c.ok ? '' : ' :: ' + c.detail}`);
    if (failed.length) { console.error(`[mock-model] self-test failed: ${failed.length}/${checks.length}`); process.exitCode = 1; }
    else console.log(`[mock-model] self-test OK (${checks.length} checks)`);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

// --------------------------------------------------------------------------- main

const isMain = Boolean(process.argv[1]) && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  const { values } = parseArgs({
    options: {
      port: { type: 'string', default: process.env.MOCK_MODEL_PORT ?? '3901' },
      host: { type: 'string', default: '127.0.0.1' },
      log: { type: 'string' },
      'self-test': { type: 'boolean', default: false },
    },
  });
  if (values.log) process.env.MOCK_MODEL_LOG = values.log;
  if (values['self-test']) {
    await selfTest();
  } else {
    const port = Number.parseInt(String(values.port), 10);
    if (!Number.isInteger(port) || port < 0 || port > 65535) {
      console.error('[mock-model] invalid --port');
      process.exit(2);
    }
    const { server } = await start(port, String(values.host));
    const shutdown = (signal) => {
      console.log(`[mock-model] ${signal}, shutting down`);
      server.close(() => process.exit(0));
      setTimeout(() => process.exit(0), 2000).unref();
    };
    process.on('SIGINT', () => shutdown('SIGINT'));
    process.on('SIGTERM', () => shutdown('SIGTERM'));
  }
}
