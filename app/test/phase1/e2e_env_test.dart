// Host-side tests for the L4-Real integration helper (T25).
//
// e2e_env.dart is used by later `integration_test/phase1_real_*.dart` suites.
// It is pure Dart (dart:io), so it can be tested without a simulator: a local
// HttpServer stands in for the credential broker and the provider.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/support/e2e_env.dart';

void main() {
  const fakeKey = 'sk-t25-e2e-env-fake-000000000000';

  group('constants', () {
    test('provider defaults match the Phase 1 acceptance contract', () {
      expect(kE2eProviderBaseUrl, 'https://opencode.ai/inference/go/v1');
      expect(kE2eModel, 'deepseek-v4.1-flash');
      expect(kE2eSessionHeader, 'x-opencode-session');
    });

    test('session ids are UUID v4', () {
      final id = newE2eSessionId();
      expect(id, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
      expect(newE2eSessionId(), isNot(id));
    });
  });

  group('requests', () {
    test('chatRequest carries model, stream, prompt and optional fields', () {
      final body = e2eChatRequest(prompt: 'Reply with exactly PONG', stream: true, maxTokens: 32);
      expect(body['model'], kE2eModel);
      expect(body['stream'], isTrue);
      expect(body['max_tokens'], 32);
      expect(body['messages'], [
        {'role': 'user', 'content': 'Reply with exactly PONG'},
      ]);
      final thinking = e2eChatRequest(prompt: 'think', reasoningEffort: 'max');
      expect(thinking['reasoning_effort'], 'max');
    });

    test('providerHeaders sets bearer, JSON and the session header', () {
      final headers = e2eProviderHeaders(key: fakeKey, session: 'session-1');
      expect(headers['authorization'], 'Bearer $fakeKey');
      expect(headers['content-type'], 'application/json');
      expect(headers[kE2eSessionHeader], 'session-1');
      expect(headers.values, isNot(contains(fakeKey)), reason: 'no header echoes the key twice');
    });
  });

  group('credential broker client', () {
    late HttpServer server;
    late int port;
    late String token;
    var requests = 0;
    var served = false;

    setUp(() async {
      requests = 0;
      served = false;
      token = 'b' * 64;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      port = server.port;
      unawaited(
        server.forEach((req) async {
          requests++;
          if (req.uri.path != '/key') {
            req.response.statusCode = 404;
            await req.response.close();
            return;
          }
          if (req.headers.value(HttpHeaders.authorizationHeader) != 'Bearer $token') {
            req.response.statusCode = 401;
            await req.response.close();
            return;
          }
          if (served) {
            req.response.statusCode = 410;
            await req.response.close();
            return;
          }
          served = true;
          req.response.headers.contentType = ContentType.json;
          req.response.write(jsonEncode({'key': fakeKey}));
          await req.response.close();
        }),
      );
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('fetchKey returns the key once and fails on a repeat (410)', () async {
      final url = 'http://127.0.0.1:$port';
      final key = await fetchBrokerKey(brokerUrl: url, brokerToken: token);
      expect(key, fakeKey);
      await expectLater(
        fetchBrokerKey(brokerUrl: url, brokerToken: token),
        throwsA(isA<E2eHarnessError>().having((e) => e.message, 'message', contains('410'))),
      );
      expect(requests, 2);
    });

    test('fetchKey fails on a wrong token without echoing the token or key', () async {
      final url = 'http://127.0.0.1:$port';
      try {
        await fetchBrokerKey(brokerUrl: url, brokerToken: 'wrong-token');
        fail('expected E2eHarnessError');
      } on E2eHarnessError catch (e) {
        expect(e.message, contains('401'));
        expect(e.message, isNot(contains('wrong-token')));
        expect(e.message, isNot(contains(fakeKey)));
      }
    });

    test('fetchKey refuses non-loopback broker URLs before connecting', () async {
      await expectLater(
        fetchBrokerKey(brokerUrl: 'http://example.com:8080', brokerToken: token),
        throwsA(isA<E2eHarnessError>().having((e) => e.message, 'message', contains('loopback'))),
      );
      expect(requests, 0);
    });

    test('fetchKey rejects a broker response without a key', () async {
      final empty = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => empty.close(force: true));
      unawaited(
        empty.forEach((req) async {
          req.response.headers.contentType = ContentType.json;
          req.response.write('{"nope":true}');
          await req.response.close();
        }),
      );
      await expectLater(
        fetchBrokerKey(brokerUrl: 'http://127.0.0.1:${empty.port}', brokerToken: token),
        throwsA(isA<E2eHarnessError>().having((e) => e.message, 'message', contains('no key'))),
      );
    });
  });

  group('provider client', () {
    test('sendE2eChat posts JSON and returns the decoded reply', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      String? seenAuth;
      String? seenSession;
      Map<String, Object?>? seenBody;
      unawaited(
        server.forEach((req) async {
          seenAuth = req.headers.value(HttpHeaders.authorizationHeader);
          seenSession = req.headers.value(kE2eSessionHeader);
          seenBody = (jsonDecode(await utf8.decoder.bind(req).join()) as Map).cast<String, Object?>();
          req.response.headers.contentType = ContentType.json;
          req.response.write(
            jsonEncode({
              'choices': [
                {
                  'message': {'role': 'assistant', 'content': 'PONG'},
                  'finish_reason': 'stop',
                },
              ],
            }),
          );
          await req.response.close();
        }),
      );
      final json = await sendE2eChat(
        key: fakeKey,
        session: 'session-2',
        baseUrl: 'http://127.0.0.1:${server.port}',
        body: e2eChatRequest(prompt: 'Reply with exactly PONG'),
      );
      expect(seenAuth, 'Bearer $fakeKey');
      expect(seenSession, 'session-2');
      expect(seenBody?['model'], kE2eModel);
      expect(e2eReplyText(json), 'PONG');
    });

    test('sendE2eChat surfaces an HTTP status without leaking the key', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      unawaited(
        server.forEach((req) async {
          req.response.statusCode = 500;
          req.response.write('{"error":"boom"}');
          await req.response.close();
        }),
      );
      try {
        await sendE2eChat(
          key: fakeKey,
          baseUrl: 'http://127.0.0.1:${server.port}',
          body: e2eChatRequest(prompt: 'x'),
        );
        fail('expected E2eHarnessError');
      } on E2eHarnessError catch (e) {
        expect(e.message, contains('500'));
        expect(e.message, isNot(contains(fakeKey)));
      }
    });

    test('SSE deltas are parsed without dropping reasoning or finish', () {
      final reply = parseE2eSse(
        'data: {"choices":[{"delta":{"reasoning_content":"think "},"finish_reason":null}]}\n\n'
        'data: {"choices":[{"delta":{"content":"PO"},"finish_reason":null}]}\n\n'
        'data: {"choices":[{"delta":{"content":"NG"},"finish_reason":"stop"}]}\n\n'
        'data: [DONE]\n\n',
      );
      expect(reply.content, 'PONG');
      expect(reply.deltas, 2);
      expect(reply.reasoning, 'think ');
      expect(reply.finishReason, 'stop');
      expect(reply.done, isTrue);
    });
  });
}
