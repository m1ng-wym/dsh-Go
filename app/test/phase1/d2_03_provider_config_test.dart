// D2-03 · API Key 与自定义渠道 — Phase 1 acceptance tests (L2).
//
// AC1 添加兼容渠道、保存成功、Key 进安全存储（Keychain 抽象）、模型进入目录；
// AC2 非法 Base URL / 被拒的 Key 有可读错误且不落半成品；AC3 编辑一个渠道
// 只改它，其他渠道与模型选择不受影响。
//
// L4（真引擎 + mock 模型 3901）deferred to T22: this worktree has no Engine
// payload, so the contract here is the L2 fake engine and the secure-storage
// abstraction.

import 'package:dsh_app/state/models_state.dart' show modelCatalogProvider, pendingModelProvider;
import 'package:dsh_app/state/provider_keys.dart';
import 'package:dsh_app/state/providers_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/providers/provider_form_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/support.dart';
import '../shell/golden_harness.dart' show FakeSettings, goldenApp, loadGoldenFonts;

class _Opener extends StatefulWidget {
  const _Opener({this.existing});

  final CustomProvider? existing;

  @override
  State<_Opener> createState() => _OpenerState();
}

class _OpenerState extends State<_Opener> {
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        onPressed: () =>
            Navigator.of(context)
                .push(MaterialPageRoute<String>(builder: (_) => ProviderFormPage(existing: widget.existing))),
        child: const Text('open'),
      ),
    ),
  );
}

Future<void> _open(
  WidgetTester tester,
  FakeProviderBackend? backend, {
  CustomProvider? existing,
  MemoryProviderKeyVault? vault,
}) async {
  await tester.runAsync(loadGoldenFonts);
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(390 * 2, 1400 * 2);
  tester.view.padding = const FakeViewPadding(top: 64, bottom: 48);
  tester.view.viewPadding = const FakeViewPadding(top: 64, bottom: 48);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    goldenApp(
      home: _Opener(existing: existing),
      brightness: Brightness.light,
      overrides: providerOverrides(backend, vault: vault),
    ),
  );
  await tester.tap(find.text('open'));
  await settle(tester);
}

Finder _field(String label) => find.descendant(
  of: find.ancestor(of: find.text(label), matching: find.byType(Column)).first,
  matching: find.byType(TextField),
);

Future<void> _type(WidgetTester tester, String label, String text) async {
  await tester.enterText(_field(label), text);
  await tester.pump();
}

