// D3-02 · 流式回复与思考过程（capability-spec.md#D3-02，spec-phase1-v1）
//
// D3-02-AC1: the answer is appended chunk by chunk (an intermediate state is
//            observable between frames); the completed transcript reopens as it
//            was.
// D3-02-AC2: thinking is its own block — collapsed with a first-line preview,
//            expandable, and never mixed into the answer.
// D3-02-AC3: a stream that dies mid-turn leaves the message in an error state
//            that can be retried, without an endless "thinking" animation and
//            without dropping what was already generated.
//
// The state tests drive the real ChatController over a scripted
// DshClient.watch(); the widget tests render the state the controller actually
// produced on the real ChatScreen.

import 'dart:async';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/widgets/thinking_pill.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/harness.dart';

class _StreamClient extends DshClient {
  _StreamClient() : super(DshConnection(Uri.parse('http://127.0.0.1:9')));

  final events = StreamController<DshEvent>.broadcast();
  final prompts = <String>[];

  @override
  Stream<DshEvent> watch(String sessionId, {WatchOptions options = const WatchOptions()}) => events.stream;

  @override
  Future<String> prompt(
    String sessionId,
    String text, {
    List<PromptImage> images = const [],
    List<String> fileReceiptIds = const [],
    String? requestId,
    PromptMode mode = PromptMode.queue,
    String? timeZone,
  }) async {
    prompts.add(text);
    return requestId ?? 'r1';
  }
}

// ── wire fixtures (DSH 0.2.x follow log shape) ───────────────────────────────

Map<String, Object?> _wire(int seq, String type, [Map<String, Object?> data = const {}]) => {
  'seq': seq,
  'time': 1762749000000 + seq,
  'type': type,
  'data': data,
};

Map<String, Object?> _record(Map<String, Object?> event) => {'type': 'event', 'event': event};

Map<String, Object?> _user(int seq, String text) => _wire(seq, 'user/message', {
  'id': 'u$seq',
  'role': 'user',
  'content': [
    {'type': 'text', 'text': text},
  ],
  'source': {'kind': 'user', 'rpcId': 'r$seq'},
});

Map<String, Object?> _reply(int seq, String text, {String reasoning = ''}) => _wire(seq, 'assistant/message', {
  'turn': 1,
  'step': 1,
  'message': {
    'id': 'm$seq',
    'role': 'assistant',
    'content': [
      if (reasoning.isNotEmpty) {'type': 'reasoning', 'text': reasoning},
      {'type': 'text', 'text': text},
    ],
    'source': {'kind': 'assistant'},
  },
});

Map<String, Object?> _snapshot({List<Map<String, Object?>> records = const []}) {
  final last = records.isEmpty ? -1 : (records.last['event']! as Map)['seq']! as int;
  return {
    'header': {
      'version': 4,
      'id': 's1',
      'createdAt': 1762749000000,
      'cwd': '/mock',
      'isSeeded': false,
      'agentPreset': 'standard',
    },
    'cursor': last,
    'records': records,
    'hasMore': false,
    'projections': {'asOfSeq': last, 'values': <String, Object?>{}},
    'assistantStream': {'revision': 0},
  };
}

DshEvent _started(String attempt, int revision) =>
    AssistantStreamStarted(attempt, revision, turn: 1, step: 0, startedAfterSeq: -1);

DshEvent _chunk(String attempt, int revision, int index, StreamChunk chunk) =>
    AssistantChunkEvent(attempt, revision, index: index, time: DateTime(2026, 11, 10, 9), chunk: chunk);

// ── driver ───────────────────────────────────────────────────────────────────

Future<ProviderContainer> _start(_StreamClient client, {Map<String, Object?>? snapshot}) async {
  final container = ProviderContainer(
    overrides: [
      activeConnectionProvider.overrideWithValue(
        AsyncData<HostConnection?>(HostConnection(client: client, label: '本机', isLocal: true)),
      ),
    ],
  );
  container.listen(chatProvider('s1'), (_, _) {});
  client.events.add(SessionSnapshotEvent.fromJson('s1', snapshot ?? _snapshot()));
  await container.pump();
  expect(container.read(chatProvider('s1')).controlReady, isTrue, reason: 'baseline snapshot applied');
  return container;
}

