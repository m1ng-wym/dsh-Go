#!/usr/bin/env node
// Real opencode-go preflight probe for Phase 1 acceptance (T25).
//
// This is test infrastructure, not product code. It sends the smallest set of
// real requests that proves the provider path the App depends on:
//   GET  /models                  -> the configured model is offered
//   POST /chat/completions        -> non-stream reply is PONG-style
//   POST /chat/completions stream -> SSE delivers >1 content delta
//   POST /chat/completions tools  -> assistant emits a tool call
//   POST /chat/completions ...    -> tool result is accepted and answered
//   POST /chat/completions think  -> reasoning_effort=max returns reasoning_content
//
// Budget: 6 requests (hard cap; exceeding it fails, it does not retry). The key
// is fetched from the loopback credential broker by default and never printed,
// logged, or written to the JSON summary. Real network failures exit 1.
//
// Usage:
//   node real_provider_probe.mjs --broker-url http://127.0.0.1:PORT --broker-token HEX
//   node real_provider_probe.mjs --self-test          # offline, no real key/network
//
// Env fallback: OPENCODE_GO_API_KEY (used only when no --broker-* is given).

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { parseArgs } from 'node:util';

const DEFAULT_BASE_URL = 'https://opencode.ai/inference/go/v1';
const DEFAULT_MODEL = 'deepseek-v4.1-flash';
const SESSION_HEADER = 'x-opencode-session';

export function redact(text, secret) {
  const value = String(text ?? '');
  if (!secret) return value;
  return value.split(secret).join('<redacted>');
}

function truncate(text, max = 300) {
  const value = String(text ?? '');
  return value.length <= max ? value : `${value.slice(0, max)}…`;
}

// --------------------------------------------------------------------------- HTTP

async function readJson(res) {
  const text = await res.text();
  try {
    return { json: JSON.parse(text), text };
  } catch {
    return { json: null, text };
  }
}

async function fetchBrokerKey(brokerUrl, brokerToken) {
  const url = new URL('/key', brokerUrl.endsWith('/') ? brokerUrl : `${brokerUrl}/`);
  const res = await fetch(url, {
    headers: { authorization: `Bearer ${brokerToken}` },
    signal: AbortSignal.timeout(15_000),
  });
  const { json, text } = await readJson(res);
  if (res.status !== 200) throw new Error(`credential broker returned HTTP ${res.status}`);
  const key = typeof json?.key === 'string' ? json.key.trim() : '';
  if (!key) throw new Error(`credential broker response had no key (${truncate(text, 80)})`);
  return key;
}

export async function resolveKey({ brokerUrl, brokerToken, env = process.env } = {}) {
  if (brokerUrl) {
    if (!brokerToken) throw new Error('--broker-url requires --broker-token');
    return fetchBrokerKey(brokerUrl, brokerToken);
  }
  const fromEnv = (env.OPENCODE_GO_API_KEY ?? '').trim();
  if (fromEnv) return fromEnv;
  throw new Error('no credential: pass --broker-url/--broker-token or set OPENCODE_GO_API_KEY');
}

// --------------------------------------------------------------------------- SSE

/** Parses an OpenAI-style SSE body into JSON events + deltas. */
export function parseSse(text) {
  const events = [];
  let done = false;
  for (const block of String(text ?? '').split(/\r?\n\r?\n/)) {
    const data = block
      .split(/\r?\n/)
      .filter((line) => line.startsWith('data:'))
      .map((line) => line.slice(5).trim())
      .join('\n');
    if (!data) continue;
    if (data === '[DONE]') {
      done = true;
      continue;
    }
    try {
      events.push(JSON.parse(data));
    } catch {
      // A malformed event is a failure at the assertion layer; keep the raw
      // count so the error can name it instead of throwing a SyntaxError.
      events.push({ __parse_error: truncate(data, 120) });
    }
  }
  return { events, done };
}

export function sseSummary(text) {
  const { events, done } = parseSse(text);
  let content = '';
  let deltas = 0;
  let reasoning = '';
  let finish = null;
  let toolCalls = [];
  let parseErrors = 0;
  for (const event of events) {
    if (event.__parse_error) {
      parseErrors++;
      continue;
    }
    const choice = event.choices?.[0];
    if (!choice) continue;
    if (choice.finish_reason) finish = choice.finish_reason;
    const delta = choice.delta ?? {};
    if (typeof delta.content === 'string' && delta.content !== '') {
      content += delta.content;
      deltas++;
    }
    if (typeof delta.reasoning_content === 'string') reasoning += delta.reasoning_content;
    if (Array.isArray(delta.tool_calls)) toolCalls = toolCalls.concat(delta.tool_calls);
  }
  return { events, done, content, deltas, reasoning, finish, toolCalls, parseErrors };
}

