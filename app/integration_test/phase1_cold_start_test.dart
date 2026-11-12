// T30 process-level cold-start persistence, auto-start and unknown-result
// recovery (Phase 1 v1.1, gap G-03 + E1/E3/E4/B5).
//
// This file is driven by scripts/e2e/ios/run_cold_start_real.sh, which runs one
// `flutter test` process per phase and terminates the app with `simctl
// terminate` between them. The phases share one installed app/data container;
// the seed process leaves fixed expectations in SharedPreferences and the
// verify process re-reads the real engine/session/draft state after the cold
// launch. Every phase prints a marker and then keeps the app alive until the
// host kills it, so the process boundary is a real process boundary (it cannot
// be faked from inside this test).
//
// The main persistence flow uses the real opencode-go provider
// (`deepseek-v4.1-flash`, T25 broker key, `x-opencode-session` header). Only the
// crash/timing phase uses a deterministic in-test local model: a real model
// cannot be relied on to still be inside one tool call at the exact moment the
// host terminates the process.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/app.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/runtime/local_paths.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart' show RuntimePhase;
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/secrets/secure_storage.dart';
import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/draft_store.dart';
import 'package:dsh_app/state/locale_state.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/state/providers_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart' show ComposerTray;
import 'package:dsh_app/ui/chat/widgets/unknown_results_banner.dart';
import 'package:dsh_app/ui/onboarding/connect_page.dart';
import 'package:dsh_app/ui/onboarding/welcome_page.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/cold_start_env.dart';
import 'support/e2e_env.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('T30_cold_start_$kColdStartPhase', (tester) async {
    switch (kColdStartPhase) {
      case 'seed':
        await _seed(tester);
      case 'verify':
        await _verify(tester);
      case 'autostart_off':
        await _autostartOff(tester);
      case 'crash':
        await _crash(tester);
      case 'crash_verify':
        await _crashVerify(tester);
      default:
        fail('unknown E2E_PHASE "$kColdStartPhase" (seed|verify|autostart_off|crash|crash_verify)');
    }
  });
}

// ---------------------------------------------------------------------------
// seed: clean install → onboarding → real provider + model → real tool turn →
// session/messages/file recorded → unsent draft (text + attachment)

Future<void> _seed(WidgetTester tester) async {
  final clock = Stopwatch()..start();
  _step('seed: clean device state and boot the real app');
  await _resetDeviceState();
  await LocalPaths.load();
  runApp(const ProviderScope(child: DshApp()));
  await _waitFor(
    tester,
    'a real first screen',
    () =>
        find.byType(WelcomePage).evaluate().isNotEmpty ||
        find.byType(ConnectPage).evaluate().isNotEmpty ||
        find.byType(HomeShell).evaluate().isNotEmpty,
    timeout: const Duration(minutes: 3),
  );
  final container = _container(tester);

  _step('seed: first-run onboarding (the wrapper uninstalled the app)');
  final runtimeBefore = container.read(localRuntimeProvider).status;
  _log('before onboarding: runtime phase=${runtimeBefore.phase.name} '
      'installed=${runtimeBefore.installedVersion} bundled=${runtimeBefore.bundledVersion} '
      'welcome=${find.byType(WelcomePage).evaluate().length} '
      'connect=${find.byType(ConnectPage).evaluate().length} '
      'home=${find.byType(HomeShell).evaluate().length}');
  if (find.byType(WelcomePage).evaluate().isEmpty) _dumpTexts(tester);
  expect(find.byType(WelcomePage), findsOneWidget, reason: 'a clean install did not show the welcome page');
  await _finishOnboarding(tester);
  await _waitFor(
    tester,
    'home shell after onboarding',
    () => find.byType(HomeShell).evaluate().isNotEmpty,
    timeout: const Duration(minutes: 3),
  );

  _step('seed: local engine running');
  await _ensureEngineRunning(tester, container, allowExplicitStart: true);
  await _waitFor(
    tester,
    'the app connects to the local engine',
    () => container.read(providerBackendProvider) != null,
    timeout: const Duration(minutes: 2),
  );

  _step('seed: real opencode-go provider, model and request header');
  final providerId = await _installRealProvider(tester, container);
  _log('provider $providerId / $kE2eModel with $kE2eSessionHeader');

  _step('seed: one completed real-model turn that writes a workspace file');
  container.read(pendingModelProvider.notifier).select(ModelSelection(provider: providerId, model: kE2eModel));
  final sessionId = await _sendTurn(
    tester,
    container,
    prompt: kColdStartSeedPrompt,
    marker: kColdStartSeedReply,
    timeout: const Duration(minutes: 8),
  );
  _log('session created and turn finished: $sessionId');

  final chat = container.read(chatProvider(sessionId));
  final reply = chat.items.whereType<AssistantChatItem>().map((item) => item.text).join('\n');
  expect(reply, contains(kColdStartSeedReply), reason: 'the real model reply did not contain the seed marker');
  expect(chat.error, isNull, reason: 'the seed turn ended with an error: ${chat.error}');
  expect(chat.running, isFalse, reason: 'the seed turn is still running');

  final title = await _waitForTitle(tester, container, sessionId);
  _log('session title: "$title"');

  final connection = container.read(activeConnectionProvider).value;
  expect(connection, isNotNull, reason: 'the app lost its local connection before reading the workspace');
  expect(connection!.client, isNotNull);
  final stat = await _waitForWorkspaceFile(tester, container, sessionId, kColdStartWorkspaceFile, kColdStartWorkspaceMarker);
  final absolute = stat.absolutePath;
  expect(absolute, isNotEmpty, reason: 'the engine did not report the workspace file path');
  expect(
    absolute.startsWith('${LocalPaths.workspace}/'),
    isTrue,
    reason: 'the real tool wrote outside the session workspace: $absolute (workspace ${LocalPaths.workspace})',
  );
  _log('workspace file: $absolute');

  _step('seed: unsent draft (typed text + one real attachment)');
  final field = _composerField();
  await _waitFor(tester, 'composer in the seeded session', () => field.evaluate().isNotEmpty, timeout: const Duration(seconds: 60));
  await tester.enterText(field, kColdStartDraftText);
  await tester.pump();
  final attachment = DraftAttachment.sniff(kColdStartDraftAttachment, kColdStartDraftPng);
  final drafts = container.read(draftStoreProvider.notifier);
  drafts.save(sessionId, kColdStartDraftText, [attachment]);
  await tester.pump();
  await drafts.flush();
  final savedDraft = container.read(draftStoreProvider).drafts[sessionId];
  expect(savedDraft, isNotNull, reason: 'the draft was not saved into the store');
  expect(savedDraft!.text, kColdStartDraftText, reason: 'the draft text was not saved');
  expect(savedDraft.attachments, hasLength(1), reason: 'the draft attachment was not saved');
  expect(savedDraft.attachments.single.name, kColdStartDraftAttachment);
  expect(savedDraft.attachments.single.bytes, kColdStartDraftPng, reason: 'the saved attachment bytes differ');
  final prefs = await SharedPreferences.getInstance();
  final storedDrafts = prefs.getString(DraftStore.preferenceKey) ?? '';
  expect(storedDrafts, contains(kColdStartDraftText), reason: 'the draft text never reached SharedPreferences');
  expect(storedDrafts, contains(kColdStartDraftAttachment), reason: 'the attachment name never reached SharedPreferences');
  _log('draft stored: ${kColdStartDraftText.length} chars + ${attachment.size}B ${attachment.name}');

  _step('seed: record the fixed expectations for the next process');
  final record = ColdStartSeedRecord(
    sessionId: sessionId,
    title: title,
    prompt: kColdStartSeedPrompt,
    replyMarker: kColdStartSeedReply,
    workspaceFile: kColdStartWorkspaceFile,
    workspaceMarker: kColdStartWorkspaceMarker,
    workspacePath: absolute,
    draftText: kColdStartDraftText,
    attachmentName: kColdStartDraftAttachment,
    attachmentBytes: kColdStartDraftPng.length,
    createdAt: DateTime.now().toUtc(),
  );
  await prefs.setString(kColdStartSeedPrefs, record.encode());
  container.read(currentSessionProvider.notifier).select(sessionId);
  await Future<void>.delayed(const Duration(milliseconds: 600));
  await tester.pump();
  expect(prefs.getString(kColdStartSeedPrefs), isNotNull, reason: 'seed metadata was not stored');
  _log('seed metadata stored in $kColdStartSeedPrefs');

  // NSUserDefaults/JSONL reaches disk asynchronously. The host kills this
  // process immediately after PHASE-PASS, so let the writes settle first.
  await Future<void>.delayed(const Duration(seconds: 2));
  await tester.pump();

  coldStartLog(
    'PHASE-PASS seed session=$sessionId title="$title" workspace=$absolute '
    'attachment=${attachment.name}/${attachment.size}B elapsed=${clock.elapsedMilliseconds}ms',
  );
  await _holdForHost(tester);
}

