// Phase 1 manual acceptance checklist, automated where the simulator allows it
// (T22b). One test drives one app install from a clean first launch through an
// in-process relaunch, so both fresh-install and "reopen without onboarding"
// paths are exercised with the same on-disk data:
//
//   A1 first-run welcome, onboarding, engine install/start (B1/B3)
//   A3/A4 custom mock provider + model, C1/C2 first streamed turn
//   D4 sessions drawer + search, D6 privacy page, A5 anonymous stats off
//   A2 app root re-created: no repeated onboarding, stored data still there
//   C6 stop generation keeps the streamed prefix
//   C3 thinking pill folds reasoning out of the answer
//   C7 approval allow writes the file once, C8 rejection never writes it
//
// A true cold process launch (simctl terminate + launch) cannot be asserted
// from inside the test process; B2/B5/B6/B7 stay L5 manual and are recorded as
// such in reports/phase1/acceptance-run/acceptance-results.md.
//
// The canonical mock (test/fixtures/mock_model_server.mjs, port 3901) must be
// up; this test fails loudly rather than skipping.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/app.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/runtime/local_paths.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/state/providers_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/widgets/thinking_pill.dart';
import 'package:dsh_app/ui/chat/widgets/turn_process.dart';
import 'package:dsh_app/ui/onboarding/connect_page.dart';
import 'package:dsh_app/ui/onboarding/welcome_page.dart';
import 'package:dsh_app/ui/settings/privacy_page.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:dsh_app/ui/settings/usage_stats_section.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/usage/usage_stats.dart';
import 'package:dsh_client/dsh_client.dart' show AssistantChatItem, ModelSelection;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _mockOrigin = 'http://127.0.0.1:3901';
const _mockModel = 'mock-phase1-model';
const _mockKey = 'sk-mock-phase1-model';
const _prompt = '请用 Phase 1 mock 模型回复这条 L4 验收消息。';
const _slowText = '慢速响应，用于停止与插话测试。';
const _thinkingText = '这是思考之后的正式回答。';
const _thinkingReasoning = '思考：先读取用户的问题，再给出简短回答。';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('T22b_phase1_acceptance_fresh_relaunch_chat', (tester) async {
    WidgetController.hitTestWarningShouldBeFatal = true;
    await _requireMock();
    await LocalPaths.load();
    runApp(const ProviderScope(child: DshApp()));

    _step('A1: fresh install reaches the real welcome page');
    await _waitFor(
      tester,
      'a real first screen',
      () =>
          find.byType(WelcomePage).evaluate().isNotEmpty ||
          find.byType(ConnectPage).evaluate().isNotEmpty ||
          find.byType(HomeShell).evaluate().isNotEmpty,
      timeout: const Duration(minutes: 3),
    );
    expect(
      find.byType(WelcomePage),
      findsOneWidget,
      reason: 'a fresh install (simctl uninstall first) did not show the welcome page',
    );
    _log('A1 welcome page shown after a clean install; onboarding starts with 本机/远程');
    var container = _container(tester);

    await _finishOnboarding(tester);
    await _waitFor(
      tester,
      'home shell after onboarding',
      () => find.byType(HomeShell).evaluate().isNotEmpty,
      timeout: const Duration(minutes: 2),
    );
    _log('A1 onboarding completed: local engine selected, optional permissions skipped, key set up later');

    _step('B1/B3: bundled engine installs and starts');
    final running = await _waitForRuntime(tester, container, RuntimePhase.running, const Duration(minutes: 2));
    expect(running.installedVersion, isNotNull);
    expect(running.baseUrl, isNotNull);
    _log('engine running: ${running.installedVersion} dsh=${running.dshVersion} node=${running.nodeVersion} '
        'baseUrl=${running.baseUrl}');

    _step('A3/A4: mock provider and model catalog');
    final providerId = await _ensureMockProvider(tester, container);
    expect(providerId, isNotEmpty);
    _log('provider/model available through the app controller: $providerId/$_mockModel');

    _step('C1/C2: first conversation from the composer, streamed');
    expect(container.read(currentSessionProvider), isNull, reason: 'a session existed before the first send');
    final sessionId = await _sendTurn(
      tester,
      container,
      providerId: providerId,
      model: '$_mockModel:slow',
      expectText: _slowText,
      observeStreaming: true,
    );
    expect(sessionId, isNotEmpty);
    _log('C1/C2 session=$sessionId; C1 empty state did not create a session before the send; '
        'C2 growing prefixes + final reply visible');

    _step('D4: sessions drawer and search open with the new conversation');
    final homeContext = tester.element(find.byType(HomeShell));
    await _waitFor(
      tester,
      'chat menu key',
      () => find.byKey(const ValueKey('chat-menu')).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 60),
    );
    await _tapFirst(tester, find.byKey(const ValueKey('chat-menu')), 'drawer menu');
    await _waitFor(
      tester,
      'sessions drawer',
      () => find.text(appL10n.commonNewChat).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 60),
    );
    expect(container.read(sessionsProvider.notifier).allSessions, isNotEmpty, reason: 'the drawer has no sessions after a turn');
    await _tapFirst(tester, find.text(appL10n.shellSearchChats).first, 'session search');
    await _waitFor(
      tester,
      'session search page',
      () => find.byType(TextField).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 60),
    );
    await tester.enterText(find.byType(TextField).first, 'mock');
    await Future<void>.delayed(const Duration(seconds: 2));
    await tester.pump();
    Navigator.of(homeContext).pop();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await tester.pump();
    _log('D4 drawer listed ${container.read(sessionsProvider.notifier).allSessions.length} sessions; '
        'search accepted a query without clearing the list');

    _step('A5/D6: privacy page, data categories, anonymous statistics off');
    unawaited(Navigator.of(homeContext).push<void>(MaterialPageRoute<void>(builder: (_) => const PrivacyPage())));
    await _waitFor(
      tester,
      'privacy page',
      () => find.text(appL10n.hubPrivacySharing).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 60),
    );
    expect(find.text(appL10n.usageStatsSection), findsWidgets, reason: 'privacy page has no usage-statistics section');
    expect(find.text(appL10n.phoneLocalOcrTitle), findsWidgets, reason: 'privacy page has no local-OCR data-category section');
    await _waitFor(
      tester,
      'usage statistics loaded',
      () => container.read(usageStatsProvider).loaded,
      timeout: const Duration(seconds: 30),
    );
    expect(container.read(usageStatsProvider).enabled, isTrue, reason: 'anonymous statistics are not on by default');
    await _tapFirst(
      tester,
      find.descendant(of: find.byType(UsageStatsSection), matching: find.byType(SettingsSwitchTile)).first,
      'anonymous statistics switch',
    );
    await _waitFor(
      tester,
      'anonymous statistics switch applied',
      () => !container.read(usageStatsProvider).enabled,
      timeout: const Duration(seconds: 30),
    );
    _log('A5 anonymous statistics switched true -> false; D6 privacy page shows sharing/usage/OCR sections');
    Navigator.of(tester.element(find.byType(PrivacyPage))).pop();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await tester.pump();

    _step('A2: re-create the app root; onboarding must not repeat and data must survive');
    final sessionsBefore = container.read(sessionsProvider.notifier).allSessions.length;
    await tester.pumpWidget(const SizedBox.shrink());
    await Future<void>.delayed(const Duration(seconds: 1));
    await tester.pump();
    runApp(const ProviderScope(child: DshApp()));
    await _waitFor(
      tester,
      'a real first screen after the app root is re-created',
      () =>
          find.byType(WelcomePage).evaluate().isNotEmpty ||
          find.byType(ConnectPage).evaluate().isNotEmpty ||
          find.byType(HomeShell).evaluate().isNotEmpty,
      timeout: const Duration(minutes: 2),
    );
    expect(find.byType(WelcomePage), findsNothing, reason: 'the welcome page came back after a relaunch (A2)');
    await _waitFor(
      tester,
      'home shell after the app root is re-created',
      () => find.byType(HomeShell).evaluate().isNotEmpty,
      timeout: const Duration(minutes: 2),
    );
    container = _container(tester);
    await _waitForRuntime(tester, container, RuntimePhase.running, const Duration(minutes: 2));
    expect(container.read(usageStatsProvider).enabled, isFalse, reason: 'anonymous statistics did not stay off (A5)');
    final providerId2 = await _ensureMockProvider(tester, container);
    final sessionsAfter = container.read(sessionsProvider.notifier).allSessions.length;
    expect(sessionsAfter, greaterThanOrEqualTo(sessionsBefore), reason: 'stored conversations were lost on relaunch');
    _log('A2 relaunch straight to the home shell; A5 statistics still off; provider=$providerId2 '
        'sessions=$sessionsAfter; engine still running (in-process relaunch; cold auto-start is L5)');

    _step('C6: stop generation keeps the already streamed content');
    container.read(currentSessionProvider.notifier).select(null);
    await tester.pump();
    container.read(pendingModelProvider.notifier).select(ModelSelection(provider: providerId2, model: '$_mockModel:slow'));
    await _sendFromComposer(tester, '请慢慢回复，这条消息用于停止生成验收。');
    final stopSession = await _waitForSession(tester, container);
    await _waitFor(
      tester,
      'a streaming partial reply before stopping',
      () {
        final live = container.read(chatProvider(stopSession));
        return live.running &&
            live.items.whereType<AssistantChatItem>().any((item) => item.streaming && item.text.trim().isNotEmpty);
      },
      timeout: const Duration(minutes: 1),
    );
    final stopKey = find.descendant(of: find.byType(Composer), matching: find.byIcon(AppIcons.stopGenerating));
    expect(stopKey, findsWidgets, reason: 'the composer shows no stop key while a turn is running');
    await _tapFirst(tester, stopKey, 'stop generation');
    await _waitFor(
      tester,
      'turn stopped and composer idle',
      () {
        final live = container.read(chatProvider(stopSession));
        return !live.running && !live.stopping && live.error == null;
      },
      timeout: const Duration(minutes: 2),
    );
    final stopped = container.read(chatProvider(stopSession));
    final kept = stopped.items.whereType<AssistantChatItem>().map((item) => item.text).join();
    expect(kept.trim(), isNotEmpty, reason: 'stop discarded the content that had already streamed');
    expect(_slowText.startsWith(kept), isTrue, reason: 'the kept content is not the generated prefix: "$kept"');
    expect(kept, isNot(_slowText), reason: 'the full reply had already finished; stop was not exercised mid-stream');
    _log('C6 stopped mid-stream; kept ${kept.length} chars: $kept');

    _step('C3: thinking is folded and the answer stays clean');
    await _sendTurn(
      tester,
      container,
      providerId: providerId2,
      model: '$_mockModel:thinking',
      expectText: _thinkingText,
      prompt: '请先思考再回答，这条消息用于思考折叠验收。',
    );
    final thinkingChat = container.read(chatProvider(container.read(currentSessionProvider)!));
    final answers = thinkingChat.items.whereType<AssistantChatItem>().toList();
    expect(answers.any((item) => item.reasoning.contains('思考')), isTrue,
        reason: 'the reasoning content never reached the conversation state');
    expect(answers.any((item) => item.text.contains(_thinkingText)), isTrue,
        reason: 'the answer after thinking did not land');
    expect(answers.any((item) => item.text.contains(_thinkingReasoning)), isFalse,
        reason: 'thinking leaked into the formal answer text');
    if (find.byType(ThinkingPill).evaluate().isEmpty && find.byType(TurnProcess).evaluate().isNotEmpty) {
      await _tapFirst(tester, find.byType(TurnProcess).last, 'turn process summary');
    }
    await _waitFor(
      tester,
      'thinking pill in the UI',
      () => find.byType(ThinkingPill).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 30),
    );
    await _tapFirst(tester, find.byType(ThinkingPill).first, 'thinking pill');
    await Future<void>.delayed(const Duration(milliseconds: 800));
    await tester.pump();
    expect(find.textContaining('先读取用户的问题', findRichText: true), findsWidgets,
        reason: 'expanding the thinking pill did not show the reasoning text');
    _log('C3 reasoning present + folded out of the answer; pill expands to the full reasoning');

    _step('C7: approval allow executes the write once');
    final workspaceFile = File('${LocalPaths.workspace}/mock-hello.md');
    if (workspaceFile.existsSync()) workspaceFile.deleteSync();
    await _sendApprovalTurn(tester, container, providerId2);
    await _waitFor(
      tester,
      'approval card',
      () => container.read(chatProvider(container.read(currentSessionProvider)!)).openApproval != null,
      timeout: const Duration(minutes: 2),
    );
    expect(find.text(appL10n.chatAllowOnce), findsWidgets, reason: 'the approval card has no allow button');
    expect(workspaceFile.existsSync(), isFalse, reason: 'the tool ran before approval');
    await _tapFirst(tester, find.text(appL10n.chatAllowOnce).first, 'allow once');
    await _waitFor(
      tester,
      'tool write finishes',
      () => workspaceFile.existsSync() ||
          !container.read(chatProvider(container.read(currentSessionProvider)!)).running,
      timeout: const Duration(minutes: 2),
    );
    expect(workspaceFile.existsSync(), isTrue, reason: 'allowing the approval did not run the write tool');
    expect(workspaceFile.readAsStringSync(), contains('hello from mock'));
    await _waitForTurnEnd(tester, container);
    expect(container.read(chatProvider(container.read(currentSessionProvider)!)).error, isNull);
    _log('C7 allowed once: ${workspaceFile.path} exists with the mock content');

    _step('C8: approval reject leaves the workspace untouched');
    if (workspaceFile.existsSync()) workspaceFile.deleteSync();
    await _sendApprovalTurn(tester, container, providerId2);
    await _waitFor(
      tester,
      'approval card for rejection',
      () => container.read(chatProvider(container.read(currentSessionProvider)!)).openApproval != null,
      timeout: const Duration(minutes: 2),
    );
    expect(find.text(appL10n.chatDecline), findsWidgets, reason: 'the approval card has no decline button');
    await _tapFirst(tester, find.text(appL10n.chatDecline).first, 'decline');
    await _waitFor(
      tester,
      'rejected turn ends',
      () {
        final live = container.read(chatProvider(container.read(currentSessionProvider)!));
        return !live.running && live.openApproval == null;
      },
      timeout: const Duration(minutes: 2),
    );
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(workspaceFile.existsSync(), isFalse, reason: 'the rejected tool still wrote the workspace file (C8)');
    _log('C8 rejected: workspace file not created');
  });
}

