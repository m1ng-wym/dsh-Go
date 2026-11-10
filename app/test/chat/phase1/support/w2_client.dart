// Wave 2 T13–T15 test support: a scripted Host for the real ChatController.
//
// The state tests drive the production controller over a fake `DshClient`;
// widget tests render the state the controller actually produced (or a
// harness state for pure presentation ACs). No test here starts a Node mock,
// a simulator or a real network connection.

import 'dart:async';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const w2Session = 's1';

Map<String, Object?> w2Wire(int seq, String type, [Map<String, Object?> data = const {}]) => {
  'seq': seq,
  'time': 1762749000000 + seq,
  'type': type,
  'data': data,
};

Map<String, Object?> w2Record(Map<String, Object?> event) => {'type': 'event', 'event': event};

Map<String, Object?> w2User(int seq, String text, {String requestId = 'r'}) => w2Wire(seq, 'user/message', {
  'id': 'u$seq',
  'role': 'user',
  'content': [
    {'type': 'text', 'text': text},
  ],
  'source': {'kind': 'user', 'rpcId': requestId},
});

Map<String, Object?> w2Reply(int seq, String text, {int turn = 1, String reasoning = ''}) =>
    w2Wire(seq, 'assistant/message', {
      'turn': turn,
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

Map<String, Object?> w2TurnEnd(int seq, {int turn = 1, String kind = 'completed'}) =>
    w2Wire(seq, 'turn/end', {
      'turn': turn,
      'reason': {'kind': kind},
    });

Map<String, Object?> w2ToolCall(
  int seq,
  String callId,
  String name,
  String arguments, {
  int turn = 1,
  int step = 1,
}) => w2Wire(seq, 'tool/call', {
  'turn': turn,
  'step': step,
  'callId': callId,
  'name': name,
  'arguments': arguments,
});

Map<String, Object?> w2ToolResult(
  int seq,
  String callId,
  String text, {
  int turn = 1,
  int step = 1,
  bool error = false,
  Map<String, Object?>? failure,
  Map<String, Object?>? meta,
}) => w2Wire(seq, 'tool/result', {
  'turn': turn,
  'step': step,
  'message': {
    'id': 't$seq',
    'role': 'tool',
    'toolCallId': callId,
    'isError': error,
    'content': [
      {'type': 'text', 'text': text},
    ],
    'source': {'kind': 'tool'},
  },
  'error': ?failure,
  'meta': ?meta,
});

/// A baseline snapshot. [records] are durable events; [inbox] seeds the
/// agent inbox exactly as DSH's projections do.
Map<String, Object?> w2Snapshot({
  List<Map<String, Object?>> records = const [],
  Map<String, List<Map<String, Object?>>> inbox = const {'next-turn': [], 'next-step': []},
}) {
  final last = records.isEmpty ? -1 : (records.last['event']! as Map)['seq']! as int;
  return {
    'header': {
      'version': 4,
      'id': w2Session,
      'createdAt': 1762749000000,
      'cwd': '/mock',
      'isSeeded': false,
      'agentPreset': 'standard',
    },
    'cursor': last,
    'records': records,
    'hasMore': false,
    'projections': {
      'asOfSeq': last,
      'values': {
        'inbox': inbox,
      },
    },
    'assistantStream': {'revision': 0},
  };
}

/// One prompt waiting in the inbox as the Host reports it.
Map<String, Object?> w2Queued(
  String itemId,
  String text, {
  required String requestId,
  bool steering = false,
  String sourceKind = 'user',
}) => {
  'id': itemId,
  'role': 'user',
  'content': [
    {'type': 'text', 'text': text},
  ],
  'source': {'kind': sourceKind, 'rpcId': requestId, 'form': 'steer'},
};

class W2Prompt {
  const W2Prompt(this.text, this.mode, this.requestId);
  final String text;
  final PromptMode mode;
  final String? requestId;
}

/// A [DshClient] that records what the controller asks for and plays back a
/// scripted event stream. Everything the target ACs need is here; failures
/// are injected per test.
class W2Client extends DshClient {
  W2Client() : super(DshConnection(Uri.parse('http://127.0.0.1:9')));

  final events = StreamController<DshEvent>.broadcast();
  final prompts = <W2Prompt>[];
  final approvals = <(ApprovalRequest, ApprovalDecision)>[];
  final answers = <(UserQuestionRequest, List<QuestionAnswer>)>[];
  final rejections = <UserQuestionRequest>[];
  final queueOps = <(String itemId, bool remove, bool steer)>[];
  final forkedAt = <int>[];
  int cancels = 0;

  Object? promptError;
  Object? cancelError;
  Object? approvalError;
  Object? answerError;
  Object? rejectError;
  Object? forkError;

  /// Hold the cancel reply until completed (the stop key's 「正在停止」).
  Completer<void>? cancelGate;

  /// Hold the prompt reply until completed.
  Completer<void>? promptGate;

  /// Inbox items the agent already took: `updateQueue` answers not-found.
  final gone = <String>{};

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
    prompts.add(W2Prompt(text, mode, requestId));
    if (promptGate case final gate?) await gate.future;
    if (promptError case final error?) throw error;
    return requestId ?? 'r';
  }

  @override
  Future<void> cancel(String sessionId) async {
    cancels++;
    if (cancelGate case final gate?) await gate.future;
    if (cancelError case final error?) throw error;
  }

  @override
  Future<void> respondApproval(ApprovalRequest request, ApprovalDecision decision) async {
    approvals.add((request, decision));
    if (approvalError case final error?) throw error;
  }

  @override
  Future<void> answerQuestion(UserQuestionRequest request, List<QuestionAnswer> answers) async {
    this.answers.add((request, answers));
    if (answerError case final error?) throw error;
  }

  @override
  Future<void> rejectQuestion(
    UserQuestionRequest request, {
    String name = 'UserQuestionError',
    String message = 'declined',
    String? code,
  }) async {
    rejections.add(request);
    if (rejectError case final error?) throw error;
  }

  @override
  Future<void> updateQueue(
    String sessionId,
    String itemId, {
    String? editText,
    bool remove = false,
    bool steer = false,
  }) async {
    queueOps.add((itemId, remove, steer));
    if (gone.contains(itemId)) {
      throw const DshRemoteException('session/queue-item-not-found', 'queued item is no longer pending');
    }
  }

  @override
  Future<String> forkSession(String sessionId, {int? atSeq}) async {
    forkedAt.add(atSeq ?? -1);
    if (forkError case final error?) throw error;
    return 'fork-session';
  }

  @override
  Future<SessionProjections?> projections(String sessionId) async => null;

  @override
  Future<String> renameSession(String sessionId, String title) async => title;
}

/// Starts the real controller on [w2Session] and waits for its baseline.
Future<ProviderContainer> startW2Chat(
  W2Client client, {
  Map<String, Object?>? snapshot,
  bool running = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  final container = ProviderContainer(
    overrides: [
      activeConnectionProvider.overrideWithValue(
        AsyncData<HostConnection?>(HostConnection(client: client, label: '本机', isLocal: true)),
      ),
    ],
  );
  container.listen(chatProvider(w2Session), (_, _) {});
  client.events.add(SessionSnapshotEvent.fromJson(w2Session, snapshot ?? w2Snapshot()));
  if (running) client.events.add(const SessionStatusEvent(w2Session, true));
  await settleW2(container);
  if (!container.read(chatProvider(w2Session)).controlReady) {
    throw StateError('baseline snapshot was not applied');
  }
  return container;
}

ChatController w2Chat(ProviderContainer container) => container.read(chatProvider(w2Session).notifier);

ChatState w2State(ProviderContainer container) => container.read(chatProvider(w2Session));

/// Lets the follow stream deliver and the 32 ms coalescing publish fire.
Future<void> settleW2(ProviderContainer container) async {
  await Future<void>.delayed(const Duration(milliseconds: 60));
  await container.pump();
}

/// The first pending prompt, for assertions about the optimistic bubble.
PendingPrompt? w2Pending(ProviderContainer container) =>
    w2State(container).pending.isEmpty ? null : w2State(container).pending.first;
