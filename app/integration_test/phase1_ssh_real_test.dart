// T33b · Real SSH host end to end, from the iOS app, with the real model.
//
// Runs the real app on the iOS Simulator against a throwaway unprivileged sshd
// and a real `dsh web` on the Mac, then a real opencode-go model:
//
//   * clean install / onboarding; the on-device engine reaches `running`;
//   * a local conversation is created as the isolation baseline;
//   * an SSH host is added through the app's own RemoteScreen → SshHostFormPage
//     flow (real SSH test connection, real TOFU prompt showing the expected
//     fingerprint, save), then activated;
//   * the link's progress steps complete, and the remote session list loads
//     from an isolated remote HOME/DSH_HOME;
//   * a real provider is written to the **remote** engine through
//     ProviderActions with `x-opencode-session: dsh-go-ios-ssh`, the pinned
//     model `deepseek-v4.1-flash` is selected, and a real prompt asks the agent
//     to create `ssh-ok.md` with `ssh real model ok` and read it back with bash;
//   * the reply streams, tool rows appear, the file is read back over a second
//     real SSH connection and its content is exact;
//   * the remote `dsh web` is killed (pid from the SSH bootstrap, command line
//     scoped to this run's DSH_HOME); the app shows reconnect/retry state,
//     starts a new remote `dsh web`, and the conversation continues;
//   * switching back to 本机 leaves the local sessions untouched and never
//     shows the SSH conversation locally.
//
// Run it with scripts/e2e/ios/run_ssh_real.sh, which starts the sshd + broker
// and passes every value below as a --dart-define. Missing values fail loudly;
// nothing here skips.
import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/app.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/remote/ssh/remote_shell.dart' show shQuote;
import 'package:dsh_app/remote/ssh/ssh_link.dart';
import 'package:dsh_app/remote/ssh/ssh_transport.dart';
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
import 'package:dsh_app/ui/onboarding/runtime_choice.dart';
import 'package:dsh_app/ui/onboarding/welcome_page.dart';
import 'package:dsh_app/ui/remote/host_key_dialog.dart';
import 'package:dsh_app/ui/remote/remote_screen.dart';
import 'package:dsh_app/ui/remote/ssh_host_form.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart'
    show
        ApprovalDecision,
        AssistantChatItem,
        ModelCatalog,
        ModelSelection,
        SessionSummary,
        ToolChatItem,
        ToolStatus,
        TurnEndedEvent;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/e2e_env.dart';

/// The real prompt. It must produce a bash-driven file write the Mac can see.
const _promptWrite =
    '在工作区创建 ssh-ok.md，写入一行 `ssh real model ok`，然后用 bash 读回文件。';
const _promptContinue = '再用 bash 读取 ssh-ok.md，并在回复里原样引用文件中的那一行内容。';
const _expectedFileLine = 'ssh real model ok';

/// Values the runner passes with --dart-define. Empty/missing values are a
/// harness failure, never a skip.
class _Cfg {
  const _Cfg._();

  static const host = String.fromEnvironment('T33B_SSH_HOST');
  static const port = int.fromEnvironment('T33B_SSH_PORT');
  static const user = String.fromEnvironment('T33B_SSH_USER');
  static const keyB64 = String.fromEnvironment('T33B_SSH_KEY_B64');
  static const fingerprint = String.fromEnvironment('T33B_HOST_FINGERPRINT');
  static const remoteHome = String.fromEnvironment('T33B_REMOTE_HOME');
  static const remoteWorkdir = String.fromEnvironment('T33B_REMOTE_WORKDIR');
  static const launchCommand = String.fromEnvironment('T33B_LAUNCH_COMMAND');
  static const model = String.fromEnvironment('E2E_MODEL', defaultValue: kE2eModel);
  static const providerBaseUrl = String.fromEnvironment('E2E_PROVIDER_BASE_URL', defaultValue: kE2eProviderBaseUrl);
  static const sessionHeaderValue = 'dsh-go-ios-ssh';

  static String get privateKey => utf8.decode(base64Decode(keyB64));

  static void require() {
    final missing = <String>[
      if (host.isEmpty) 'T33B_SSH_HOST',
      if (port <= 0) 'T33B_SSH_PORT',
      if (user.isEmpty) 'T33B_SSH_USER',
      if (keyB64.isEmpty) 'T33B_SSH_KEY_B64',
      if (fingerprint.isEmpty) 'T33B_HOST_FINGERPRINT',
      if (remoteHome.isEmpty) 'T33B_REMOTE_HOME',
      if (remoteWorkdir.isEmpty) 'T33B_REMOTE_WORKDIR',
      if (launchCommand.isEmpty) 'T33B_LAUNCH_COMMAND',
    ];
    if (missing.isNotEmpty) {
      throw E2eHarnessError(
        'missing --dart-define(s): ${missing.join(', ')} '
        '(use scripts/e2e/ios/run_ssh_real.sh)',
      );
    }
    E2eConfig.requireBroker();
    if (!fingerprint.startsWith('SHA256:')) {
      throw E2eHarnessError('T33B_HOST_FINGERPRINT must be an OpenSSH SHA256 fingerprint');
    }
  }
}

class _Turn {
  const _Turn({
    required this.sessionId,
    required this.text,
    required this.streamingPrefixes,
    required this.tools,
    required this.model,
  });

