// T26 · D3-01/PERSIST-01: a new-chat send survives an engine restart.
//
// D3-01-AC1: the first message creates the session, selects it and starts the
//            turn.
// PERSIST-01-AC2: stopping and starting the engine (same app process) leaves
//            the app able to continue; a send that raced the stop must not be
//            lost.
//
// The defect this file pins: while `session/create` for a new chat is in
// flight the active connection generation changes (engine stop → start), so
// the create rejects as superseded. The composer must wait for the new ready
// connection, retry creation exactly once and still deliver the draft, its
// attachments and its quote. Before the fix the send returned silently: no
// session, no prompt, the turn never started.
//
// This is an app-controller behavior test on the real ChatScreen; the Host is
// a fake controller that changes the connection at the exact moment the
// create is superseded.

import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/state/composer_quote.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/widgets/notice_row.dart' show ErrorBanner;
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/harness.dart';

/// The active host's connection, which a test can stop and start.
class _Connection extends Notifier<HostConnection?> {
  _Connection(this.initial);

  final HostConnection initial;

  @override
  HostConnection? build() => initial;

  void select(HostConnection? next) => state = next;
}

final _connectionProvider = NotifierProvider<_Connection, HostConnection?>(() => throw UnimplementedError());

HostConnection _host() =>
    HostConnection(client: DshClient(DshConnection(Uri.parse('http://127.0.0.1:9'))), isLocal: true);

/// A session controller whose first create is superseded by an engine stop →
/// start; every later create succeeds unless [secondFailure] says otherwise.
class _SupersededSessions extends FakeSessions {
  _SupersededSessions({required this.nextConnection, this.secondFailure});

  final HostConnection nextConnection;
  final Object? secondFailure;
  var attempts = 0;

  /// Which connection each create ran on, in order.
  final attemptClients = <DshClient?>[];
  final createdSessions = <String>[];

  @override
  Future<String> create({bool autoApprove = true}) async {
    attempts++;
    attemptClients.add(ref.read(activeConnectionProvider).value?.client);
    if (attempts == 1) {
      // The engine is stopped under the in-flight create; the app then
      // reconnects to the restarted engine before the request is rejected.
      ref.read(_connectionProvider.notifier).select(null);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      ref.read(_connectionProvider.notifier).select(nextConnection);
      throw const DshClosedException('session creation superseded');
    }
    if (secondFailure case final failure?) throw failure;
    createdSessions.add(created);
    return created;
  }
}

Future<(ChatHarness, ProviderContainer)> _pump(
  WidgetTester tester, {
  required HostConnection first,
  required _SupersededSessions sessions,
}) async {
  usePhoneView(tester);
  mockClipboard(tester);
  SharedPreferences.setMockInitialValues({});
  final harness = ChatHarness();
  await tester.pumpWidget(
    testApp(
      const ChatScreen(),
      overrides: <Override>[
        for (final override in harness.overrides)
          if (override.origin != activeConnectionProvider && override.origin != sessionsProvider) override,
        _connectionProvider.overrideWith(() => _Connection(first)),
        activeConnectionProvider.overrideWith((ref) => AsyncData(ref.watch(_connectionProvider))),
        sessionsProvider.overrideWith(() => sessions),
      ],
    ),
  );
  await pumpFrames(tester);
  return (harness, ProviderScope.containerOf(tester.element(find.byType(ChatScreen))));
}

void _closeHosts(WidgetTester tester, Iterable<HostConnection> hosts) {
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    for (final host in hosts) {
      await host.client.close();
    }
  });
}

String _input(WidgetTester tester) => tester.widget<TextField>(find.byType(TextField)).controller?.text ?? '';

Future<void> _sendByKeyboard(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await pumpFrames(tester);
}

Future<void> _attachFile(WidgetTester tester, ChatHarness harness, DraftAttachment file) async {
  harness.picker.files = [file];
  await tester.tap(find.bySemanticsLabel('添加图片或文件'));
  await pumpFrames(tester);
  await tester.tap(find.text('文件'));
  await pumpFrames(tester);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('D3-01_new_chat_send_retries_after_engine_restart', (tester) async {
    const prompt = '重启中也要发出这条';
    const quote = '重启前引用的一段';
    final first = _host();
    final restarted = _host();
    final sessions = _SupersededSessions(nextConnection: restarted);
    final (harness, container) = await _pump(tester, first: first, sessions: sessions);
    _closeHosts(tester, [first, restarted]);

    final file = DraftAttachment.sniff('keep.txt', Uint8List.fromList('kept'.codeUnits));
    await _attachFile(tester, harness, file);
    container.read(composerQuoteProvider.notifier).set('new', quote);
    await tester.enterText(find.byType(TextField), prompt);
    await tester.pump();

    await _sendByKeyboard(tester);
    // Let the fake Host's restart delay elapse and the retry run.
    await pumpFrames(tester, 20);

    expect(sessions.attempts, 2, reason: 'D3-01-AC1: the superseded create is retried exactly once, not looped');
    expect(sessions.attemptClients, [
      first.client,
      restarted.client,
    ], reason: 'PERSIST-01-AC2: the retry runs on the new ready connection');
    expect(sessions.createdSessions, [
      sessions.created,
    ], reason: 'D3-01-AC1: exactly one session is created, and never a duplicate');
    expect(
      container.read(currentSessionProvider),
      sessions.created,
      reason: 'D3-01-AC1: the recovered session is the open conversation',
    );

    final chat = harness.controllers[sessions.created];
    expect(chat, isNotNull, reason: 'D3-01-AC1: the turn controller exists for the created session');
    expect(chat!.sent, hasLength(1), reason: 'D3-01-AC1: the first prompt is delivered once');
    expect(chat.sent.single, contains(prompt));
    expect(chat.sent.single, contains(quote), reason: 'the quote survives the restart');
    expect(chat.sentAttachments.single.map((attachment) => attachment.name), [
      'keep.txt',
    ], reason: 'the attachment survives the restart');
    expect(_input(tester), isEmpty, reason: 'the composer clears only once the prompt is accepted');
    expect(find.byType(ErrorBanner), findsNothing, reason: 'a recovered send shows no failure');
    expect(tester.takeException(), isNull);
  });

  testWidgets('D3-01_restart_retry_failure_shows_error_and_keeps_draft', (tester) async {
    const prompt = '重试失败也要留住';
    final first = _host();
    final restarted = _host();
    final sessions = _SupersededSessions(
      nextConnection: restarted,
      secondFailure: const DshRemoteException('session/create-failed', 'mock create failure'),
    );
    final (harness, container) = await _pump(tester, first: first, sessions: sessions);
    _closeHosts(tester, [first, restarted]);

    await tester.enterText(find.byType(TextField), prompt);
    await tester.pump();
    await _sendByKeyboard(tester);
    await pumpFrames(tester, 20);

    expect(sessions.attempts, 2, reason: 'one retry, then the real failure is reported');
    expect(find.byType(ErrorBanner), findsOneWidget, reason: 'the failure is shown, not swallowed');
    final message = tester.widget<ErrorBanner>(find.byType(ErrorBanner)).message;
    expect(message, contains('新建对话失败'), reason: 'the error names the failed action');
    expect(_input(tester), prompt, reason: 'D3-01 错误/边界: 发送失败保留输入内容');
    expect(container.read(currentSessionProvider), isNull);
    expect(harness.controllers, isEmpty, reason: 'no prompt is handed to a chat controller');
    expect(tester.takeException(), isNull);
  });
}
