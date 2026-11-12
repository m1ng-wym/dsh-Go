// Phase 1 L4-Real (G-06): the real iOS app against a real, self-hosted
// ds-harness-remote Server + Host, and the real opencode-go model.
//
// The runner (`scripts/e2e/ios/run_remote_real.sh`) starts:
//   * the self-hosted Server and a `dsh web` Host in an isolated DSH_HOME
//     (`scripts/e2e/remote/relay_stack.sh`),
//   * the loopback credential broker (T25) holding the real opencode-go key,
//   * a loopback control endpoint that restarts only the Host process.
//
// This file then drives the app itself: onboarding, local engine, the 远程主机
// page's self-hosted email/password sheet, the first-connect fingerprint
// prompt, a real provider created through the app's provider actions (T28
// `x-opencode-session` header), a real prompt that writes a file on the Host
// via bash, a Host restart with `remoteStates` recovery, a continued
// conversation, and the switch back to 本机.
//
// Defines (dart-define / dart-define-from-file):
//   E2E_BROKER_URL, E2E_BROKER_TOKEN          credential broker (T25)
//   E2E_RELAY_URL, E2E_RELAY_ACCOUNT,
//   E2E_RELAY_PASSWORD                         self-hosted Server
//   E2E_RELAY_HOST_NAME                        default "E2E Host"
//   E2E_RELAY_WORKDIR                          session cwd, under the Host DSH_HOME
//   E2E_HOST_RESTART_URL                       loopback control endpoint
//
// No key, password or token is ever printed or asserted on.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/app.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/remote/relay/dsh_remote_backend.dart';
import 'package:dsh_app/runtime/local_paths.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/secrets/secure_storage.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/locale_state.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/state/providers_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/onboarding/connect_page.dart';
import 'package:dsh_app/ui/onboarding/welcome_page.dart';
import 'package:dsh_app/ui/remote/host_key_dialog.dart';
import 'package:dsh_app/ui/remote/relay_login_sheet.dart';
import 'package:dsh_app/ui/remote/remote_screen.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart'
    show
        AssistantChatItem,
        DshWorkspaceApi,
        ModelCatalog,
        ModelSelection,
        SessionSummary,
        ToolChatItem,
        ToolStatus,
        UserChatItem;
import 'package:dsh_remote/dsh_remote.dart' show RemoteConnectionPhase, RemoteConnectionState, RemoteDshClient;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/e2e_env.dart';

const _relayUrl = String.fromEnvironment('E2E_RELAY_URL');
const _relayAccount = String.fromEnvironment('E2E_RELAY_ACCOUNT');
const _relayPassword = String.fromEnvironment('E2E_RELAY_PASSWORD');
const _relayHostName = String.fromEnvironment('E2E_RELAY_HOST_NAME', defaultValue: 'E2E Host');
const _relayWorkdir = String.fromEnvironment('E2E_RELAY_WORKDIR');
const _restartUrl = String.fromEnvironment('E2E_HOST_RESTART_URL');

const _sessionHeader = 'x-opencode-session';
const _sessionHeaderValue = 'dsh-go-ios-remote';
const _remoteFile = 'remote-ok.md';
const _remoteFileLine = 'remote real model ok';
const _prompt1 = '在工作区创建 remote-ok.md，写入一行 remote real model ok，然后用 bash 读回。';
const _prompt2 = '重启后继续：用 bash 再次读取 remote-ok.md，并回复文件里的那一行。';

