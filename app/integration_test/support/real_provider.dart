// T31 L4-Real: the real opencode-go provider as the app creates it.
//
// The acceptance key is fetched once from the T25 loopback credential broker
// (`E2E_BROKER_URL` / `E2E_BROKER_TOKEN`, see `e2e_env.dart`) and handed to
// `ProviderActions.save`; it is never printed, logged or asserted on. The
// provider is the same `opencode-go` route a person would add by hand:
//
//   * OpenAI-compatible endpoint https://opencode.ai/inference/go/v1
//   * one `deepseek-v4.1-flash` model (1M context, 384K output, text+image,
//     `max` thinking effort)
//   * the gateway's required `x-opencode-session` request header
//
// After the engine announces the route in `session/modelCatalog` the model is
// selected for the next new conversation (`pendingModelProvider`). Everything
// goes through production app state; no HTTP call to the model is made here.
//
// Test-only infrastructure: no product code imports this file.
library;

import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/state/providers_state.dart';
import 'package:dsh_client/dsh_client.dart' show ModelCatalog, ModelInfo, ModelSelection;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'e2e_env.dart';

/// The custom provider the app adds for the real acceptance model.
const String kRealProviderName = 'opencode-go';
const String kRealProviderBaseUrl = kE2eProviderBaseUrl;

/// The required opencode-go session header value for this run. Not a secret:
/// it only tells the gateway which logical session the requests belong to.
const String kRealProviderSessionHeader = kE2eSessionHeader;
const String kRealProviderSessionValue = 'dsh-go-ios-e2e';

/// The pinned acceptance model.
const String kRealModelId = kE2eModel;
const String kRealModelName = 'DeepSeek V4.1 Flash';
const int kRealModelContextWindow = 1000000;
const int kRealModelMaxTokens = 384000;
const List<String> kRealModelInput = ['text', 'image'];

/// The thinking effort every real turn uses (`reasoning_effort=max`, verified
/// by the T25 real-provider smoke).
const String kRealReasoningEffort = 'max';

/// The provider and model a [RealProviderHandle] put in the app.
class RealProviderHandle {
  const RealProviderHandle({required this.providerId, required this.modelId});

  final String providerId;
  final String modelId;

  ModelSelection get selection => ModelSelection(
    provider: providerId,
    model: modelId,
    reasoningEffort: kRealReasoningEffort,
  );

  @override
  String toString() => '$providerId/$modelId ($kRealReasoningEffort)';
}

/// The single model entry the acceptance route declares.
ProviderModelSpec realProviderModelSpec() => const ProviderModelSpec(
  id: kRealModelId,
  name: kRealModelName,
  contextWindow: kRealModelContextWindow,
  maxTokens: kRealModelMaxTokens,
  input: kRealModelInput,
  // `llm-pi-ai` model entries carry the selectable thinking levels here; the
  // engine turns `max` into `reasoning_effort: "max"` on the wire.
  extra: {
    'reasoningEfforts': {kRealReasoningEffort: kRealReasoningEffort},
  },
);

/// Creates (or repairs) the real provider through [ProviderActions] and waits
/// for the engine's catalog to list it, then selects the model for the next
/// conversation.
///
/// Fails loudly: a missing broker define, a broker that answers with an error,
/// a non-writable provider settings surface, or a catalog that never lists the
/// model are all test failures (never skips).
Future<RealProviderHandle> createRealProvider(
  WidgetTester tester,
  ProviderContainer container, {
  Duration catalogTimeout = const Duration(minutes: 2),
}) async {
  E2eConfig.requireBroker();

  final keyFetch = Stopwatch()..start();
  final key = await fetchBrokerKey();
  _log('credential fetched from the loopback broker in ${keyFetch.elapsedMilliseconds}ms (value not logged)');

  final snapshot = await _waitForProviders(tester, container);
  final existing = _findExisting(snapshot);
  final actions = container.read(providerActionsProvider);
  final draft = ProviderDraft(
    name: kRealProviderName,
    api: ProviderApi.openaiCompletions,
    baseUrl: kRealProviderBaseUrl,
    apiKey: existing == null || !snapshot.keyStored(existing) ? key : '',
    models: [realProviderModelSpec()],
    headers: const {kRealProviderSessionHeader: kRealProviderSessionValue},
  );

  final save = Stopwatch()..start();
  final String providerId;
  if (existing == null) {
    providerId = await actions.save(draft);
    _log('real provider created: $providerId in ${save.elapsedMilliseconds}ms');
  } else {
    providerId = existing.id;
    await actions.save(draft, existing: existing);
    _log('real provider updated: $providerId in ${save.elapsedMilliseconds}ms');
  }
  expect(providerId, matches(RegExp(r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$')), reason: 'invalid provider route id');

  final catalogWait = Stopwatch()..start();
  ModelCatalog? catalog;
  ModelInfo? model;
  while (catalogWait.elapsed < catalogTimeout) {
    try {
      container.invalidate(modelCatalogProvider);
      catalog = await container.read(modelCatalogProvider.future).timeout(const Duration(seconds: 20));
    } catch (error) {
      _log('model catalog read failed, retrying: $error');
    }
    model = catalog?.models
        .where((entry) => entry.provider == providerId && entry.id == kRealModelId)
        .firstOrNull;
    if (model != null) break;
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await tester.pump();
  }
  expect(
    model,
    isNotNull,
    reason: 'the engine catalog never listed $kRealModelId on $providerId '
        'within ${catalogTimeout.inSeconds}s (routable=${catalog?.routableProviders}, '
        'failures=${catalog?.failures})',
  );
  expect(
    catalog!.routableProviders,
    contains(providerId),
    reason: 'the engine did not make the real provider routable',
  );
  expect(
    model!.efforts.map((effort) => effort.id),
    contains(kRealReasoningEffort),
    reason: 'the engine did not expose the $kRealReasoningEffort thinking level for $kRealModelId',
  );
  _log('catalog lists $providerId/$kRealModelId with thinking '
      '${model.efforts.map((effort) => effort.id).join(",")} '
      'after ${catalogWait.elapsedMilliseconds}ms');

  container.read(pendingModelProvider.notifier).select(
    ModelSelection(provider: providerId, model: kRealModelId, reasoningEffort: kRealReasoningEffort),
  );
  _log('model selected for the next conversation: $providerId/$kRealModelId effort=$kRealReasoningEffort');
  return RealProviderHandle(providerId: providerId, modelId: kRealModelId);
}

CustomProvider? _findExisting(ProvidersSnapshot snapshot) {
  final wanted = kRealProviderBaseUrl.replaceFirst(RegExp(r'/+$'), '');
  for (final provider in snapshot.providers) {
    if (provider.baseUrl.replaceFirst(RegExp(r'/+$'), '') == wanted) return provider;
  }
  return null;
}

Future<ProvidersSnapshot> _waitForProviders(WidgetTester tester, ProviderContainer container) async {
  final clock = Stopwatch()..start();
  while (clock.elapsed < const Duration(minutes: 2)) {
    try {
      final snapshot = await container.read(customProvidersProvider.future).timeout(const Duration(seconds: 20));
      if (snapshot != null && snapshot.supported && snapshot.writable) return snapshot;
    } catch (error) {
      _log('provider snapshot read failed, retrying: $error');
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await tester.pump();
  }
  fail('the local engine exposed no writable provider settings within 2 minutes');
}

void _log(String message) => debugPrint('[phase1-workspace-real] $message');
