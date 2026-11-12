// T27 · L4-Real: the real approval card (C7 allow / C8 deny) with the real
// opencode-go model, on a clean install.
//
// What this test proves, on the simulator, with the real on-device engine and
// the real model (no mock model):
//
//   * a clean install starts local conversations with the Host's
//     `workspace-write` / `ask` permission default — `autoApproveCommands` is
//     off, so an escalation must reach the person (the T22b gap);
//   * a real custom provider (`https://opencode.ai/inference/go/v1`,
//     `deepseek-v4.1-flash`, `x-opencode-session`) is created through the app's
//     own controller and its model is selected;
//   * the model asks for a sandbox escalation to write outside the workspace;
//     the approval card names the command/path and the reason, 「允许本次」
//     answers once, the write happens exactly once and the turn finishes;
//   * a second conversation asks for the same kind of approval for another
//     file; 「拒绝」 leaves the file absent, the tool row records the denial and
//     the turn ends without a retry storm.
//
// The key is fetched from the T25 loopback credential broker at run time
// (`E2E_BROKER_URL` / `E2E_BROKER_TOKEN`, started by
// `scripts/e2e/ios/run_approval_real.sh`) and is never printed, logged or
// asserted on.
//
// Screenshots are taken by the wrapper: this test writes a marker into the
// app's temporary directory when the approval card is on screen, then waits
// (bounded) for the wrapper to write the matching `.shot` marker after
// `xcrun simctl io ... screenshot`. Without the wrapper the test goes on
// after the bounded wait, so it still runs by hand.
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:dsh_app/app.dart';
import 'package:dsh_app/launch/startup_trace.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/runtime/local_paths.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/secrets/secure_storage.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/locale_state.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/state/provider_keys.dart';
import 'package:dsh_app/state/providers_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/features_state.dart';
import 'package:dsh_app/state/session_modes.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/widgets/approval_card.dart';
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

import 'support/e2e_env.dart';

const _providerName = 'OpenCode Go';
const _sessionHeader = 'dsh-go-ios-approval';

/// The T27 prompt names the exact outside-workspace target so the test does not
/// depend on how the engine's shell spells `$HOME`. The on-device bash terminal
/// is confined to the workspace even after escalation (its virtual filesystem
/// only mounts the workspace and a private temp root), so the one-shot
/// escalation must ride the `write` tool — the tool whose `danger-full-access`
/// policy is unfenced. The write is asked for explicitly so the turn raises
/// exactly one approval, and the parent directory is created by the test before
/// the prompt so the model has no reason to run a preparatory command.
const _escalationArgs = '"sandbox_permissions": "danger-full-access" 和 justification: "创建用户要求的审批验收文件"';

String _allowPromptFor(String target) =>
    '请直接用 write 工具创建文件 `$target`，内容为 `approved`。目录已经存在，不需要先运行任何命令。'
    '这需要完全访问权限，请在 write 的参数中带上 $_escalationArgs，然后等待我的批准。'
    '不要改用 bash，不要只解释，也不要改写其他路径。';

String _allowTightenedFor(String target) =>
    '上一个回复没有请求审批。请只调用一次 write 工具，file_path 必须是 `$target`，content 为 `approved`，'
    '参数中必须带 $_escalationArgs，然后等待我的批准。'
    '不要调用 bash，不要只解释，也不要改写其他路径。';

String _denyPromptFor(String target) =>
    '请再次用 write 工具创建另一个文件 `$target`，内容为 `approved`。目录已经存在，不需要先运行任何命令。'
    '这需要完全访问权限，请在 write 的参数中带上 '
    '"sandbox_permissions": "danger-full-access" 和 justification: "创建用户要求的第二个审批验收文件"，'
    '然后等待我的批准；如果被拒绝，不要重试，直接说明已取消。';

