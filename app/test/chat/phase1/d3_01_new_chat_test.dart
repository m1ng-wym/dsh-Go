// D3-01 · 新对话与首条消息建会话（capability-spec.md#D3-01，spec-phase1-v1）
//
// D3-01-AC1: opening a new chat shows the composer + empty state and creates
//            nothing; the first send creates the session, selects it, and sends
//            the prompt. The created session is the one the drawer lists.
// D3-01-AC2: without a usable host (or when creation fails) the composer stays
//            usable and the person gets a clear guidance/error, never a crash;
//            a failed send keeps what they typed.
//
// These are behavior tests on the real ChatScreen + composer: no channel is
// mocked, and the Host is a fake controller (no "only assert the mock was
// called" — every expect is on the screen or on user-visible state).

import 'package:dsh_app/state/chat_state.dart';
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

/// A session list that behaves like the Host's: a create adds the new session
/// to the list the drawer renders.
class _RecordingSessions extends FakeSessions {
  final createdIds = <String>[];

  @override
  Future<String> create({bool autoApprove = true}) async {
    final id = await super.create(autoApprove: autoApprove);
    createdIds.add(id);
    state = AsyncData([
      ...?state.value,
      SessionSummary(
        sessionId: id,
        updatedAt: DateTime(2026, 11, 10, 9),
        running: false,
        blank: true,
        agentAvailable: true,
      ),
    ]);
    return id;
  }
}

/// `session/create` fails, as the Host can when it is going away.
class _FailingSessions extends FakeSessions {
  var attempts = 0;

  @override
  Future<String> create({bool autoApprove = true}) async {
    attempts++;
    throw const DshRemoteException('session/create-failed', 'mock create failure');
  }
}

Future<ChatHarness> _pump(
  WidgetTester tester, {
  String? session,
  Map<String, ChatState> states = const {},
  bool connected = true,
  SessionsController Function()? sessions,
}) async {
  usePhoneView(tester);
  mockClipboard(tester);
  final harness = ChatHarness(session: session, states: states, connected: connected);
  final overrides = <Override>[
    for (final override in harness.overrides)
      if (sessions == null || override.origin != sessionsProvider) override,
    if (sessions != null) sessionsProvider.overrideWith(sessions),
  ];
  await tester.pumpWidget(testApp(const ChatScreen(), overrides: overrides));
  await pumpFrames(tester);
  return harness;
}

ProviderContainer _container(WidgetTester tester) => ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));

String _input(WidgetTester tester) => tester.widget<TextField>(find.byType(TextField)).controller?.text ?? '';

