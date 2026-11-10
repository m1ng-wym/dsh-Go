// D3-04 · 排队发送 / 立即发送 / 改为插话 / 撤回（capability-spec.md#D3-04）
//
// D3-04-AC1: while a turn runs, 「排队」 puts the message in the bottom queue
//            area; when the turn ends the queued message starts the next turn
//            (the engine takes it out of the inbox; the app must send it once
//            and not duplicate it).
// D3-04-AC2: 「立即发送」/「改为插话」/「撤回」 respectively send it now, turn it
//            into a steer, or return it to the composer — consistently, with
//            no duplicate send.
//
// The inbox is seeded exactly as DSH's `projections.inbox` reports it, so the
// queue actions run against the real controller and the real `session/updateQueue`.

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';
import 'support/w2_client.dart';

Map<String, Object?> _queuedSnapshot() => w2Snapshot(
  records: [w2Record(w2User(0, '把项目跑起来')), w2Record(w2Reply(1, '正在运行测试'))],
  inbox: {
    'next-turn': [
      w2Queued('q1', '顺便把 README 也改了', requestId: 'r-q1'),
    ],
    'next-step': [],
  },
);

void main() {
  test('D3-04_queued_message_sends_after_turn', () async {
    final client = W2Client();
    final container = await startW2Chat(client, running: true);
    addTearDown(() async {
      container.dispose();
      await client.events.close();
    });

    final ok = await w2Chat(container).send('顺便把 README 也改了', mode: SendMode.queue);
    await settleW2(container);
    expect(ok, isTrue);
    final prompt = client.prompts.single;
    expect(
      prompt.mode,
      PromptMode.queue,
      reason: 'D3-04-AC1: a queued prompt waits for the running turn to finish',
    );
    expect(client.cancels, 0, reason: 'D3-04-AC1: queueing must not stop the turn');
    expect(w2State(container).pending.single.mode, SendMode.queue);
    expect(w2State(container).running, isTrue);

    // The turn ends. The engine starts the next turn with the queued prompt;
    // its echo lands on the same optimistic bubble.
    client.events.add(SessionLogEvent.fromJson(w2User(2, '顺便把 README 也改了', requestId: prompt.requestId!)));
    client.events.add(const SessionStatusEvent(w2Session, false));
    await settleW2(container);
    expect(w2State(container).running, isFalse);
    expect(w2State(container).pending, isEmpty, reason: 'D3-04-AC1: the echo settles the queued bubble');

    client.events.add(const SessionStatusEvent(w2Session, true));
    await settleW2(container);
    expect(w2State(container).running, isTrue, reason: 'D3-04-AC1: the queued message started the next turn');
    expect(
      client.prompts,
      hasLength(1),
      reason: 'D3-04-AC1: the queued message is sent exactly once (the engine takes it from the inbox)',
    );
  });

  test('D3-04_queue_actions_do_not_duplicate', () async {
    final client = W2Client();
    final container = await startW2Chat(client, running: true, snapshot: _queuedSnapshot());
    addTearDown(() async {
      container.dispose();
      await client.events.close();
    });

    final queued = w2State(container).pending.single;
    expect(queued.inboxId, 'q1');
    expect(queued.mode, SendMode.queue);

    // 「改为插话」: one queue mutation, the turn keeps running.
    expect(await w2Chat(container).steerQueued(queued), isTrue);
    expect(client.queueOps, [('q1', false, true)]);
    expect(client.cancels, 0);

    // 「撤回」: one removal; the Host then reports the inbox mutation and
    // the bubble goes.
    expect(await w2Chat(container).withdrawQueued(queued), isTrue);
    expect(client.queueOps.last, ('q1', true, false));
    client.events.add(
      SessionLogEvent.fromJson(
        w2Wire(3, 'agent/inbox/spliced', {'target': 'next-turn', 'start': 0, 'removedCount': 1}),
      ),
    );
    await settleW2(container);
    expect(w2State(container).pending, isEmpty);
    expect(client.prompts, isEmpty, reason: 'D3-04-AC2: withdrawing never sends');
  });

  test('D3-04_send_now_sends_once_in_place', () async {
    final client = W2Client();
    final container = await startW2Chat(client, running: true, snapshot: _queuedSnapshot());
    addTearDown(() async {
      container.dispose();
      await client.events.close();
    });

    final queued = w2State(container).pending.single;
    final lost = await w2Chat(container).sendNow(queued);
    await settleW2(container);

    expect(lost, isEmpty);
    expect(client.cancels, 1, reason: 'D3-04-AC2: 立即发送 stops the running turn');
    expect(client.queueOps.where((op) => op.$1 == 'q1'), [('q1', true, false)]);
    expect(client.prompts, hasLength(1), reason: 'D3-04-AC2: it goes back exactly once');
    expect(client.prompts.single.text, '顺便把 README 也改了');
    expect(client.prompts.single.requestId, 'r-q1', reason: 'the same request id keeps the bubble');
    expect(client.prompts.single.mode, PromptMode.queue);
  });

  testWidgets('D3-04_withdraw_returns_text_to_composer', (tester) async {
    usePhoneView(tester);
    mockClipboard(tester);
    final harness = ChatHarness(
      session: w2Session,
      states: {
        w2Session: ChatState(
          loading: false,
          running: true,
          pending: [
            PendingPrompt(
              requestId: 'r-q1',
              text: '顺便把 README 也改了',
              time: DateTime(2026, 11, 10, 9),
              mode: SendMode.queue,
              slot: InboxSlot.nextTurn,
              inboxId: 'q1',
            ),
          ],
        ),
      },
    );
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await pumpFrames(tester);

    expect(find.text('排队中 · 本轮结束后发送'), findsOneWidget, reason: 'D3-04-AC1: queued messages sit in the bottom queue');
    await tester.tap(find.text('撤回'));
    await pumpFrames(tester);

    final chat = harness.controllers[w2Session]!;
    expect(chat.withdrawn, ['r-q1'], reason: 'D3-04-AC2: 撤回 removes it once');
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, '顺便把 README 也改了', reason: 'D3-04-AC2: the text returns to the composer');
    expect(find.text('已撤回，可修改后再发'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