const _providerName = 'OpenCode Go (E2E remote)';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('T33b_real_self_hosted_remote_host_restart_and_local_isolation', (tester) async {
    WidgetController.hitTestWarningShouldBeFatal = true;
    _requireRelayConfig();
    E2eConfig.requireBroker();
    final runClock = Stopwatch()..start();

    _step('fetch the real opencode-go key from the loopback broker');
    final apiKey = await fetchBrokerKey();
    _log('broker key fetched (not printed): ${apiKey.length} chars');

    _step('clean install state and boot the real app');
    await _resetDeviceState();
    await LocalPaths.load();
    runApp(const ProviderScope(child: DshApp()));
    await _waitFor(
      tester,
      'the app reaches a real first screen',
      () =>
          find.byType(WelcomePage).evaluate().isNotEmpty ||
          find.byType(ConnectPage).evaluate().isNotEmpty ||
          find.byType(HomeShell).evaluate().isNotEmpty,
      timeout: const Duration(minutes: 3),
    );
    final container = ProviderScope.containerOf(tester.element(find.byType(DshApp)), listen: false);

    _step('first run onboarding');
    await _finishOnboarding(tester, container);
    await _waitFor(
      tester,
      'home shell after onboarding',
      () => find.byType(HomeShell).evaluate().isNotEmpty,
      timeout: const Duration(minutes: 2),
    );

    _step('the local engine is running and connected');
    await _waitLocalEngine(tester, container);
    _screenshot('local-home');

    _step('local baseline: one local session, before any remote host');
    String? localSessionId;
    try {
      localSessionId = await container.read(sessionsProvider.notifier).create();
      _log('local baseline session: $localSessionId');
    } catch (error) {
      _log('local baseline session could not be created (continuing empty): $error');
    }
    await Future<void>.delayed(const Duration(milliseconds: 800));
    await tester.pump();
    final localIdsBefore = _sessionIds(container);
    final localEngineBefore = await _waitForLocalSessions(tester, container, 'the local engine baseline');
    final localEngineBeforeCount = localEngineBefore.length;
    if (localSessionId != null) {
      expect(
        localEngineBefore.any((row) => row.sessionId == localSessionId),
        isTrue,
        reason: 'the local engine did not list the baseline session it just created',
      );
    }
    _log('local baseline sessions: visible=$localIdsBefore engine=$localEngineBeforeCount');

    // ── Self-hosted sign-in through the app's own sheet ─────────────────────
    _step('open 远程主机 and sign in to the self-hosted Server through the real sheet');
    final navigator = Navigator.of(tester.element(find.byType(HomeShell)));
    unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => const RemoteScreen())));
    await _waitFor(
      tester,
      'remote screen',
      () => find.byType(RemoteScreen).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 30),
    );
    await _waitFor(
      tester,
      'self-hosted sign-in entry',
      () => find.text(appL10n.remoteSelfHostedEmailSignIn).evaluate().isNotEmpty,
      timeout: const Duration(minutes: 1),
    );
    await _tapFirst(tester, find.text(appL10n.remoteSelfHostedEmailSignIn), 'self-hosted email sign-in');
    await _waitFor(
      tester,
      'self-hosted login sheet',
      () => find.byType(SelfHostedLoginSheet).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 30),
    );
    final loginFields = find.descendant(of: find.byType(SelfHostedLoginSheet), matching: find.byType(TextField));
    expect(loginFields, findsNWidgets(3), reason: 'the self-hosted sheet no longer has server/email/password fields');
    await tester.enterText(loginFields.at(0), _relayUrl);
    await tester.enterText(loginFields.at(1), _relayAccount);
    await tester.enterText(loginFields.at(2), _relayPassword);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    final signInClock = Stopwatch()..start();
    await _tapFirst(
      tester,
      find.descendant(
        of: find.byType(SelfHostedLoginSheet),
        matching: find.widgetWithText(FilledButton, appL10n.commonSignIn),
      ),
      'sign in',
    );
    await _waitFor(tester, 'self-hosted sign-in completes and the sheet closes', () {
      final account = container.read(relayAccountProvider).value;
      return find.byType(SelfHostedLoginSheet).evaluate().isEmpty && (account?.signedIn ?? false);
    }, timeout: const Duration(minutes: 2));
    _log('self-hosted sign-in: ${signInClock.elapsedMilliseconds}ms server=$_relayUrl');
    await _waitFor(tester, 'the online "$_relayHostName" Host is listed', () {
      final account = container.read(relayAccountProvider).value;
      return account != null &&
          account.hosts.any((host) => host.name == _relayHostName && host.online) &&
          account.hosts.firstWhere((host) => host.name == _relayHostName).fingerprint != null;
    }, timeout: const Duration(minutes: 2));
    var host = container
        .read(relayAccountProvider)
        .value!
        .hosts
        .firstWhere((candidate) => candidate.name == _relayHostName);
    final hostRef = HostRef.relay(host.id, name: host.name);
    final fingerprint = host.fingerprint!;
    _log(
      'host listed: id=${host.id} name="${host.name}" online=${host.online} '
      'platform=${host.platform} harness=${host.harnessVersion} fingerprint=$fingerprint',
    );
    _screenshot('host-list');

    // ── First connect: the person accepts the fingerprint in the real dialog ─
    _step('select the Host and accept its fingerprint through the real trust dialog');
    await _waitFor(
      tester,
      'the Host row',
      () => find.byKey(ValueKey('remote-row-${host.id}')).evaluate().isNotEmpty,
      timeout: const Duration(minutes: 1),
    );
    await _tapFirst(tester, find.byKey(ValueKey('remote-row-${host.id}')), 'the Host row');
    await _waitFor(
      tester,
      'first-connect fingerprint dialog',
      () => find.byType(RelayTrustDialog).evaluate().isNotEmpty,
      timeout: const Duration(minutes: 2),
    );
    expect(
      find.descendant(of: find.byType(RelayTrustDialog), matching: find.text(fingerprint)).evaluate().isNotEmpty,
      isTrue,
      reason: 'the trust dialog does not show the fingerprint the Server listed',
    );
    _screenshot('trust-dialog');
    final connectClock = Stopwatch()..start();
    await _tapFirst(
      tester,
      find.descendant(
        of: find.byType(RelayTrustDialog),
        matching: find.widgetWithText(FilledButton, appL10n.remoteHostKeyTrustConnect),
      ),
      'trust and connect',
    );
    await _waitFor(
      tester,
      'the trust dialog closes and the relay Host becomes active',
      () => find.byType(RelayTrustDialog).evaluate().isEmpty && container.read(activeHostProvider) == hostRef,
      timeout: const Duration(minutes: 1),
    );
    final backend = container.read(relayBackendProvider);
    expect(backend, isA<DshRemoteRelayBackend>(), reason: 'the app is not using the real relay backend');
    expect(
      (backend as DshRemoteRelayBackend).approves(host.id, fingerprint),
      isTrue,
      reason: 'accepting the dialog did not pin exactly the listed fingerprint (the real controller callback)',
    );
    await _waitFor(tester, 'the encrypted relay connection to the Host is ready', () {
      final connection = container.read(activeConnectionProvider).value;
      return connection != null && !connection.isLocal && connection.hostId == host.id;
    }, timeout: const Duration(minutes: 2));
    var remoteClient = container.read(activeConnectionProvider).value!.client;
    _log(
      'relay connected in ${connectClock.elapsedMilliseconds}ms; '
      'carrier=${remoteClient.remoteCarrier?.kind} transport=${container.read(hostLinkStatusProvider(hostRef)).value?.path?.name}',
    );
    _screenshot('remote-connected');

    _step('the remote session list loads');
    await _waitFor(
      tester,
      'the remote session list',
      () => container.read(sessionsProvider).hasValue,
      timeout: const Duration(minutes: 2),
    );
    _log('remote sessions: ${_sessionIds(container)}');

    // ── Real provider through the app's provider actions (T28 headers) ──────
    _step('create the real opencode-go provider on the remote Host');
    await _waitForWritableProviders(tester, container);
    final providerClock = Stopwatch()..start();
    final providerId = await container
        .read(providerActionsProvider)
        .save(
          ProviderDraft(
            name: _providerName,
            api: ProviderApi.openaiCompletions,
            baseUrl: kE2eProviderBaseUrl,
            apiKey: apiKey,
            models: const [ProviderModelSpec(id: kE2eModel, name: 'DeepSeek V4.1 Flash (E2E)')],
            headers: const {_sessionHeader: _sessionHeaderValue},
          ),
        );
    _log('provider saved on the remote Host: $providerId (${providerClock.elapsedMilliseconds}ms)');
    final provider = await _waitForProvider(tester, container, providerId);
    expect(
      provider.headers[_sessionHeader],
      _sessionHeaderValue,
      reason: 'T28 request header not stored on the remote route',
    );
    expect(provider.models.any((model) => model.id == kE2eModel), isTrue);

    _step('the engine lists the real model on the remote Host');
    final catalogClock = Stopwatch()..start();
    final catalog = await _waitForModel(tester, container, providerId);
    _log(
      'model catalog has $providerId/$kE2eModel after ${catalogClock.elapsedMilliseconds}ms '
      '(${catalog.models.length} models)',
    );

    // The session's workspace is an explicit folder under the Host's isolated
    // DSH_HOME, so the file is also checked on the Mac by the runner.
    _step('create the remote session in $_relayWorkdir and select the real model');
    final created = await remoteClient.createSession(cwd: _relayWorkdir);
    final sessionId = created.sessionId;
    expect(sessionId, isNotEmpty);
    final engineSessions = await remoteClient.listSessions();
    expect(
      engineSessions.any((row) => row.sessionId == sessionId),
      isTrue,
      reason: 'the remote Host did not list the session it just created',
    );
    await container.read(sessionsProvider.notifier).refresh();
    await _waitFor(
      tester,
      'the remote session list loads',
      () => container.read(sessionsProvider).hasValue && !container.read(sessionsProvider).isLoading,
      timeout: const Duration(minutes: 1),
    );
    _log('remote session list: engine=${engineSessions.length} visible=${_sessionIds(container)} created=$sessionId');
    container.read(currentSessionProvider.notifier).select(sessionId);
    await tester.pump();
    await _waitFor(
      tester,
      'the chat composer for the remote session',
      () => find.byType(Composer).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 60),
    );
    final chatSub = container.listen<ChatState>(chatProvider(sessionId), (_, _) {}, fireImmediately: true);
    final modelApplied = await container
        .read(chatProvider(sessionId).notifier)
        .setModel(ModelSelection(provider: providerId, model: kE2eModel));
    expect(modelApplied, isTrue, reason: 'the app could not select the real model on the remote session');
    final permission = await remoteClient.setPermissionPreset(sessionId, 'danger-full-access');
    expect(permission.success, isTrue, reason: 'the Host refused danger-full-access: ${permission.text}');
    chatSub.close();
    _log('remote session ready: $sessionId model=$providerId/$kE2eModel permission=danger-full-access');
    _screenshot('remote-session');

    // ── First real turn: stream, tool row, file on the Host ─────────────────
    _step('send the real prompt on the remote Host');
    final turnClock = Stopwatch()..start();
    final turn1 = await _sendTurn(tester, container, sessionId, _prompt1);
    _log(
      'turn 1 finished in ${turnClock.elapsedMilliseconds}ms: '
      'assistant=${turn1.assistant.length} streamingSnapshots=${turn1.streamingSnapshots} '
      'tools=${turn1.tools.map((tool) => '${tool.name}:${tool.status.name}').join(',')}',
    );
    expect(turn1.assistant, isNotEmpty, reason: 'the real model reply never landed');
    expect(turn1.streamingSnapshots, greaterThanOrEqualTo(1), reason: 'the reply did not arrive as a stream');
    await _waitFor(
      tester,
      'the remote session list shows the conversation after its first turn',
      () => _sessionIds(container).contains(sessionId),
      timeout: const Duration(minutes: 1),
    );
    expect(turn1.tools, isNotEmpty, reason: 'the model ran no tool row (bash was expected)');
    expect(
      turn1.tools.any((tool) => tool.status == ToolStatus.succeeded),
      isTrue,
      reason: 'no tool call succeeded: ${turn1.tools.map((tool) => '${tool.name}:${tool.status.name}')}',
    );
    _screenshot('turn-1');

    _step('read the remote workspace file through the remote connection');
    final remoteText = await remoteClient.readWorkspaceText(sessionId, _remoteFile);
    expect(remoteText.text, contains(_remoteFileLine), reason: 'the remote file does not hold the requested line');
    expect(remoteText.absolutePath, isNotEmpty);
    _log('remote file: ${remoteText.absolutePath} bytes=${remoteText.bytes} text="${remoteText.text.trim()}"');

    // ── Host restart: drop, reconnect, remoteStates recovery ────────────────
    _step('restart the Host process and observe remoteStates recovery');
    remoteClient = container.read(activeConnectionProvider).value!.client;
    final generationBefore = remoteClient.mux.generation!.number;
    final restartStates = <RemoteConnectionState>[];
    final stateSub = remoteClient.remoteStates!.listen(restartStates.add);
    final restartClock = Stopwatch()..start();
    final restart = await _restartHost();
    _log('Host restart: $restart (${restartClock.elapsedMilliseconds}ms)');
    var sawDrop = false;
    var recovered = false;
    final recoveryDeadline = DateTime.now().add(const Duration(minutes: 5));
    while (DateTime.now().isBefore(recoveryDeadline)) {
      if (restartStates.any((state) => state.phase != RemoteConnectionPhase.connected)) sawDrop = true;
      if (sawDrop && restartStates.isNotEmpty && restartStates.last.phase == RemoteConnectionPhase.connected) {
        recovered = true;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await tester.pump();
    }
    await stateSub.cancel();
    _log('remoteStates: ${restartStates.map((state) => state.phase.name).join(' -> ')}');
    expect(sawDrop, isTrue, reason: 'remoteStates never reported the Host restart');
    expect(recovered, isTrue, reason: 'the relay client never reached connected again after the Host came back');
    expect(
      container.read(activeHostProvider),
      hostRef,
      reason: 'the app switched away from the Host during the reconnect',
    );
    final recoveredClient = container.read(activeConnectionProvider).value?.client;
    expect(
      identical(recoveredClient, remoteClient),
      isTrue,
      reason: 'the active connection changed instead of recovering in place',
    );
    final generationAfter = remoteClient.mux.generation!.number;
    expect(
      generationAfter,
      greaterThan(generationBefore),
      reason: 'the mux generation did not advance after the Host restart',
    );
    _log(
      'reconnected in place: generation $generationBefore -> $generationAfter, '
      'total ${restartClock.elapsedMilliseconds}ms',
    );
    _screenshot('reconnected');

    _step('continue the same conversation after the restart');
    await _waitFor(
      tester,
      'the conversation history returns after the restart',
      () => container
          .read(chatProvider(sessionId))
          .items
          .whereType<AssistantChatItem>()
          .any((item) => item.text.isNotEmpty),
      timeout: const Duration(minutes: 2),
    );
    final turnClock2 = Stopwatch()..start();
    final turn2 = await _sendTurn(tester, container, sessionId, _prompt2);
    _log(
      'turn 2 finished in ${turnClock2.elapsedMilliseconds}ms: '
      'assistant=${turn2.assistant.length} streamingSnapshots=${turn2.streamingSnapshots} '
      'tools=${turn2.tools.map((tool) => '${tool.name}:${tool.status.name}').join(',')}',
    );
    expect(
      turn2.assistant.where((text) => text.isNotEmpty),
      isNotEmpty,
      reason: 'the continued turn produced no reply',
    );
    expect(turn2.tools, isNotEmpty, reason: 'the continued turn ran no tool row');
    expect(
      turn2.assistant.any((text) => text.contains(_remoteFileLine)) ||
          turn2.tools.any((tool) => tool.resultText.contains(_remoteFileLine)),
      isTrue,
      reason: 'the continued turn did not show the file line read back by bash',
    );
    final afterText = await remoteClient.readWorkspaceText(sessionId, _remoteFile);
    expect(afterText.text, contains(_remoteFileLine), reason: 'remote-ok.md changed after the restart');
    _screenshot('turn-2');

    // ── Back to 本机: no mixing ─────────────────────────────────────────────
    _step('switch back to 本机 and verify local/remote sessions never mix');
    container.read(activeHostProvider.notifier).select(HostRef.local);
    await _waitFor(tester, 'the local connection after switching back', () {
      final connection = container.read(activeConnectionProvider).value;
      return container.read(activeHostProvider).isLocal && connection != null && connection.isLocal;
    }, timeout: const Duration(minutes: 2));
    await _waitFor(tester, 'the local session list after switching back', () {
      final connection = container.read(activeConnectionProvider).value;
      if (connection == null || !connection.isLocal) return false;
      final ids = _sessionIds(container);
      if (ids.contains(sessionId)) return false;
      return container.read(sessionsProvider).hasValue && !container.read(sessionsProvider).isLoading;
    }, timeout: const Duration(minutes: 2));
    final localIdsAfter = _sessionIds(container);
    final localEngineSessions = await _waitForLocalSessions(tester, container, 'the local engine after switching back');
    final localEngineIds = [for (final row in localEngineSessions) row.sessionId];
    _log('local visible sessions after switching back: $localIdsAfter');
    _log('local engine sessions after switching back: $localEngineIds');
    expect(
      localIdsAfter.toSet(),
      localIdsBefore.toSet(),
      reason: 'the local sessions changed across the remote session',
    );
    expect(
      localIdsAfter,
      isNot(contains(sessionId)),
      reason: 'the remote Host session leaked into the local session list',
    );
    expect(localEngineIds, isNot(contains(sessionId)), reason: 'the remote Host session leaked into the local engine');
    expect(
      localEngineIds.length,
      localEngineBeforeCount,
      reason: 'the local engine session count changed across the remote session',
    );
    if (localSessionId != null) {
      expect(
        localEngineIds,
        contains(localSessionId),
        reason: 'the local baseline session disappeared from the local engine',
      );
    }
    expect(container.read(activeHostProvider).isLocal, isTrue);
    _screenshot('local-again');

    _log(
      'SUMMARY {'
      '"result":"pass",'
      '"totalMs":${runClock.elapsedMilliseconds},'
      '"server":"$_relayUrl",'
      '"host":"${host.name}",'
      '"hostId":"${host.id}",'
      '"fingerprint":"$fingerprint",'
      '"provider":"$providerId",'
      '"model":"$providerId/$kE2eModel",'
      '"session":"$sessionId",'
      '"timer1Ms":${turnClock.elapsedMilliseconds},'
      '"timer2Ms":${turnClock2.elapsedMilliseconds},'
      '"restartMs":${restartClock.elapsedMilliseconds},'
      '"generation":[$generationBefore,$generationAfter],'
      '"remoteFile":"${remoteText.absolutePath}",'
      '"localBefore":"${localIdsBefore.length}",'
      '"localAfter":"${localIdsAfter.length}",'
      '"localEngineSessions":"${localEngineIds.length}"'
      '}',
    );
  }, timeout: const Timeout(Duration(minutes: 60)));
}

