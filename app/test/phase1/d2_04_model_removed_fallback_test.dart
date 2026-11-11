// T29 · D2-04 (G-14) — a send for a deleted model falls back.
//
// The selected route can disappear between the model switch and the next
// message (the person deleted the provider on the web page). The engine does
// not reject `session/prompt` for that: it admits the message and the turn
// ends with the pi-ai adapter's `UNKNOWN_MODEL` failure. By then the prompt is
// durable and must never be sent twice. The app has to:
//   * notice the gone model, re-read `session/modelCatalog`;
//   * switch to the previous available model (else the catalog default, else
//     the first available one);
//   * say so, and leave the typed text where the person can still send it;
//   * retry only a prompt that was never admitted, never an accepted one;
//   * never react to any other turn failure (an AUTH failure is not a model
//     problem).
//
// `UNKNOWN_MODEL` is the code llm-pi-ai throws for a model that is no longer
// configured (`packages/llm/llm-pi-ai/src/adapter.ts`, 0.2.2-rc.1); it reaches
// the client as `turn/end.reason.error.code`.

import 'dart:async';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/ui/chat/widgets/turn_failure_text.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _previous = ModelSelection(provider: 'deepseek-official', model: 'deepseek-v4-pro', reasoningEffort: 'high');
const _custom = ModelSelection(provider: 'xyz', model: 'abc');

/// The pi-ai failure for a route/model the adapter no longer configures.
const _unknownModel = LlmFailure(code: 'UNKNOWN_MODEL', message: 'pi-ai provider "xyz" has no configured model "abc"');

class _FakeClient extends DshClient {
  _FakeClient() : super(DshConnection(Uri.parse('http://127.0.0.1:9')));

  final events = StreamController<DshEvent>.broadcast();
  final prompts = <String>[];
  final models = <ModelSelection>[];

  /// Fails the fallback switch (a lost reply: its outcome is unknown, so the
  /// controller must not try it again on its own).
  Object? modelError;

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
    return requestId ?? 'request-${prompts.length}';
  }

  @override
  Future<ModelSelectionResult> setModelResult(
    String sessionId, {
    required String provider,
    required String model,
    String? reasoningEffort,
  }) async {
    final selection = ModelSelection(provider: provider, model: model, reasoningEffort: reasoningEffort);
    models.add(selection);
    if (modelError case final error?) throw error;
    return ModelSelectionResult(
      selected: selection,
      defaultSave: const ModelDefaultSave(status: ModelDefaultSaveStatus.saved),
    );
  }
}

/// Two providers, so both the remembered previous model and the first-model
/// fallback can be exercised.
ModelCatalog _catalog({bool custom = true}) => ModelCatalog(
  defaultSelection: _previous,
  routableProviders: ['deepseek-official', if (custom) 'xyz'],
  groups: [
    const ProviderGroup('deepseek-official', 'DeepSeek', [
      ModelInfo(
        provider: 'deepseek-official',
        id: 'deepseek-v4-pro',
        name: 'DeepSeek-V4-Pro',
        efforts: [ReasoningEffort('off', 'Off', null), ReasoningEffort('high', 'High', null)],
        defaultEffort: 'high',
      ),
      ModelInfo(provider: 'deepseek-official', id: 'deepseek-flash', name: 'DeepSeek-V41-Flash'),
    ]),
    if (custom) const ProviderGroup('xyz', 'XYZ', [ModelInfo(provider: 'xyz', id: 'abc', name: 'ABC')]),
  ],
  failures: const [],
);

typedef _Harness = ({ProviderContainer container, _FakeClient client});

Future<_Harness> _start({required ModelCatalog Function() catalog}) async {
  final client = _FakeClient();
  final container = ProviderContainer(
    overrides: [
      operatingSystemProvider.overrideWithValue('ios'),
      activeConnectionProvider.overrideWithValue(
        AsyncData<HostConnection?>(HostConnection(client: client, label: '本机', isLocal: true)),
      ),
      modelCatalogProvider.overrideWith((ref) async => catalog()),
    ],
  );
  addTearDown(() async {
    container.dispose();
    await client.events.close();
  });
  container.listen(chatProvider('s1'), (_, _) {});
  client.events.add(
    SessionSnapshotEvent.fromJson('s1', {
      'header': {'id': 's1'},
      'cursor': -1,
      'records': <Object?>[],
      'projections': {
        'asOfSeq': -1,
        'values': {
          'modelSelection': {'next': _previous.toJson()},
        },
      },
    }),
  );
  await container.pump();
  expect(container.read(chatProvider('s1')).controlReady, isTrue);
  return (container: container, client: client);
}