// ---------------------------------------------------------------------------
// verify: cold launch → no onboarding → session/message/title → draft restored
// → engine auto-start running → a new real-model turn succeeds

Future<void> _verify(WidgetTester tester) async {
  final clock = Stopwatch()..start();
  _step('verify: cold launch after the host terminated the seed process');
  await LocalPaths.load();
  runApp(const ProviderScope(child: DshApp()));
  await _waitFor(
    tester,
    'home shell (no onboarding)',
    () => find.byType(HomeShell).evaluate().isNotEmpty,
    timeout: const Duration(minutes: 4),
  );
  final container = _container(tester);
  expect(find.byType(WelcomePage), findsNothing, reason: 'the cold launch showed onboarding again');
  expect(find.byType(ConnectPage), findsNothing, reason: 'the cold launch showed the connect step again');
  expect(find.byKey(const ValueKey('runtime-option-local')), findsNothing, reason: 'the cold launch asked to choose a runtime');
  _log('cold launch reached HomeShell without onboarding');

  final settings = container.read(settingsProvider);
  expect(settings.loaded, isTrue, reason: 'settings did not load');
  expect(settings.autoStartLocal, isTrue, reason: 'the auto-start setting was not on for the verify phase');

  _step('verify: recorded seed expectations are in the same data container');
  final prefs = await SharedPreferences.getInstance();
  final record = ColdStartSeedRecord.decode(prefs.getString(kColdStartSeedPrefs));
  expect(record, isNotNull, reason: 'the seed record is missing: this is not the seed data container');
  _log('seed record: session=${record!.sessionId} title="${record.title}" file=${record.workspacePath}');

  _step('verify: draft text and attachment restored by DraftStore (D4-07)');
  await _waitFor(
    tester,
    'drafts restored from the previous process',
    () => container.read(draftStoreProvider).loaded,
    timeout: const Duration(seconds: 90),
  );
  final draft = container.read(draftStoreProvider).drafts[record.sessionId];
  expect(draft, isNotNull, reason: 'the unsent draft was not restored after the cold launch');
  expect(draft!.text, record.draftText, reason: 'the restored draft text differs');
  expect(draft.attachments, hasLength(1), reason: 'the draft attachment was not restored');
  expect(draft.attachments.single.name, record.attachmentName, reason: 'the restored attachment name differs');
  expect(draft.attachments.single.bytes, kColdStartDraftPng, reason: 'the restored attachment bytes differ');
  expect(draft.attachments.single.size, record.attachmentBytes, reason: 'the restored attachment size differs');
  _log('draft restored: text=${draft.text.length} chars attachment=${draft.attachments.single.name}');

  _step('verify: engine auto-start reaches running without the test asking');
  await _waitForAutoStart(tester, container);
  final running = container.read(localRuntimeProvider).status;
  expect(running.baseUrl, isNotNull, reason: 'the auto-started engine has no base URL');
  expect(running.token, isNotNull, reason: 'the auto-started engine has no token');
  _log('engine running: ${running.installedVersion} baseUrl=${running.baseUrl}');
  await _waitFor(
    tester,
    'the app reconnects to the auto-started engine',
    () => container.read(providerBackendProvider) != null,
    timeout: const Duration(minutes: 2),
  );

  _step('verify: session, title and messages survived');
  final sessions = await _waitForSessions(tester, container, record.sessionId);
  final summary = sessions.where((row) => row.sessionId == record.sessionId).firstOrNull;
  expect(summary, isNotNull, reason: 'the seed session is gone from the session list');
  expect(summary!.blank, isFalse, reason: 'the seed session came back blank');
  final title = await _waitForTitle(tester, container, record.sessionId);
  expect(title, record.title, reason: 'the session title changed across the cold launch');
  _log('session persisted: ${record.sessionId} title="$title"');

  container.read(currentSessionProvider.notifier).select(record.sessionId);
  await _waitFor(tester, 'the persisted chat opens', () => find.byType(Composer).evaluate().isNotEmpty, timeout: const Duration(minutes: 2));
  await _waitForChat(tester, container, record.sessionId);
  final chat = container.read(chatProvider(record.sessionId));
  final users = chat.items.whereType<UserChatItem>().map((item) => item.text).toList();
  final assistants = chat.items.whereType<AssistantChatItem>().map((item) => item.text).join('\n');
  expect(users, contains(record.prompt), reason: 'the seed user message is missing after the cold launch');
  expect(assistants, contains(record.replyMarker), reason: 'the seed assistant reply is missing after the cold launch');
  _log('messages persisted: ${users.length} user, ${chat.items.whereType<AssistantChatItem>().length} assistant');

  _step('verify: the workspace file written by the real tool is still there');
  final connection = container.read(activeConnectionProvider).value;
  expect(connection, isNotNull, reason: 'the app is not connected to the auto-started engine');
  final stat = await connection!.client.statFile(record.sessionId, record.workspaceFile);
  final workspaceText = await connection.client.readWorkspaceText(record.sessionId, record.workspaceFile);
  expect(workspaceText.text.trim(), record.workspaceMarker, reason: 'the workspace file content changed across the cold launch');
  // The Simulator may reissue the app's data container when it reinstalls the
  // bundle; the app relocates its storage and the Host reports the file under
  // the new root. The relative workspace location is what must not change.
  expect(
    stat.absolutePath,
    '${LocalPaths.workspace}/${record.workspaceFile}',
    reason: 'the workspace file is not under the current workspace root',
  );
  _log('workspace file persisted: ${stat.absolutePath} (${stat.bytes}B); '
      'seed root was ${record.workspacePath}');
  if (stat.absolutePath != record.workspacePath) {
    _log('the data container was reissued across the process boundary; the app relocated its storage '
        '(seed=${record.workspacePath}, now=${stat.absolutePath})');
  }

  _step('verify: the restored draft is visible in the real composer');
  final field = _composerField();
  await _waitFor(
    tester,
    'restored draft text in the composer',
    () => field.evaluate().isNotEmpty && tester.widget<TextField>(field).controller?.text == record.draftText,
    timeout: const Duration(seconds: 60),
  );
  final tray = find.byType(ComposerTray);
  expect(tray, findsOneWidget, reason: 'the restored attachment is not in the composer tray');
  final trayWidget = tester.widget<ComposerTray>(tray);
  expect(trayWidget.items, hasLength(1), reason: 'the composer tray does not hold exactly one restored attachment');
  expect(trayWidget.items.single.name, record.attachmentName);
  expect(trayWidget.items.single.bytes, kColdStartDraftPng);
  _log('draft UI restored: text + ${trayWidget.items.single.name}');

  _step('verify: a new real-model turn in the same session succeeds');
  final close = find.descendant(of: tray, matching: find.byIcon(AppIcons.close));
  expect(close, findsOneWidget, reason: 'the restored attachment has no remove control');
  await tester.tap(close);
  await tester.pump();
  await tester.enterText(field, '');
  await tester.pump();
  final before = container.read(currentSessionProvider);
  await _sendInCurrentSession(tester, container, prompt: kColdStartVerifyPrompt, marker: kColdStartVerifyReply);
  expect(container.read(currentSessionProvider), before, reason: 'the new turn switched away from the persisted session');
  final after = container.read(chatProvider(record.sessionId));
  expect(after.error, isNull, reason: 'the new real-model turn ended with an error: ${after.error}');
  expect(
    after.items.whereType<AssistantChatItem>().any((item) => item.text.contains(kColdStartVerifyReply)),
    isTrue,
    reason: 'the new real-model reply did not land in the persisted session',
  );
  _log('new real-model turn in ${record.sessionId} succeeded');

  _step('verify: turn auto-start off for the next cold launch');
  await container.read(settingsProvider.notifier).setAutoStartLocal(false);
  expect(container.read(settingsProvider).autoStartLocal, isFalse);
  expect(prefs.getBool(kColdStartAutoStartPrefs), isFalse, reason: 'the auto-start preference did not persist');
  _log('auto-start preference written off');
  await Future<void>.delayed(const Duration(seconds: 2));
  await tester.pump();

  coldStartLog('PHASE-PASS verify session=${record.sessionId} title="$title" elapsed=${clock.elapsedMilliseconds}ms');
  await _holdForHost(tester);
}