  final String sessionId;
  final String text;
  final int streamingPrefixes;
  final List<ToolChatItem> tools;
  final ModelSelection? model;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'T33b_ssh_real_host_real_model',
    (tester) async {
      WidgetController.hitTestWarningShouldBeFatal = true;
      final total = Stopwatch()..start();

      _step('configuration');
      _Cfg.require();
      _log('ssh ${_Cfg.host}:${_Cfg.port} user=${_Cfg.user} fingerprint=${_Cfg.fingerprint}');
      _log('remote HOME=${_Cfg.remoteHome}');
      _log('remote workdir=${_Cfg.remoteWorkdir}');
      _log('remote launch: ${_Cfg.launchCommand} (the app appends --host 127.0.0.1 --port 0 --no-open)');
      final sshKey = _Cfg.privateKey;
      expect(sshKey.contains('PRIVATE KEY-----'), isTrue, reason: 'the throwaway client key did not decode to PEM');

      _step('real provider key from the loopback broker (fetched once, never logged)');
      final apiKey = await fetchBrokerKey();
      expect(apiKey.trim(), isNotEmpty);
      _log('broker key fetched: ${apiKey.length} chars');

      _step('clean install: reset device state, boot the real app');
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
      final container = ProviderScope.containerOf(tester.element(find.byType(DshApp)), listen: false);
      // Keep the remote connection provider alive for the whole run.
      final keepAlive = container.listen(activeConnectionProvider, (_, _) {}, fireImmediately: true);
      addTearDown(keepAlive.close);

      await _finishOnboarding(tester, container);
      await _waitFor(
        tester,
        'home shell after onboarding',
        () => find.byType(HomeShell).evaluate().isNotEmpty,
        timeout: const Duration(minutes: 3),
      );

      _step('local engine: install/start to running, connect');
      await _verifyLocalEngine(tester, container);
      final localConn = await _waitConnection(tester, container, HostKind.local, const Duration(minutes: 2));
      expect(localConn.isLocal, isTrue);

      _step('local baseline: one local conversation');
      final localBefore = (await localConn.client.listSessions()).map((s) => s.sessionId).toSet();
      final localSession = (await localConn.client.createSession(cwd: localWorkspaceDir)).sessionId;
      expect(localSession, isNotEmpty);
      // A session created but never written to has no log on disk and does not
      // survive the local engine pausing for the SSH host. A real user message
      // (no provider key is set, so no model call) makes it a durable session,
      // so "unchanged" after switching back is meaningful.
      final localEnded = Completer<void>();
      final localWatch = localConn.client.watch(localSession).listen((event) {
        if (event is TurnEndedEvent && !localEnded.isCompleted) localEnded.complete();
      });
      await localConn.client.prompt(localSession, '本机基线会话：这条消息用于主机隔离校验。');
      try {
        await localEnded.future.timeout(const Duration(seconds: 90));
      } on TimeoutException {
        _log('the local baseline turn did not end within 90s; continuing');
      }
      await localWatch.cancel();
      final localAfterCreate = (await localConn.client.listSessions()).map((s) => s.sessionId).toSet();
      expect(localAfterCreate, {...localBefore, localSession});
      _log('local session created: $localSession (local list: ${localAfterCreate.join(', ')})');

      _step('open 远程主机 and fill the real Add SSH host form');
      final navigator = Navigator.of(tester.element(find.byType(HomeShell)));
      unawaited(
        navigator.push(MaterialPageRoute<void>(builder: (_) => const RemoteScreen())),
      );
      await _waitFor(
        tester,
        'RemoteScreen',
        () => find.byType(RemoteScreen).evaluate().isNotEmpty,
        timeout: const Duration(seconds: 30),
      );
      await _tapFirst(tester, find.text(appL10n.remoteAddSshHost), '添加 SSH 主机');
      await _waitFor(
        tester,
        'SshHostFormPage',
        () => find.byType(SshHostFormPage).evaluate().isNotEmpty,
        timeout: const Duration(seconds: 30),
      );
      await _tapFirst(tester, find.text(appL10n.remotePrivateKey), '私钥 auth');
      await tester.pump();
      final fields = find.byType(TextField);
      expect(fields, findsNWidgets(8), reason: 'unexpected SSH form field count');
      await _setField(tester, fields, 0, 'T33b 本机 SSH');
      await _setField(tester, fields, 1, _Cfg.host);
      await _setField(tester, fields, 2, _Cfg.user);
      await _setField(tester, fields, 3, '${_Cfg.port}');
      await _setField(tester, fields, 4, sshKey);
      await _setField(tester, fields, 6, _Cfg.launchCommand);
      await _setField(tester, fields, 7, _Cfg.remoteWorkdir);
      _log('form filled: host=${_Cfg.host} port=${_Cfg.port} user=${_Cfg.user} auth=privateKey');

      _step('real SSH test connection + TOFU prompt with the expected fingerprint');
      await _tapFirst(tester, find.text(appL10n.remoteTestConnection), '测试连接');
      await _waitFor(
        tester,
        'host key trust prompt',
        () => find.byType(HostKeyDialog).evaluate().isNotEmpty,
        timeout: const Duration(minutes: 3),
      );
      expect(
        find.text(_Cfg.fingerprint),
        findsWidgets,
        reason: 'the TOFU prompt did not show the expected host-key fingerprint',
      );
      _log('trust prompt showed ${_Cfg.fingerprint}');
      await _tapFirst(tester, find.text(appL10n.remoteHostKeyTrustConnect), '信任并连接');
      await _waitFor(
        tester,
        'test connection starts the remote dsh web',
        () =>
            find.text(appL10n.remoteDshStarted).evaluate().isNotEmpty ||
            find.text(appL10n.remoteDshReused).evaluate().isNotEmpty,
        timeout: const Duration(minutes: 4),
      );
      _log('test connection reached the remote DSH');
      await _waitFor(
        tester,
        'test connection settles',
        () => find.text(appL10n.remoteTestConnection).evaluate().isNotEmpty,
        timeout: const Duration(minutes: 2),
      );
      await _tapFirst(tester, find.text(appL10n.commonSave), '保存');
      await _waitFor(
        tester,
        'host saved, back on RemoteScreen',
        () => find.byType(SshHostFormPage).evaluate().isEmpty && find.byType(RemoteScreen).evaluate().isNotEmpty,
        timeout: const Duration(seconds: 30),
      );

      final savedList = container.read(hostsProvider).ssh;
      final saved = savedList.singleWhere((h) => h.host == _Cfg.host && h.port == _Cfg.port);
      expect(saved.auth, SshAuthMethod.privateKey);
      expect(saved.hostKeyFingerprint, _Cfg.fingerprint);
      expect(saved.hostKeyType, isNotNull);
      expect(saved.launchCommand, _Cfg.launchCommand);
      expect(saved.workingDirectory, _Cfg.remoteWorkdir);
      final hostRef = HostRef.ssh(saved.id);
      _log('host saved: id=${saved.id} key=${saved.hostKeyType} ${saved.hostKeyFingerprint}');

      _step('activate the SSH host and follow the link progress steps');
      final phases = <HostLinkPhase>[];
      final steps = <HostLinkStep>{};
      await _tapFirst(tester, find.text(saved.name), 'activate ${saved.name}');
      // hostLinkProvider is autoDispose: poll the link that is current at each
      // tick instead of holding a pre-activation instance (which is disposed
      // and recreated), and collect the progress steps it reports.
      final sshConn = await _waitSshConnection(tester, container, hostRef, phases, steps);
      expect(sshConn.isLocal, isFalse);
      expect(sshConn.label, '${saved.name} · SSH');
      expect(sshConn.workingDirectory, _Cfg.remoteWorkdir);
      final link = container.read(hostLinkProvider(hostRef))!;
      await _waitFor(
        tester,
        'SSH link connected',
        () => link.status.phase == HostLinkPhase.connected,
        timeout: const Duration(minutes: 2),
      );
      expect(link.status.completed, HostLinkStep.values.toSet());
      expect(steps, containsAll(HostLinkStep.values), reason: 'a progress step never reached the observed statuses');
      _log('link phases: ${phases.map((p) => p.name).join(' -> ')}');
      _log('link steps completed: ${link.status.completed.map((s) => s.name).join(', ')}');

      _step('remote session list loads from the isolated DSH_HOME');
      final remoteInitial = await sshConn.client.listSessions();
      expect(remoteInitial, isEmpty, reason: 'the isolated remote DSH_HOME already had sessions');
      final remoteRows = await _waitSessionList(tester, container, const Duration(minutes: 2));
      expect(remoteRows.map((s) => s.sessionId), isEmpty);
      _log('remote session list: empty (fresh DSH_HOME ${_Cfg.remoteHome}/.dsh)');

      _step('build the real provider on the REMOTE engine via ProviderActions (with headers)');
      final backend = container.read(providerBackendProvider);
      expect(backend, isNotNull, reason: 'no provider backend for the active remote connection');
      expect(backend!.isLocal, isFalse, reason: 'ProviderActions would write to the local engine');
      final remoteSnapshot = await _waitProviders(tester, container, local: false);
      _log(
        'remote provider backend: host=${backend.hostLabel} local=${remoteSnapshot.local} '
        'writable=${remoteSnapshot.writable} supported=${remoteSnapshot.supported}',
      );
      final actions = container.read(providerActionsProvider);
      final providerId = await actions.save(
        ProviderDraft(
          name: 'OpenCode Go SSH',
          api: ProviderApi.openaiCompletions,
          baseUrl: _Cfg.providerBaseUrl,
          apiKey: apiKey,
          models: const [ProviderModelSpec(id: kE2eModel, name: 'DeepSeek V4.1 Flash')],
          headers: const {kE2eSessionHeader: _Cfg.sessionHeaderValue},
        ),
      );
      expect(providerId, isNotEmpty);
      final settings = await backend.read();
      final profile = settings?.profiles.firstWhere(
        (p) => p.route == providerId,
        orElse: () => throw StateError('the provider was not written to the remote engine'),
      );
      expect(
        profile!.headers,
        const {kE2eSessionHeader: _Cfg.sessionHeaderValue},
        reason: 'the remote engine did not store the custom request headers',
      );
      final reread = await _waitProviders(tester, container, local: false, requireId: providerId);
      expect(reread.keyStored(reread.byId(providerId)!), isTrue, reason: 'the remote engine has no provider key');
      _log(
        'provider on remote engine: $providerId headers=${jsonEncode(profile.headers)} '
        'keyStored=${reread.keyStored(reread.byId(providerId)!)}',
      );

      final catalog = await _waitModelCatalog(tester, container, providerId);
      expect(
        catalog.models.any((m) => m.provider == providerId && m.id == _Cfg.model),
        isTrue,
        reason: 'the remote model catalog does not list $providerId/${_Cfg.model}',
      );
      container.read(pendingModelProvider.notifier).select(
        ModelSelection(provider: providerId, model: _Cfg.model),
      );
      _log('model selected on the remote engine: $providerId/${_Cfg.model}');

      _step('real model turn on the REMOTE engine: write and read back ssh-ok.md');
      final turn1 = await _sendTurn(tester, container, _promptWrite);
      expect(turn1.streamingPrefixes, greaterThanOrEqualTo(1), reason: 'the real reply never streamed to the UI');
      expect(turn1.tools, isNotEmpty, reason: 'the turn produced no tool row');
      expect(
        turn1.tools.any((t) => t.status == ToolStatus.succeeded),
        isTrue,
        reason: 'no tool call succeeded: ${turn1.tools.map((t) => '${t.name}/${t.status.name}')}',
      );
      _log(
        'turn 1 done: session=${turn1.sessionId} streamingPrefixes=${turn1.streamingPrefixes} '
        'tools=${turn1.tools.map((t) => '${t.name}/${t.status.name}').join(', ')}',
      );
      _log('turn 1 reply (${turn1.text.length} chars): ${_clip(turn1.text)}');
      if (turn1.model != null) {
        expect(turn1.model!.provider, providerId);
        expect(turn1.model!.model, _Cfg.model);
      }
      final sshSessionId = turn1.sessionId;
      final remoteAfterTurn = (await sshConn.client.listSessions()).map((s) => s.sessionId).toSet();
      expect(remoteAfterTurn, contains(sshSessionId), reason: 'the remote session list does not contain the turn');
      expect(
        (await localConn.client.listSessions()).map((s) => s.sessionId),
        isNot(contains(sshSessionId)),
        reason: 'the SSH conversation leaked into the local engine',
      );
      final uiRows = await _waitSessionContains(tester, container, sshSessionId, const Duration(minutes: 2));
      expect(uiRows.map((s) => s.sessionId), contains(sshSessionId));
      _log('remote session list shows $sshSessionId; local engine does not have it');

      _step('read the remote workspace file over a second real SSH connection');
      final probe = await DartSshTransport.connect(
        SshConnectParams(
          host: _Cfg.host,
          port: _Cfg.port,
          username: _Cfg.user,
          auth: SshAuthMethod.privateKey,
          secrets: SshSecrets(privateKey: sshKey),
        ),
        (key) async {
          expect(key.fingerprint, _Cfg.fingerprint, reason: 'the SSH probe saw a different host key');
          return key.fingerprint == _Cfg.fingerprint;
        },
      );
      addTearDown(probe.close);
      final remoteFilePath = '${_Cfg.remoteWorkdir}/ssh-ok.md';
      final cat = await probe.run('cat ${shQuote(remoteFilePath)}');
      expect(cat.exitCode, 0, reason: 'reading $remoteFilePath over SSH failed: ${cat.stderr.trim()}');
      final fileText = cat.stdout.trim();
      expect(fileText, _expectedFileLine, reason: 'the remote workspace file has the wrong content: $fileText');
      _log('remote file $remoteFilePath = ${jsonEncode(fileText)}');

      _step('kill the remote dsh web (pid from the SSH bootstrap, scoped to this run)');
      final homeResult = await probe.run(r'printf %s "$HOME"');
      final remoteUserHome = homeResult.stdout.trim();
      expect(homeResult.exitCode, 0, reason: 'could not read the remote HOME: ${homeResult.stderr.trim()}');
      final pidResult = await probe.run(
        r'pid=$(cat "$HOME/.dsh-app-remote/web.pid" 2>/dev/null) || exit 7; printf %s "$pid"',
      );
      expect(pidResult.exitCode, 0, reason: 'no dsh-app bootstrap pid file under $remoteUserHome: ${pidResult.stderr.trim()}');
      final oldPid = int.tryParse(pidResult.stdout.trim());
      expect(oldPid, isNotNull, reason: 'the bootstrap pid is not a number: ${pidResult.stdout}');
      // Ownership: the pid file is in this run's private temp HOME
      // (sshd SetEnv HOME made it the session HOME), and the bootstrap wrote the
      // process start time next to it. Matching it rules out a recycled pid.
      final argsResult = await probe.run('ps -p $oldPid -o args=');
      expect(argsResult.stdout, contains('dsh'), reason: 'pid $oldPid is not dsh: ${argsResult.stdout}');
      expect(argsResult.stdout, contains('web'), reason: 'pid $oldPid is not dsh web: ${argsResult.stdout}');
      final recordedStart = await probe.run(r'cat "$HOME/.dsh-app-remote/web.st" 2>/dev/null');
      final liveStart = await probe.run('ps -p $oldPid -o lstart=');
      expect(recordedStart.stdout.trim(), isNotEmpty, reason: 'the bootstrap recorded no remote dsh start time');
      expect(
        liveStart.stdout.trim(),
        recordedStart.stdout.trim(),
        reason: 'pid $oldPid was reused by another process (start time differs)',
      );
      _log(
        'remote dsh web pid=$oldPid owned by this run '
        '(start=${liveStart.stdout.trim()}, args=${_clip(argsResult.stdout.trim())})',
      );
      final originalClient = sshConn.client;
      await probe.run(
        'kill -TERM $oldPid 2>/dev/null; i=0; while kill -0 $oldPid 2>/dev/null && [ \$i -lt 100 ]; do '
        'sleep 0.1; i=\$((i+1)); done; kill -0 $oldPid 2>/dev/null && kill -9 $oldPid 2>/dev/null; true',
      );

      _step('assert the reconnect/retry state');
      var noticed = false;
      final noticeDeadline = DateTime.now().add(const Duration(seconds: 25));
      while (DateTime.now().isBefore(noticeDeadline)) {
        final status = container.read(hostLinkProvider(hostRef))?.status;
        if (status != null) phases.add(status.phase);
        final current = container.read(activeConnectionProvider).value;
        if (status?.phase == HostLinkPhase.reconnecting ||
            status?.phase == HostLinkPhase.failed ||
            current == null ||
            !identical(current.client, originalClient)) {
          noticed = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await tester.pump();
      }
      if (!noticed) {
        _log('the app had not noticed the dead remote dsh yet; using its real retry action');
        container.read(remoteConnectionProvider(hostRef).notifier).retry();
      }
      await _waitFor(
        tester,
        'the link leaves connected after the remote dsh died',
        () {
          final status = container.read(hostLinkProvider(hostRef))?.status;
          return status != null &&
              (status.phase == HostLinkPhase.reconnecting ||
                  status.phase == HostLinkPhase.failed ||
                  container.read(activeConnectionProvider).value == null);
        },
        timeout: const Duration(minutes: 2),
      );
      final lostStatus = container.read(hostLinkProvider(hostRef))!.status;
      expect(phases, contains(HostLinkPhase.reconnecting));
      _log(
        'reconnect state observed: phase=${lostStatus.phase.name} attempt=${lostStatus.attempt} '
        'error=${lostStatus.error?.kind.name} (autoNotice=$noticed)',
      );

      _step('the app restarts the remote dsh and the link comes back');
      HostConnection? reconnected;
      final reconnectDeadline = DateTime.now().add(const Duration(minutes: 4));
      while (DateTime.now().isBefore(reconnectDeadline)) {
        final status = container.read(hostLinkProvider(hostRef))?.status;
        if (status != null) phases.add(status.phase);
        final current = container.read(activeConnectionProvider).value;
        if (status?.phase == HostLinkPhase.connected &&
            current != null &&
            current.kind == HostKind.ssh &&
            !identical(current.client, originalClient)) {
          reconnected = current;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
        await tester.pump();
      }
      expect(reconnected, isNotNull, reason: 'the SSH link never reconnected with a fresh client');
      final linkAfter = container.read(hostLinkProvider(hostRef))!;
      expect(linkAfter.status.completed, HostLinkStep.values.toSet());
      final linkAfterEndpoint = (linkAfter as SshHostLink).endpoint;
      expect(linkAfterEndpoint, isNotNull);
      expect(linkAfterEndpoint!.reused, isFalse, reason: 'the app reused the killed remote dsh instead of starting a new one');
      final newPidResult = await probe.run(r'cat "$HOME/.dsh-app-remote/web.pid" 2>/dev/null');
      final newPid = int.tryParse(newPidResult.stdout.trim());
      expect(newPid, isNotNull, reason: 'the restarted remote dsh wrote no bootstrap pid');
      expect(newPid, isNot(oldPid), reason: 'the remote dsh pid did not change');
      // The launch environment (HOME/DSH_HOME) is not part of argv; prove
      // ownership with the bootstrap's own start-time record instead.
      final newArgs = await probe.run('ps -p $newPid -o args=');
      expect(newArgs.stdout, contains('dsh'), reason: 'the restarted pid is not dsh: ${newArgs.stdout}');
      final newStart = await probe.run('ps -p $newPid -o lstart=');
      final newRecorded = await probe.run(r'cat "$HOME/.dsh-app-remote/web.st" 2>/dev/null');
      expect(newStart.stdout.trim(), newRecorded.stdout.trim(), reason: 'the restarted pid is not the bootstrap-recorded one');
      _log(
        'remote dsh restarted: pid $oldPid -> $newPid; endpoint port ${linkAfterEndpoint.port} '
        '(reused=${linkAfterEndpoint.reused}, start=${newStart.stdout.trim()})',
      );

      _step('the conversation continues after the restart');
      await _waitFor(
        tester,
        'new remote client is active',
        () => identical(container.read(activeConnectionProvider).value?.client, reconnected!.client),
        timeout: const Duration(minutes: 1),
      );
      expect(container.read(currentSessionProvider), sshSessionId, reason: 'the conversation was lost on reconnect');
      final turn2 = await _sendTurn(
        tester,
        container,
        _promptContinue,
        expectSession: sshSessionId,
      );
      expect(turn2.sessionId, sshSessionId);
      expect(turn2.streamingPrefixes, greaterThanOrEqualTo(1));
      expect(turn2.tools, isNotEmpty, reason: 'the continuation produced no tool row');
      expect(
        turn2.text.toLowerCase(),
        contains(_expectedFileLine),
        reason: 'the continuation reply did not quote the file line: ${_clip(turn2.text)}',
      );
      _log(
        'turn 2 done after reconnect: streamingPrefixes=${turn2.streamingPrefixes} '
        'tools=${turn2.tools.map((t) => '${t.name}/${t.status.name}').join(', ')}',
      );
      _log('turn 2 reply (${turn2.text.length} chars): ${_clip(turn2.text)}');
      final afterRestart = await probe.run('cat ${shQuote(remoteFilePath)}');
      expect(afterRestart.stdout.trim(), _expectedFileLine);

      _step('switch back to 本机: local sessions unchanged, SSH conversation hidden');
      container.read(activeHostProvider.notifier).select(HostRef.local);
      await _waitFor(
        tester,
        'new chat on 本机 after the host switch',
        () => container.read(currentSessionProvider) == null,
        timeout: const Duration(seconds: 30),
      );
      final backLocal = await _waitConnection(tester, container, HostKind.local, const Duration(minutes: 3));
      expect(backLocal.isLocal, isTrue);
      final localFinal = (await backLocal.client.listSessions()).map((s) => s.sessionId).toSet();
      expect(localFinal, {...localBefore, localSession}, reason: 'the local session list changed while on SSH');
      expect(localFinal, isNot(contains(sshSessionId)), reason: 'the SSH conversation leaked into local sessions');
      final localUiRows = await _waitSessionList(tester, container, const Duration(minutes: 2));
      expect(localUiRows.map((s) => s.sessionId).toSet(), localFinal);
      expect(localUiRows.map((s) => s.sessionId), isNot(contains(sshSessionId)));
      expect(container.read(activeHostProvider).isLocal, isTrue);
      expect(container.read(activeConnectionProvider).value?.isLocal, isTrue);
      _log('local list after switching back: ${localFinal.join(', ')} (SSH $sshSessionId absent)');

      _log('PASS in ${total.elapsed.inSeconds}s');
    },
    timeout: const Timeout(Duration(minutes: 25)),
  );
}

// ---------------------------------------------------------------------------
// Turn

Future<_Turn> _sendTurn(
  WidgetTester tester,
  ProviderContainer container,
  String prompt, {
  String? expectSession,
}) async {
  await _waitComposer(tester);
  final field = find.descendant(of: find.byType(Composer), matching: find.byType(TextField));
  expect(field, findsOneWidget, reason: 'the composer has no text field');
  for (var attempt = 0; attempt < 3; attempt++) {
    await tester.enterText(field, prompt);
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await tester.pump();
    if (tester.widget<TextField>(field).controller?.text == prompt) break;
    _log('composer draft reset (attempt ${attempt + 1}), re-entering');
  }
  expect(tester.widget<TextField>(field).controller?.text, prompt, reason: 'the composer keeps clearing the prompt');
  final send = find.descendant(of: find.byType(Composer), matching: find.byIcon(AppIcons.send));
  await _waitFor(
    tester,
    'send key enabled',
    () {
      final composers = tester.widgetList<Composer>(find.byType(Composer)).toList();
      return send.evaluate().isNotEmpty &&
          composers.isNotEmpty &&
          composers.every((c) => c.connected && c.sessionReady && !c.busy);
    },
    timeout: const Duration(seconds: 90),
  );
  await _tapFirst(tester, send, 'send prompt');
  await _waitFor(
    tester,
    'a conversation owns the turn',
    () => container.read(currentSessionProvider) != null,
    timeout: const Duration(seconds: 90),
  );
  final sessionId = container.read(currentSessionProvider)!;
  if (expectSession != null) {
    expect(sessionId, expectSession, reason: 'the send started a different conversation');
  }
  _log('turn prompt sent to remote session $sessionId');

  final observed = <String>{};
  var streamingPrefixes = 0;
  final approvals = <String>{};
  final sub = container.listen<ChatState>(chatProvider(sessionId), (previous, next) {
    for (final item in next.items.whereType<AssistantChatItem>()) {
      if (item.streaming && item.text.trim().isNotEmpty) {
        streamingPrefixes++;
        observed.add(item.text);
      }
    }
    for (final tool in next.items.whereType<ToolChatItem>()) {
      final request = tool.pendingApproval;
      if (request == null || !approvals.add(tool.callId)) continue;
      _log('approving ${tool.name} (${tool.callId}) on the remote engine');
      final client = container.read(activeConnectionProvider).value?.client;
      unawaited(client?.respondApproval(request, ApprovalDecision.allowOnce).catchError((Object _) {}) ??
          Future<void>.value());
    }
  }, fireImmediately: true);

  try {
    ChatState chat = container.read(chatProvider(sessionId));
    final clock = Stopwatch()..start();
    while (clock.elapsed < const Duration(minutes: 6)) {
      chat = container.read(chatProvider(sessionId));
      if (chat.error != null) {
        fail('the turn failed before it ended: ${chat.error}');
      }
      final finals = chat.items
          .whereType<AssistantChatItem>()
          .where((item) => !item.streaming && item.text.trim().isNotEmpty)
          .toList();
      if (!chat.running && chat.pending.isEmpty && finals.isNotEmpty) {
        // A tool result may still be followed by one more model step; settle.
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        await tester.pump();
        final settled = container.read(chatProvider(sessionId));
        if (!settled.running) {
          chat = settled;
          break;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();
    }
    if (chat.running || chat.pending.isNotEmpty) {
      fail('the turn did not end within 6 minutes (running=${chat.running}, pending=${chat.pending.length})');
    }
    final finals = chat.items
        .whereType<AssistantChatItem>()
        .where((item) => !item.streaming && item.text.trim().isNotEmpty)
        .toList();
    expect(finals, isNotEmpty, reason: 'no completed assistant reply landed');
    final text = finals.last.text.trim();
    expect(text, isNotEmpty);
    final tools = chat.items.whereType<ToolChatItem>().toList();
    for (final tool in tools) {
      _log(
        'tool row: ${tool.name} status=${tool.status.name} '
        'result=${_clip(tool.resultText.trim())}',
      );
    }
    return _Turn(
      sessionId: sessionId,
      text: text,
      streamingPrefixes: streamingPrefixes,
      tools: tools,
      model: chat.model,
    );
  } finally {
    sub.close();
  }
}

Future<void> _waitComposer(WidgetTester tester) async {
  await _waitFor(
    tester,
    'chat composer',
    () => find.byType(Composer).evaluate().isNotEmpty,
    timeout: const Duration(minutes: 2),
  );
  final clock = Stopwatch()..start();
  while (clock.elapsed < const Duration(minutes: 3)) {
    final composers = tester.widgetList<Composer>(find.byType(Composer)).toList();
    if (composers.isNotEmpty && composers.every((c) => c.connected && c.sessionReady && !c.busy)) return;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pump();
  }
  fail('the composer never became ready on the active host');
}

// ---------------------------------------------------------------------------
// Providers / catalog / sessions

Future<ProvidersSnapshot> _waitProviders(
  WidgetTester tester,
  ProviderContainer container, {
  required bool local,
  String? requireId,
  Duration timeout = const Duration(minutes: 3),
}) async {
  final clock = Stopwatch()..start();
  Object? lastError;
  while (clock.elapsed < timeout) {
    try {
      container.invalidate(customProvidersProvider);
      final snapshot = await container.read(customProvidersProvider.future).timeout(const Duration(seconds: 30));
      if (snapshot != null &&
          snapshot.supported &&
          snapshot.writable &&
          snapshot.local == local &&
          (requireId == null || snapshot.byId(requireId) != null)) {
        return snapshot;
      }
    } catch (error) {
      lastError = error;
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await tester.pump();
  }
  fail('no writable provider settings from the ${local ? 'local' : 'remote'} engine'
      '${requireId == null ? '' : ' with $requireId'}${lastError == null ? '' : ' (last error: $lastError)'}');
}

Future<ModelCatalog> _waitModelCatalog(
  WidgetTester tester,
  ProviderContainer container,
  String providerId,
) async {
  final clock = Stopwatch()..start();
  Object? lastError;
  while (clock.elapsed < const Duration(minutes: 3)) {
    try {
      container.invalidate(modelCatalogProvider);
      final catalog = await container.read(modelCatalogProvider.future).timeout(const Duration(seconds: 30));
      if (catalog != null && catalog.models.any((m) => m.provider == providerId && m.id == _Cfg.model)) {
        return catalog;
      }
    } catch (error) {
      lastError = error;
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await tester.pump();
  }
  fail('the remote engine never listed $providerId/${_Cfg.model}'
      '${lastError == null ? '' : ' (last error: $lastError)'}');
}

Future<List<SessionSummary>> _waitSessionContains(
  WidgetTester tester,
  ProviderContainer container,
  String sessionId,
  Duration timeout,
) async {
  final clock = Stopwatch()..start();
  List<SessionSummary> rows = const [];
  while (clock.elapsed < timeout) {
    final value = container.read(sessionsProvider);
    if (value.hasError) fail('the session list failed: ${value.error}');
    final current = value.value;
    if (current != null && !value.isLoading) {
      rows = current;
      if (rows.any((row) => row.sessionId == sessionId)) return rows;
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await tester.pump();
  }
  fail('session $sessionId never appeared in the session list (rows: ${rows.map((r) => r.sessionId)})');
}

Future<List<SessionSummary>> _waitSessionList(
  WidgetTester tester,
  ProviderContainer container,
  Duration timeout,
) async {
  final clock = Stopwatch()..start();
  while (clock.elapsed < timeout) {
    final value = container.read(sessionsProvider);
    if (value.hasError) fail('the session list failed: ${value.error}');
    final rows = value.value;
    if (rows != null && !value.isLoading) return rows;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await tester.pump();
  }
  fail('the ${container.read(activeHostProvider).kind.name} session list never loaded');
}

// ---------------------------------------------------------------------------
// Connections / runtime / onboarding

/// Waits for the SSH connection while recording the autoDispose link's
/// progress (phase, current step and the cumulative completed steps).
Future<HostConnection> _waitSshConnection(
  WidgetTester tester,
  ProviderContainer container,
  HostRef hostRef,
  List<HostLinkPhase> phases,
  Set<HostLinkStep> steps,
) async {
  final clock = Stopwatch()..start();
  Object? lastError;
  while (clock.elapsed < const Duration(minutes: 5)) {
    final link = container.read(hostLinkProvider(hostRef));
    if (link != null) {
      phases.add(link.status.phase);
      if (link.status.step != null) steps.add(link.status.step!);
      steps.addAll(link.status.completed);
    }
    final value = container.read(activeConnectionProvider);
    if (value.hasError) lastError = value.error;
    final connection = value.value;
    if (connection != null && connection.kind == HostKind.ssh) return connection;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await tester.pump();
  }
  _dumpTexts(tester);
  fail(
    'no SSH connection within 5 minutes'
    '${lastError == null ? '' : ' (last error: $lastError)'}',
  );
}

Future<HostConnection> _waitConnection(
  WidgetTester tester,
  ProviderContainer container,
  HostKind kind,
  Duration timeout,
) async {
  final clock = Stopwatch()..start();
  Object? lastError;
  while (clock.elapsed < timeout) {
    final value = container.read(activeConnectionProvider);
    if (value.hasError) lastError = value.error;
    final connection = value.value;
    if (connection != null && connection.kind == kind) return connection;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pump();
  }
  fail(
    'no ${kind.name} connection within ${timeout.inMinutes} minutes'
    '${lastError == null ? '' : ' (last error: $lastError)'}',
  );
}

Future<void> _verifyLocalEngine(WidgetTester tester, ProviderContainer container) async {
  final status = await _waitForRuntimePhase(
    tester,
    container,
    (phase) => phase == RuntimePhase.installed || phase == RuntimePhase.running || phase == RuntimePhase.error,
    'runtime settled after onboarding',
    const Duration(minutes: 3),
  );
  expect(status.phase, isNot(RuntimePhase.error), reason: 'runtime error: ${status.error}');
  expect(status.installedVersion, isNotNull);
  if (status.phase != RuntimePhase.running) {
    await container.read(localRuntimeProvider.notifier).start();
  }
  final running = await _waitForRuntimePhase(
    tester,
    container,
    (phase) => phase == RuntimePhase.running,
    'local engine running',
    const Duration(minutes: 2),
  );
  expect(running.baseUrl, isNotNull);
  expect(running.token, isNotNull);
  await _waitFor(
    tester,
    'the app connects to the local engine',
    () => container.read(providerBackendProvider)?.isLocal == true,
    timeout: const Duration(minutes: 2),
  );
  _log('local engine running: ${running.installedVersion} dsh=${running.dshVersion}');
}

Future<RuntimeStatus> _waitForRuntimePhase(
  WidgetTester tester,
  ProviderContainer container,
  bool Function(RuntimePhase) done,
  String what,
  Duration timeout,
) async {
  final clock = Stopwatch()..start();
  while (clock.elapsed < timeout) {
    final state = container.read(localRuntimeProvider);
    if (state.loaded && done(state.status.phase)) return state.status;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pump();
  }
  final state = container.read(localRuntimeProvider);
  _dumpTexts(tester);
  fail('$what: timed out (phase=${state.status.phase.name}, error=${state.status.error})');
}

Future<void> _finishOnboarding(WidgetTester tester, ProviderContainer container) async {
  if (find.byType(HomeShell).evaluate().isNotEmpty) {
    _log('first screen: home shell');
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
    // The welcome→runtime slide can still cover the card when the first tap
    // lands, leaving 远程主机 selected; verify the selection and retry.
    final localCard = find.byKey(const ValueKey('runtime-option-local'));
    var selected = false;
    for (var attempt = 0; attempt < 4 && !selected; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      await tester.pump();
      await tester.ensureVisible(localCard);
      await tester.tap(localCard);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await tester.pump();
      final cards = tester.widgetList<RuntimeOptionCard>(find.byType(RuntimeOptionCard)).toList();
      selected = cards.any((card) => card.key == const ValueKey('runtime-option-local') && card.selected);
      _log(
        'runtime choice: attempt ${attempt + 1} selectedLocal=$selected '
        '(cards: ${cards.map((c) => '${c.key}/${c.selected}').join(', ')}, '
        'runtimeAvailable=${container.read(localRuntimeProvider).available})',
      );
    }
    expect(selected, isTrue, reason: '本机 could not be selected in the first-run runtime choice');
    await _tapFirst(tester, find.widgetWithText(FilledButton, appL10n.commonContinue), 'runtime 继续');
  } else {
    _log('first screen: connect page (runtime already installed)');
  }
  if (find.byKey(const ValueKey('setup-appearance-card')).evaluate().isNotEmpty) {
    _log('appearance step: continuing');
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
    'home shell',
    () => find.byType(HomeShell).evaluate().isNotEmpty,
    timeout: const Duration(minutes: 3),
  );
}

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
  expect(AppLanguageController.initial, AppLanguage.zh);
}

// ---------------------------------------------------------------------------
// Waiting, tapping, logging

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
  } catch (_) {
    // Not inside a scrollable.
  }
  await tester.pump(const Duration(milliseconds: 120));
  await tester.tap(target);
  await Future<void>.delayed(const Duration(milliseconds: 250));
  await tester.pump();
}

Future<void> _setField(WidgetTester tester, Finder fields, int index, String text) async {
  final field = fields.at(index);
  await tester.ensureVisible(field);
  await tester.enterText(field, text);
  await tester.pump();
}

String _clip(String text, [int max = 220]) {
  final oneLine = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return oneLine.length <= max ? oneLine : '${oneLine.substring(0, max)}…';
}

void _step(String message) => _log('=== $message');

void _log(String message) => debugPrint('[t33b-ssh] $message');

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