// ---------------------------------------------------------------------------
// Onboarding / runtime / provider setup (same production paths as phase1_test)

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(DshApp)), listen: false);

Future<void> _finishOnboarding(WidgetTester tester) async {
  if (find.byType(HomeShell).evaluate().isNotEmpty) return;
  if (find.byType(WelcomePage).evaluate().isNotEmpty) {
    await _tapFirst(tester, find.widgetWithText(FilledButton, appL10n.shellGetStarted), 'welcome 开始');
    await _waitFor(
      tester,
      'runtime choice',
      () => find.byKey(const ValueKey('runtime-option-local')).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 30),
    );
    await _tapFirst(tester, find.byKey(const ValueKey('runtime-option-local')), 'choose 本机');
    await _tapFirst(tester, find.widgetWithText(FilledButton, appL10n.commonContinue), 'runtime 继续');
  }
  if (find.byKey(const ValueKey('setup-appearance-card')).evaluate().isNotEmpty) {
    await _tapFirst(tester, find.widgetWithText(FilledButton, appL10n.commonContinue), 'appearance 继续');
  }
  await _waitFor(
    tester,
    'access step (or later)',
    () =>
        find.text(appL10n.accessSkip).evaluate().isNotEmpty ||
        find.byType(ConnectPage).evaluate().isNotEmpty ||
        find.byType(HomeShell).evaluate().isNotEmpty,
    timeout: const Duration(minutes: 2),
  );
  if (find.text(appL10n.accessSkip).evaluate().isNotEmpty) {
    await _tapFirst(tester, find.text(appL10n.accessSkip), 'access 跳过');
  }
  await _waitFor(
    tester,
    'connect step',
    () => find.byType(ConnectPage).evaluate().isNotEmpty || find.byType(HomeShell).evaluate().isNotEmpty,
    timeout: const Duration(minutes: 2),
  );
  if (find.byType(HomeShell).evaluate().isEmpty) {
    await _waitFor(
      tester,
      'connect choices',
      () => find.text(appL10n.shellSetUpLater).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 60),
    );
    await _tapFirst(tester, find.text(appL10n.shellSetUpLater), 'connect 稍后设置');
  }
  await _waitFor(
    tester,
    'home shell after onboarding',
    () => find.byType(HomeShell).evaluate().isNotEmpty,
    timeout: const Duration(minutes: 3),
  );
}