String _denyTightenedFor(String target) =>
    '上一个回复没有请求审批。请只调用一次 write 工具，file_path 必须是 `$target`，content 为 `approved`，'
    '参数中必须带 "sandbox_permissions": "danger-full-access" 和 justification: "创建用户要求的第二个审批验收文件"，'
    '然后等待我的批准。如果被拒绝就不要重试；不要调用 bash，不要只解释，也不要改写其他路径。';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final previousOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    _log('FlutterError: ${details.exceptionAsString()}\n${details.stack ?? ''}');
    previousOnError?.call(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    _log('uncaught async error: $error\n$stack');
    return true;
  };

  testWidgets('T27_L4_clean_default_real_approval_allow_and_deny', (tester) async {
    WidgetController.hitTestWarningShouldBeFatal = true;
    E2eConfig.requireBroker();
    final overall = Stopwatch()..start();

    _step('prepare device state and boot the real app');
    _log('app temp directory: ${Directory.systemTemp.path}');
    await _resetDeviceState();
    await LocalPaths.load();
    runApp(const ProviderScope(child: DshApp()));
    // This suite bypasses lib/main.dart, so the native startup watch would show
    // its "stuck starting" overlay over the app (and the screenshots) even
    // though the app is fine. Close it explicitly.
    StartupTrace.mark('integration test');
    StartupTrace.finished();

    await _waitFor(
      tester,
      'the app reaches a real first screen',
      () =>
          find.byType(WelcomePage).evaluate().isNotEmpty ||
          find.byType(ConnectPage).evaluate().isNotEmpty ||
          find.byType(HomeShell).evaluate().isNotEmpty,
      timeout: const Duration(minutes: 3),
    );
    final container = _container(tester);

    _step('clean install: onboarding (local engine, optional permissions skipped)');
    await _finishOnboarding(tester);
    await _waitFor(
      tester,
      'home shell after onboarding',
      () => find.byType(HomeShell).evaluate().isNotEmpty,
      timeout: const Duration(minutes: 2),
    );

    _step('real local engine: installed and running');
    final runtime = await _waitForRuntime(tester, container);
    expect(runtime.baseUrl, isNotNull);
    expect(runtime.token, isNotNull);
    _log(
      'runtime running: ${runtime.installedVersion} dsh=${runtime.dshVersion} '
      'node=${runtime.nodeVersion} baseUrl=${runtime.baseUrl}',
    );

    _step('C7/C8 precondition: clean permission default is workspace-write, not danger-full-access');
    await _waitForSettingsLoaded(tester, container);
    expect(
      container.read(settingsProvider).autoApproveCommands,
      isFalse,
      reason: 'a clean install auto-approved commands; the approval card would be unreachable',
    );
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getBool('auto_approve_commands'),
      isNull,
      reason: 'a clean install persisted a full-access choice it never showed the person',
    );
    final permission = await _waitForPermission(tester, container);
    expect(permission.hostDefault, 'workspace-write', reason: 'clean install default changed');
    expect(permission.hostDefault, isNot('danger-full-access'));
    expect(permission.invalidDefault, isFalse);
    _log(
      'permission default: ${permission.hostDefault} (autoApprove=${container.read(settingsProvider).autoApproveCommands})',
    );

    _step('real provider: opencode-go with the required session header');
    final key = await fetchBrokerKey();
    _log('credential broker answered (key not logged)');
    final providerId = await _createRealProvider(tester, container, key);
    final catalog = await _waitForModel(tester, container, providerId);
    expect(
      catalog.models.any((model) => model.provider == providerId && model.id == E2eConfig.model),
      isTrue,
      reason: '${E2eConfig.model} is not in the engine catalog',
    );
    container.read(pendingModelProvider.notifier).select(ModelSelection(provider: providerId, model: E2eConfig.model));
    _log('model selected: $providerId/${E2eConfig.model}');

    _step('C7: real model asks for a sandbox escalation; allow once writes the file');
    final engineHome = LocalPaths.home;
    final allowFile = File('$engineHome/Desktop/dsh-approval-ok.txt');
    // The target directory is setup, not the operation under test: creating it
    // here keeps the model from running a preparatory command (and thus from
    // raising a second approval) on the confined bash terminal.
    allowFile.parent.createSync(recursive: true);
    if (allowFile.existsSync()) allowFile.deleteSync();
    _log(
      'engine home=$engineHome home env=${Platform.environment['HOME']} '
      'tmp=${Directory.systemTemp.path} allow file=${allowFile.path}',
    );
    final allow = await _approvalTurn(
      tester,
      container,
      label: 'allow',
      prompt: _allowPromptFor(allowFile.path),
      tightenedPrompt: _allowTightenedFor(allowFile.path),
      decision: ApprovalDecision.allowOnce,
      expectedFile: allowFile,
      expectExists: true,
    );
    expect(allow.approvals, hasLength(1), reason: 'the allowed turn raised more than one approval: ${allow.approvals}');
    final writes = allow.items
        .whereType<ToolChatItem>()
        .where((item) => item.status == ToolStatus.succeeded && _writesFile(item, 'dsh-approval-ok.txt'))
        .toList();
    expect(
      writes,
      hasLength(1),
      reason:
          'the allowed file write ran more than once (or not at all); '
          'approvals=${allow.approvals.map((a) => a.toolName).toList()} '
          'items=${allow.items.whereType<ToolChatItem>().map((t) => '${t.name}:${t.status.name}:${t.arguments}').toList()}',
    );
    expect(allowFile.existsSync(), isTrue, reason: 'allowing the escalation did not create ${allowFile.path}');
    expect(allowFile.readAsStringSync().trim(), 'approved');
    _log(
      'allowed: ${allowFile.path} exists (content approved), '
      'tool=${writes.first.name} call=${writes.first.callId}, '
      'turn ended in ${allow.turnMs}ms',
    );
    await _snapshotSignal('done-a');

    _step('C8: second prompt in the same conversation; real model asks for another escalation; deny leaves no file');
    // Keep the same conversation: leaving it for a new chat swaps the composer's
    // draft scope, and a draft typed during that swap is cleared. The second
    // approval is about the denial, not about conversation creation.
    final denyFile = File('$engineHome/Desktop/dsh-approval-no.txt');
    denyFile.parent.createSync(recursive: true);
    if (denyFile.existsSync()) denyFile.deleteSync();
    final deny = await _approvalTurn(
      tester,
      container,
      label: 'deny',
      prompt: _denyPromptFor(denyFile.path),
      tightenedPrompt: _denyTightenedFor(denyFile.path),
      decision: ApprovalDecision.reject,
      expectedFile: denyFile,
      expectExists: false,
      startSession: allow.sessionId,
    );
    expect(deny.approvals, hasLength(1), reason: 'a denied approval was retried (retry storm): ${deny.approvals}');
    expect(denyFile.existsSync(), isFalse, reason: 'the denied escalation still created ${denyFile.path}');
    final denialRows = deny.items.whereType<ToolChatItem>().where(
      (item) =>
          item.arguments.contains('dsh-approval-no.txt') &&
          (item.status == ToolStatus.denied ||
              (item.status == ToolStatus.failed && item.resultText.toLowerCase().contains('denied'))),
    );
    expect(
      denialRows,
      isNotEmpty,
      reason:
          'the tool row does not record the denial: '
          '${deny.items.whereType<ToolChatItem>().map((t) => '${t.name}:${t.status.name}:${t.resultText}').toList()}',
    );
    _log('denied: ${denyFile.path} absent, denial row recorded, turn ended in ${deny.turnMs}ms');
    await _snapshotSignal('done-b');

    _step('session modes stayed workspace-write, not danger-full-access');
    // The first conversation is still selected in the drawer history; read its
    // own modes from the log the engine served.
    final allowSession = allow.sessionId;
    container.read(currentSessionProvider.notifier).select(allowSession);
    await tester.pump();
    final modes = await _waitForModes(tester, container, allowSession);
    expect(modes.preset, 'workspace-write', reason: 'the real session was not in workspace-write');
    expect(modes.risky, isFalse);

    final total = overall.elapsed;
    _log(
      'T27 PASS in ${total.inSeconds}s: '
      'allow approvals=${allow.approvals.length}, deny approvals=${deny.approvals.length}',
    );
    _snapshotSignal('done');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await tester.pump();
  }, timeout: const Timeout(Duration(minutes: 25)));
}