// --------------------------------------------------------------------------- checks

export async function runChecks({
  baseUrl = DEFAULT_BASE_URL,
  key,
  session = randomUUID(),
  model = DEFAULT_MODEL,
  maxRequests = 6,
  timeoutMs = 180_000,
  log = () => {},
} = {}) {
  if (!key) throw new Error('runChecks requires a key');
  const base = baseUrl.replace(/\/+$/, '');
  const checks = [];
  const logs = [];
  const say = (line) => {
    const safe = redact(line, key);
    logs.push(safe);
    log(safe);
  };
  let requests = 0;

  function countRequest(label) {
    if (requests >= maxRequests) {
      throw new Error(`request budget exhausted (${maxRequests}); refusing to send ${label}`);
    }
    requests++;
    say(`request ${requests}/${maxRequests}: ${label}`);
  }

  const headers = () => ({
    authorization: `Bearer ${key}`,
    'content-type': 'application/json',
    [SESSION_HEADER]: session,
  });

  async function postChat(body, label) {
    countRequest(label);
    const res = await fetch(`${base}/chat/completions`, {
      method: 'POST',
      headers: headers(),
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(timeoutMs),
    });
    const text = await res.text();
    if (!res.ok) throw new Error(`${label}: HTTP ${res.status}: ${truncate(text)}`);
    let json = null;
    try {
      json = JSON.parse(text);
    } catch {
      // stream bodies are not JSON; the caller parses SSE
    }
    return { res, text, json };
  }

  async function step(name, fn) {
    try {
      const detail = await fn();
      checks.push({ name, ok: true, detail: detail ?? '' });
      say(`ok ${name}${detail ? `: ${detail}` : ''}`);
    } catch (e) {
      const detail = redact(e?.message ?? e, key);
      checks.push({ name, ok: false, detail });
      say(`FAIL ${name}: ${detail}`);
      throw e;
    }
  }

  try {
    await step('models_lists_model', async () => {
      countRequest('GET /models');
      const res = await fetch(`${base}/models`, { headers: headers(), signal: AbortSignal.timeout(timeoutMs) });
      const { json, text } = await readJson(res);
      if (!res.ok) throw new Error(`GET /models: HTTP ${res.status}: ${truncate(text)}`);
      const ids = Array.isArray(json?.data) ? json.data.map((m) => m?.id).filter(Boolean) : [];
      if (!ids.includes(model)) throw new Error(`/models does not list ${model} (${ids.length} models)`);
      return `${ids.length} models, includes ${model}`;
    });

    await step('nonstream_pong', async () => {
      const { json } = await postChat(
        {
          model,
          stream: false,
          max_tokens: 32,
          messages: [{ role: 'user', content: 'Reply with exactly PONG and nothing else.' }],
        },
        'POST /chat/completions (non-stream)',
      );
      const message = json?.choices?.[0]?.message ?? {};
      const content = typeof message.content === 'string' ? message.content.trim() : '';
      const finish = json?.choices?.[0]?.finish_reason ?? null;
      if (!/^PONG[.!]?$/i.test(content)) throw new Error(`expected a PONG reply, got ${JSON.stringify(truncate(content, 60))}`);
      return `reply=${JSON.stringify(content)}, finish=${finish}`;
    });

    await step('sse_stream', async () => {
      const { res, text } = await postChat(
        {
          model,
          stream: true,
          max_tokens: 64,
          messages: [{ role: 'user', content: 'Count from 1 to 3, one number per line, nothing else.' }],
        },
        'POST /chat/completions (stream)',
      );
      const contentType = res.headers.get('content-type') ?? '';
      if (!contentType.includes('text/event-stream')) throw new Error(`stream response is not SSE (${contentType || 'no content-type'})`);
      const summary = sseSummary(text);
      if (summary.parseErrors > 0) throw new Error(`${summary.parseErrors} unparseable SSE event(s)`);
      if (summary.deltas <= 1) throw new Error(`expected >1 content delta, got ${summary.deltas}`);
      if (!summary.content.trim()) throw new Error('stream produced no text');
      if (!summary.done) throw new Error('stream did not end with data: [DONE]');
      return `${summary.deltas} deltas, ${summary.content.trim().length} chars, finish=${summary.finish}`;
    });

    let toolCall = null;
    await step('tool_call', async () => {
      const tools = [
        {
          type: 'function',
          function: {
            name: 'echo_tool',
            description: 'Echo the given text back to the caller.',
            parameters: {
              type: 'object',
              properties: { text: { type: 'string', description: 'Text to echo' } },
              required: ['text'],
              additionalProperties: false,
            },
          },
        },
      ];
      const toolMessages = [
        { role: 'system', content: 'You are an acceptance smoke test. Call the requested tool; do not answer in text.' },
        { role: 'user', content: 'Call echo_tool with text exactly PONG.' },
      ];
      const { json } = await postChat(
        { model, stream: false, messages: toolMessages, tools, tool_choice: 'auto', max_tokens: 200 },
        'POST /chat/completions (tool call)',
      );
      const message = json?.choices?.[0]?.message ?? {};
      const calls = Array.isArray(message.tool_calls) ? message.tool_calls : [];
      if (calls.length === 0) {
        throw new Error(`assistant returned no tool_calls (content: ${JSON.stringify(truncate(message.content ?? '', 60))})`);
      }
      const call = calls[0];
      if (call?.function?.name !== 'echo_tool') throw new Error(`unexpected tool name: ${call?.function?.name}`);
      let args = null;
      try {
        args = JSON.parse(call.function.arguments ?? '');
      } catch {
        throw new Error(`tool arguments are not JSON: ${truncate(call.function.arguments, 80)}`);
      }
      if (typeof args?.text !== 'string' || !args.text) throw new Error('tool arguments have no text');
      toolCall = call;
      return `${call.function.name}(${truncate(call.function.arguments, 60)})`;
    });

    await step('tool_result_roundtrip', async () => {
      if (!toolCall) throw new Error('no tool call to answer');
      const messages = [
        { role: 'system', content: 'You are an acceptance smoke test. When a tool result is provided, answer with the tool result text exactly.' },
        { role: 'user', content: 'Call echo_tool with text exactly PONG.' },
        { role: 'assistant', content: toolCall.function.arguments ? null : '', tool_calls: [toolCall] },
        { role: 'tool', tool_call_id: toolCall.id, content: 'PONG' },
      ];
      const { json } = await postChat(
        { model, stream: false, messages, max_tokens: 64 },
        'POST /chat/completions (tool result)',
      );
      const message = json?.choices?.[0]?.message ?? {};
      const content = typeof message.content === 'string' ? message.content.trim() : '';
      if (!content) throw new Error('assistant produced no text after the tool result');
      if (!/PONG/i.test(content)) throw new Error(`assistant did not use the tool result: ${JSON.stringify(truncate(content, 80))}`);
      return `reply=${JSON.stringify(truncate(content, 60))}`;
    });

    await step('thinking_reasoning', async () => {
      const { json } = await postChat(
        {
          model,
          stream: false,
          reasoning_effort: 'max',
          max_tokens: 600,
          messages: [{ role: 'user', content: 'What is 17*3? Think it through, then answer with just the number.' }],
        },
        'POST /chat/completions (reasoning_effort=max)',
      );
      const message = json?.choices?.[0]?.message ?? {};
      const reasoning = typeof message.reasoning_content === 'string' ? message.reasoning_content.trim() : '';
      const content = typeof message.content === 'string' ? message.content.trim() : '';
      if (!reasoning) throw new Error('reasoning_content is empty with reasoning_effort=max');
      if (!content) throw new Error('no final content after reasoning');
      return `${reasoning.length} reasoning chars, reply=${JSON.stringify(truncate(content, 40))}`;
    });
  } catch (e) {
    return { ok: false, error: redact(e?.message ?? e, key), checks, logs, requests, model, session };
  }

  return { ok: checks.every((c) => c.ok), checks, logs, requests, model, session };
}