// ---------------------------------------------------------------------------
// autostart_off: cold launch with the setting off must leave the engine alone;
// then the setting is turned back on for the remaining phases.

Future<void> _autostartOff(WidgetTester tester) async {
  final clock = Stopwatch()..start();
  expect(coldStartAutoStartOff, isTrue, reason: 'the wrapper did not pass E2E_AUTOSTART=off');
  _step('autostart_off: cold launch with auto-start switched off');
  await LocalPaths.load();
  runApp(const ProviderScope(child: DshApp()));
  await _waitFor(
    tester,
    'home shell (no onboarding)',
    () => find.byType(HomeShell).evaluate().isNotEmpty,
    timeout: const Duration(minutes: 4),
  );
  final container = _container(tester);
  expect(find.byType(WelcomePage), findsNothing);
  expect(find.byType(ConnectPage), findsNothing);
  final settings = container.read(settingsProvider);
  expect(settings.loaded, isTrue);
  expect(settings.autoStartLocal, isFalse, reason: 'the off setting did not survive the cold launch');
  expect(settings.autoStartLocalExplicit, isTrue, reason: 'the off setting was not the stored user choice');

  // The launch-time auto start runs once, shortly after the first home frame.
  // Watch long enough to see it not happen, and fail if anything asks the
  // engine to start or if a base URL shows up.
  final observed = <String>[];
  final started = Stopwatch()..start();
  while (started.elapsed < const Duration(seconds: 25)) {
    final state = container.read(localRuntimeProvider);
    if (state.loaded) {
      final phase = state.status.phase.name;
      if (observed.isEmpty || observed.last != phase) observed.add(phase);
      if (state.status.phase == RuntimePhase.running ||
          state.status.phase == RuntimePhase.starting ||
          state.status.phase == RuntimePhase.stopping ||
          state.status.phase == RuntimePhase.error) {
        fail('auto-start off still changed the engine phase to ${state.status.phase.name} '
            '(error=${state.status.error}); observed=$observed');
      }
      expect(state.status.baseUrl, isNull, reason: 'an auto-started engine exposed a base URL with auto-start off');
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await tester.pump();
  }
  final finalStatus = container.read(localRuntimeProvider).status;
  expect(observed, isNotEmpty, reason: 'the native runtime never reported a status');
  expect(observed.toSet(), {RuntimePhase.installed.name},
      reason: 'the engine was not left installed with auto-start off: $observed');
  expect(finalStatus.phase, RuntimePhase.installed, reason: 'auto-start off ended in ${finalStatus.phase.name}');
  expect(finalStatus.baseUrl, isNull);
  _log('auto-start off: engine never started for 25s; observed=$observed');

  _step('autostart_off: turn the setting back on for the remaining phases');
  await container.read(settingsProvider.notifier).setAutoStartLocal(true);
  final prefs = await SharedPreferences.getInstance();
  expect(container.read(settingsProvider).autoStartLocal, isTrue);
  expect(prefs.getBool(kColdStartAutoStartPrefs), isTrue, reason: 'the auto-start preference did not persist back on');
  _log('auto-start preference written back on');
  await Future<void>.delayed(const Duration(seconds: 1));
  await tester.pump();

  coldStartLog('PHASE-PASS autostart_off observed=${observed.join(",")} elapsed=${clock.elapsedMilliseconds}ms');
  await _holdForHost(tester);
}

// ---------------------------------------------------------------------------
// crash: a deterministic local model drives one slow real tool call; the host
// kills the process while the call is dispatched and its result is unknown.

Future<void> _crash(WidgetTester tester) async {
  final clock = Stopwatch()..start();
  _step('crash: cold launch, real engine, mock provider, slow real tool turn');
  await LocalPaths.load();
  runApp(const ProviderScope(child: DshApp()));
  await _waitFor(tester, 'home shell', () => find.byType(HomeShell).evaluate().isNotEmpty, timeout: const Duration(minutes: 4));
  final container = _container(tester);
  await _waitForAutoStart(tester, container);
  await _waitFor(
    tester,
    'the app connects to the local engine',
    () => container.read(providerBackendProvider) != null,
    timeout: const Duration(minutes: 2),
  );

  final mock = await _CrashModelServer.start();
  addTearDown(mock.close);
  final providerId = await _installCrashProvider(tester, container, mock);
  _log('crash mock provider $providerId -> http://127.0.0.1:${mock.port}/v1');

  final sessions = container.read(sessionsProvider.notifier);
  final sessionId = await sessions.create(autoApprove: false);
  final connection = container.read(activeConnectionProvider).value!;
  final presetCommand = await connection.client.setPermissionPreset(sessionId, 'danger-full-access');
  _log('crash permission command: success=${presetCommand.success} text=${presetCommand.text}');
  expect(presetCommand.success, isTrue, reason: 'the engine did not accept the full-access permission preset');
  final selected = await connection.client.setModel(sessionId, provider: providerId, model: kColdStartCrashModel);
  expect(selected.model, kColdStartCrashModel, reason: 'the crash session did not accept the deterministic mock model');
  // A bash command still asks on iOS even under full access (there is no real
  // sandbox backend); approving it is what lets the slow call be dispatched.
  container.read(chatProvider(sessionId).notifier).setAutoApprove(true);
  final preset = container.read(chatProvider(sessionId).notifier).projections.permissionPreset;
  _log('crash session effective permission preset=$preset');
  final record = ColdStartCrashRecord(
    sessionId: sessionId,
    providerId: providerId,
    model: kColdStartCrashModel,
    countFile: kColdStartCrashCountFile,
    command: kColdStartCrashCommand,
    prompt: kColdStartCrashPrompt,
  );
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(kColdStartCrashPrefs, record.encode());
  _log('crash session $sessionId preset=danger-full-access (so the slow bash call is really dispatched)');

  container.read(currentSessionProvider.notifier).select(sessionId);
  await _waitFor(tester, 'crash composer', () => find.byType(Composer).evaluate().isNotEmpty, timeout: const Duration(minutes: 2));
  await _sendInCurrentSession(tester, container, prompt: kColdStartCrashPrompt, marker: '', waitForReply: false);

  _step('crash: wait until the slow tool is in flight or its outcome is unknown');
  LifecycleSnapshot? snapshot;
  LifecycleCall? dispatched;
  ToolChatItem? engineUnknown;
  String? countText;
  var autoApproved = false;
  final wait = Stopwatch()..start();
  while (wait.elapsed < const Duration(minutes: 3)) {
    try {
      snapshot = await connection.client.getLifecycleStatus(sessionId, timeout: const Duration(seconds: 5));
      for (final call in snapshot.calls) {
        // The crash session runs exactly one slow tool; its name comes from the
        // engine's tool registry, so the dispatch state is more reliable than a
        // hard-coded tool name.
        if (call.active || call.dispatchActive || (!call.hasReturned && call.phase != 'prepared')) {
          dispatched = call;
        }
      }
    } catch (error) {
      _log('lifecycle read while the tool runs failed (retrying): $error');
    }
    try {
      countText = (await connection.client.readWorkspaceText(sessionId, kColdStartCrashCountFile)).text;
    } catch (_) {
      countText = null;
    }
    final chat = container.read(chatProvider(sessionId));
    if (chat.error != null) fail('the crash turn failed before the tool was in flight: ${chat.error}');
    // On iOS the bash tool's dispatch is gated behind an approval; when that
    // gate ends without a durable result the engine records the call as an
    // unknown outcome. That is the mid-turn interruption this phase needs.
    engineUnknown = chat.items.whereType<ToolChatItem>().where((tool) {
      return tool.status == ToolStatus.failed &&
          (tool.failure?.code == 'TOOL_OUTCOME_UNKNOWN' || tool.failure?.name == 'ToolOutcomeUnknownError');
    }).firstOrNull;
    final otherFailed = chat.items.whereType<ToolChatItem>().where((tool) {
      return tool.status == ToolStatus.failed &&
          tool.failure?.code != 'TOOL_OUTCOME_UNKNOWN' &&
          tool.failure?.name != 'ToolOutcomeUnknownError';
    }).toList();
    if (otherFailed.isNotEmpty) {
      final tool = otherFailed.first;
      fail('the crash tool failed before dispatch: name=${tool.name} '
          'failure=${tool.failure?.name}/${tool.failure?.code}/${tool.failure?.reason} '
          'result=${tool.resultText} approval=${tool.approvalOutcome}');
    }
    if (engineUnknown != null || (dispatched != null && (countText ?? '').contains(kColdStartCrashExecuted))) break;
    if (chat.approvals.isNotEmpty && !autoApproved) {
      autoApproved = true;
      _log('crash approval pending for ${chat.approvals.map((a) => a.toolName).join(',')}; allowing it once');
      container.read(chatProvider(sessionId).notifier).setAutoApprove(true);
    }
    if (wait.elapsed.inSeconds % 5 == 0 && wait.elapsed.inMilliseconds % 1000 < 250) {
      _log('crash poll: lifecycle=${snapshot?.state.wire} '
          'calls=${snapshot?.calls.map((c) => '${c.identity.name}:${c.phase}:active=${c.active}:dispatch=${c.dispatchActive}').toList()} '
          'running=${chat.running} approvals=${chat.approvals.map((a) => a.toolName).toList()} '
          'tools=${chat.items.whereType<ToolChatItem>().map((t) => '${t.name}:${t.status.name}').toList()}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await tester.pump();
  }
  if (engineUnknown == null) {
    expect(dispatched, isNotNull,
        reason: 'the slow call was never observed in flight and the engine recorded no unknown outcome; '
            'lifecycle state=${snapshot?.state.wire} '
            'calls=${snapshot?.calls.map((c) => '${c.identity.name}:${c.phase}:active=${c.active}').toList()}');
    expect(countText, contains(kColdStartCrashExecuted), reason: 'the tool produced no workspace side effect before the kill');
    expect(dispatched!.hasReturned, isFalse, reason: 'the slow tool already returned before the host could kill the app');
    _log('tool in flight: name=${dispatched.identity.name} seq=${dispatched.identity.callSeq} '
        'phase=${dispatched.phase} active=${dispatched.active} dispatchActive=${dispatched.dispatchActive}');
  } else {
    _log('engine recorded the interrupted tool as unknown: name=${engineUnknown.name} '
        'failure=${engineUnknown.failure?.name}/${engineUnknown.failure?.code} '
        'approval=${engineUnknown.approvalOutcome} lifecycle=${snapshot?.state.wire}');
  }

  // Filesystem baseline: how many times the tool's side effect was present
  // before the process boundary. The cold relaunch and the confirmation must
  // not increase it.
  final baselineLines = await _safeCountLines(connection.client, sessionId, kColdStartCrashCountFile);
  final updated = ColdStartCrashRecord(
    sessionId: sessionId,
    providerId: providerId,
    model: kColdStartCrashModel,
    countFile: kColdStartCrashCountFile,
    command: kColdStartCrashCommand,
    prompt: kColdStartCrashPrompt,
    baselineLines: baselineLines,
  );
  await prefs.setString(kColdStartCrashPrefs, updated.encode());
  await Future<void>.delayed(const Duration(seconds: 2));
  await tester.pump();

  coldStartLog(
    'CRASH-READY-TO-KILL session=$sessionId '
    'reason=${engineUnknown != null ? 'engine-unknown' : 'tool-in-flight'} '
    'callSeq=${dispatched?.identity.callSeq ?? -1} baselineLines=$baselineLines '
    'count=${(countText ?? '').trim()} elapsed=${clock.elapsedMilliseconds}ms',
  );
  // The host wrapper kills this process now. Staying alive keeps the tool
  // call unresolved instead of letting the turn finish.
  final until = DateTime.now().add(const Duration(minutes: 6));
  while (DateTime.now().isBefore(until)) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await tester.pump();
  }
  fail('the host never terminated the app during the slow tool turn');
}

// ---------------------------------------------------------------------------
// crash_verify: after the mid-turn kill, the banner must say the result is
// unknown; the tool must not run again before (or after) the confirmation.

Future<void> _crashVerify(WidgetTester tester) async {
  final clock = Stopwatch()..start();
  _step('crash_verify: cold launch after the host killed the app mid-tool');
  await LocalPaths.load();
  runApp(const ProviderScope(child: DshApp()));
  await _waitFor(tester, 'home shell', () => find.byType(HomeShell).evaluate().isNotEmpty, timeout: const Duration(minutes: 4));
  final container = _container(tester);
  expect(find.byType(WelcomePage), findsNothing);
  await _waitForAutoStart(tester, container);
  await _waitFor(
    tester,
    'the app connects to the auto-started engine',
    () => container.read(providerBackendProvider) != null,
    timeout: const Duration(minutes: 2),
  );

  final prefs = await SharedPreferences.getInstance();
  final record = ColdStartCrashRecord.decode(prefs.getString(kColdStartCrashPrefs));
  expect(record, isNotNull, reason: 'the crash record is missing: the crash phase did not reach its session');
  _log('crash record: session=${record!.sessionId} file=${record.countFile}');

  final connection = container.read(activeConnectionProvider).value!;
  final client = connection.client;

  _step('crash_verify: the engine recorded the call as unknown, not as success');
  LifecycleSnapshot? snapshot;
  final wait = Stopwatch()..start();
  while (wait.elapsed < const Duration(seconds: 90)) {
    try {
      snapshot = await client.getLifecycleStatus(record.sessionId, timeout: const Duration(seconds: 5));
      if (snapshot.hasUnknownResult) break;
    } catch (error) {
      _log('lifecycle read after the cold launch failed (retrying): $error');
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await tester.pump();
  }
  expect(snapshot, isNotNull, reason: 'the lifecycle route never answered after the cold launch');
  expect(snapshot!.hasUnknownResult, isTrue,
      reason: 'the interrupted tool call was not reported as unknown (state=${snapshot.state.wire})');
  final unresolved = snapshot.unresolvedCalls.toList();
  _log('lifecycle after cold launch: state=${snapshot.state.wire} '
      'unresolved=${unresolved.map((c) => '${c.identity.name}#${c.identity.callSeq}:${c.phase}').join(',')}');
  // The engine's own unknown placeholder (TOOL_OUTCOME_UNKNOWN) can exist
  // without a call row in the coordinator snapshot; the banner is driven by
  // hasUnknownResult, which is what this phase asserts.

  _step('crash_verify: the workspace side effect did not grow before confirmation');
  final before = await _safeCountLines(client, record.sessionId, record.countFile);
  expect(before, record.baselineLines,
      reason: 'the tool ran again before the user confirmed '
          '(baseline ${record.baselineLines}, now $before)');

  _step('crash_verify: the unknown-result banner is shown for the session');
  container.read(currentSessionProvider.notifier).select(record.sessionId);
  await _waitFor(tester, 'the recovered chat opens', () => find.byType(Composer).evaluate().isNotEmpty, timeout: const Duration(minutes: 2));
  await _waitFor(
    tester,
    'the unknown-result banner',
    () => find.byType(UnknownResultsBanner).evaluate().isNotEmpty &&
        find.text(appL10n.harmonyUnknownResults).evaluate().isNotEmpty,
    timeout: const Duration(minutes: 1),
  );
  expect(find.text(appL10n.harmonyUnknownResultsReview), findsOneWidget);
  // Opening the session resumes the agent, which reconciles: still one line.
  await Future<void>.delayed(const Duration(seconds: 2));
  await tester.pump();
  final afterResume = await _safeCountLines(client, record.sessionId, record.countFile);
  expect(afterResume, record.baselineLines,
      reason: 'opening the recovered session re-executed the tool '
          '(baseline ${record.baselineLines}, now $afterResume)');

  _step('crash_verify: the user confirms; the tool is still not re-executed');
  await tester.tap(find.text(appL10n.harmonyUnknownResultsReview));
  await tester.pumpAndSettle();
  await _waitFor(
    tester,
    'the confirmation dialog',
    () => find.text(appL10n.harmonyUnknownResultsContinue).evaluate().isNotEmpty,
    timeout: const Duration(seconds: 30),
  );
  await tester.tap(find.text(appL10n.harmonyUnknownResultsContinue));
  await tester.pumpAndSettle();
  await _waitFor(
    tester,
    'the banner to go after confirmation',
    () => find.text(appL10n.harmonyUnknownResults).evaluate().isEmpty,
    timeout: const Duration(seconds: 60),
  );
  final acknowledged = Stopwatch()..start();
  while (acknowledged.elapsed < const Duration(seconds: 60)) {
    final now = await client.getLifecycleStatus(record.sessionId, timeout: const Duration(seconds: 5));
    if (!now.hasUnknownResult) break;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  final afterConfirm = await _safeCountLines(client, record.sessionId, record.countFile);
  expect(afterConfirm, record.baselineLines,
      reason: 'confirming the unknown result re-executed the tool '
          '(baseline ${record.baselineLines}, now $afterConfirm)');
  _log('acknowledged; workspace side-effect lines still ${record.baselineLines}');

  coldStartLog('PHASE-PASS crash_verify session=${record.sessionId} elapsed=${clock.elapsedMilliseconds}ms');
  await _holdForHost(tester);
}

// ---------------------------------------------------------------------------
// Real provider

Future<String> _installRealProvider(WidgetTester tester, ProviderContainer container) async {
  E2eConfig.requireBroker();
  final key = await fetchBrokerKey();
  expect(key, isNotEmpty, reason: 'the credential broker returned an empty key');
  final snapshot = await _waitForProviders(tester, container);
  CustomProvider? existing;
  for (final provider in snapshot.providers) {
    if (provider.baseUrl == kE2eProviderBaseUrl) {
      existing = provider;
      break;
    }
  }
  final actions = container.read(providerActionsProvider);
  final String providerId;
  final draft = ProviderDraft(
    name: 'OpenCode Go (T30)',
    api: ProviderApi.openaiCompletions,
    baseUrl: kE2eProviderBaseUrl,
    apiKey: existing == null || !snapshot.keyStored(existing) ? key : '',
    models: const [ProviderModelSpec(id: kE2eModel, name: 'DeepSeek V4.1 Flash')],
    headers: {kE2eSessionHeader: newE2eSessionId()},
  );
  if (existing == null) {
    providerId = await actions.save(draft);
    _log('real provider created: $providerId');
  } else {
    providerId = existing.id;
    await actions.save(draft, existing: existing);
    _log('real provider reused: $providerId');
  }
  return _waitForCatalog(tester, container, providerId, kE2eModel);
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

Future<String> _waitForCatalog(
  WidgetTester tester,
  ProviderContainer container,
  String providerId,
  String model,
) async {
  final clock = Stopwatch()..start();
  while (clock.elapsed < const Duration(minutes: 3)) {
    try {
      container.invalidate(modelCatalogProvider);
      final catalog = await container.read(modelCatalogProvider.future).timeout(const Duration(seconds: 20));
      if (catalog != null && catalog.models.any((entry) => entry.provider == providerId && entry.id == model)) return providerId;
    } catch (error) {
      _log('model catalog read failed, retrying: $error');
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await tester.pump();
  }
  fail('model $providerId/$model did not appear in the engine catalog within 3 minutes');
}

Future<String> _installCrashProvider(
  WidgetTester tester,
  ProviderContainer container,
  _CrashModelServer mock,
) async {
  await _waitForProviders(tester, container);
  final actions = container.read(providerActionsProvider);
  final id = await actions.save(
    ProviderDraft(
      name: kColdStartCrashProviderName,
      api: ProviderApi.openaiCompletions,
      baseUrl: 'http://127.0.0.1:${mock.port}/v1',
      apiKey: kColdStartCrashKey,
      models: const [ProviderModelSpec(id: kColdStartCrashModel, name: 'T30 Crash Model')],
    ),
  );
  return _waitForCatalog(tester, container, id, kColdStartCrashModel);
}

// ---------------------------------------------------------------------------
// Session / turn helpers

Future<String> _sendTurn(
  WidgetTester tester,
  ProviderContainer container, {
  required String prompt,
  required String marker,
  required Duration timeout,
}) async {
  await _waitFor(tester, 'chat composer', () => find.byType(Composer).evaluate().isNotEmpty, timeout: const Duration(minutes: 2));
  container.read(currentSessionProvider.notifier).select(null);
  await _waitFor(
    tester,
    'new chat state',
    () => container.read(currentSessionProvider) == null,
    timeout: const Duration(seconds: 30),
  );
  final field = _composerField();
  for (var attempt = 0; attempt < 3; attempt++) {
    await tester.enterText(field, prompt);
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await tester.pump();
    if (tester.widget<TextField>(field).controller?.text == prompt) break;
    _log('composer draft was reset by the new-chat switch (attempt ${attempt + 1}), re-entering');
  }
  expect(tester.widget<TextField>(field).controller?.text, prompt, reason: 'the composer keeps clearing the prompt');
  await _waitForSendEnabled(tester);
  await tester.tap(_sendButton());
  await _waitFor(
    tester,
    'the send creates the conversation',
    () => container.read(currentSessionProvider) != null,
    timeout: timeout,
  );
  final sessionId = container.read(currentSessionProvider)!;
  await _waitForTurn(tester, container, sessionId, marker, timeout: timeout);
  return sessionId;
}

Future<void> _sendInCurrentSession(
  WidgetTester tester,
  ProviderContainer container, {
  required String prompt,
  required String marker,
  bool waitForReply = true,
}) async {
  final field = _composerField();
  for (var attempt = 0; attempt < 3; attempt++) {
    await tester.enterText(field, prompt);
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await tester.pump();
    if (tester.widget<TextField>(field).controller?.text == prompt) break;
  }
  expect(tester.widget<TextField>(field).controller?.text, prompt, reason: 'the composer keeps clearing the prompt');
  await _waitForSendEnabled(tester);
  await tester.tap(_sendButton());
  final sessionId = container.read(currentSessionProvider);
  expect(sessionId, isNotNull, reason: 'sending in a persisted session lost the session');
  if (waitForReply) {
    await _waitForTurn(tester, container, sessionId!, marker, timeout: const Duration(minutes: 8));
  } else {
    await _waitFor(
      tester,
      'the chat starts running',
      () => container.read(chatProvider(sessionId!)).running || container.read(chatProvider(sessionId)).items.isNotEmpty,
      timeout: const Duration(minutes: 2),
    );
  }
}

Future<void> _waitForSendEnabled(WidgetTester tester) async {
  final send = _sendButton();
  await _waitFor(
    tester,
    'send key enabled after typing',
    () {
      final composers = tester.widgetList<Composer>(find.byType(Composer)).toList();
      return send.evaluate().isNotEmpty &&
          composers.isNotEmpty &&
          composers.every((composer) => composer.connected && composer.sessionReady && !composer.busy);
    },
    timeout: const Duration(minutes: 2),
  );
}

Future<void> _waitForTurn(
  WidgetTester tester,
  ProviderContainer container,
  String sessionId,
  String marker, {
  required Duration timeout,
}) async {
  var autoApproved = false;
  final clock = Stopwatch()..start();
  while (clock.elapsed < timeout) {
    final chat = container.read(chatProvider(sessionId));
    if (chat.error != null) fail('the turn failed before it ended: ${chat.error}');
    if (!autoApproved && chat.approvals.isNotEmpty) {
      autoApproved = true;
      _log('approval requested for ${chat.approvals.map((a) => a.toolName).join(',')}; allowing it once (real UI feature)');
      container.read(chatProvider(sessionId).notifier).setAutoApprove(true);
    }
    final done = !chat.loading &&
        !chat.running &&
        chat.items.whereType<AssistantChatItem>().any((item) => !item.streaming && item.text.contains(marker));
    if (done) return;
    if (marker.isEmpty &&
        !chat.loading &&
        !chat.running &&
        chat.items.whereType<ToolChatItem>().isNotEmpty) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
  final chat = container.read(chatProvider(sessionId));
  final texts = chat.items
      .map((item) => switch (item) {
            UserChatItem(:final text) => 'user(${text.length}):${text.substring(0, text.length.clamp(0, 60))}',
            AssistantChatItem(:final text) => 'assistant(${text.length}):${text.substring(0, text.length.clamp(0, 60))}',
            _ => item.runtimeType.toString(),
          })
      .join(' | ');
  fail('the turn did not finish with the expected marker within ${timeout.inSeconds}s '
      '(running=${chat.running}, loading=${chat.loading}, items=$texts)');
}

Future<void> _waitForChat(WidgetTester tester, ProviderContainer container, String sessionId) async {
  await _waitFor(
    tester,
    'the persisted conversation loads',
    () {
      final chat = container.read(chatProvider(sessionId));
      return !chat.loading && chat.items.isNotEmpty;
    },
    timeout: const Duration(minutes: 2),
  );
  final chat = container.read(chatProvider(sessionId));
  if (chat.error != null) fail('the persisted conversation failed to load: ${chat.error}');
}

Future<String> _waitForTitle(WidgetTester tester, ProviderContainer container, String sessionId) async {
  final clock = Stopwatch()..start();
  String title = '';
  while (clock.elapsed < const Duration(minutes: 2)) {
    title = (container.read(chatProvider(sessionId).select((chat) => chat.title)) ?? '').trim();
    if (title.isNotEmpty) return title;
    try {
      final rows = await container.read(sessionsProvider.future).timeout(const Duration(seconds: 15));
      final row = rows.where((entry) => entry.sessionId == sessionId).firstOrNull;
      final listed = (row?.title ?? '').trim();
      if (listed.isNotEmpty) return listed;
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await tester.pump();
  }
  fail('the seeded session never got a title (session $sessionId)');
}

Future<List<SessionSummary>> _waitForSessions(WidgetTester tester, ProviderContainer container, String sessionId) async {
  final clock = Stopwatch()..start();
  while (clock.elapsed < const Duration(minutes: 2)) {
    try {
      final rows = await container.read(sessionsProvider.future).timeout(const Duration(seconds: 15));
      if (rows.any((row) => row.sessionId == sessionId)) return rows;
    } catch (error) {
      _log('session list read failed, retrying: $error');
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await tester.pump();
  }
  fail('the seeded session $sessionId never appeared in the session list');
}

Future<DshFileStat> _waitForWorkspaceFile(
  WidgetTester tester,
  ProviderContainer container,
  String sessionId,
  String file,
  String marker,
) async {
  final connection = container.read(activeConnectionProvider).value;
  expect(connection, isNotNull);
  final clock = Stopwatch()..start();
  Object? lastError;
  while (clock.elapsed < const Duration(minutes: 1)) {
    try {
      final stat = await connection!.client.statFile(sessionId, file);
      final text = await connection.client.readWorkspaceText(sessionId, file);
      if (text.text.trim() == marker) return stat;
      lastError = 'content "${text.text.trim()}" != "$marker"';
    } catch (error) {
      lastError = error;
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await tester.pump();
  }
  fail('the real model never wrote $file with the expected marker ($lastError)');
}

Future<int> _safeCountLines(DshClient client, String sessionId, String file) async {
  try {
    return (await _countLines(client, sessionId, file)).length;
  } catch (_) {
    return 0;
  }
}

Future<List<String>> _countLines(DshClient client, String sessionId, String file) async {
  final text = (await client.readWorkspaceText(sessionId, file)).text;
  return text
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
}

// ---------------------------------------------------------------------------
// Runtime helpers

Future<void> _ensureEngineRunning(WidgetTester tester, ProviderContainer container, {required bool allowExplicitStart}) async {
  var started = false;
  final clock = Stopwatch()..start();
  while (clock.elapsed < const Duration(minutes: 5)) {
    final state = container.read(localRuntimeProvider);
    if (state.loaded) {
      if (state.status.phase == RuntimePhase.running) return;
      if (state.status.phase == RuntimePhase.error) fail('engine error: ${state.status.error}');
      if (state.status.phase == RuntimePhase.installed && allowExplicitStart && !started) {
        started = true;
        _log('engine installed; the seed phase starts it explicitly');
        await container.read(localRuntimeProvider.notifier).start();
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pump();
  }
  await _waitForRuntimePhase(tester, container, RuntimePhase.running, const Duration(minutes: 3));
}

/// Waits for the launch-time auto start without ever asking for a start.
Future<void> _waitForAutoStart(WidgetTester tester, ProviderContainer container) async {
  final initial = container.read(localRuntimeProvider);
  final clock = Stopwatch()..start();
  while (!initial.loaded && clock.elapsed < const Duration(seconds: 60)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
  final loaded = container.read(localRuntimeProvider);
  expect(loaded.loaded, isTrue, reason: 'the native runtime never reported its first status');
  // The launch-time auto start can finish before this test reads the status;
  // a running engine here still came from the launch, because the test has not
  // asked for a start and the previous app process was terminated.
  expect(
    loaded.status.phase,
    anyOf(RuntimePhase.installed, RuntimePhase.starting, RuntimePhase.running),
    reason: 'this is not a cold engine: the launch started in ${loaded.status.phase.name}',
  );
  final phases = <String>[loaded.status.phase.name];
  final watch = Stopwatch()..start();
  while (watch.elapsed < const Duration(minutes: 4)) {
    final state = container.read(localRuntimeProvider);
    if (state.loaded) {
      if (state.status.phase.name != phases.last) phases.add(state.status.phase.name);
      if (state.status.phase == RuntimePhase.running) {
        final status = state.status;
        expect(status.baseUrl, isNotNull, reason: 'the auto-started engine has no base URL');
        expect(status.token, isNotNull, reason: 'the auto-started engine has no token');
        expect(status.error, isNull, reason: 'the auto-start reported an error: ${status.error}');
        _log('auto-start phases: ${phases.join(' -> ')}');
        return;
      }
      if (state.status.phase == RuntimePhase.error) {
        fail('the auto-start ended in error after ${phases.join(' -> ')}: ${state.status.error}');
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await tester.pump();
  }
  fail('the engine did not auto-start within 4 minutes (phases: ${phases.join(' -> ')})');
}

Future<void> _waitForRuntimePhase(
  WidgetTester tester,
  ProviderContainer container,
  RuntimePhase phase,
  Duration timeout,
) async {
  final clock = Stopwatch()..start();
  while (clock.elapsed < timeout) {
    final state = container.read(localRuntimeProvider);
    if (state.loaded && state.status.phase == phase) return;
    if (state.loaded && state.status.phase == RuntimePhase.error) {
      fail('the engine reported an error while waiting for ${phase.name}: ${state.status.error}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pump();
  }
  fail('the engine never reached ${phase.name} within ${timeout.inSeconds}s');
}

// ---------------------------------------------------------------------------
// Onboarding / device state (same real app path as the other L4 suites)

Future<void> _finishOnboarding(WidgetTester tester) async {
  if (find.byType(HomeShell).evaluate().isNotEmpty) {
    _log('first screen: home shell (phone already set up)');
    return;
  }
  if (find.byType(WelcomePage).evaluate().isNotEmpty) {
    _log('first screen: welcome page');
    await _tapFirst(tester, find.widgetWithText(FilledButton, appL10n.shellGetStarted), 'welcome 开始');
    await _waitFor(
      tester,
      'runtime choice',
      () => find.byKey(const ValueKey('runtime-option-local')).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 30),
    );
    await _tapFirst(tester, find.byKey(const ValueKey('runtime-option-local')), 'choose 本机');
    await _tapFirst(tester, find.widgetWithText(FilledButton, appL10n.commonContinue), 'runtime 继续');
  } else {
    _log('first screen: connect page (runtime already installed)');
  }
  if (find.byKey(const ValueKey('setup-appearance-card')).evaluate().isNotEmpty) {
    await _tapFirst(tester, find.widgetWithText(FilledButton, appL10n.commonContinue), 'appearance 继续');
  }
  await _waitFor(
    tester,
    'access step (or a later first-run page)',
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
      'connect step choices',
      () => find.text(appL10n.shellSetUpLater).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 60),
    );
    await _tapFirst(tester, find.text(appL10n.shellSetUpLater), 'connect 稍后设置');
  }
  await _waitFor(
    tester,
    'home shell (onboarding done)',
    () => find.byType(HomeShell).evaluate().isNotEmpty,
    timeout: const Duration(minutes: 3),
  );
}

Future<void> _resetDeviceState() async {
  final prefs = await SharedPreferences.getInstance();
  final cleared = await prefs.clear();
  _log('prefs.clear()=$cleared; remaining keys=${prefs.getKeys().toList()}');
  await prefs.setString(AppLanguageController.prefsKey, AppLanguage.zh.name);
  try {
    final storage = const AppSecureStorage();
    final secrets = await storage.readAll();
    for (final key in secrets.keys) {
      await storage.delete(key: key);
    }
    _log('cleared ${secrets.length} secure-storage entries');
  } catch (error) {
    _log('secure storage could not be cleared (continuing): $error');
  }
  await AppLanguageController.load();
  AppLocale.use(AppLocale.zhCN);
  expect(AppLanguageController.initial, AppLanguage.zh, reason: 'the UI language could not be pinned to Chinese');
}

// ---------------------------------------------------------------------------
// Deterministic local model for the crash/timing phase only

class _CrashModelServer {
  _CrashModelServer._(this._server) {
    _server.listen(_handle);
  }

  final HttpServer _server;
  int requests = 0;
  bool toolServed = false;

  int get port => _server.port;

  static Future<_CrashModelServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _CrashModelServer._(server);
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.method == 'GET' && request.uri.path == '/v1/models') {
        _json(request.response, 200, {
          'object': 'list',
          'data': [
            {'id': kColdStartCrashModel, 'object': 'model', 'created': 0, 'owned_by': 't30'},
          ],
        });
        return;
      }
      if (request.method == 'POST' && request.uri.path == '/v1/chat/completions') {
        final raw = await utf8.decodeStream(request);
        final body = jsonDecode(raw) as Map<String, Object?>;
        requests++;
        final tools = body['tools'];
        final messages = body['messages'] as List<Object?>? ?? const [];
        final hasToolResult = messages.whereType<Map<Object?, Object?>>().any((message) => message['role'] == 'tool');
        final wantsTool = tools is List && tools.isNotEmpty && !hasToolResult;
        final stream = body['stream'] == true;
        final model = '${body['model'] ?? kColdStartCrashModel}';
        _log('crash mock request #$requests model=$model stream=$stream tools=${tools is List ? tools.length : 0} '
            'toolResult=$hasToolResult');
        if (wantsTool) {
          toolServed = true;
          if (stream) {
            await _sseToolCall(request.response, model);
          } else {
            _json(request.response, 200, {
              'id': 'chatcmpl-t30-crash-1',
              'object': 'chat.completion',
              'created': 0,
              'model': model,
              'choices': [
                {
                  'index': 0,
                  'finish_reason': 'tool_calls',
                  'message': {
                    'role': 'assistant',
                    'content': 'Running the slow command.',
                    'tool_calls': [
                      {
                        'id': 'call_t30_crash_1',
                        'type': 'function',
                        'function': {'name': 'bash', 'arguments': jsonEncode({'command': kColdStartCrashCommand, 'timeoutMs': kColdStartCrashTimeoutMs})},
                      },
                    ],
                  },
                },
              ],
            });
          }
          return;
        }
        final text = 'T30 crash session';
        if (stream) {
          await _sseText(request.response, model, text);
        } else {
          _json(request.response, 200, {
            'id': 'chatcmpl-t30-crash-text',
            'object': 'chat.completion',
            'created': 0,
            'model': model,
            'choices': [
              {
                'index': 0,
                'finish_reason': 'stop',
                'message': {'role': 'assistant', 'content': text},
              },
            ],
          });
        }
        return;
      }
      _json(request.response, 404, {
        'error': {'message': 'not found: ${request.uri.path}'},
      });
    } catch (error) {
      try {
        _json(request.response, 500, {
          'error': {'message': '$error'},
        });
      } catch (_) {}
    }
  }

  Future<void> _sseToolCall(HttpResponse response, String model) async {
    final base = {'id': 'chatcmpl-t30-crash-1', 'object': 'chat.completion.chunk', 'created': 0, 'model': model};
    response
      ..statusCode = 200
      ..headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8')
      ..headers.set('cache-control', 'no-cache')
      ..bufferOutput = false;
    response.write('data: ${jsonEncode({...base, 'choices': [
      {'index': 0, 'delta': {'content': 'Running the slow command.'}, 'finish_reason': null},
    ]})}\n\n');
    response.write('data: ${jsonEncode({...base, 'choices': [
      {
        'index': 0,
        'delta': {
          'tool_calls': [
            {
              'index': 0,
              'id': 'call_t30_crash_1',
              'type': 'function',
              'function': {'name': 'bash', 'arguments': jsonEncode({'command': kColdStartCrashCommand, 'timeoutMs': kColdStartCrashTimeoutMs})},
            },
          ],
        },
        'finish_reason': null,
      },
    ]})}\n\n');
    response.write('data: ${jsonEncode({...base, 'choices': [
      {'index': 0, 'delta': const <String, Object?>{}, 'finish_reason': 'tool_calls'},
    ]})}\n\n');
    response.write('data: [DONE]\n\n');
    await response.close();
  }

  Future<void> _sseText(HttpResponse response, String model, String text) async {
    final base = {'id': 'chatcmpl-t30-crash-text', 'object': 'chat.completion.chunk', 'created': 0, 'model': model};
    response
      ..statusCode = 200
      ..headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8')
      ..headers.set('cache-control', 'no-cache')
      ..bufferOutput = false;
    response.write('data: ${jsonEncode({...base, 'choices': [
      {'index': 0, 'delta': {'content': text}, 'finish_reason': null},
    ]})}\n\n');
    response.write('data: ${jsonEncode({...base, 'choices': [
      {'index': 0, 'delta': const <String, Object?>{}, 'finish_reason': 'stop'},
    ]})}\n\n');
    response.write('data: [DONE]\n\n');
    await response.close();
  }

  void _json(HttpResponse response, int status, Object body) {
    final encoded = utf8.encode(jsonEncode(body));
    response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..headers.contentLength = encoded.length
      ..add(encoded);
    unawaited(response.close());
  }
}

// ---------------------------------------------------------------------------
// Waiting / drive helpers

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(DshApp)), listen: false);

Finder _composerField() => find.descendant(of: find.byType(Composer), matching: find.byType(TextField));

Finder _sendButton() => find.descendant(of: find.byType(Composer), matching: find.byIcon(AppIcons.send));

Future<void> _holdForHost(WidgetTester tester) async {
  coldStartLog('waiting for the host to terminate this process');
  final until = DateTime.now().add(const Duration(minutes: 6));
  while (DateTime.now().isBefore(until)) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await tester.pump();
  }
  fail('the host never terminated the app; phases must be ended by scripts/e2e/ios/run_cold_start_real.sh');
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
  await Future<void>.delayed(const Duration(milliseconds: 500));
  await tester.pump();
  try {
    await tester.ensureVisible(target);
  } catch (_) {}
  await tester.pump(const Duration(milliseconds: 150));
  await tester.tap(target);
  await Future<void>.delayed(const Duration(milliseconds: 250));
  await tester.pump();
}

void _step(String message) => coldStartLog('=== $message');

void _log(String message) => coldStartLog(message);

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
