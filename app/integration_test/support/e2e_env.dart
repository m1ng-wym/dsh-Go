// Helpers for the L4-Real Phase 1 integration suites (T25).
//
// These suites run on a simulator against the real opencode-go provider. The
// key follows the acceptance rule (test-plan §1.1): it is fetched at run time
// from the loopback credential broker started by `scripts/e2e/*`, never read
// from a file in the repo and never printed, logged or asserted on.
//
// The broker URL/token are compile-time defines:
//
//   flutter test integration_test/phase1_real_*.dart \
//     --dart-define=E2E_BROKER_URL=http://127.0.0.1:PORT \
//     --dart-define=E2E_BROKER_TOKEN=<64 hex>
//
// Everything here is test-only infrastructure; no product code imports it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// opencode-go OpenAI-compatible endpoint used by Phase 1 acceptance.
const kE2eProviderBaseUrl = 'https://opencode.ai/inference/go/v1';

/// The pinned acceptance model.
const kE2eModel = 'deepseek-v4.1-flash';

/// Required opencode-go session header (a UUID per logical session).
const kE2eSessionHeader = 'x-opencode-session';

/// A harness precondition failed. Messages never contain a key or token.
class E2eHarnessError implements Exception {
  const E2eHarnessError(this.message);

  final String message;

  @override
  String toString() => 'E2eHarnessError: $message';
}

/// Compile-time configuration for the real suites.
class E2eConfig {
  const E2eConfig._();

  static const brokerUrl = String.fromEnvironment('E2E_BROKER_URL');
  static const brokerToken = String.fromEnvironment('E2E_BROKER_TOKEN');
  static const providerBaseUrl = String.fromEnvironment('E2E_PROVIDER_BASE_URL', defaultValue: kE2eProviderBaseUrl);
  static const model = String.fromEnvironment('E2E_MODEL', defaultValue: kE2eModel);

  static bool get hasBroker => brokerUrl.isNotEmpty && brokerToken.isNotEmpty;

  static void requireBroker() {
    if (!hasBroker) {
      throw const E2eHarnessError(
        'E2E_BROKER_URL and E2E_BROKER_TOKEN must be passed with --dart-define '
        '(start the broker with scripts/e2e/credential_broker.mjs)',
      );
    }
  }
}

bool _isLoopbackHost(String host) => host == '127.0.0.1' || host == '::1' || host == 'localhost';

/// Random UUID v4 for [kE2eSessionHeader].
String newE2eSessionId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// Fetches the provider key from the loopback credential broker (one-shot).
///
/// The broker is deliberately loopback-only: refuse any other host so the
/// bearer token cannot be sent to a remote endpoint by accident.
Future<String> fetchBrokerKey({
  String? brokerUrl,
  String? brokerToken,
  Duration timeout = const Duration(seconds: 15),
  HttpClient? httpClient,
}) async {
  final url = (brokerUrl ?? E2eConfig.brokerUrl).trim();
  final token = (brokerToken ?? E2eConfig.brokerToken).trim();
  if (url.isEmpty || token.isEmpty) {
    throw const E2eHarnessError('credential broker URL/token are empty (see E2eConfig.requireBroker)');
  }
  final Uri base;
  try {
    base = Uri.parse(url);
  } on FormatException {
    throw const E2eHarnessError('credential broker URL is not a valid URI');
  }
  if (base.scheme != 'http' || !_isLoopbackHost(base.host)) {
    throw const E2eHarnessError('credential broker must be plain HTTP on loopback (127.0.0.1/localhost)');
  }
  final uri = Uri(scheme: 'http', host: base.host, port: base.hasPort ? base.port : null, path: '/key');
  final client = httpClient ?? HttpClient()
    ..connectionTimeout = timeout;
  final owned = httpClient == null;
  try {
    final request = await client.getUrl(uri).timeout(timeout);
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    final response = await request.close().timeout(timeout);
    final body = await response.transform(utf8.decoder).join().timeout(timeout);
    if (response.statusCode != HttpStatus.ok) {
      throw E2eHarnessError('credential broker returned HTTP ${response.statusCode}');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const E2eHarnessError('credential broker returned invalid JSON');
    }
    final key = decoded is Map ? decoded['key'] : null;
    if (key is! String || key.trim().isEmpty) {
      throw const E2eHarnessError('credential broker response has no key');
    }
    return key.trim();
  } on E2eHarnessError {
    rethrow;
  } on TimeoutException {
    throw const E2eHarnessError('credential broker timed out');
  } on SocketException {
    throw const E2eHarnessError('credential broker is unreachable on loopback');
  } finally {
    if (owned) client.close(force: true);
  }
}

/// Headers for a real provider request. The key is only in Authorization.
Map<String, String> e2eProviderHeaders({required String key, String? session}) => {
  HttpHeaders.authorizationHeader: 'Bearer $key',
  HttpHeaders.contentTypeHeader: 'application/json',
  kE2eSessionHeader: session ?? newE2eSessionId(),
};