/// Ctrl+Enter in the composer: the hardware send path (session_creation_scope
/// uses the same gesture).
Future<void> _sendByKeyboard(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await pumpFrames(tester);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('D3-01-AC1 新对话', () {
    testWidgets('D3-01_new_chat_shows_composer_and_creates_nothing', (tester) async {
      final sessions = _RecordingSessions();
      final harness = await _pump(tester, sessions: () => sessions);

      expect(find.byType(TextField), findsOneWidget, reason: 'D3-01-AC1: the composer is already usable');
      expect(
        tester.widget<TextField>(find.byType(TextField)).enabled,
        isNot(false),
        reason: 'D3-01-AC1: the input is usable before a session exists',
      );
      expect(sessions.creates, 0, reason: 'D3-01-AC1: opening a new chat must not create a session');
      expect(sessions.createdIds, isEmpty);
      expect(_container(tester).read(currentSessionProvider), isNull);
      expect(harness.sessions.creates, 0);
    });

    testWidgets('D3-01_first_message_creates_session_and_sends_prompt', (tester) async {
      const prompt = '帮我看看测试为什么失败';
      final sessions = _RecordingSessions();
      final harness = await _pump(tester, sessions: () => sessions);

      await tester.enterText(find.byType(TextField), prompt);
      await tester.pump();
      await _sendByKeyboard(tester);

      expect(sessions.creates, 1, reason: 'D3-01-AC1: the first message is what creates the session');
      expect(sessions.createdIds, [harness.sessions.created]);
      final container = _container(tester);
      expect(
        container.read(currentSessionProvider),
        harness.sessions.created,
        reason: 'D3-01-AC1: the new session is the open conversation',
      );
      final listed = container.read(sessionsProvider).value ?? const <SessionSummary>[];
      expect(
        listed.map((s) => s.sessionId),
        contains(harness.sessions.created),
        reason: 'D3-01-AC1: the created session appears in the session list',
      );
      final chat = harness.controllers[harness.sessions.created];
      expect(chat, isNotNull);
      expect(chat!.sent, [prompt], reason: 'D3-01-AC1: the first prompt starts the turn');
      expect(_input(tester), isEmpty, reason: 'the composer is cleared once the prompt is accepted');
      expect(tester.takeException(), isNull);
    });

    testWidgets('D3-01_empty_input_does_not_create_or_send', (tester) async {
      final sessions = _RecordingSessions();
      final harness = await _pump(tester, sessions: () => sessions);

      await _sendByKeyboard(tester);
      expect(sessions.creates, 0, reason: 'D3-01 错误/边界: 空输入不可发送');
      expect(harness.controllers, isEmpty);

      await tester.enterText(find.byType(TextField), '   ');
      await tester.pump();
      await _sendByKeyboard(tester);
      expect(sessions.creates, 0, reason: 'D3-01 错误/边界: 只有空白也不可发送');
      expect(tester.takeException(), isNull);
    });
  });

  group('D3-01-AC2 不可用主机与失败', () {
    testWidgets('D3-01_send_without_host_shows_error', (tester) async {
      final sessions = _RecordingSessions();
      final harness = await _pump(tester, connected: false, sessions: () => sessions);

      // Guidance is on screen before the attempt, and the input stays usable.
      expect(find.text('引擎未连接'), findsOneWidget, reason: 'D3-01-AC2: no host is explained on the new chat');
      expect(find.text('连接引擎后即可发送'), findsOneWidget, reason: 'D3-01-AC2: the composer says what sending needs');
      expect(
        tester.widget<TextField>(find.byType(TextField)).enabled,
        isNot(false),
        reason: 'D3-01-AC2: the input is usable without a host',
      );

      await tester.enterText(find.byType(TextField), '连上再发');
      await tester.pump();
      await _sendByKeyboard(tester);

      expect(sessions.creates, 0, reason: 'D3-01-AC2: nothing is created without a host');
      expect(harness.controllers, isEmpty, reason: 'D3-01-AC2: no prompt is handed to a chat controller');
      expect(_input(tester), '连上再发', reason: 'the draft survives the blocked send');
      expect(find.text('连接引擎后即可发送'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'D3-01-AC2: no crash');
    });

    testWidgets('D3-01_create_failure_shows_error_and_keeps_input', (tester) async {
      const prompt = '这条要保住';
      final failing = _FailingSessions();
      await _pump(tester, sessions: () => failing);

      await tester.enterText(find.byType(TextField), prompt);
      await tester.pump();
      await _sendByKeyboard(tester);

      expect(failing.attempts, 1, reason: 'D3-01-AC2: one attempt, no retry loop');
      expect(find.byType(ErrorBanner), findsOneWidget, reason: 'D3-01-AC2: the failure is shown, not swallowed');
      final message = tester.widget<ErrorBanner>(find.byType(ErrorBanner)).message;
      expect(message, contains('新建对话失败'), reason: 'D3-01-AC2: the error names the failed action');
      expect(_input(tester), prompt, reason: 'D3-01 错误/边界: 发送失败保留输入内容');
      expect(_container(tester).read(currentSessionProvider), isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('D3-01_send_failure_keeps_draft', (tester) async {
      const prompt = '发送失败也要留住';
      final harness = await _pump(tester, session: 's1', states: const {'s1': ChatState(loading: false)});
      harness.controllers['s1']!.sendResult = Future<bool>.value(false);

      await tester.enterText(find.byType(TextField), prompt);
      await tester.pump();
      await _sendByKeyboard(tester);

      expect(harness.controllers['s1']!.sent, [prompt]);
      expect(_input(tester), prompt, reason: 'D3-01 错误/边界: 发送失败保留输入内容');
      expect(tester.takeException(), isNull);
    });
  });
}