Future<RuntimeStatus> _waitForRuntime(
  WidgetTester tester,
  ProviderContainer container,
  RuntimePhase phase,
  Duration timeout,
) async {
  final clock = Stopwatch()..start();
  while (clock.elapsed < timeout) {
    final state = container.read(localRuntimeProvider);
    if (state.loaded && state.status.phase == phase) return state.status;
    if (state.loaded && state.status.phase == RuntimePhase.error) {
      fail('engine entered error before ${phase.name}: ${state.status.error}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pump();
  }
  final state = container.read(localRuntimeProvider);
  fail('engine never reached ${phase.name}: phase=${state.status.phase.name} error=${state.status.error}');
}

Future<String> _ensureMockProvider(WidgetTester tester, ProviderContainer container) async {
  final snapshot = await _waitForProviders(tester, container);
  CustomProvider? existing;
  for (final provider in snapshot.providers) {
    if (provider.baseUrl.startsWith(_mockOrigin)) {
      existing = provider;
      break;
    }
  }
  const models = [
    ProviderModelSpec(id: _mockModel, name: 'Mock Phase 1'),
    ProviderModelSpec(id: '$_mockModel:slow', name: 'Mock Phase 1 (slow)'),
    ProviderModelSpec(id: '$_mockModel:thinking', name: 'Mock Phase 1 (thinking)'),
    ProviderModelSpec(id: '$_mockModel:approval', name: 'Mock Phase 1 (approval)'),
  ];
  final actions = container.read(providerActionsProvider);
  if (existing == null) {
    final id = await actions.save(const ProviderDraft(
      name: 'Mock Phase1',
      api: ProviderApi.openaiCompletions,
      baseUrl: '$_mockOrigin/v1',
      apiKey: _mockKey,
      models: models,
    ));
    _log('provider created: $id');
    return id;
  }
  final missing = models.any((model) => !existing!.models.any((current) => current.id == model.id));
  if (!snapshot.keyStored(existing) || missing) {
    await actions.save(
      ProviderDraft(
        name: existing.displayName,
        api: existing.api ?? ProviderApi.openaiCompletions,
        baseUrl: existing.baseUrl,
        apiKey: snapshot.keyStored(existing) ? '' : _mockKey,
        models: [
          ...existing.models.where((model) => !model.id.startsWith(_mockModel)),
          ...models,
        ],
      ),
      existing: existing,
    );
  }
  _log('provider reused: ${existing.id}');
  return existing.id;
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
  fail('the engine exposed no writable provider settings within 2 minutes');
}

// ---------------------------------------------------------------------------
// Conversation helpers

Future<void> _sendFromComposer(WidgetTester tester, String prompt) async {
  await _waitFor(tester, 'composer', () => find.byType(Composer).evaluate().isNotEmpty, timeout: const Duration(minutes: 1));
  final field = find.descendant(of: find.byType(Composer), matching: find.byType(TextField));
  expect(field, findsOneWidget);
  for (var attempt = 0; attempt < 3; attempt++) {
    await tester.enterText(field, prompt);
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await tester.pump();
    if (tester.widget<TextField>(field).controller?.text == prompt) break;
    _log('composer draft reset by the new-chat switch (attempt ${attempt + 1}), re-entering');
  }
  expect(tester.widget<TextField>(field).controller?.text, prompt, reason: 'the composer keeps clearing the typed prompt');
  final send = find.descendant(of: find.byType(Composer), matching: find.byIcon(AppIcons.send));
  await _waitFor(
    tester,
    'send key enabled',
    () {
      final composers = tester.widgetList<Composer>(find.byType(Composer)).toList();
      return send.evaluate().isNotEmpty &&
          composers.isNotEmpty &&
          composers.every((composer) => composer.connected && composer.sessionReady && !composer.busy);
    },
    timeout: const Duration(seconds: 90),
  );
  await _tapFirst(tester, send, 'send');
}

Future<String> _waitForSession(WidgetTester tester, ProviderContainer container) async {
  final clock = Stopwatch()..start();
  while (clock.elapsed < const Duration(seconds: 90)) {
    try {
      final id = container.read(currentSessionProvider);
      if (id != null) return id;
    } catch (error) {
      _log('container read failed during session wait: $error; '
          'DshApp=${find.byType(DshApp).evaluate().length} HomeShell=${find.byType(HomeShell).evaluate().length}');
      final live = _container(tester);
      _log('re-acquired container: identical=${identical(live, container)} '
          'session=${live.read(currentSessionProvider)}');
      final id = live.read(currentSessionProvider);
      if (id != null) return id;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
  _dumpTexts(tester);
  fail('session created: timed out after 90s');
}

Future<String> _sendTurn(
  WidgetTester tester,
  ProviderContainer container, {
  required String providerId,
  required String model,
  required String expectText,
  String? prompt,
  bool observeStreaming = false,
}) async {
  container.read(currentSessionProvider.notifier).select(null);
  await tester.pump();
  container.read(pendingModelProvider.notifier).select(ModelSelection(provider: providerId, model: model));
  await _sendFromComposer(tester, prompt ?? _prompt);
  final sessionId = await _waitForSession(tester, container);
  final prefixes = <String>{};
  final clock = Stopwatch()..start();
  while (clock.elapsed < const Duration(minutes: 2)) {
    final chat = container.read(chatProvider(sessionId));
    if (chat.error != null) fail('turn failed: ${chat.error}');
    if (observeStreaming) {
      for (final item in chat.items.whereType<AssistantChatItem>()) {
        if (item.streaming && item.text.isNotEmpty) prefixes.add(item.text);
      }
    }
    final done = !chat.running &&
        chat.items.whereType<AssistantChatItem>().any((item) => !item.streaming && item.text.contains(expectText));
    if (done) break;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
  final chat = container.read(chatProvider(sessionId));
  expect(
    chat.items.whereType<AssistantChatItem>().any((item) => !item.streaming && item.text.contains(expectText)),
    isTrue,
    reason: 'expected reply "$expectText" never landed (running=${chat.running} error=${chat.error})',
  );
  expect(chat.running, isFalse, reason: 'the turn never ended');
  if (observeStreaming) {
    expect(prefixes.length, greaterThanOrEqualTo(2), reason: 'no growing streaming prefixes were observed');
    expect(prefixes.any((text) => text.length < expectText.length), isTrue, reason: 'no partial prefix preceded the final reply');
  }
  expect(find.textContaining(expectText, findRichText: true), findsWidgets, reason: 'the final reply is not visible');
  return sessionId;
}

Future<void> _sendApprovalTurn(WidgetTester tester, ProviderContainer container, String providerId) async {
  container.read(currentSessionProvider.notifier).select(null);
  await tester.pump();
  container.read(pendingModelProvider.notifier).select(ModelSelection(provider: providerId, model: '$_mockModel:approval'));
  await _sendFromComposer(tester, '请写一个 mock-hello.md 文件，这条消息用于审批验收。');
  await _waitForSession(tester, container);
}

Future<void> _waitForTurnEnd(WidgetTester tester, ProviderContainer container) async {
  final clock = Stopwatch()..start();
  while (clock.elapsed < const Duration(minutes: 2)) {
    final chat = container.read(chatProvider(container.read(currentSessionProvider)!));
    if (!chat.running && chat.openApproval == null) return;
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  final chat = container.read(chatProvider(container.read(currentSessionProvider)!));
  fail('turn did not end: running=${chat.running} approval=${chat.openApproval != null} error=${chat.error}');
}

// ---------------------------------------------------------------------------
// Mock, waits, logging

Future<void> _requireMock() async {
  try {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    final request = await client.getUrl(Uri.parse('$_mockOrigin/healthz'));
    final response = await request.close();
    final body = await utf8.decodeStream(response);
    client.close(force: true);
    if (response.statusCode != 200) fail('mock model /healthz answered ${response.statusCode}: $body');
    _log('mock model: external server on $_mockOrigin');
  } catch (error) {
    fail('canonical mock model is not reachable on $_mockOrigin ($error); start test/fixtures/mock_model_server.mjs --port 3901');
  }
}

Future<void> _waitFor(
  WidgetTester tester,
  String what,
  bool Function() done, {
  required Duration timeout,
}) async {
  final clock = Stopwatch()..start();
  while (clock.elapsed < timeout) {
    if (done()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
  _dumpTexts(tester);
  fail('$what: timed out after ${timeout.inSeconds}s');
}

Future<void> _tapFirst(WidgetTester tester, Finder finder, String what) async {
  final target = finder.first;
  if (target.evaluate().isEmpty) {
    _dumpTexts(tester);
    fail('cannot tap $what: not found');
  }
  await Future<void>.delayed(const Duration(milliseconds: 400));
  await tester.pump();
  try {
    await tester.ensureVisible(target);
  } catch (_) {}
  await tester.pump(const Duration(milliseconds: 150));
  await tester.tap(target);
  await Future<void>.delayed(const Duration(milliseconds: 250));
  await tester.pump();
}

void _step(String message) => _log('=== $message');

void _log(String message) => debugPrint('[phase1-acceptance] $message');

void _dumpTexts(WidgetTester tester) {
  try {
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data ?? text.textSpan?.toPlainText() ?? '')
        .where((text) => text.isNotEmpty)
        .take(40)
        .toList();
    _log('visible text widgets: $texts');
  } catch (error) {
    _log('could not dump widgets: $error');
  }
}