// --------------------------------------------------------------------------- self-test

function mockServer() {
  const state = { keyServed: false, requests: 0 };
  const server = http.createServer((req, res) => {
    state.requests++;
    const url = new URL(req.url ?? '/', 'http://127.0.0.1');
    const bad = url.pathname.startsWith('/bad/');
    if (url.pathname.endsWith('/key')) {
      if (req.headers.authorization !== 'Bearer test-token') {
        res.writeHead(401).end('{"error":"unauthorized"}');
        return;
      }
      if (state.keyServed) {
        res.writeHead(410).end('{"error":"gone"}');
        return;
      }
      state.keyServed = true;
      res.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify({ key: 'sk-probe-selftest-fake' }));
      return;
    }
    if (url.pathname.endsWith('/models')) {
      res
        .writeHead(200, { 'content-type': 'application/json' })
        .end(JSON.stringify({ object: 'list', data: [{ id: 'deepseek-v4.1-flash' }] }));
      return;
    }
    if (!url.pathname.endsWith('/chat/completions')) {
      res.writeHead(404).end('{}');
      return;
    }
    let body = '';
    req.on('data', (d) => (body += d));
    req.on('end', () => {
      const parsed = body ? JSON.parse(body) : {};
      if (bad) {
        res.writeHead(200, { 'content-type': 'application/json' }).end(
          JSON.stringify({ choices: [{ message: { role: 'assistant', content: 'NOPE' }, finish_reason: 'stop' }] }),
        );
        return;
      }
      if (parsed.stream) {
        const chunks = ['1\n', '2\n', '3\n'];
        let sse = '';
        for (const c of chunks) {
          sse += `data: ${JSON.stringify({ choices: [{ index: 0, delta: { content: c }, finish_reason: null }] })}\n\n`;
        }
        sse += `data: ${JSON.stringify({ choices: [{ index: 0, delta: {}, finish_reason: 'stop' }] })}\n\n`;
        sse += 'data: [DONE]\n\n';
        res.writeHead(200, { 'content-type': 'text/event-stream' }).end(sse);
        return;
      }
      const messages = Array.isArray(parsed.messages) ? parsed.messages : [];
      const last = messages[messages.length - 1] ?? {};
      let message;
      if (last.role === 'tool') {
        message = { role: 'assistant', content: 'PONG' };
      } else if (Array.isArray(parsed.tools) && parsed.tools.length > 0) {
        message = {
          role: 'assistant',
          content: null,
          tool_calls: [{ id: 'call_selftest_1', type: 'function', function: { name: 'echo_tool', arguments: '{"text":"PONG"}' } }],
        };
      } else if (parsed.reasoning_effort) {
        message = { role: 'assistant', content: '51', reasoning_content: '17 * 3 = 51.' };
      } else {
        message = { role: 'assistant', content: 'PONG' };
      }
      res
        .writeHead(200, { 'content-type': 'application/json' })
        .end(JSON.stringify({ choices: [{ index: 0, message, finish_reason: 'stop' }] }));
    });
  });
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve({ server, port: server.address().port, state }));
  });
}

