// D2-03-AC4 · 自定义渠道的额外请求头 — Phase 1 acceptance tests (L2).
//
// A compatible gateway may need extra request headers before it will infer
// (opencode-go wants `x-opencode-session`). The advanced section of the
// add/edit provider form carries them:
//   * names are RFC 7230 tokens, values carry no CR/LF or control character,
//     duplicate names (case-insensitively) and more than 20 rows are refused;
//   * create writes them into the profile, edit writes the whole current map
//     only when it changed (an emptied map clears the route's headers);
//   * existing headers read back into the form and survive a save of other
//     fields;
//   * header values never show up in logs or error text.
//
// L4-Real (opencode-go `deepseek-v4.1-flash` through the real engine) is the
// separate live harness; this file is the L2 widget/unit contract.

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/providers_state.dart';
import 'package:dsh_app/ui/providers/provider_form_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/support.dart';
import '../shell/golden_harness.dart' show goldenApp, loadGoldenFonts;

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

Future<void> _open(WidgetTester tester, FakeProviderBackend? backend, {CustomProvider? existing}) async {
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
      overrides: providerOverrides(backend),
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

Future<void> _openHeaders(WidgetTester tester) async {
  await tester.ensureVisible(find.text('请求头'));
  await tester.tap(find.text('请求头'));
  await settle(tester);
}

/// Flips the advanced section so the page rebuilds without typing into a field
/// (which would run the single-line formatter over the value again).
Future<void> _toggleHeaders(WidgetTester tester) async {
  await tester.ensureVisible(find.text('请求头'));
  await tester.tap(find.text('请求头'));
  await settle(tester);
  await tester.tap(find.text('请求头'));
  await settle(tester);
}

Finder _headerName(int i) => find.byKey(ValueKey('provider-header-name-$i'));

Finder _headerValue(int i) => find.byKey(ValueKey('provider-header-value-$i'));

Future<void> _addHeader(WidgetTester tester, {required int index, required String name, required String value}) async {
  await tester.ensureVisible(find.text('添加请求头'));
  await tester.tap(find.text('添加请求头'));
  await settle(tester);
  await tester.enterText(_headerName(index), name);
  await tester.enterText(_headerValue(index), value);
  await tester.pump();
}

Finder _saveButton() => find.widgetWithText(FilledButton, '保存');

bool _saveEnabled(WidgetTester tester) => tester.widget<FilledButton>(_saveButton()).onPressed != null;

/// Texts the page draws as plain Text (the form's own labels and messages, not
/// what a TextField holds while it is being edited).
Iterable<String> _drawnTexts(WidgetTester tester) =>
    tester.widgetList<Text>(find.byType(Text)).map((t) => t.data ?? t.textSpan?.toPlainText() ?? '');

CustomProvider _headedProvider({String value = 'sess-old'}) => CustomProvider.fromProfile(
  ProviderProfile(
    route: 'custom-headed',
    displayName: 'Headed Gateway',
    api: 'openai-completions',
    baseUrl: 'https://gw.example.com/v1',
    apiKeyEnv: 'CUSTOM_HEADED_API_KEY',
    models: const [ProviderModelSpec(id: 'qwen3-coder')],
    headers: {'X-Team': 'ops', 'x-opencode-session': value},
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => SharedPreferences.setMockInitialValues({}));

  group('validation', () {
    test('D2-03_provider_header_name_and_value_validation', () {
      // RFC 7230 token: tchar+ (`!#$%&'*+-.^_` | ~`, digits, letters).
      for (final good in ['x-opencode-session', 'X-Team', 'x-team_2', r"!#$%&'*+-.^_`|~", 'a1', 'A']) {
        expect(headerNameError(good), isNull, reason: good);
      }
      for (final bad in ['', ' ', '  x', 'x ', 'bad name', 'bad:name', 'bad\nname', 'bäd', 'bad(', 'x\u0000y']) {
        expect(headerNameError(bad), isNotNull, reason: bad);
      }

      for (final good in ['', 'sess-abc', 'a b', '值', 'x']) {
        expect(headerValueError(good), isNull, reason: good);
      }
      for (final bad in ['a\nb', 'a\rb', 'a\u0000b', 'a\u0007b', 'a\tb']) {
        expect(headerValueError(bad), isNotNull, reason: bad);
      }
    });

    test('D2-03_provider_headers_map_rejects_duplicates_empty_names_and_too_many_rows', () {
      expect(headersError(const {}), isNull);
      expect(headersError(const {'x-opencode-session': 'sess-7'}), isNull);
      expect(headersError(const {'X-Token': 'a', 'x-token': 'b'}), appL10n.providerHeaderDuplicate);
      expect(headersError(const {'': 'v'}), appL10n.providerHeaderInvalidName);
      expect(headersError(const {'bad name': 'v'}), appL10n.providerHeaderInvalidName);
      expect(headersError(const {'x-y': 'a\nb'}), appL10n.providerHeaderInvalidValue);
      expect(headersError(const {'x-y': 'a\rb'}), appL10n.providerHeaderInvalidValue);
      expect(headersError(const {'x-y': 'a\u0000b'}), appL10n.providerHeaderInvalidValue);

      final twenty = {for (var i = 0; i < 20; i++) 'x-header-$i': '$i'};
      expect(headersError(twenty), isNull);
      expect(headersError({...twenty, 'x-header-20': '20'}), appL10n.providerHeaderLimit);
    });

    test('D2-03_provider_headers_roundtrip_from_profile', () {
      const profile = ProviderProfile(
        route: 'custom-gw',
        displayName: 'GW',
        api: 'openai-completions',
        baseUrl: 'https://gw.example.com/v1',
        headers: {'X-Team': 'ops', 'x-opencode-session': 'sess-7'},
      );
      expect(CustomProvider.fromProfile(profile).headers, {'X-Team': 'ops', 'x-opencode-session': 'sess-7'});
      expect(
        ProviderProfile.fromJson('custom-gw', const {
          'headers': {'X-Team': 'ops'},
        }).headers,
        {'X-Team': 'ops'},
      );
      expect(
        const ProviderDraft(
          name: 'GW',
          api: ProviderApi.openaiCompletions,
          baseUrl: 'https://gw.example.com/v1',
        ).headers,
        isEmpty,
      );
    });
  });

  group('save', () {
    ProviderContainer container(FakeProviderBackend backend) {
      final c = ProviderContainer(
        overrides: [
          providerBackendProvider.overrideWithValue(backend),
          customProvidersProvider.overrideWith((ref) async => null),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    const model = [ProviderModelSpec(id: 'qwen3-coder')];

    test('D2-03_provider_headers_saved_on_create_and_updated_on_edit', () async {
      final backend = FakeProviderBackend();
      final actions = container(backend).read(providerActionsProvider);

      final id = await actions.save(
        const ProviderDraft(
          name: 'GW',
          api: ProviderApi.openaiCompletions,
          baseUrl: 'https://gw.example.com/v1',
          headers: {'x-opencode-session': 'sess-7'},
          models: model,
        ),
      );
      expect(id, 'custom-gw');
      expect(backend.profiles.singleWhere((p) => p.route == id).headers, {'x-opencode-session': 'sess-7'});

      // Edit: the whole current map is written when it changed.
      await actions.save(
        const ProviderDraft(
          name: 'GW',
          api: ProviderApi.openaiCompletions,
          baseUrl: 'https://gw.example.com/v1',
          headers: {'x-opencode-session': 'sess-8', 'X-Team': 'ops'},
          models: model,
        ),
        existing: CustomProvider.fromProfile(backend.profiles.singleWhere((p) => p.route == id)),
      );
      expect(backend.calls.last.$1, 'update');
      expect(backend.calls.last.$2['headers'], {'x-opencode-session': 'sess-8', 'X-Team': 'ops'});
      expect(backend.profiles.singleWhere((p) => p.route == id).headers, {
        'x-opencode-session': 'sess-8',
        'X-Team': 'ops',
      });

      // Unchanged headers are left out of the mutate, so nothing on the server
      // side is rewritten (or cleared) for a form that did not touch them.
      await actions.save(
        const ProviderDraft(
          name: 'GW 2',
          api: ProviderApi.openaiCompletions,
          baseUrl: 'https://gw.example.com/v1',
          headers: {'x-opencode-session': 'sess-8', 'X-Team': 'ops'},
          models: model,
        ),
        existing: CustomProvider.fromProfile(backend.profiles.singleWhere((p) => p.route == id)),
      );
      expect(backend.calls.last.$2.containsKey('headers'), isFalse);
      expect(backend.profiles.singleWhere((p) => p.route == id).headers, {
        'x-opencode-session': 'sess-8',
        'X-Team': 'ops',
      });

      // Removing every row clears the stored map.
      await actions.save(
        const ProviderDraft(
          name: 'GW 2',
          api: ProviderApi.openaiCompletions,
          baseUrl: 'https://gw.example.com/v1',
          models: model,
        ),
        existing: CustomProvider.fromProfile(backend.profiles.singleWhere((p) => p.route == id)),
      );
      expect(backend.calls.last.$2['headers'], isEmpty);
      expect(backend.profiles.singleWhere((p) => p.route == id).headers, isEmpty);
    });

    test('D2-03_provider_headers_invalid_map_is_never_written', () async {
      final backend = FakeProviderBackend();
      final actions = container(backend).read(providerActionsProvider);
      await expectLater(
        actions.save(
          const ProviderDraft(
            name: 'GW',
            api: ProviderApi.openaiCompletions,
            baseUrl: 'https://gw.example.com/v1',
            headers: {'bad name': 'v'},
            models: model,
          ),
        ),
        throwsA(isA<ProviderFailure>().having((e) => e.message, 'message', appL10n.providerHeaderInvalidName)),
      );
      expect(backend.calls.where((c) => c.$1 != 'read'), isEmpty);
    });
  });

  group('form', () {
    testWidgets('D2-03_provider_headers_typed_on_create_are_saved', (tester) async {
      final backend = FakeProviderBackend();
      await _open(tester, backend);

      await _type(tester, 'Base URL', 'https://gw.example.com/v1');
      await _type(tester, 'API Key', 'sk-gw');
      await _addModel(tester, 'qwen3-coder');
      await _openHeaders(tester);
      await _addHeader(tester, index: 0, name: 'x-opencode-session', value: 'sess-abc');

      expect(_saveEnabled(tester), isTrue);
      await tester.tap(_saveButton());
      await settle(tester);

      expect(backend.callNames.where((c) => c != 'read'), ['create', 'storeKey']);
      final create = backend.calls.firstWhere((c) => c.$1 == 'create').$2;
      expect(create['headers'], {'x-opencode-session': 'sess-abc'});
      expect(backend.profiles.single.headers, {'x-opencode-session': 'sess-abc'});
    });

    testWidgets('D2-03_provider_header_rows_can_be_removed', (tester) async {
      final backend = FakeProviderBackend();
      await _open(tester, backend);
      await _type(tester, 'Base URL', 'https://gw.example.com/v1');
      await _type(tester, 'API Key', 'sk-gw');
      await _addModel(tester, 'qwen3-coder');
      await _openHeaders(tester);
      await _addHeader(tester, index: 0, name: 'x-opencode-session', value: 'sess-abc');
      await tester.ensureVisible(find.byKey(const ValueKey('provider-header-remove-0')));
      await tester.tap(find.byKey(const ValueKey('provider-header-remove-0')));
      await settle(tester);
      expect(_headerName(0), findsNothing);

      await tester.tap(_saveButton());
      await settle(tester);
      expect(backend.calls.firstWhere((c) => c.$1 == 'create').$2.containsKey('headers'), isFalse);
    });

    testWidgets('D2-03_provider_headers_roundtrip_into_the_edit_form', (tester) async {
      final backend = FakeProviderBackend(profiles: [_headedProvider().toProfileForTest()]);
      await _open(tester, backend, existing: _headedProvider());

      // Existing headers are shown (the advanced section opens by default when
      // the route already has some) and are not dropped on save.
      expect(_headerName(0), findsOneWidget);
      expect(tester.widget<TextField>(_headerName(0)).controller!.text, 'X-Team');
      expect(tester.widget<TextField>(_headerValue(0)).controller!.text, 'ops');
      expect(tester.widget<TextField>(_headerName(1)).controller!.text, 'x-opencode-session');
      expect(tester.widget<TextField>(_headerValue(1)).controller!.text, 'sess-old');

      await tester.enterText(_headerValue(1), 'sess-new');
      await tester.pump();
      await tester.tap(_saveButton());
      await settle(tester);

      final update = backend.calls.firstWhere((c) => c.$1 == 'update').$2;
      expect(update['headers'], {'X-Team': 'ops', 'x-opencode-session': 'sess-new'});
      expect(backend.profiles.single.headers, {'X-Team': 'ops', 'x-opencode-session': 'sess-new'});
    });

    testWidgets('D2-03_provider_headers_invalid_name_or_value_disables_save', (tester) async {
      final backend = FakeProviderBackend();
      await _open(tester, backend);
      await _type(tester, 'Base URL', 'https://gw.example.com/v1');
      await _type(tester, 'API Key', 'sk-gw');
      await _addModel(tester, 'qwen3-coder');
      await _openHeaders(tester);

      await _addHeader(tester, index: 0, name: 'bad name', value: 'v');
      expect(find.text(appL10n.providerHeaderInvalidName), findsOneWidget);
      expect(_saveEnabled(tester), isFalse);

      // A single-line field strips pasted line breaks, so the action layer's
      // guard is what a value arriving another way (an import, the API) meets:
      // put one in the controller and rebuild the page.
      await _addHeader(tester, index: 1, name: 'x-opencode-session', value: 'sess-ok');
      tester.widget<TextField>(_headerValue(1)).controller!.text = 'sess-\nsecret-42';
      await _toggleHeaders(tester);
      expect(find.text(appL10n.providerHeaderInvalidValue), findsOneWidget);
      expect(_saveEnabled(tester), isFalse);
      expect(_drawnTexts(tester).join('\n'), isNot(contains('secret-42')));

      // Case-insensitive duplicates are refused.
      await tester.enterText(_headerName(0), 'X-Dup');
      await tester.enterText(_headerValue(0), 'one');
      await tester.enterText(_headerName(1), 'x-dup');
      await tester.enterText(_headerValue(1), 'two');
      await tester.pump();
      expect(find.text(appL10n.providerHeaderDuplicate), findsOneWidget);
      expect(_saveEnabled(tester), isFalse);

      // Nothing reached the engine.
      expect(backend.callNames.where((c) => c != 'read' && c != 'discover'), isEmpty);
    });

    testWidgets('D2-03_provider_header_values_are_not_logged_or_shown_in_errors', (tester) async {
      final printed = <String>[];
      final original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) printed.add(message);
      };
      try {
        final backend = FakeProviderBackend();
        await _open(tester, backend);
        await _type(tester, 'Base URL', 'https://gw.example.com/v1');
        await _type(tester, 'API Key', 'sk-gw');
        await _addModel(tester, 'qwen3-coder');
        await _openHeaders(tester);
        await _addHeader(tester, index: 0, name: 'x-opencode-session', value: 'session-value-7f3a');
        // A newline cannot be typed into the single-line editor; simulate a
        // value that reached the controller another way, then rebuild the page.
        tester.widget<TextField>(_headerValue(0)).controller!.text = 'session-value-7f3a\n';
        await _toggleHeaders(tester);

        // The value is in the editor (the user must be able to fix it) but not
        // in any message the form draws, nor in anything the app printed.
        expect(find.text(appL10n.providerHeaderInvalidValue), findsOneWidget);
        expect(_drawnTexts(tester).join('\n'), isNot(contains('session-value-7f3a')));
        for (final line in printed) {
          expect(line, isNot(contains('session-value-7f3a')));
        }
      } finally {
        debugPrint = original;
      }
    });
  });
}

extension on CustomProvider {
  /// The profile `CustomProvider` was read from, for a fake backend's store.
  ProviderProfile toProfileForTest() => ProviderProfile(
    route: id,
    displayName: displayName,
    api: api?.wire,
    baseUrl: baseUrl,
    apiKeyEnv: apiKeyEnv,
    models: models,
    headers: headers,
  );
}