// ---------------------------------------------------------------------------
// Onboarding / runtime (same production paths as phase1_test)

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

Future<RuntimeStatus> _waitForRuntime(WidgetTester tester, ProviderContainer container) async {
  final clock = Stopwatch()..start();
  while (clock.elapsed < const Duration(minutes: 5)) {
    final state = container.read(localRuntimeProvider);
    if (state.loaded && state.status.phase == RuntimePhase.running) {
      // The app's own host connection is what the rest of the test uses.
      if (container.read(providerBackendProvider) != null) return state.status;
    }
    if (state.loaded && state.status.phase == RuntimePhase.error) {
      fail('engine entered error: ${state.status.error}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pump();
  }
  final state = container.read(localRuntimeProvider);
  fail('engine never reached running: phase=${state.status.phase.name} error=${state.status.error}');
}

Future<void> _waitForSettingsLoaded(WidgetTester tester, ProviderContainer container) async {
  final clock = Stopwatch()..start();
  while (clock.elapsed < const Duration(seconds: 60)) {
    if (container.read(settingsProvider).loaded) return;
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('settings never loaded');
}

Future<PermissionState> _waitForPermission(WidgetTester tester, ProviderContainer container) async {
  final clock = Stopwatch()..start();
  Object? lastError;
  while (clock.elapsed < const Duration(minutes: 2)) {
    try {
      container.invalidate(permissionStateProvider(null));
      final value = await container.read(permissionStateProvider(null).future).timeout(const Duration(seconds: 20));
      if (value != null) return value;
    } catch (error) {
      lastError = error;
      _log('permission read failed, retrying: $error');
    }
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  fail('permission state never loaded: $lastError');
}

// ---------------------------------------------------------------------------
// Real provider + model

Future<String> _createRealProvider(WidgetTester tester, ProviderContainer container, String key) async {
  final clock = Stopwatch()..start();
  while (clock.elapsed < const Duration(minutes: 2)) {
    try {
      final snapshot = await container.read(customProvidersProvider.future).timeout(const Duration(seconds: 20));
      if (snapshot != null && snapshot.supported && snapshot.writable) {
        final id = await container
            .read(providerActionsProvider)
            .save(
              const ProviderDraft(
                name: _providerName,
                api: ProviderApi.openaiCompletions,
                baseUrl: kE2eProviderBaseUrl,
                headers: {kE2eSessionHeader: _sessionHeader},
                models: [ProviderModelSpec(id: kE2eModel, name: 'DeepSeek V4.1 Flash')],
              ).copyForKey(key),
            );
        _log(
          'provider created: $id base=$kE2eProviderBaseUrl header=$kE2eSessionHeader'
          ' model=$kE2eModel',
        );
        return id;
      }
    } catch (error) {
      _log('provider snapshot/save failed, retrying: $error');
    }
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  fail('the local engine exposed no writable provider settings within 2 minutes');
}

extension on ProviderDraft {
  /// `ProviderDraft` has no `copyWith`; the key is injected here without
  /// putting it on the const draft or in any log line.
  ProviderDraft copyForKey(String key) =>
      ProviderDraft(name: name, api: api, baseUrl: baseUrl, apiKey: key, models: models, headers: headers);
}

Future<ModelCatalog> _waitForModel(WidgetTester tester, ProviderContainer container, String providerId) async {
  final clock = Stopwatch()..start();
  ModelCatalog? catalog;
  while (clock.elapsed < const Duration(minutes: 2)) {
    try {
      container.invalidate(modelCatalogProvider);
      catalog = await container.read(modelCatalogProvider.future).timeout(const Duration(seconds: 20));
    } catch (error) {
      _log('model catalog read failed, retrying: $error');
    }
    if (catalog != null && catalog.models.any((model) => model.provider == providerId && model.id == kE2eModel)) {
      return catalog;
    }
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  fail('model $kE2eModel is not in the engine catalog after 2 minutes');
}

// ---------------------------------------------------------------------------
// Approval turns

class _ApprovalTurnResult {
  _ApprovalTurnResult({
    required this.sessionId,
    required this.approvals,
    required this.items,
    required this.turnMs,
    required this.promptUsed,
  });

  final String sessionId;
  final List<ApprovalRequest> approvals;
  final List<ChatItem> items;
  final int turnMs;
  final String promptUsed;

  List<ToolChatItem> get successes =>
      items.whereType<ToolChatItem>().where((item) => item.status == ToolStatus.succeeded).toList();
}

/// Sends [prompt], waits for the approval card, answers it with [decision], and
/// checks [expectedFile]. When no card appears on the first attempt the
/// tightened prompt is sent once (T27's two-attempt rule); a card missing after
/// that fails the test, never skips.
Future<_ApprovalTurnResult> _approvalTurn(
  WidgetTester tester,
  ProviderContainer container, {
  required String label,
  required String prompt,
  required String tightenedPrompt,
  required ApprovalDecision decision,
  required File expectedFile,
  required bool expectExists,
  String? startSession,
}) async {
  final approvals = <ApprovalRequest>[];
  final seen = <String>{};
  var sessionId = container.read(currentSessionProvider) ?? '';
  var promptUsed = prompt;
  var turnMs = 0;
  var finalItems = <ChatItem>[];
  var lastState = const ChatState(loading: true);

  for (var attempt = 0; attempt < 2; attempt++) {
    // The first attempt is the prompt T27 specifies. The second is the
    // tightened tool-argument prompt; it also doubles as the repair attempt
    // when bash was approved but the virtual terminal could not reach the
    // path outside the workspace (only a real full-access write may do that).
    final text = attempt == 0 ? prompt : tightenedPrompt;
    final observed = await _sendAndObserve(
      tester,
      container,
      text,
      label: '$label-${attempt + 1}',
      session: attempt == 0 ? startSession : sessionId,
    );
    sessionId = observed.sessionId;
    promptUsed = text;
    turnMs += observed.turnMs;
    finalItems = [...observed.items];
    for (final approval in observed.approvals) {
      if (seen.add(approval.eventId)) approvals.add(approval);
    }

    if (observed.approvals.isEmpty) {
      final chat = await _waitTurnIdle(tester, container, sessionId, const Duration(minutes: 3));
      finalItems = [...chat.items];
      lastState = chat;
      _log(
        '$label-${attempt + 1}: no approval card (running=${chat.running}, error=${chat.error}, '
        'items=${_describe(chat.items)})',
      );
      if (attempt == 0) continue;
      _dumpTexts(tester);
      fail(
        '$label: the real model never requested a sandbox escalation after two attempts '
        '(the approval card is unreachable; this is a real FAIL, not a skip). '
        'Last state: ${_describe(finalItems)}',
      );
    }

    final approval = observed.approvals.first;
    await _waitFor(
      tester,
      '$label approval card',
      () => find.byType(ApprovalCard).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 20),
    );
    final card = tester.widget<ApprovalCard>(find.byType(ApprovalCard).first);
    final tool = _toolFor(observed.items, approval.callId);
    expect(card.request.eventId, approval.eventId);
    expect(approval.toolName, isNotEmpty, reason: '$label: the approval names no tool');
    expect(
      (approval.reason ?? approval.describe()).trim(),
      isNotEmpty,
      reason: '$label: the approval has no reason for the person',
    );
    _log(
      '$label-${attempt + 1} approval card: tool=${approval.toolName} callId=${approval.callId} '
      'reason=${approval.reason ?? approval.describe()} '
      'command=${tool?.arguments ?? '(not in the loaded transcript)'}',
    );
    // D3-06-AC1: the card names the path or command it asks about. The
    // Chinese approval card renders `view.command`/`view.path` from this same
    // tool call (L2 d3_06 covers that rendering); on L4 the transcript and
    // the request are the authoritative content.
    final targetName = label == 'allow' ? 'dsh-approval-ok.txt' : 'dsh-approval-no.txt';
    if (tool != null && tool.arguments.isNotEmpty) {
      expect(
        tool.arguments,
        contains(targetName),
        reason: '$label: the tool call the card asks about does not name $targetName',
      );
    } else {
      // The card can arrive before the tool/call row is in the loaded
      // transcript. The final tool-row assertions below still prove the exact
      // command/path; the screenshot shows what the person saw.
      _log('$label: the card landed before its tool/call row; command is asserted on the final row');
    }

    // The conversation stays scrolled to its bottom; bring the card's buttons
    // into view before the evidence screenshot and the tap. Close the keyboard
    // so it cannot cover the card on the smaller layout.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 300));
    final answerText = decision == ApprovalDecision.allowOnce ? appL10n.chatAllowOnce : appL10n.chatDecline;
    // Tap the label itself inside the card: the button widget can sit under a
    // route/entrance transform, while the visible text is what the person taps.
    final openCard = find.byWidgetPredicate(
      (widget) => widget is ApprovalCard && widget.request.eventId == approval.eventId,
    );
    final button = find.descendant(of: openCard, matching: find.text(answerText));
    expect(button, findsWidgets, reason: '$label: the card has no $answerText button');
    await _scrollIntoView(tester, button.last);

    await _snapshotSignal('card-$label');

    _log('$label: answering ${decision.name}');
    await _scrollIntoView(tester, button.last);
    // A person taps the visible label. Do not fall back to calling the card's
    // responder: a pet or another overlay covering the button is a real UI
    // defect (the pet is fixed to yield while a card waits), so a miss must
    // fail loudly instead of turning the L4 check into an API call.
    await _tapFirst(tester, button.last, '$label approval answer');
    _log(
      '$label: tapped $answerText; cards=${find.byType(ApprovalCard).evaluate().length} '
      'chat.running=${container.read(chatProvider(sessionId)).running} '
      'open=${container.read(chatProvider(sessionId)).openApproval?.eventId}',
    );
    final lastTap = <String, DateTime>{approval.eventId: DateTime.now()};

    // Wait for the turn to settle, answering any unexpected follow-up card with
    // the same decision so a stuck turn cannot hide a retry; the retry count is
    // asserted by the caller.
    final clock = Stopwatch()..start();
    var last = container.read(chatProvider(sessionId));
    var nextSettleLog = 0;
    while (clock.elapsed < const Duration(minutes: 5)) {
      last = container.read(chatProvider(sessionId));
      if (clock.elapsedMilliseconds - nextSettleLog >= 2000) {
        nextSettleLog = clock.elapsedMilliseconds + 2000;
        _log(
          '$label: settling ${clock.elapsed.inSeconds}s: running=${last.running} syncing=${last.syncing} '
          'streamLost=${last.streamLost} stopping=${last.stopping} pending=${last.pending.length} '
          'approvals=${last.approvals.map((a) => a.eventId).join(',')} '
          'open=${last.openApproval?.eventId} error=${last.error} items=${_describe(last.items)}',
        );
      }
      final extra = last.openApproval;
      if (extra != null) {
        if (!seen.contains(extra.eventId)) {
          seen.add(extra.eventId);
          approvals.add(extra);
          _log('$label: another approval arrived (${extra.eventId}); answering ${decision.name} too');
        }
        // The first tap may land while the previous response is still in
        // flight (the card disables its buttons). Retry until the card is
        // actually answered; a later duplicate is impossible once it is gone.
        final tapped = lastTap[extra.eventId];
        if (tapped == null || DateTime.now().difference(tapped) > const Duration(milliseconds: 1500)) {
          lastTap[extra.eventId] = DateTime.now();
          final again = decision == ApprovalDecision.allowOnce
              ? find.widgetWithText(FilledButton, answerText)
              : find.widgetWithText(OutlinedButton, answerText);
          if (again.evaluate().isNotEmpty) {
            await _scrollIntoView(tester, again.first);
            await _tapFirst(tester, again.first, '$label extra approval');
          }
        }
      }
      if (!last.running && last.openApproval == null) break;
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (last.running) {
      _dumpTexts(tester);
      fail('$label: the turn is still running after 5 minutes (error=${last.error})');
    }
    if (last.error != null) fail('$label: the turn ended with an error: ${last.error}');
    finalItems = [...last.items];
    lastState = last;
    turnMs += clock.elapsedMilliseconds;

    final fileClock = Stopwatch()..start();
    while (expectExists && !expectedFile.existsSync() && fileClock.elapsed < const Duration(seconds: 60)) {
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!expectExists) {
      // Give a late side effect a moment to show up before asserting absence.
      await Future<void>.delayed(const Duration(seconds: 3));
      await tester.pump();
    }
    if (decision == ApprovalDecision.reject || !expectExists || expectedFile.existsSync()) break;
    if (attempt == 0) {
      _log(
        '$label: the allowed ${approval.toolName} did not create ${expectedFile.path}; '
        'repairing with the tightened write prompt',
      );
    }
  }

  if (expectExists && !expectedFile.existsSync()) {
    _log(
      '$label: tool rows: ${lastState.items.whereType<ToolChatItem>().map((t) => '${t.name}[${t.status.name}] ${t.arguments} => ${t.resultText}').join(' | ')}',
    );
  }
  final observed = _ApprovalTurnResult(
    sessionId: sessionId,
    approvals: approvals,
    items: finalItems,
    turnMs: turnMs,
    promptUsed: promptUsed,
  );
  _log(
    '$label: result approvals=${approvals.length} '
    'tools=[${finalItems.whereType<ToolChatItem>().map((t) => '${t.name}:${t.status.name}').join(',')}] '
    'file ${expectedFile.path} exists=${expectedFile.existsSync()} (expected $expectExists)',
  );
  return observed;
}

class _ObservedTurn {
  _ObservedTurn({required this.sessionId, required this.approvals, required this.items, required this.turnMs});

  final String sessionId;
  final List<ApprovalRequest> approvals;
  final List<ChatItem> items;
  final int turnMs;
}

Future<_ObservedTurn> _sendAndObserve(
  WidgetTester tester,
  ProviderContainer container,
  String prompt, {
  required String label,
  String? session,
}) async {
  final started = Stopwatch()..start();
  final before = container.read(currentSessionProvider);
  if (session != null && container.read(currentSessionProvider) != session) {
    container.read(currentSessionProvider.notifier).select(session);
    final wait = Stopwatch()..start();
    while (wait.elapsed < const Duration(seconds: 30) && container.read(currentSessionProvider) != session) {
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(
      container.read(currentSessionProvider),
      session,
      reason: 'could not reselect the conversation before the next prompt',
    );
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
  await _sendPrompt(tester, container, prompt);
  final clock = Stopwatch()..start();
  String? sessionId = session ?? container.read(currentSessionProvider);
  final approvals = <ApprovalRequest>[];
  final seen = <String>{};
  ProviderSubscription<ChatState>? sub;
  ChatState last = const ChatState(loading: true);
  var accepted = false;
  var idlePolls = 0;
  var lastLog = 0;
  try {
    while (clock.elapsed < const Duration(minutes: 5)) {
      sessionId ??= container.read(currentSessionProvider);
      if (sessionId == null) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        continue;
      }
      last = container.read(chatProvider(sessionId));
      sub ??= container.listen<ChatState>(chatProvider(sessionId), (_, next) {
        for (final approval in next.approvals) {
          if (seen.add(approval.eventId)) approvals.add(approval);
        }
      }, fireImmediately: true);
      for (final approval in last.approvals) {
        if (seen.add(approval.eventId)) approvals.add(approval);
      }
      // A freshly created conversation loads empty and idle before the send
      // is accepted. A pending prompt, the user's row or a running turn is
      // what proves the send reached the engine; an idle empty state is not
      // the end of a turn that never started.
      if (last.running || last.pending.isNotEmpty || last.items.any((item) => item is UserChatItem)) {
        accepted = true;
        idlePolls = 0;
      }
      if (clock.elapsedMilliseconds - lastLog >= 2000) {
        lastLog = clock.elapsedMilliseconds;
        _log(
          '$label: observing $sessionId: running=${last.running} loading=${last.loading} '
          'pending=${last.pending.length} approvals=${last.approvals.length} '
          'accepted=$accepted items=${_describe(last.items)} error=${last.error}',
        );
      }
      if (approvals.isNotEmpty) {
        await tester.pump();
        if (find.byType(ApprovalCard).evaluate().isNotEmpty) break;
      }
      // The turn is over only after it was accepted and stays idle for two
      // full seconds (the running flag flickers between events).
      if (accepted && !last.running && last.pending.isEmpty && last.openApproval == null && last.error == null) {
        idlePolls++;
        if (idlePolls >= 20) break;
      } else {
        idlePolls = 0;
      }
      if (!accepted && clock.elapsed > const Duration(seconds: 30)) {
        _log('$label: the prompt never reached the engine (no pending prompt, running turn or user row)');
        break;
      }
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  } finally {
    sub?.close();
  }
  final id = sessionId ?? before ?? (throw StateError('$label: no session was created'));
  _log(
    '$label: prompt sent to $id, approvals=${approvals.length}, running=${last.running}, '
    'elapsed=${started.elapsedMilliseconds}ms, items=${_describe(last.items)}',
  );
  return _ObservedTurn(sessionId: id, approvals: approvals, items: last.items, turnMs: started.elapsedMilliseconds);
}

Future<void> _sendPrompt(WidgetTester tester, ProviderContainer container, String prompt) async {
  await _waitFor(
    tester,
    'composer',
    () => find.byType(Composer).evaluate().isNotEmpty,
    timeout: const Duration(minutes: 1),
  );
  final field = find.descendant(of: find.byType(Composer), matching: find.byType(TextField));
  expect(field, findsOneWidget, reason: 'the composer has no text field');

  List<Composer> composers() => tester.widgetList<Composer>(find.byType(Composer)).toList();

  /// Wait until the composer is idle and accepting a send.
  Future<void> waitIdle() async {
    final clock = Stopwatch()..start();
    var nextLog = 0;
    while (clock.elapsed < const Duration(seconds: 150)) {
      final list = composers();
      final send = find.descendant(of: find.byType(Composer), matching: find.byIcon(AppIcons.send));
      final ready =
          send.evaluate().isNotEmpty &&
          list.isNotEmpty &&
          list.every((composer) => composer.connected && composer.sessionReady && !composer.busy);
      if (ready) return;
      if (clock.elapsedMilliseconds >= nextLog) {
        nextLog = clock.elapsedMilliseconds + 5000;
        final fields = list
            .map(
              (composer) =>
                  'connected=${composer.connected} sessionReady=${composer.sessionReady} '
                  'busy=${composer.busy} running=${composer.running} stopping=${composer.stopping} '
                  'draft=${composer.controller.text.length}',
            )
            .join(' | ');
        final runtime = container.read(localRuntimeProvider).status;
        final conn = container.read(activeConnectionProvider);
        _log(
          'composer wait ${clock.elapsed.inSeconds}s: [$fields] send=${send.evaluate().length} '
          'runtime=${runtime.phase.name}/${runtime.error} connection=${conn.value != null}/${conn.error}',
        );
      }
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    _dumpTexts(tester);
    fail('composer ready: timed out after 150s');
  }

  /// Wait for a stable draft scope: no session creation, no sync wait.
  Future<void> waitStable() async {
    final clock = Stopwatch()..start();
    var stable = 0;
    while (clock.elapsed < const Duration(seconds: 60)) {
      final list = composers();
      final ok = list.isNotEmpty && list.every((composer) => composer.connected && !composer.busy);
      stable = ok ? stable + 1 : 0;
      if (stable >= 10) return;
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    fail('composer never became stable (connected, not busy)');
  }

  void setDraft(String text) {
    final composer = composers().first;
    composer.controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  await waitStable();

  var sent = false;
  for (var attempt = 0; attempt < 4 && !sent; attempt++) {
    // Set the existing controller instead of going through the platform text
    // input connection: after a turn the chat screen may swap the draft scope
    // on a rebuild, and an `enterText` connection can be cleared with it.
    setDraft(prompt);
    await tester.pump();
    await waitIdle();
    final current = composers().first.controller.text;
    if (current != prompt) {
      _log('draft was cleared before send (attempt ${attempt + 1}, length=${current.length}); re-setting');
      setDraft(prompt);
      await tester.pump();
    }
    final send = find.descendant(of: find.byType(Composer), matching: find.byIcon(AppIcons.send));
    await _tapFirst(tester, send, 'send');
    final clock = Stopwatch()..start();
    while (clock.elapsed < const Duration(seconds: 15)) {
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final text = composers().first.controller.text;
      if (text.isEmpty) {
        sent = true;
        break;
      }
      final id = container.read(currentSessionProvider);
      if (id != null) {
        final chat = container.read(chatProvider(id));
        if (chat.running || chat.pending.isNotEmpty || chat.items.any((item) => item is UserChatItem)) {
          sent = true;
          break;
        }
      }
    }
    if (!sent) _log('send was not accepted (attempt ${attempt + 1}); the draft is still in the composer');
  }
  if (!sent) {
    setDraft('');
    await tester.pump();
    _dumpTexts(tester);
    fail('the composer never accepted the prompt (draft cleared instead of sending twice)');
  }
  final clock = Stopwatch()..start();
  while (container.read(currentSessionProvider) == null && clock.elapsed < const Duration(seconds: 90)) {
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  expect(container.read(currentSessionProvider), isNotNull, reason: 'the first send created no session');
}

/// A successful tool row that actually writes [name] (not a later read of it).
bool _writesFile(ToolChatItem item, String name) {
  if (!item.arguments.contains(name)) return false;
  if (item.name == 'write' || item.name == 'edit' || item.name == 'str_replace_editor') return true;
  if (item.name == 'bash' || item.name == 'pwsh') {
    return RegExp(r'(>|>>|\btee\b|\btouch\b|\bprintf\b)').hasMatch(item.arguments);
  }
  return false;
}

ToolChatItem? _toolFor(List<ChatItem> items, String? callId) {
  if (callId == null) return null;
  for (final item in items.whereType<ToolChatItem>()) {
    if (item.callId == callId) return item;
  }
  return null;
}

Future<ChatState> _waitTurnIdle(
  WidgetTester tester,
  ProviderContainer container,
  String sessionId,
  Duration timeout,
) async {
  final clock = Stopwatch()..start();
  ChatState chat = container.read(chatProvider(sessionId));
  while (chat.running && clock.elapsed < timeout) {
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    chat = container.read(chatProvider(sessionId));
  }
  return chat;
}

Future<SessionModes> _waitForModes(WidgetTester tester, ProviderContainer container, String sessionId) async {
  final clock = Stopwatch()..start();
  SessionModes modes = SessionModes.unknown;
  while (clock.elapsed < const Duration(minutes: 1)) {
    modes = container.read(sessionModesProvider(sessionId));
    if (modes.preset != null) return modes;
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return modes;
}

// ---------------------------------------------------------------------------
// Device state, waiting, logging, screenshot handshake

/// A predictable clean install: no stored key, no provider-key copies, no
/// preferences. The runtime itself is removed by the wrapper's `simctl
/// uninstall`; this only pins the in-app stores.
Future<void> _resetDeviceState() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.clear();
  await prefs.setString(AppLanguageController.prefsKey, AppLanguage.zh.name);
  try {
    final storage = const AppSecureStorage();
    final secrets = await storage.readAll();
    for (final key in secrets.keys) {
      await storage.delete(key: key);
    }
    _log('cleared ${secrets.length} secure-storage entries (including ${ProviderKeyVault.prefix}* keys)');
  } catch (error) {
    _log('secure storage could not be cleared (continuing): $error');
  }
  await AppLanguageController.load();
  AppLocale.use(AppLocale.zhCN);
  expect(AppLanguageController.initial, AppLanguage.zh, reason: 'the UI language could not be pinned to Chinese');
}

Future<void> _waitFor(WidgetTester tester, String what, bool Function() done, {required Duration timeout}) async {
  final clock = Stopwatch()..start();
  while (clock.elapsed < timeout) {
    if (done()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
  _dumpTexts(tester);
  fail('$what: timed out after ${timeout.inSeconds}s');
}

/// Scrolls [target] into view and lets the scroll animation finish before a
/// screenshot or a tap (the list ignores pointers while it is still moving).
Future<void> _scrollIntoView(WidgetTester tester, Finder target) async {
  try {
    await tester.ensureVisible(target);
  } catch (_) {
    // Not inside a scrollable; nothing to scroll.
  }
  await tester.pump();
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
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
  } catch (_) {
    // Not inside a scrollable; nothing to reveal.
  }
  await tester.pump();
  // The approval card animates in above the composer; a tap delivered before
  // the entrance finishes lands on the overlay instead of the button. Wait
  // until the button itself is under the tap point, then tap.
  final render = tester.renderObject(target);
  var hittable = false;
  for (var i = 0; i < 50; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    final result = tester.hitTestOnBinding(tester.getCenter(target));
    if (result.path.any((entry) => identical(entry.target, render))) {
      hittable = true;
      break;
    }
  }
  if (!hittable) {
    _dumpTexts(tester);
    fail('cannot tap $what: the widget never became hittable');
  }
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(target);
  await Future<void>.delayed(const Duration(milliseconds: 250));
  await tester.pump();
}

/// The wrapper takes screenshots; this marker handshake keeps the card on
/// screen long enough. Without a wrapper the wait is bounded and the test goes
/// on.
bool _shotsAvailable = false;

Future<void> _snapshotSignal(String name) async {
  final ready = File('${Directory.systemTemp.path}/dsh-t27-$name.ready');
  try {
    ready.writeAsStringSync(DateTime.now().toIso8601String(), flush: true);
  } catch (error) {
    _log('could not write screenshot marker $name: $error');
    return;
  }
  final shot = File('${Directory.systemTemp.path}/dsh-t27-$name.shot');
  final clock = Stopwatch()..start();
  while (!shot.existsSync() && clock.elapsed < const Duration(seconds: 20)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  _shotsAvailable = shot.existsSync();
  _log(
    'screenshot marker $name: ${_shotsAvailable ? 'captured by the wrapper' : 'no wrapper, continuing'}; '
    '${Directory.systemTemp.path}/dsh-t27-$name',
  );
}

String _describe(List<ChatItem> items) {
  final parts = <String>[];
  for (final item in items) {
    switch (item) {
      case ToolChatItem():
        parts.add(
          'tool ${item.name}[${item.status.name}] ${item.arguments.length > 120 ? '${item.arguments.substring(0, 120)}…' : item.arguments}',
        );
      case AssistantChatItem():
        if (item.text.trim().isNotEmpty) {
          parts.add(
            'assistant "${item.text.trim().length > 80 ? '${item.text.trim().substring(0, 80)}…' : item.text.trim()}"',
          );
        }
      default:
        break;
    }
  }
  return parts.take(12).join(' | ');
}

void _step(String message) {
  _log('=== $message');
}

void _log(String message) {
  debugPrint('[t27-e2e] $message');
}

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
