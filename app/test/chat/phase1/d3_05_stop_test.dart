// D3-05 · 停止生成（capability-spec.md#D3-05）
//
// D3-05-AC1: the stop key ends the turn, the UI goes idle, what was generated
//            stays, and the next message can go at once.
// D3-05-AC2: queued messages start the next turn after a stop (the app takes
//            the last waiting prompt out and puts it back, which wakes it).
// D3-05-AC3: a stop that cannot be confirmed (timeout / connection lost) is
//            reported as not stopped; the turn keeps running and no tool or
//            prompt is repeated.

import 'dart:async';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

DshEvent _started(String attempt, int revision) =>
    AssistantStreamStarted(attempt, revision, turn: 1, step: 0, startedAfterSeq: -1);

DshEvent _chunk(String attempt, int revision, int index, StreamChunk chunk) =>
    AssistantChunkEvent(attempt, revision, index: index, time: DateTime(2026, 11, 10, 9), chunk: chunk);

void main() {
  test('D3-05_stop_ends_turn_and_keeps_partial', () async {
    final client = W2Client();
    final container = await startW2Chat(client, running: true);
    addTearDown(() async {
      container.dispose();
      await client.events.close();
    });

    client.events.add(_started('a1', 0));
    client.events.add(_chunk('a1', 1, 0, const BlockStartChunk(0, 'text')));
    client.events.add(_chunk('a1', 2, 1, const TextDeltaChunk(0, '第一段已经生成')));
    await settleW2(container);
    expect(w2State(container).items.whereType<AssistantChatItem>().last.text, '第一段已经生成');

    unawaited(w2Chat(container).cancel());
    await settleW2(container);
    expect(client.cancels, 1, reason: 'D3-05-AC1: one stop asks the Host to cancel once');
    expect(w2State(container).stopping, isTrue, reason: 'D3-05-AC1: the key shows it is stopping');

    client.events.add(const SessionStatusEvent(w2Session, false));
    await settleW2(container);
    final stopped = w2State(container);
    expect(stopped.running, isFalse, reason: 'D3-05-AC1: the turn is over');
    expect(stopped.stopping, isFalse, reason: 'D3-05-AC1: the stop key is gone');
    final partial = stopped.items.whereType<AssistantChatItem>().last;
    expect(partial.text, '第一段已经生成', reason: 'D3-05-AC1: what was generated is kept');

    final ok = await w2Chat(container).send('继续，换个思路');
    await settleW2(container);
    expect(ok, isTrue, reason: 'D3-05-AC1: the next message can go at once');
    expect(client.prompts.last.text, '继续，换个思路');
    expect(client.prompts.last.mode, PromptMode.queue);
    client.events.add(const SessionStatusEvent(w2Session, true));
    await settleW2(container);
    expect(w2State(container).running, isTrue, reason: 'D3-05-AC1: the next turn starts');
  });

  test('D3-05_stop_then_queue_starts_next', () async {
    final client = W2Client();
    final container = await startW2Chat(client, running: true, snapshot: _queuedSnapshot());
    addTearDown(() async {
      container.dispose();
      await client.events.close();
    });

    final queued = w2State(container).pending.single;
    expect(queued.inboxId, 'q1');

    final lost = await w2Chat(container).cancel();
    await settleW2(container);

    expect(lost, isEmpty);
    expect(client.cancels, 1, reason: 'D3-05-AC2: stop the running turn');
    expect(client.queueOps, [('q1', true, false)], reason: 'D3-05-AC2: take the waiting prompt out');
    expect(client.prompts, hasLength(1), reason: 'D3-05-AC2: put it back so the Host starts the next turn');
    expect(client.prompts.single.text, '顺便把 README 也改了');
    expect(client.prompts.single.requestId, 'r-q1');
    expect(client.prompts.single.mode, PromptMode.queue);
  });

  test('D3-05_stop_failure_does_not_claim_stopped', () async {
    final client = W2Client();
    final container = await startW2Chat(client, running: true);
    addTearDown(() async {
      container.dispose();
      await client.events.close();
    });

    client.cancelError = const DshTransportException('mock connection lost');
    final lost = await w2Chat(container).cancel();
    await settleW2(container);

    expect(lost, isEmpty);
    expect(client.cancels, 1);
    final state = w2State(container);
    expect(state.stopping, isFalse, reason: 'D3-05-AC3: the key comes back');
    expect(state.running, isTrue, reason: 'D3-05-AC3: it does not pretend the turn stopped');
    expect(state.error, '没能停下，再试一次', reason: 'D3-05-AC3: the failure is visible and actionable');
    expect(client.prompts, isEmpty, reason: 'D3-05-AC3: nothing is sent again');
    expect(client.queueOps, isEmpty, reason: 'D3-05-AC3: no queue is touched without a confirmed stop');
  });

  testWidgets('D3-05_stop_timeout_reports_unknown', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final client = W2Client();
    final container = ProviderContainer(
      overrides: [
        activeConnectionProvider.overrideWithValue(
          AsyncData<HostConnection?>(HostConnection(client: client, label: '本机', isLocal: true)),
        ),
      ],
    );
    final sub = container.listen(chatProvider(w2Session), (_, _) {});
    client.events.add(SessionSnapshotEvent.fromJson(w2Session, w2Snapshot()));
    client.events.add(const SessionStatusEvent(w2Session, true));
    await tester.pump(const Duration(milliseconds: 40));

    client.cancelGate = Completer<void>();
    unawaited(container.read(chatProvider(w2Session).notifier).cancel());
    await tester.pump();
    expect(sub.read().stopping, isTrue);

    // Ten seconds pass without an answer from the Host.
    await tester.pump(const Duration(seconds: 10));
    final state = sub.read();
    expect(state.stopping, isFalse, reason: 'D3-05-AC3: the stop key comes back');
    expect(state.running, isTrue, reason: 'D3-05-AC3: it does not pretend the turn stopped');
    expect(
      state.error,
      isNotNull,
      reason: 'D3-05-AC3: an unconfirmed stop is reported (结果未知), not silently ignored',
    );
    expect(state.error, contains('没能停下'), reason: 'D3-05-AC3: the copy says it did not stop and can be retried');
    expect(client.cancels, 1, reason: 'D3-05-AC3: a timeout must not re-send the stop');

    client.cancelGate!.complete();
    await tester.pump();
    sub.close();
    container.dispose();
    await client.events.close();
  });
}