/// OpenAI-compatible chat body for a real prompt.
Map<String, Object?> e2eChatRequest({
  required String prompt,
  bool stream = false,
  int maxTokens = 256,
  String? model,
  String? system,
  List<Map<String, Object?>>? messages,
  List<Map<String, Object?>>? tools,
  String? reasoningEffort,
}) {
  final list = messages != null
      ? List<Map<String, Object?>>.of(messages)
      : <Map<String, Object?>>[
          if (system != null && system.trim().isNotEmpty) {'role': 'system', 'content': system},
          {'role': 'user', 'content': prompt},
        ];
  return {
    'model': model ?? E2eConfig.model,
    'stream': stream,
    'max_tokens': maxTokens,
    'messages': list,
    'tools': ?tools,
    'reasoning_effort': ?reasoningEffort,
  };
}

/// POSTs one chat completion and returns the decoded JSON object.
///
/// Errors carry the HTTP status only: no key, URL or response body.
Future<Map<String, Object?>> sendE2eChat({
  required String key,
  required Map<String, Object?> body,
  String? baseUrl,
  String? session,
  Duration timeout = const Duration(seconds: 120),
  HttpClient? httpClient,
}) async {
  final base = (baseUrl ?? E2eConfig.providerBaseUrl).replaceFirst(RegExp(r'/+$'), '');
  final uri = Uri.parse('$base/chat/completions');
  final client = httpClient ?? HttpClient()
    ..connectionTimeout = timeout;
  final owned = httpClient == null;
  try {
    final request = await client.postUrl(uri).timeout(timeout);
    e2eProviderHeaders(key: key, session: session).forEach(request.headers.set);
    request.add(utf8.encode(jsonEncode(body)));
    final response = await request.close().timeout(timeout);
    final text = await response.transform(utf8.decoder).join().timeout(timeout);
    if (response.statusCode != HttpStatus.ok) {
      throw E2eHarnessError('provider returned HTTP ${response.statusCode}');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const E2eHarnessError('provider returned invalid JSON');
    }
    if (decoded is! Map) throw const E2eHarnessError('provider returned a non-object JSON body');
    return decoded.cast<String, Object?>();
  } on E2eHarnessError {
    rethrow;
  } on TimeoutException {
    throw const E2eHarnessError('provider request timed out');
  } on SocketException {
    throw const E2eHarnessError('provider is unreachable');
  } finally {
    if (owned) client.close(force: true);
  }
}

/// Assistant text from a chat-completions response (empty when absent).
String e2eReplyText(Map<String, Object?> json) {
  final choices = json['choices'];
  if (choices is! List || choices.isEmpty) return '';
  final first = choices.first;
  if (first is! Map) return '';
  final message = first['message'];
  if (message is! Map) return '';
  final content = message['content'];
  return content is String ? content.trim() : '';
}

/// Parsed SSE reply (text deltas, reasoning, tool calls, finish marker).
class E2eSseReply {
  const E2eSseReply({
    required this.content,
    required this.deltas,
    required this.reasoning,
    required this.finishReason,
    required this.done,
    required this.toolCalls,
  });

  final String content;
  final int deltas;
  final String reasoning;
  final String? finishReason;
  final bool done;
  final List<Object?> toolCalls;
}

/// Parses OpenAI-style SSE (`data: {...}` + `data: [DONE]`) for real suites.
E2eSseReply parseE2eSse(String text) {
  var content = '';
  var reasoning = '';
  var deltas = 0;
  String? finish;
  var done = false;
  final toolCalls = <Object?>[];
  for (final block in text.split(RegExp(r'\r?\n\r?\n'))) {
    final data = block
        .split(RegExp(r'\r?\n'))
        .where((line) => line.startsWith('data:'))
        .map((line) => line.substring(5).trim())
        .join('\n');
    if (data.isEmpty) continue;
    if (data == '[DONE]') {
      done = true;
      continue;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(data);
    } on FormatException {
      throw const E2eHarnessError('provider sent an unparseable SSE event');
    }
    if (decoded is! Map) continue;
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) continue;
    final choice = choices.first;
    if (choice is! Map) continue;
    if (choice['finish_reason'] is String) finish = choice['finish_reason'] as String;
    final delta = choice['delta'];
    if (delta is! Map) continue;
    final chunk = delta['content'];
    if (chunk is String && chunk.isNotEmpty) {
      content += chunk;
      deltas++;
    }
    final think = delta['reasoning_content'];
    if (think is String) reasoning += think;
    final calls = delta['tool_calls'];
    if (calls is List) toolCalls.addAll(calls);
  }
  return E2eSseReply(
    content: content,
    deltas: deltas,
    reasoning: reasoning,
    finishReason: finish,
    done: done,
    toolCalls: toolCalls,
  );
}
