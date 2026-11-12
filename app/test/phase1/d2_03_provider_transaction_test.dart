// T29 · D2-03 (G-13) — a provider save is never half-written.
//
// The profile is written before its API key (the official page's order). A
// key write that fails used to leave the new route behind (or the edited
// profile changed) with no key: the list showed a broken provider and the
// next save started from a state nobody chose. These tests inject the key
// failure into a fake engine and require the save to compensate:
//   * create: the just-created route is removed again, no key is left, the
//     failure stays readable, and a retry creates cleanly;
//   * update: every edited field (name/api/Base URL/models/headers) goes back
//     to the snapshot taken before the write and the old key is untouched;
//   * no key write (keyless / empty key) does no compensation at all.
//
// Key material must never reach the error text.

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/providers_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/support.dart';

const _createDraft = ProviderDraft(
  name: 'New Gateway',
  api: ProviderApi.openaiCompletions,
  baseUrl: 'https://new.example.com/v1',
  apiKey: 'sk-new-secret',
  models: [ProviderModelSpec(id: 'qwen3-coder')],
  headers: {'x-opencode-session': 'sess-new'},
);

const _updateDraft = ProviderDraft(
  name: 'Renamed Gateway',
  api: ProviderApi.anthropicMessages,
  baseUrl: 'https://changed.example.com',
  apiKey: 'sk-replacement-secret',
  models: [ProviderModelSpec(id: 'changed-model')],
  headers: {'X-Changed': 'yes'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => SharedPreferences.setMockInitialValues({}));

  ProviderContainer container(FakeProviderBackend backend) {
    final c = ProviderContainer(
      overrides: [
        providerBackendProvider.overrideWithValue(backend),
        // The actions read the raw engine for their before-snapshot; the
        // display snapshot is not an edit authority here.
        customProvidersProvider.overrideWith((ref) async => null),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  group('create', () {
    test('D2-03_provider_create_rolls_back_the_route_when_the_key_fails', () async {
      final backend = FakeProviderBackend()..storeKeyError = const DshRemoteException('credential/rejected', 'x');
      final actions = container(backend).read(providerActionsProvider);

      await expectLater(
        actions.save(_createDraft),
        throwsA(
          isA<ProviderFailure>()
              .having((f) => f.savedId, 'savedId', isNull)
              .having((f) => f.message, 'message', isNotEmpty)
              .having((f) => f.message, 'message', isNot(contains('sk-new-secret'))),
        ),
      );

      // The half-created route and the key reference are gone.
      expect(backend.profiles, isEmpty);
      expect(backend.stored, isEmpty);
      expect(backend.calls.map((c) => c.$1), containsAllInOrder(['read', 'create', 'storeKey', 'remove']));

      // A retry starts from a clean engine and creates once.
      backend.storeKeyError = null;
      final id = await actions.save(_createDraft);
      expect(backend.profiles.single.route, id);
      expect(backend.stored[deriveProviderKeyRef(id)], 'sk-new-secret');
      expect(backend.calls.where((c) => c.$1 == 'create'), hasLength(2));
    });

    test('D2-03_provider_keyless_create_has_no_rollback_side_effects', () async {
      final backend = FakeProviderBackend();
      final actions = container(backend).read(providerActionsProvider);

      final id = await actions.save(
        const ProviderDraft(
          name: 'Local vLLM',
          api: ProviderApi.openaiCompletions,
          baseUrl: 'http://192.168.1.20:8000/v1',
          models: [ProviderModelSpec(id: 'qwen3-32b')],
        ),
      );

      expect(id, 'custom-local-vllm');
      expect(backend.profiles.single.apiKeyEnv, isNull);
      expect(backend.calls.map((c) => c.$1), ['read', 'create']);
      expect(backend.stored, isEmpty);
    });

    test('D2-03_provider_create_surfaces_both_errors_when_rollback_fails', () async {
      final backend = FakeProviderBackend()
        ..storeKeyError = const DshRemoteException('credential/rejected', 'x')
        ..removeError = const DshRemoteException('gateway/internal', 'rollback refused');
      final actions = container(backend).read(providerActionsProvider);

      await expectLater(
        actions.save(_createDraft),
        throwsA(
          isA<ProviderFailure>()
              // The route is still there, so the form can switch to it and
              // retry the key instead of pretending the save vanished.
              .having((f) => f.savedId, 'savedId', 'custom-new-gateway')
              .having(
                (f) => f.message,
                'message',
                allOf(
                  contains(appL10n.stateCredentialFromEnvironment),
                  contains(appL10n.commonFailedTryAgain),
                  isNot(contains('sk-new-secret')),
                ),
              ),
        ),
      );
      expect(backend.profiles.single.route, 'custom-new-gateway');
      expect(backend.stored, isEmpty);
    });
  });

  group('update', () {
    test('D2-03_provider_update_restores_the_before_snapshot_when_the_key_fails', () async {
      final backend = sampleBackend();
      final actions = container(backend).read(providerActionsProvider);
      final existing = CustomProvider.fromProfile(gateway);
      backend.storeKeyError = const DshRemoteException('credential/rejected', 'x');

      await expectLater(
        actions.save(_updateDraft, existing: existing),
        throwsA(
          isA<ProviderFailure>()
              .having((f) => f.savedId, 'savedId', isNull)
              .having((f) => f.message, 'message', isNot(contains('sk-replacement-secret'))),
        ),
      );

      // Every field the draft wrote is back to the before snapshot; the old
      // key reference and its stored key were never touched.
      final restored = backend.profiles.singleWhere((p) => p.route == gateway.route);
      expect(restored.displayName, gateway.displayName);
      expect(restored.api, gateway.api);
      expect(restored.baseUrl, gateway.baseUrl);
      expect(restored.models.map((m) => m.id), gateway.models.map((m) => m.id));
      expect(restored.headers, gateway.headers);
      expect(restored.apiKeyEnv, gateway.apiKeyEnv);
      expect(backend.stored[gateway.apiKeyEnv], 'sk-gw');

      // A retry after the key endpoint recovers applies the edit once.
      backend.storeKeyError = null;
      await actions.save(_updateDraft, existing: existing);
      final updated = backend.profiles.singleWhere((p) => p.route == gateway.route);
      expect(updated.displayName, 'Renamed Gateway');
      expect(backend.stored[gateway.apiKeyEnv], 'sk-replacement-secret');
    });

    test('D2-03_provider_keyless_update_removes_the_key_reference_again', () async {
      const keyless = ProviderProfile(
        route: 'custom-keyless',
        displayName: 'Keyless Gateway',
        api: 'openai-completions',
        baseUrl: 'https://keyless.example.com/v1',
        models: [ProviderModelSpec(id: 'qwen3-coder')],
      );
      final backend = FakeProviderBackend(profiles: const [keyless])
        ..storeKeyError = const DshRemoteException('credential/rejected', 'x');
      final actions = container(backend).read(providerActionsProvider);

      await expectLater(
        actions.save(
          const ProviderDraft(
            name: 'Keyless Gateway',
            api: ProviderApi.openaiCompletions,
            baseUrl: 'https://keyless.example.com/v1',
            apiKey: 'sk-typed-now',
            models: [ProviderModelSpec(id: 'qwen3-coder')],
          ),
          existing: CustomProvider.fromProfile(keyless),
        ),
        throwsA(isA<ProviderFailure>()),
      );

      // The route is keyless again, not pointing at a key that never landed.
      final restored = backend.profiles.single;
      expect(restored.apiKeyEnv, isNull);
      expect(restored.displayName, 'Keyless Gateway');
      final rollback = backend.calls.lastWhere((call) => call.$1 == 'update');
      expect(rollback.$2['clearApiKeyEnv'], isTrue);
      expect(backend.profiles.single.apiKeyEnv, isNull);
      expect(backend.stored, isEmpty);
    });

    test('D2-03_provider_update_with_an_empty_key_does_not_roll_back', () async {
      final backend = FakeProviderBackend(
        profiles: const [gateway],
        credentials: const {'CUSTOM_MYGW_API_KEY': 'sk-gw'},
      );
      final actions = container(backend).read(providerActionsProvider);
      final existing = CustomProvider.fromProfile(gateway);

      await actions.save(
        const ProviderDraft(
          name: 'Renamed Gateway',
          api: ProviderApi.openaiCompletions,
          baseUrl: 'https://gw.example.com/v1',
          models: [ProviderModelSpec(id: 'qwen3-coder')],
        ),
        existing: existing,
      );

      expect(backend.calls.map((c) => c.$1), ['read', 'update']);
      expect(backend.profiles.single.displayName, 'Renamed Gateway');
      expect(backend.stored[gateway.apiKeyEnv], 'sk-gw');
    });
  });
}
