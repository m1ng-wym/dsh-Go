// D2-01/AC3 · 全新安装的权限默认值 — Phase 1 regression guard.
//
// C7/C8 (the approval card) are only reachable when a new local conversation
// starts in the Host's `workspace-write` / `ask` preset. T22b could not reach
// the card and suspected a persisted full-access setting; this file pins the
// clean-install path so that suspicion stays falsifiable:
//
//   * with no SharedPreferences at all, `autoApproveCommands` is false and no
//     `auto_approve_commands` key is written just by reading settings;
//   * the Host's catalog default (workspace-write) is what the 权限 page shows
//     for a new conversation, not the danger-full-access preset;
//   * creating a local conversation sends no `/permission danger-full-access`
//     command — the only path that forces full access is the explicit user
//     switch, which a fresh install leaves off.
//
// L4-Real (`phase1_real_approval_test.dart`) proves the same values from the
// real engine before it asks the real model for an approval.

import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/features_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../plugins/support/fake_plugin_host.dart';
import '../shell/golden_harness.dart' show FakeRuntime, runningStatus;

/// Settings as a fresh install builds them: no stored key, no stored switches,
/// every policy default at its product default.
class _FreshSettings extends SettingsController {
  @override
  AppSettings build() => const AppSettings(loaded: true);
}

const _catalog = {
  'options': [
    {'value': 'workspace-write', 'name': 'workspace-write'},
    {'value': 'danger-full-access', 'name': 'danger-full-access'},
    {'value': 'auto', 'name': 'auto'},
  ],
  'defaultPreset': 'workspace-write',
};

FakePluginCarrier _cleanHost() {
  final carrier = FakePluginCarrier();
  // A fresh engine: the permission namespace exists but carries no saved
  // default, so the catalog's own workspace-write is the effective default.
  carrier.handlers['settings/describe'] = (_) => {
    'writable': true,
    'namespaces': [
      {'ns': 'permission', 'value': <String, Object?>{}, 'revision': 1},
    ],
  };
  carrier.handlers['permissionPresets/catalog'] = (_) => _catalog;
  carrier.handlers['session/list'] = (_) => {'items': <Object?>[]};
  carrier.handlers['session/create'] = (_) => {'sessionId': 'clean-session'};
  return carrier;
}

ProviderContainer _container(FakePluginCarrier carrier) {
  final client = DshClient.withCarrier(carrier);
  addTearDown(client.close);
  return ProviderContainer(
    overrides: [
      activeConnectionProvider.overrideWithValue(AsyncData(fakeHost(client))),
      readListIdentityProvider.overrideWithValue(null),
      localRuntimeProvider.overrideWith(
        () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
      ),
      settingsProvider.overrideWith(_FreshSettings.new),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('D2-01 fresh install: autoApproveCommands is false and stays unpersisted', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final sub = container.listen(settingsProvider, (_, _) {});
    addTearDown(sub.close);

    // The real controller's _load() reads the (empty) preferences. Give the
    // keystore/vault lookups a bounded number of event-loop turns.
    for (var i = 0; i < 100 && !container.read(settingsProvider).loaded; i++) {
      await pumpEventQueue();
    }
    expect(container.read(settingsProvider).loaded, isTrue, reason: 'settings never finished loading');
    expect(
      container.read(settingsProvider).autoApproveCommands,
      isFalse,
      reason: 'a clean install must ask for commands, not run them without approval',
    );
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getBool('auto_approve_commands'),
      isNull,
      reason: 'the default is not a user choice and must not be persisted as one',
    );
  });

  test('D2-01 a clean Host default is workspace-write, never danger-full-access', () async {
    final carrier = _cleanHost();
    final container = _container(carrier);
    addTearDown(container.dispose);
    final sub = container.listen(permissionStateProvider(null), (_, _) {});
    addTearDown(sub.close);

    final state = await container.read(permissionStateProvider(null).future);
    expect(state, isNotNull);
    expect(
      state!.hostDefault,
      'workspace-write',
      reason: 'the fresh engine default changed; new chats would skip approval',
    );
    expect(state.hostDefault, isNot('danger-full-access'));
    expect(state.current, isNull, reason: 'a new chat has no session preset yet');
    expect(state.invalidDefault, isFalse);
    expect(state.defaultOptions?.map((o) => o.value), contains('workspace-write'));
  });

  test('D2-01 creating a local conversation does not force full access', () async {
    final carrier = _cleanHost();
    final container = _container(carrier);
    addTearDown(container.dispose);
    final sub = container.listen(sessionsProvider, (_, _) {});
    addTearDown(sub.close);
    await pumpEventQueue();

    final sessionId = await container.read(sessionsProvider.notifier).create();
    expect(sessionId, 'clean-session');

    // The only full-access write is the explicit 完全权限 switch
    // (settings_state.setAutoApproveCommands + sessions_state's guarded
    // autoApprove branch). A fresh install must never take it implicitly.
    expect(
      carrier.argsOf('commands/execute').where((args) => '${args['line']}'.contains('danger-full-access')),
      isEmpty,
      reason: 'new local session forced danger-full-access; the approval card would be unreachable',
    );
    expect(
      carrier.argsOf('settings/mutate'),
      isEmpty,
      reason: 'session creation must not rewrite the host permission default',
    );
    // The created session is what the composer/chat state can use.
    final create = carrier.argsOf('session/create').single;
    expect((create['request'] as Map?)?['cwd'], isNotNull);
  });
}