Future<void> _addModel(WidgetTester tester, String id) async {
  await tester.tap(find.text('手动添加'));
  await settle(tester);
  await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), id);
  await tester.tap(find.widgetWithText(FilledButton, '添加'));
  await settle(tester);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => SharedPreferences.setMockInitialValues({}));

  test('D2-03_provider_keys_use_the_secure_storage_prefix', () async {
    // The Keychain abstraction keeps one namespaced item per provider and
    // leaves the DeepSeek key and everything else alone.
    FlutterSecureStorage.setMockInitialValues({
      'deepseek_api_key': 'sk-deep',
      'provider_key_custom-a': 'sk-a',
      'unrelated': 'x',
    });
    const vault = SecureProviderKeyVault();
    expect(await vault.readAll(), {'custom-a': 'sk-a'});

    await vault.write('custom-b', 'sk-b');
    expect(await vault.readAll(), {'custom-a': 'sk-a', 'custom-b': 'sk-b'});
    expect(await const FlutterSecureStorage().read(key: 'provider_key_custom-b'), 'sk-b');

    await vault.delete('custom-a');
    expect(await vault.readAll(), {'custom-b': 'sk-b'});
  });

  testWidgets('D2-03_add_custom_provider_saves_key_to_keychain', (tester) async {
    final backend = FakeProviderBackend(discoverResult: discovered);
    final vault = MemoryProviderKeyVault();
    await _open(tester, backend, vault: vault);

    await _type(tester, '名称', 'My Gateway');
    await _type(tester, 'Base URL', 'https://gw.example.com/v1');
    await _type(tester, 'API Key', 'sk-gw-secret');
    // The key is never shown as plain text in the form (the obscured
    // EditableText still holds it; no Text widget may).
    expect(tester.widget<TextField>(_field('API Key')).obscureText, isTrue);
    expect(
      tester.widgetList<Text>(find.byType(Text)).map((t) => t.data ?? t.textSpan?.toPlainText()),
      isNot(contains('sk-gw-secret')),
    );

    await tester.tap(find.text('获取模型'));
    await settle(tester);
    expect(find.byType(ModelPickerSheet), findsOneWidget);
    await tester.tap(find.text('添加 3 个模型'));
    await settle(tester);
    await tester.tap(find.text('保存'));
    await settle(tester);

    // Profile first, then the key, as the engine requires.
    expect(backend.callNames.where((c) => c != 'read'), ['discover', 'create', 'storeKey']);
    expect(backend.stored['CUSTOM_MY_GATEWAY_API_KEY'], 'sk-gw-secret');
    expect(vault.data, {'custom-my-gateway': 'sk-gw-secret'});

    // The Keychain copy is the only on-phone copy: no key in preferences.
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys()) {
      expect('${prefs.get(key)}', isNot(contains('sk-gw-secret')), reason: key);
    }

    final container = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
    expect(container.read(settingsProvider).customProviderIds, contains('custom-my-gateway'));
    expect(container.read(settingsProvider).customProviderIds, isNot(contains('sk-gw-secret')));
  });

  testWidgets('D2-03_saved_model_appears_in_model_catalog_after_invalidation', (tester) async {
    await tester.runAsync(() async {
      final backend = FakeProviderBackend();
      final vault = MemoryProviderKeyVault();
      var reads = 0;
      final container = ProviderContainer(
        overrides: [
          providerBackendProvider.overrideWithValue(backend),
          providerKeyVaultProvider.overrideWithValue(vault),
          settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true, apiKey: 'sk-x'))),
          readListIdentityProvider.overrideWithValue(const ReadListIdentity('phase1-test')),
          // The save reads the snapshot best-effort; no cache/timer in this
          // container-only test.
          customProvidersProvider.overrideWith((ref) async => null),
          modelCatalogProvider.overrideWith((ref) async {
            reads++;
            final settings = await backend.read();
            final profiles = settings?.profiles ?? const <ProviderProfile>[];
            return ModelCatalog(
              defaultSelection: null,
              routableProviders: [for (final p in profiles) p.route],
              groups: [
                for (final p in profiles)
                  ProviderGroup(p.route, p.displayName ?? p.route, [
                    for (final m in p.models)
                      ModelInfo(provider: p.route, id: m.id, name: m.name ?? m.id, efforts: const []),
                  ]),
              ],
              failures: const [],
            );
          }),
        ],
      );
      try {
        await container.read(modelCatalogProvider.future);
        expect(reads, 1);

        final id = await container
            .read(providerActionsProvider)
            .save(
              const ProviderDraft(
                name: 'My Gateway',
                api: ProviderApi.openaiCompletions,
                baseUrl: 'https://gw.example.com/v1',
                apiKey: 'sk-gw',
                models: [ProviderModelSpec(id: 'qwen3-coder', name: 'Qwen3 Coder')],
              ),
            );
        expect(id, 'custom-my-gateway');
        final catalog = await container.read(modelCatalogProvider.future);
        expect(reads, 2, reason: 'the save invalidates the model catalog');
        expect(catalog!.groups.single.models.single.id, 'qwen3-coder');
        expect(catalog.groups.single.id, 'custom-my-gateway');
      } finally {
        container.dispose();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
  });

  test('D2-03_base_url_validation_rejects_unusable_urls', () {
    expect(baseUrlError(''), isNotNull);
    expect(baseUrlError('gw.example.com'), isNotNull, reason: 'no scheme');
    expect(baseUrlError('ftp://gw.example.com'), isNotNull, reason: 'not HTTP(S)');
    expect(baseUrlError('https://gw.example.com/v1?x=1'), isNotNull, reason: 'query is not part of a Base URL');
    expect(baseUrlError('https://gw.example.com/v1#x'), isNotNull, reason: 'fragment is not part of a Base URL');
    expect(baseUrlError('https://gw.example.com/v1'), isNull);
    // The mock model server's documented address is a valid custom Base URL.
    expect(baseUrlError('http://127.0.0.1:3901/v1'), isNull);
  });

  testWidgets('D2-03_invalid_base_url_shows_error', (tester) async {
    final backend = FakeProviderBackend();
    await _open(tester, backend);
    await _type(tester, 'Base URL', 'gw.example.com');
    await _type(tester, 'API Key', 'sk-1');
    await _addModel(tester, 'm1');

    await tester.tap(find.text('保存'));
    await settle(tester);
    expect(find.text('以 http:// 或 https:// 开头的完整地址'), findsOneWidget);
    // Nothing was written: no half-configured channel.
    expect(backend.callNames.where((c) => c != 'read'), isEmpty);
    expect(find.byType(ProviderFormPage), findsOneWidget);
  });

  testWidgets('D2-03_rejected_key_shows_readable_error_and_saves_nothing', (tester) async {
    final backend = FakeProviderBackend()..discoverError = listingRefused('https://gw.example.com/v1', 401);
    await _open(tester, backend);
    await _type(tester, 'Base URL', 'https://gw.example.com/v1');
    await _type(tester, 'API Key', 'sk-wrong');

    await tester.tap(find.text('获取模型'));
    await settle(tester);
    expect(find.text('API Key 无效或没有权限'), findsOneWidget);
    expect(backend.callNames.where((c) => c != 'read' && c != 'discover'), isEmpty);
    expect(find.byType(ModelPickerSheet), findsNothing);
    expect(find.byType(ProviderFormPage), findsOneWidget);

    // A pasted NAME=value line is refused before any request.
    await _type(tester, 'API Key', 'OPENAI_API_KEY=sk-123');
    await tester.tap(find.text('保存'));
    await settle(tester);
    expect(find.text('只粘贴 Key 本身，不带变量名'), findsOneWidget);
    expect(backend.callNames.where((c) => c != 'read' && c != 'discover'), isEmpty);
  });

  testWidgets('D2-03_edit_provider_isolated_to_one_channel', (tester) async {
    final backend = sampleBackend();
    final vault = MemoryProviderKeyVault({'custom-claude-relay': 'sk-claude'});
    await _open(tester, backend, existing: CustomProvider.fromProfile(gateway), vault: vault);
    final container = ProviderScope.containerOf(tester.element(find.byType(ProviderFormPage)));
    const picked = ModelSelection(provider: 'deepseek-official', model: 'deepseek-v4-pro');
    container.read(pendingModelProvider.notifier).select(picked);

    await _type(tester, 'Base URL', 'https://gw2.example.com/v1');
    await _type(tester, 'API Key', 'sk-gw-new');
    await tester.tap(find.text('保存'));
    await settle(tester);

    expect(backend.callNames.where((c) => c != 'read'), ['update', 'storeKey']);
    final update = backend.calls.firstWhere((c) => c.$1 == 'update').$2;
    expect(update['id'], 'custom-mygw');
    expect(update['baseURL'], 'https://gw2.example.com/v1');
    expect(update['expectedRevision'], 3);

    // The other two channels are byte-for-byte what they were.
    final relay = backend.profiles.firstWhere((p) => p.route == 'custom-claude-relay');
    expect(relay.baseUrl, 'https://relay.example.cn');
    expect(relay.apiKeyEnv, 'CUSTOM_CLAUDE_RELAY_API_KEY');
    expect(relay.models.single.id, 'claude-sonnet-4-5');
    final lan = backend.profiles.firstWhere((p) => p.route == 'custom-lan');
    expect(lan.baseUrl, 'http://192.168.1.20:8000/v1');
    expect(backend.stored['CUSTOM_LAN_API_KEY'], 'x');

    // Only the edited channel's Keychain item changed; the model selection
    // picked for the next chat is untouched.
    expect(vault.data['custom-mygw'], 'sk-gw-new');
    expect(vault.data['custom-claude-relay'], 'sk-claude');
    expect(container.read(pendingModelProvider), picked);
  });
}