async function selfTest() {
  let pass = 0;
  let failed = 0;
  const ok = (name, cond, detail = '') => {
    if (cond) {
      pass++;
      process.stdout.write(`PASS self-test: ${name}\n`);
    } else {
      failed++;
      process.stderr.write(`FAIL self-test: ${name}${detail ? ` — ${detail}` : ''}\n`);
    }
  };
  const { server, port } = await mockServer();
  const good = `http://127.0.0.1:${port}/good/v1`;
  const bad = `http://127.0.0.1:${port}/bad/v1`;
  const brokerUrl = `http://127.0.0.1:${port}`;
  const fakeKey = 'sk-probe-selftest-fake';
  try {
    // 1. SSE parser on a synthetic body.
    const parsed = sseSummary(
      'data: {"choices":[{"delta":{"content":"a"},"finish_reason":null}]}\n\n' +
        'data: {"choices":[{"delta":{"content":"b"},"finish_reason":"stop"}]}\n\n' +
        'data: [DONE]\n\n',
    );
    ok('SSE parser counts deltas and sees [DONE]', parsed.deltas === 2 && parsed.done === true && parsed.content === 'ab');

    // 2. Full check suite against a mock provider, key via broker.
    const key = await resolveKey({ brokerUrl, brokerToken: 'test-token' });
    ok('broker hands the probe a key', key === fakeKey);
    const goodResult = await runChecks({ baseUrl: good, key, session: '00000000-0000-4000-8000-000000000000', log: () => {} });
    ok('all real-path checks pass against the mock provider', goodResult.ok === true, JSON.stringify(goodResult.checks));
    ok('probe used exactly 6 requests (budget)', goodResult.requests === 6, `got ${goodResult.requests}`);
    ok(
      'every check ran (models, nonstream, SSE, tool call, tool result, thinking)',
      ['models_lists_model', 'nonstream_pong', 'sse_stream', 'tool_call', 'tool_result_roundtrip', 'thinking_reasoning'].every((n) =>
        goodResult.checks.some((c) => c.name === n && c.ok),
      ),
    );
    ok('probe logs never contain the key', !goodResult.logs.join('\n').includes(fakeKey));
    ok('probe summary never contains the key', !JSON.stringify(goodResult).includes(fakeKey));

    // 3. A wrong reply must fail loudly, naming the check.
    const badResult = await runChecks({ baseUrl: bad, key, log: () => {} });
    ok('a wrong reply fails the probe', badResult.ok === false);
    ok('the failure names nonstream_pong', badResult.checks.some((c) => c.name === 'nonstream_pong' && !c.ok), JSON.stringify(badResult.checks));
    ok('the failure does not leak the key', !JSON.stringify(badResult).includes(fakeKey));

    // 4. Request budget is enforced rather than silently exceeded.
    const budget = await runChecks({ baseUrl: good, key, maxRequests: 2, log: () => {} });
    ok('request budget is enforced', budget.ok === false && /budget/.test(budget.error ?? ''), budget.error);

    // 5. Broker is one-shot; a second fetch fails and nothing prints the key.
    const brokerRes = await fetch(`${brokerUrl}/key`, { headers: { authorization: 'Bearer test-token' } });
    ok('broker key is one-shot (410 on repeat)', brokerRes.status === 410, `got ${brokerRes.status}`);
    let missing = false;
    try {
      await resolveKey({});
    } catch {
      missing = true;
    }
    ok('no credential is a hard error', missing);

    // 6. Stream parse errors are surfaced, not swallowed.
    const broken = sseSummary('data: {not json}\n\n');
    ok('malformed SSE is counted', broken.parseErrors === 1);
  } finally {
    server.close();
  }
  if (failed > 0) {
    process.stderr.write(`self-test: FAIL (${failed}/${pass + failed} checks)\n`);
    return 1;
  }
  process.stdout.write(`self-test: PASS (${pass} checks)\n`);
  return 0;
}