ChatController _chat(_Harness h) => h.container.read(chatProvider('s1').notifier);
ChatState _state(_Harness h) => h.container.read(chatProvider('s1'));

Future<void> _waitFor(bool Function() ready, {String reason = 'condition'}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for $reason');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Map<String, Object?> _userMessage(String text, String rpcId) => {
  'id': 'msg-$rpcId',
  'role': 'user',
  'content': [
    {'type': 'text', 'text': text},
  ],
  'source': {'kind': 'user', 'rpcId': rpcId},
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => SharedPreferences.setMockInitialValues({}));

  test('D2-04_removed_model_falls_back_before_admission_and_keeps_the_draft', () async {
    var catalog = _catalog();
    final h = await _start(catalog: () => catalog);
    final chat = _chat(h);

    // The model sheet read the catalog, then the person switched away from
    // the official model to the custom route.
    await h.container.read(modelCatalogProvider.future);
    expect(await chat.setModel(_custom), isTrue);

    // The route is deleted: the next catalog read no longer lists it.
    catalog = _catalog(custom: false);
    h.container.invalidate(modelCatalogProvider);
    await h.container.read(modelCatalogProvider.future);

    final sent = await chat.send('这段不能丢');
    expect(sent, isFalse, reason: 'the prompt must not be admitted for a gone model');
    expect(h.client.prompts, isEmpty);
    expect(_state(h).pending, isEmpty, reason: 'nothing was queued for the deleted model');
    expect(_state(h).items.whereType<UserChatItem>(), isEmpty);
    expect(_state(h).error, appL10n.stateChatModelUnavailable);
    expect(_state(h).model!.toJson(), _previous.toJson());
    expect(h.client.models.last.toJson(), _previous.toJson(), reason: 'the fallback was applied on the session');

    // The controller returned false, so the composer's _giveBack path keeps
    // the typed text (D3-01_send_failure_keeps_draft); a second send goes out
    // once, under the fallback model.
    expect(await chat.send('这段不能丢'), isTrue);
    expect(h.client.prompts, ['这段不能丢']);
  });

  test('D2-04_unknown_model_turn_falls_back_without_sending_the_prompt_twice', () async {
    var catalog = _catalog();
    final h = await _start(catalog: () => catalog);
    final chat = _chat(h);
    await h.container.read(modelCatalogProvider.future);
    expect(await chat.setModel(_custom), isTrue);

    // The engine admits the prompt; the route disappears before the model
    // call resolves.
    expect(await chat.send('accepted once'), isTrue);
    catalog = _catalog(custom: false);

    var seq = 100;
    SessionLogEvent log(String type, Map<String, Object?> data) =>
        SessionLogEvent.fromJson({'seq': ++seq, 'time': 1792700000000 + seq, 'type': type, 'data': data});
    h.client.events.add(log('user/message', _userMessage('accepted once', 'request-1')));
    h.client.events.add(log('turn/start', {'turn': 1}));
    h.client.events.add(
      log('turn/end', {
        'turn': 1,
        'reason': {
          'kind': 'error',
          'error': {'code': _unknownModel.code, 'message': _unknownModel.message},
        },
      }),
    );

    await _waitFor(
      () => _state(h).model?.provider == _previous.provider && _state(h).model?.model == _previous.model,
      reason: 'fallback model',
    );
    // The transcript publishes on its own coalesced timer.
    await Future<void>.delayed(const Duration(milliseconds: 80));

    final state = _state(h);
    expect(state.error, appL10n.stateChatModelUnavailable);
    expect(state.model!.toJson(), _previous.toJson());
    expect(h.client.models.last.toJson(), _previous.toJson());
    // The accepted prompt is durable exactly once; the fallback never sends
    // it again on its own.
    expect(h.client.prompts, ['accepted once']);
    expect(state.items.whereType<UserChatItem>().where((item) => item.text == 'accepted once'), hasLength(1));
    // The failed turn itself is readable, by its stable code.
    final notice = state.items.whereType<NoticeChatItem>().single;
    expect(notice.failure?.code, 'UNKNOWN_MODEL');
    expect(turnFailureText(notice.failure?.code), appL10n.chatErrModelUnsupported);

    // The next message uses the fallback, with no text lost.
    expect(await chat.send('next message'), isTrue);
    expect(h.client.prompts, ['accepted once', 'next message']);
  });

  test('D2-04_other_turn_failures_never_switch_models', () async {
    final catalog = _catalog();
    final h = await _start(catalog: () => catalog);
    final chat = _chat(h);
    expect(await chat.setModel(_custom), isTrue);
    expect(await chat.send('hello'), isTrue);

    var seq = 200;
    SessionLogEvent log(String type, Map<String, Object?> data) =>
        SessionLogEvent.fromJson({'seq': ++seq, 'time': 1792700000000 + seq, 'type': type, 'data': data});
    h.client.events.add(log('user/message', _userMessage('hello', 'request-1')));
    h.client.events.add(log('turn/start', {'turn': 1}));
    h.client.events.add(
      log('turn/end', {
        'turn': 1,
        'reason': {
          'kind': 'error',
          'error': {'code': 'AUTH', 'message': 'invalid API key'},
        },
      }),
    );

    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(_state(h).model!.toJson(), _custom.toJson(), reason: 'only model-missing failures may switch the model');
    expect(h.client.models.map((m) => m.toJson()), [_custom.toJson()], reason: 'no fallback switch was attempted');
    expect(h.client.prompts, ['hello']);
    expect(_state(h).items.whereType<NoticeChatItem>().single.failure?.code, 'AUTH');
  });

  test('D2-04_removed_model_with_no_available_fallback_keeps_the_text_and_reports', () async {
    var catalog = _catalog();
    final h = await _start(catalog: () => catalog);
    final chat = _chat(h);
    await h.container.read(modelCatalogProvider.future);
    expect(await chat.setModel(_custom), isTrue);

    // No models at all remain after the deletion.
    catalog = const ModelCatalog(defaultSelection: null, routableProviders: [], groups: [], failures: []);
    h.container.invalidate(modelCatalogProvider);
    await h.container.read(modelCatalogProvider.future);

    expect(await chat.send('keep me'), isFalse);
    expect(h.client.prompts, isEmpty);
    expect(_state(h).error, appL10n.stateChatModelUnavailable);
    expect(_state(h).pending, isEmpty);
    expect(h.client.models.map((m) => m.toJson()), [
      _custom.toJson(),
    ], reason: 'nothing to switch to, so no switch was attempted');
  });

  test('D2-04_unknown_fallback_outcome_is_not_retried_blindly', () async {
    var catalog = _catalog();
    final h = await _start(catalog: () => catalog);
    final chat = _chat(h);
    await h.container.read(modelCatalogProvider.future);
    expect(await chat.setModel(_custom), isTrue);

    catalog = _catalog(custom: false);
    h.container.invalidate(modelCatalogProvider);
    await h.container.read(modelCatalogProvider.future);
    // The switch's reply is lost: its outcome is unknown, so it must be
    // attempted exactly once and never repeated by the fallback.
    h.client.modelError = const DshTransportException('connection lost');

    expect(await chat.send('text survives'), isFalse);
    expect(h.client.models.map((m) => m.toJson()), [
      _custom.toJson(),
      _previous.toJson(),
    ], reason: 'one fallback attempt');
    expect(_state(h).model!.toJson(), _custom.toJson(), reason: 'the failed switch rolled back');
    expect(_state(h).error, contains(appL10n.stateChatModelSwitchFailed));
    expect(h.client.prompts, isEmpty);
    expect(_state(h).pending, isEmpty);
  });
}