/// The controller batches live events into a 32 ms publish; give it a real
/// turn of the event loop (the same pattern as send_controller_test's settle).
Future<void> _settle(ProviderContainer container) async {
  await Future<void>.delayed(const Duration(milliseconds: 60));
  await container.pump();
}

AssistantChatItem? _lastAnswer(ProviderContainer container) {
  final items = container.read(chatProvider('s1')).items.whereType<AssistantChatItem>().toList();
  return items.isEmpty ? null : items.last;
}

Future<void> _pumpState(WidgetTester tester, ChatState state) async {
  usePhoneView(tester);
  mockClipboard(tester);
  final harness = ChatHarness(session: 's1', states: {'s1': state});
  await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
  await pumpFrames(tester);
}

const _reasoning = '第一段思考:先确认按钮在请求期间是否禁用。\n第二段:再补一个连点测试。';
const _preview = '第一段思考:先确认按钮在请求期间是否禁用。';
const _answer = '是**超时重试**多发了一次请求。';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('D3-02_stream_appends_chunks_incrementally', () async {
    final client = _StreamClient();
    final container = await _start(client);
    addTearDown(() async {
      container.dispose();
      await client.events.close();
    });

    client.events.add(_started('a1', 0));
    client.events.add(_chunk('a1', 1, 0, const BlockStartChunk(0, 'text')));
    client.events.add(_chunk('a1', 2, 1, const TextDeltaChunk(0, '你是')));
    await _settle(container);

    final first = _lastAnswer(container);
    expect(first, isNotNull, reason: 'D3-02-AC1: the answer starts before the stream ends');
    expect(first!.text, '你是', reason: 'D3-02-AC1: an intermediate state is observable between frames');
    expect(first.streaming, isTrue, reason: 'D3-02-AC1: the live answer is marked as still streaming');

    client.events.add(_chunk('a1', 3, 2, const TextDeltaChunk(0, '一个好')));
    await _settle(container);
    expect(_lastAnswer(container)!.text, '你是一个好', reason: 'D3-02-AC1: each chunk is appended, not replaced');

    // The wire may repeat a frame; the transcript drops it by chunk index.
    client.events.add(_chunk('a1', 3, 2, const TextDeltaChunk(0, '一个好')));
    await _settle(container);
    expect(_lastAnswer(container)!.text, '你是一个好', reason: 'D3-02 错误/边界: 重复分片被去重');

    client.events.add(_chunk('a1', 4, 3, const TextDeltaChunk(0, ' assistant')));
    client.events.add(_chunk('a1', 5, 4, const FinishChunk('stop', null)));
    client.events.add(AssistantStreamEnded('a1', 6, index: 5, committed: true));
    await _settle(container);

    final done = _lastAnswer(container);
    expect(done!.text, '你是一个好 assistant', reason: 'D3-02-AC1: the final text keeps every chunk');
    expect(done.streaming, isFalse, reason: 'a settled stream is no longer live');
  });

  test('D3-02_reopened_transcript_shows_the_full_answer', () async {
    final client = _StreamClient();
    final container = await _start(
      client,
      snapshot: _snapshot(
        records: [
          _record(_user(0, '问题')),
          _record(_reply(1, '完整回答', reasoning: '先想')),
        ],
      ),
    );
    addTearDown(() async {
      container.dispose();
      await client.events.close();
    });

    final answers = container.read(chatProvider('s1')).items.whereType<AssistantChatItem>().toList();
    expect(answers, hasLength(1));
    expect(answers.single.text, '完整回答', reason: 'D3-02-AC1: reopening the transcript shows the whole answer');
    expect(answers.single.reasoning, '先想');
  });

  testWidgets('D3-02_thinking_collapsed_shows_preview', (tester) async {
    await _pumpState(
      tester,
      ChatState(
        items: [
          UserChatItem(seq: 1, time: DateTime(2026, 11, 10, 9), text: '帮我看看', images: const [], files: const []),
          AssistantChatItem(id: 'a2', seq: 2, time: DateTime(2026, 11, 10, 9), text: _answer, reasoning: _reasoning),
        ],
        loading: false,
      ),
    );

    expect(find.text('思考'), findsOneWidget, reason: 'D3-02-AC2: thinking is its own collapsible block');
    expect(
      find.text(_preview),
      findsOneWidget,
      reason: 'D3-02-AC2: collapsed thinking shows the first line as a preview',
    );
    expect(find.textContaining('第二段'), findsNothing, reason: 'D3-02-AC2: collapsed thinking hides the rest');
    expect(find.textContaining('超时重试'), findsWidgets, reason: 'the answer is rendered separately');

    await tester.tap(find.text('思考'));
    await pumpFrames(tester, 8);
    expect(find.textContaining('第二段'), findsWidgets, reason: 'D3-02-AC2: the block expands');
    expect(find.textContaining('超时重试'), findsWidgets, reason: 'D3-02-AC2: thinking did not replace the answer');

    await tester.tap(find.text('思考'));
    await pumpFrames(tester, 8);
    expect(find.text(_preview), findsOneWidget, reason: 'D3-02-AC2: it folds back to the preview');
    expect(tester.takeException(), isNull);
  });

  testWidgets('D3-02_stream_error_shows_retry_state', (tester) async {
    final client = _StreamClient();
    late ChatState state;
    // The publish timer is a real 32 ms Timer; drive it in the async zone.
    await tester.runAsync(() async {
      final container = await _start(client);
      addTearDown(() async {
        container.dispose();
        await client.events.close();
      });

      client.events.add(_started('a1', 0));
      client.events.add(_chunk('a1', 1, 0, const BlockStartChunk(0, 'reasoning')));
      client.events.add(_chunk('a1', 2, 1, const ReasoningDeltaChunk(0, _reasoning)));
      await _settle(container);
      expect(_lastAnswer(container)!.streaming, isTrue, reason: 'the mock stream is live');

      client.events.addError(const DshRemoteException('io/closed', 'mock stream dropped'));
      await _settle(container);
      state = container.read(chatProvider('s1'));
      expect(state.streamLost, isTrue);
      expect(
        _lastAnswer(container)!.streaming,
        isFalse,
        reason: 'D3-02-AC3: a dead stream must not keep the message looking like it is still thinking',
      );
    });

    expect(state.error, '对话同步中断', reason: 'D3-02-AC3: the person is told the stream was interrupted');
    expect(state.loading, isFalse, reason: 'D3-02-AC3: no endless spinner');
    final lost = state.items.whereType<AssistantChatItem>().last;
    expect(lost.reasoning, _reasoning, reason: 'D3-02-AC3: what was generated is not dropped');

    // The real UI of that state: no endless "思考中" animation, a retry action,
    // and the partial thinking still visible.
    await _pumpState(tester, state);
    expect(find.text('思考中'), findsNothing, reason: 'D3-02-AC3: the thinking animation stops');
    expect(find.byType(ThinkingTicker), findsNothing, reason: 'D3-02-AC3: no endless live window');
    expect(find.text('对话同步中断'), findsOneWidget, reason: 'D3-02-AC3: the error is visible');
    expect(find.text('重新同步'), findsOneWidget, reason: 'D3-02-AC3: the error carries a retry action');
    expect(find.textContaining('第一段思考'), findsWidgets, reason: 'D3-02-AC3: generated content stays readable');
    expect(tester.takeException(), isNull);
  });

  test('D3-02_empty_reply_does_not_add_a_row', () async {
    final client = _StreamClient();
    final container = await _start(client);
    addTearDown(() async {
      container.dispose();
      await client.events.close();
    });

    final before = container.read(chatProvider('s1')).items.length;
    client.events.add(_started('a1', 0));
    client.events.add(_chunk('a1', 1, 0, const FinishChunk('stop', null)));
    client.events.add(AssistantStreamEnded('a1', 2, index: 1, committed: true));
    await _settle(container);

    expect(container.read(chatProvider('s1')).items, hasLength(before), reason: 'D3-02 错误/边界: 空回复不产生一行内容');
  });
}