// --------------------------------------------------------------------------- entry

async function main(argv) {
  const { values } = parseArgs({
    args: argv,
    options: {
      'base-url': { type: 'string', default: DEFAULT_BASE_URL },
      model: { type: 'string', default: DEFAULT_MODEL },
      'broker-url': { type: 'string' },
      'broker-token': { type: 'string' },
      session: { type: 'string' },
      'max-requests': { type: 'string', default: '6' },
      'timeout-ms': { type: 'string', default: '180000' },
      'json-out': { type: 'string' },
      'self-test': { type: 'boolean', default: false },
    },
    allowPositionals: false,
  });
  if (values['self-test']) return selfTest();

  let key;
  try {
    key = await resolveKey({ brokerUrl: values['broker-url'], brokerToken: values['broker-token'] });
  } catch (e) {
    process.stderr.write(`[probe] ${redact(e?.message ?? e)}\n`);
    return 2;
  }
  const result = await runChecks({
    baseUrl: values['base-url'],
    key,
    model: values.model,
    session: values.session ?? randomUUID(),
    maxRequests: Number.parseInt(values['max-requests'], 10),
    timeoutMs: Number.parseInt(values['timeout-ms'], 10),
    log: (line) => process.stderr.write(`[probe] ${line}\n`),
  });
  const summary = {
    ok: result.ok,
    error: result.error ?? null,
    base_url: values['base-url'],
    model: result.model,
    session: result.session,
    requests: result.requests,
    checks: result.checks,
  };
  const serialized = JSON.stringify(summary);
  if (values['json-out']) {
    const jsonPath = path.resolve(values['json-out']);
    fs.mkdirSync(path.dirname(jsonPath), { recursive: true });
    fs.writeFileSync(jsonPath, `${JSON.stringify(summary, null, 2)}\n`, { mode: 0o600 });
    fs.chmodSync(jsonPath, 0o600);
  }
  process.stdout.write(`PROBE_RESULT ${serialized}\n`);
  return result.ok ? 0 : 1;
}

const isMain = process.argv[1] != null && path.resolve(process.argv[1]) === path.resolve(new URL(import.meta.url).pathname);
if (isMain) {
  main(process.argv.slice(2))
    .then((code) => process.exit(code))
    .catch((e) => {
      process.stderr.write(`[probe] ${redact(e?.stack ?? e)}\n`);
      process.exit(1);
    });
}
