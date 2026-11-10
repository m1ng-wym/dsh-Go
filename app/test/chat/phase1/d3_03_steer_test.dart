// D3-03 · 插话（steer）（capability-spec.md#D3-03，spec-phase1-v1）
//
// D3-03-AC1: while a turn runs, sending a message directly shows it at the
//            bottom of the conversation, does not interrupt the turn, and the
//            next request carries it (steer semantics).
// D3-03-AC2: when that send fails (connection lost), the text goes back into
//            the composer with a prompt; it is not lost.
//
// The state tests drive the real ChatController over a scripted Host; the
// widget test renders the state that controller produced. The real engine's
// next request containing the steer text is L4 (T22): no Engine artifact is
// available in this worktree, so it is recorded as deferred.

import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';
import 'support/w2_client.dart';

Future<void> _pumpState(WidgetTester tester, ChatState state) async {
  usePhoneView(tester);
  mockClipboard(tester);
  final harness = ChatHarness(session: w2Session, states: {w2Session: state});
  await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
  await pumpFrames(tester);
}

/// A fake controller whose failed send also shows the send error, as the real
/// controller does. The ordinary harness fake only records calls.
class _FailingSendController extends FakeChatController {
  _FailingSendController(super.sessionId, super.initial);

  @override
  Future<bool> send(
    String text, {
    List<DraftAttachment> attachments = const [],
    SendMode mode = SendMode.now,
    bool verbatim = false,
    Future<bool> Function(String requestId)? beforeDeliver,
    bool Function()? deliveryAllowed,
  }) async {
    final ok = await super.send(
      text,
      attachments: attachments,
      mode: mode,
      verbatim: verbatim,
      beforeDeliver: beforeDeliver,
      deliveryAllowed: deliveryAllowed,
    );
    if (!ok) state = state.copyWith(error: '发送失败:连接已断开');
    return ok;
  }
}

void main() {
  test('D3-03_steer_does_not_abort_turn', () async {
    final client = W2Client();
    final container = await startW2Chat(
      client,
      running: true,
      snapshot: w2Snapshot(
        records: [w2Record(w2User(0, '把项目跑起来')), w2Record(w2Reply(1, '正在运行测试'))],
      ),
    );
    addTearDown(() async {
      container.dispose();
      await client.events.close();
    });

    final before = w2State(container);
    expect(before.running, isTrue, reason: 'D3-03-AC1: baseline turn is running');
    expect(before.items.whereType<AssistantChatItem>().single.text, '正在运行测试');

    final ok = await w2Chat(container).send('用 pnpm 别用 npm');
    await settleW2(container);

    expect(ok, isTrue);
    expect(client.cancels, 0, reason: 'D3-03-AC1: a steer must not stop the running turn');
    final prompt = client.prompts.single;
    expect(prompt.text, '用 pnpm 别用 npm');
    expect(
      prompt.mode,
      PromptMode.steer,
      reason: 'D3-03-AC1: the prompt joins the turn at its next step (the engine puts it in the next request)',
    );

    final state = w2State(container);
    expect(state.running, isTrue, reason: 'D3-03-AC1: generation goes on');
    expect(state.pending, hasLength(1), reason: 'D3-03-AC1: the message is shown while it waits');
    expect(state.pending.single.text, '用 pnpm 别用 npm');
    expect(state.pending.single.mode, SendMode.steer);
    expect(state.error, isNull);
  });

  testWidgets('D3-03_steer_shows_at_the_bottom_of_the_conversation', (tester) async {
    final client = W2Client();
    late ChatState state;
    // Real timers belong in runAsync; the widget clock is fake.
    await tester.runAsync(() async {
      final container = await startW2Chat(
        client,
        running: true,
        snapshot: w2Snapshot(
          records: [w2Record(w2User(0, '把项目跑起来')), w2Record(w2Reply(1, '正在运行测试'))],
        ),
      );
      addTearDown(() async {
        container.dispose();
        await client.events.close();
      });
      await w2Chat(container).send('用 pnpm 别用 npm');
      await settleW2(container);
      state = w2State(container);
    });

    await _pumpState(tester, state);
    final answer = tester.getTopLeft(find.textContaining('正在运行测试', findRichText: true).first);
    final steer = tester.getTopLeft(find.text('用 pnpm 别用 npm'));
    expect(
      steer.dy,
      greaterThan(answer.dy),
      reason: 'D3-03-AC1: the interjection is shown at the bottom of the conversation',
    );
    expect(find.text('插话中'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('D3-03_steer_failure_restores_draft', () async {
    final client = W2Client();
    final container = await startW2Chat(client, running: true);
    addTearDown(() async {
      container.dispose();
      await client.events.close();
    });

    client.promptError = const DshTransportException('mock connection lost');
    final ok = await w2Chat(container).send('用 pnpm 别用 npm');
    await settleW2(container);

    expect(ok, isFalse, reason: 'D3-03-AC2: a failed steer resolves to false so the screen can restore the text');
    final state = w2State(container);
    expect(state.pending, isEmpty, reason: 'D3-03-AC2: the failed bubble does not stay in the conversation');
    expect(state.error, isNotNull, reason: 'D3-03-AC2: the person is told the send failed');
    expect(state.error, contains('发送失败'));
    expect(state.running, isTrue, reason: 'D3-03-AC2: the turn keeps going');
    expect(client.cancels, 0);
  });

  testWidgets('D3-03_steer_failure_restores_draft_2', (tester) async {
    usePhoneView(tester);
    mockClipboard(tester);
    final harness = ChatHarness(
      session: w2Session,
      states: {w2Session: const ChatState(loading: false, running: true)},
      controllerFactory: _FailingSendController.new,
    );
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await pumpFrames(tester);

    await tester.enterText(find.byType(TextField), '用 pnpm 别用 npm');
    await pumpFrames(tester, 2);
    harness.controllers[w2Session]!.sendResult = Future.value(false);
    await tester.tap(find.byIcon(AppIcons.send));
    await pumpFrames(tester);

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, '用 pnpm 别用 npm', reason: 'D3-03-AC2: the message goes back into the composer');
    expect(find.text('发送失败:连接已断开'), findsOneWidget, reason: 'D3-03-AC2: the failure is visible');
    expect(harness.controllers[w2Session]!.sent, ['用 pnpm 别用 npm']);
    expect(tester.takeException(), isNull);
  });
}