// ---------------------------------------------------------------------------
// Real turn

class _TurnResult {
  _TurnResult({required this.assistant, required this.streamingSnapshots, required this.tools});

  /// Final, non-streaming assistant texts of the turns this call waited for.
  final List<String> assistant;

  /// Distinct growing assistant prefixes observed while streaming.
  final int streamingSnapshots;
  final List<ToolChatItem> tools;
}

Future<_TurnResult> _sendTurn(WidgetTester tester, ProviderContainer container, String sessionId, String prompt) async {
  await _waitFor(
    tester,
    'the remote composer',
    () => find.byType(Composer).evaluate().isNotEmpty,
    timeout: const Duration(minutes: 1),
  );
  final field = find.descendant(of: find.byType(Composer), matching: find.byType(TextField));
  expect(field, findsOneWidget, reason: 'the remote composer has no text field');
  for (var attempt = 0; attempt < 3; attempt++) {
    await tester.enterText(field, prompt);
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await tester.pump();
    if (tester.widget<TextField>(field).controller?.text == prompt) break;
  }
  expect(tester.widget<TextField>(field).controller?.text, prompt, reason: 'the composer keeps clearing the prompt');

  final send = find.descendant(of: find.byType(Composer), matching: find.byIcon(AppIcons.send));
  await _waitFor(tester, 'the remote send key', () {
    final composers = tester.widgetList<Composer>(find.byType(Composer)).toList();
    return send.evaluate().isNotEmpty &&
        composers.isNotEmpty &&
        composers.every((composer) => composer.connected && composer.sessionReady && !composer.busy);
  }, timeout: const Duration(minutes: 2));

  final assistantPrefixes = <String>{};
  final tools = <String, ToolChatItem>{};
  final baseline = container.read(chatProvider(sessionId));
  final repliedBefore = {
    for (final item in baseline.items.whereType<AssistantChatItem>())
      if (!item.streaming && item.text.isNotEmpty) item.key,
  };
  final toolsBefore = {for (final item in baseline.items.whereType<ToolChatItem>()) item.callId};
  final subscription = container.listen<ChatState>(chatProvider(sessionId), (previous, next) {
    for (final item in next.items.whereType<AssistantChatItem>()) {
      if (item.streaming && item.text.isNotEmpty) assistantPrefixes.add(item.text);
    }
    for (final item in next.items.whereType<ToolChatItem>()) {
      tools[item.callId] = item;
    }
  }, fireImmediately: true);

  try {
    await _tapFirst(tester, send, 'send');
    // The first send may still be creating/adopting the session's snapshot;
    // wait for the prompt to appear before waiting for the end.
    await _waitFor(
      tester,
      'the prompt appears in the conversation',
      () => container
          .read(chatProvider(sessionId))
          .items
          .whereType<UserChatItem>()
          .any((item) => item.text.contains(prompt)),
      timeout: const Duration(minutes: 2),
    );

    final clock = Stopwatch()..start();
    ChatState chat = container.read(chatProvider(sessionId));
    while (clock.elapsed < const Duration(minutes: 6)) {
      chat = container.read(chatProvider(sessionId));
      if (chat.error != null) {
        _dumpChat(sessionId, chat);
        fail('the real turn failed: ${chat.error}');
      }
      final replies = chat.items
          .whereType<AssistantChatItem>()
          .where((item) => !item.streaming && item.text.isNotEmpty && !repliedBefore.contains(item.key))
          .toList();
      if (!chat.running && replies.isNotEmpty && chat.pending.isEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();
    }
    chat = container.read(chatProvider(sessionId));
    final replies = chat.items
        .whereType<AssistantChatItem>()
        .where((item) => !item.streaming && item.text.isNotEmpty && !repliedBefore.contains(item.key))
        .map((item) => item.text)
        .toList();
    final turnTools = chat.items.whereType<ToolChatItem>().where((item) => !toolsBefore.contains(item.callId)).toList();
    _log(
      'turn state: running=${chat.running} error=${chat.error} replies=${replies.length} '
      'tools=${turnTools.map((tool) => '${tool.name}:${tool.status.name}').join(',')} '
      'pending=${chat.pending.length} streaming prefixes=${assistantPrefixes.length}',
    );
    for (final tool in turnTools) {
      _log(
        '  tool ${tool.name} status=${tool.status.name} args=${_short(tool.arguments)} result=${_short(tool.resultText)}',
      );
    }
    expect(chat.running, isFalse, reason: 'the turn did not end');
    expect(chat.error, isNull, reason: 'the turn ended with an error: ${chat.error}');
    expect(chat.pending, isEmpty, reason: 'the prompt never settled');
    expect(
      replies,
      isNotEmpty,
      reason:
          'the real model produced no final assistant message (items: ${chat.items.map((item) => item.runtimeType).toList()})',
    );
    return _TurnResult(assistant: replies, streamingSnapshots: assistantPrefixes.length, tools: turnTools);
  } finally {
    subscription.close();
  }
}

// ---------------------------------------------------------------------------
// Local engine / providers

Future<void> _waitLocalEngine(WidgetTester tester, ProviderContainer container) async {
  final clock = Stopwatch()..start();
  var askedToStart = false;
  while (clock.elapsed < const Duration(minutes: 4)) {
    final status = container.read(localRuntimeProvider).status;
    if (status.phase == RuntimePhase.installed && !askedToStart) {
      askedToStart = true;
      unawaited(container.read(localRuntimeProvider.notifier).start());
    }
    if (status.phase == RuntimePhase.running && container.read(providerBackendProvider) != null) {
      _log('local engine running: baseUrl=${status.baseUrl} dsh=${status.dshVersion} node=${status.nodeVersion}');
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pump();
  }
  final status = container.read(localRuntimeProvider).status;
  _dumpTexts(tester);
  fail('the local engine never reached running+connected (phase=${status.phase.name}, error=${status.error})');
}

Future<List<SessionSummary>> _waitForLocalSessions(
  WidgetTester tester,
  ProviderContainer container,
  String what,
) async {
  final clock = Stopwatch()..start();
  Object? lastError;
  while (clock.elapsed < const Duration(minutes: 2)) {
    final connection = container.read(activeConnectionProvider).value;
    if (container.read(activeHostProvider).isLocal && connection != null && connection.isLocal) {
      try {
        return await connection.client.listSessions().timeout(const Duration(seconds: 15));
      } catch (error) {
        lastError = error;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pump();
  }
  fail('$what did not answer within 2 minutes (last error: $lastError)');
}

Future<ProvidersSnapshot> _waitForWritableProviders(WidgetTester tester, ProviderContainer container) async {
  final clock = Stopwatch()..start();
  while (clock.elapsed < const Duration(minutes: 3)) {
    try {
      final snapshot = await container.read(customProvidersProvider.future).timeout(const Duration(seconds: 20));
      if (snapshot != null && snapshot.supported && snapshot.writable) return snapshot;
    } catch (error) {
      _log('remote provider snapshot read failed, retrying: $error');
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await tester.pump();
  }
  fail('the remote Host exposed no writable provider settings within 3 minutes');
}

Future<CustomProvider> _waitForProvider(WidgetTester tester, ProviderContainer container, String providerId) async {
  final clock = Stopwatch()..start();
  while (clock.elapsed < const Duration(minutes: 2)) {
    try {
      final snapshot = await container.read(customProvidersProvider.future).timeout(const Duration(seconds: 20));
      final provider = snapshot?.byId(providerId);
      if (provider != null) return provider;
    } catch (error) {
      _log('remote provider re-read failed, retrying: $error');
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await tester.pump();
  }
  fail('the remote Host did not read provider $providerId back within 2 minutes');
}

Future<ModelCatalog> _waitForModel(WidgetTester tester, ProviderContainer container, String providerId) async {
  ModelCatalog? catalog;
  final clock = Stopwatch()..start();
  while (clock.elapsed < const Duration(minutes: 3)) {
    try {
      container.invalidate(modelCatalogProvider);
      catalog = await container.read(modelCatalogProvider.future).timeout(const Duration(seconds: 20));
    } catch (error) {
      _log('remote model catalog read failed, retrying: $error');
    }
    if (catalog != null && catalog.models.any((model) => model.provider == providerId && model.id == kE2eModel)) {
      return catalog;
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await tester.pump();
  }
  fail('$providerId/$kE2eModel is not in the remote Host catalog after 3 minutes');
}

// ---------------------------------------------------------------------------
// Host restart control (loopback; the runner owns the process)

Future<Map<String, Object?>> _restartHost() async {
  final uri = Uri.parse(_restartUrl);
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client.postUrl(uri).timeout(const Duration(seconds: 10));
    final response = await request.close().timeout(const Duration(minutes: 4));
    final body = await utf8.decodeStream(response).timeout(const Duration(seconds: 30));
    final decoded = jsonDecode(body);
    if (response.statusCode != HttpStatus.ok || decoded is! Map) {
      throw E2eHarnessError('Host restart endpoint answered HTTP ${response.statusCode}');
    }
    final map = decoded.cast<String, Object?>();
    if (map['ok'] != true) throw E2eHarnessError('Host restart failed: ${map['error']}');
    return map;
  } on TimeoutException {
    throw const E2eHarnessError('Host restart timed out');
  } finally {
    client.close(force: true);
  }
}

// ---------------------------------------------------------------------------
// First run (same flow as phase1_test.dart)

Future<void> _finishOnboarding(WidgetTester tester, ProviderContainer container) async {
  final startedAtHome = find.byType(HomeShell).evaluate().isNotEmpty;
  if (startedAtHome) {
    _log('first screen: home shell (phone already set up)');
    return;
  }
  if (find.byType(WelcomePage).evaluate().isNotEmpty) {
    _log('first screen: welcome page');
    await _tapFirst(tester, find.widgetWithText(FilledButton, appL10n.shellGetStarted), 'welcome start');
    await _waitFor(
      tester,
      'runtime choice',
      () => find.byKey(const ValueKey('runtime-option-local')).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 30),
    );
    if (!container.read(localRuntimeProvider).available) {
      fail(
        'this simulator build has no local runtime (app/ios/Engine is not prepared; '
        'run tooling/ios/prepare-engine.sh or copy a prepared Engine for this revision)',
      );
    }
    await _tapFirst(tester, find.byKey(const ValueKey('runtime-option-local')), 'choose local');
    await _tapFirst(tester, find.widgetWithText(FilledButton, appL10n.commonContinue), 'runtime continue');
  } else {
    _log('first screen: connect page (runtime already installed)');
  }
  if (find.byKey(const ValueKey('setup-appearance-card')).evaluate().isNotEmpty) {
    await _tapFirst(tester, find.widgetWithText(FilledButton, appL10n.commonContinue), 'appearance continue');
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
    await _tapFirst(tester, find.text(appL10n.accessSkip), 'access skip');
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
    await _tapFirst(tester, find.text(appL10n.shellSetUpLater), 'connect later');
  }
  await _waitFor(
    tester,
    'home shell (onboarding done)',
    () => find.byType(HomeShell).evaluate().isNotEmpty,
    timeout: const Duration(minutes: 4),
  );
}

// ---------------------------------------------------------------------------
// Device state and helpers

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
    _log('cleared ${secrets.length} secure-storage entries');
  } catch (error) {
    _log('secure storage could not be cleared (continuing): $error');
  }
  await AppLanguageController.load();
  AppLocale.use(AppLocale.zhCN);
  expect(AppLanguageController.initial, AppLanguage.zh, reason: 'the UI language could not be pinned to Chinese');
}

List<String> _sessionIds(ProviderContainer container) => [
  for (final session in container.read(sessionsProvider).value ?? const <SessionSummary>[]) session.sessionId,
];

void _requireRelayConfig() {
  final missing = [
    if (_relayUrl.isEmpty) 'E2E_RELAY_URL',
    if (_relayAccount.isEmpty) 'E2E_RELAY_ACCOUNT',
    if (_relayPassword.isEmpty) 'E2E_RELAY_PASSWORD',
    if (_relayWorkdir.isEmpty) 'E2E_RELAY_WORKDIR',
    if (_restartUrl.isEmpty) 'E2E_HOST_RESTART_URL',
  ];
  if (missing.isNotEmpty) {
    throw E2eHarnessError('missing dart-defines: ${missing.join(', ')}');
  }
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

Future<void> _tapFirst(WidgetTester tester, Finder finder, String what) async {
  final target = finder.first;
  if (target.evaluate().isEmpty) {
    _dumpTexts(tester);
    fail('cannot tap $what: not found');
  }
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await tester.pump();
  try {
    await tester.ensureVisible(target);
  } catch (_) {}
  await tester.pump(const Duration(milliseconds: 150));
  await tester.tap(target);
  await Future<void>.delayed(const Duration(milliseconds: 250));
  await tester.pump();
}

void _dumpChat(String sessionId, ChatState chat) {
  _log('chat $sessionId: running=${chat.running} error=${chat.error} pending=${chat.pending.length}');
  for (final item in chat.items) {
    _log('  item ${item.runtimeType} key=${item.key}');
  }
}

void _dumpTexts(WidgetTester tester) {
  try {
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data ?? text.textSpan?.toPlainText() ?? '')
        .where((text) => text.isNotEmpty)
        .take(60)
        .toList();
    _log('visible text widgets: $texts');
  } catch (error) {
    _log('could not dump widgets: $error');
  }
}

String _short(String text, [int max = 160]) => text.length <= max ? text : '${text.substring(0, max)}…';

void _screenshot(String slug) => _log('=== screenshot:$slug');

void _step(String message) => _log('=== $message');

void _log(String message) => debugPrint('[phase1-remote-real] $message');
