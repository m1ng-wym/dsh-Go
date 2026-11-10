// D1-10 · SSH 远程主机（T20）
//
// AC1 表单填主机/端口/凭据 → 测试连接 → 首次 TOFU 指纹信任 → 保存主机。
// AC2 连接后自动在远端启动 dsh web、建立本地转发、会话列表/流式消息可用，断线自动重连。
// AC3 认证失败/指纹不匹配/远端起不来 → 具体错误、不泄露口令/私钥、不建隧道、不留半成品主机。
//
// Fake SSH transport only. Its tunnel is a loopback socket into FakeDsh, so
// the production SshHostLink, LocalForwarder and DshClient run for real while
// no real sshd, host or external network is involved.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/remote/ssh/ssh_link.dart';
import 'package:dsh_app/remote/ssh/ssh_transport.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/remote/link_progress.dart';
import 'package:dsh_app/ui/remote/ssh_host_form.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../packages/dsh_client/test/support/fake_dsh.dart';
import '../shell/golden_harness.dart';
import 'support/bridge_ssh.dart';
import 'support/wait.dart';

class _LoopbackBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

class _NoLocal extends LocalConnectionController {
  @override
  Future<HostConnection?> build() async => null;
}

/// Polls [condition] while letting real socket IO and the widget tree move.
Future<void> _pumpUntil(WidgetTester tester, bool Function() condition, {required String what}) async {
  for (var i = 0; i < 300; i++) {
    if (condition()) return;
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
  fail('等待超时：$what');
}

/// Polls [condition] in a plain async test.
Future<void> _until(bool Function() condition, {required String what, Duration timeout = const Duration(seconds: 15)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等待超时：$what');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  _LoopbackBinding();

  setUp(() {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
  });

  group('D1-10 · SSH 远程主机（fake SSH → FakeDsh）', () {
    testWidgets('D1-10_add_ssh_host_requires_fingerprint_trust', (tester) async {
      final dsh = (await tester.runAsync(FakeDsh.start))!;
      addTearDown(() => tester.runAsync(dsh.close));
      dsh.handlers['session/list'] = (_) => {'ok': true, 'value': {'items': <Object?>[]}};
      final server = BridgeSshServer(forwardPort: dsh.port, token: FakeDsh.token);
      final secrets = MemorySecretStore();

      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: const SshHostFormPage(),
          brightness: Brightness.light,
          overrides: [
            secretStoreProvider.overrideWithValue(secrets),
            sshTransportFactoryProvider.overrideWithValue(server.connect),
          ],
        ),
      );
      await tester.pump();
      await tester.enterText(find.byType(TextField).at(0), '书房电脑');
      await tester.enterText(find.byType(TextField).at(1), '10.0.0.8');
      await tester.enterText(find.byType(TextField).at(2), 'me');
      await tester.enterText(find.byType(TextField).at(3), '2222');
      await tester.enterText(find.byType(TextField).at(4), 's3cret');
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
      await tester.pump();

      // First use: the key is shown, and nothing is authenticated yet.
      await tester.tap(find.text('测试连接'));
      await _pumpUntil(tester, () => find.text('信任这台主机？').evaluate().isNotEmpty, what: '指纹信任弹窗');
      expect(find.text(server.hostKey.fingerprint), findsOneWidget);
      expect(server.connects, hasLength(1), reason: '已经去读了主机指纹');
      expect(server.connects.single.port, 2222);
      expect(server.connects.single.username, 'me');
      expect(server.transports, isEmpty, reason: '确认指纹之前不完成 SSH 认证');
      expect(server.remote.launches, 0, reason: '确认指纹之前不启动远端 DSH');
      expect(secrets.values, isEmpty);
      expect(find.text('保存'), findsOneWidget);

      // Declining trusts nothing and saves nothing.
      await tester.tap(find.text('取消'));
      await _pumpUntil(tester, () => find.text('已取消信任主机').evaluate().isNotEmpty, what: '取消信任的错误');
      expect(server.transports, isEmpty);
      expect(secrets.values, isEmpty);
      expect((await SharedPreferences.getInstance()).getString(HostsController.prefsKey), isNull);

      // Trusting pins the fingerprint, then a real tunnel reaches the fake host.
      await tester.tap(find.text('测试连接'));
      await _pumpUntil(tester, () => find.text('信任这台主机？').evaluate().isNotEmpty, what: '第二次信任弹窗');
      await tester.tap(find.text('信任并连接'));
      await _pumpUntil(
        tester,
        () => find.text('已在远端启动 DSH').evaluate().isNotEmpty,
        what: '测试连接成功',
      );
      expect(server.remote.launches, 1);
      expect(server.transports, hasLength(1));
      expect(server.last.tunnels, contains(('127.0.0.1', dsh.port)));
      expect(find.text(server.hostKey.fingerprint), findsOneWidget, reason: '表单里可见已信任的指纹');

      // Saving keeps the pinned key and puts the password only in the secret store.
      await tester.tap(find.text('保存'));
      // The form's test link closes itself once open() resolves; wait for its
      // keepalive/WebSocket timers to stop before the widget test tears down.
      await _pumpUntil(tester, () => server.last.isClosed, what: '测试连接会话关闭');
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      expect(server.remote.launches, 1);
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(HostsController.prefsKey);
      expect(raw, isNotNull);
      expect(raw, isNot(contains('s3cret')));
      final configs = (jsonDecode(raw!) as List).map((e) => SshHostConfig.fromJson(e)).whereType<SshHostConfig>();
      expect(configs, hasLength(1));
      final config = configs.single;
      expect(config.host, '10.0.0.8');
      expect(config.port, 2222);
      expect(config.user, 'me');
      expect(config.hostKeyFingerprint, server.hostKey.fingerprint);
      expect(secrets.values[SshSecrets.passwordKey(config.id)], 's3cret');
    });

    test('D1-10_ssh_connect_and_stream_message', () async {
      final dsh = await FakeDsh.start();
      addTearDown(dsh.close);
      dsh.handlers['session/list'] = (_) => {
        'ok': true,
        'value': {
          'items': [
            {
              'sessionId': 'session-1',
              'updatedAt': 1786000000000,
              'projections': {
                'asOfSeq': 0,
                'values': {'title': '远端会话'},
              },
            },
          ],
        },
      };
      Map<String, Object?>? prompted;
      dsh.handlers['session/prompt'] = (args) {
        prompted = args;
        return {'ok': true, 'value': {'accepted': true}};
      };
      dsh.onOpen = (socket, streamId, endpoint, payload) {
        if (endpoint != 'session/follow') return;
        socket.item(streamId, {
          'type': 'snapshot',
          'header': {'version': 4, 'id': 'session-1', 'createdAt': 1786000000000, 'cwd': '/home/me', 'isSeeded': false},
          'cursor': -1,
          'records': <Object?>[],
          'hasMore': false,
          'projections': {'asOfSeq': -1, 'values': <String, Object?>{}},
          'assistantStream': {'revision': 0},
        });
        socket.item(streamId, {
          'type': 'assistant-stream',
          'frame': {
            'type': 'start',
            'attemptId': 'attempt-1',
            'revision': 1,
            'turn': 1,
            'step': 1,
            'startedAfterSeq': -1,
          },
        });
        socket.item(streamId, {
          'type': 'assistant-stream',
          'frame': {
            'type': 'chunk',
            'attemptId': 'attempt-1',
            'revision': 2,
            'index': 0,
            'time': 1786000000001,
            'chunk': {'type': 'text-delta', 'index': 1, 'text': '流式回来'},
          },
        });
      };

      final server = BridgeSshServer(forwardPort: dsh.port, token: FakeDsh.token);
      final link = SshHostLink(
        config: bridgeSshConfig(fingerprint: bridgeHostKey.fingerprint),
        loadSecrets: () async => const SshSecrets(password: 'pw'),
        transportFactory: server.connect,
        backoff: Backoff(initial: const Duration(milliseconds: 5), maxAttempts: 3),
      );
      addTearDown(link.close);

      final phases = <HostLinkPhase>[];
      link.statuses.listen((s) => phases.add(s.phase));
      final client = await link.open().timeout(const Duration(seconds: 20));
      expect(link.status.isConnected, isTrue);
      expect(link.status.completed, HostLinkStep.values.toSet());
      expect(server.remote.launches, 1, reason: '自动在远端启动一次 dsh web');
      expect(
        server.remote.scripts.any((s) => s.contains('dsh web --host 127.0.0.1 --port 0 --no-open')),
        isTrue,
        reason: '启动命令带 dsh web 的固定参数',
      );
      final portBefore = link.localPort;
      expect(portBefore, isNotNull, reason: '本地端口转发已建立');
      expect(server.last.tunnels, isNotEmpty);
      expect(server.last.tunnels.every((t) => t.$1 == '127.0.0.1' && t.$2 == dsh.port), isTrue);

      // Session list loads and a prompt goes through the tunnel.
      final sessions = await client.listSessions();
      expect(sessions.map((s) => s.sessionId), ['session-1']);
      final events = <DshEvent>[];
      final watch = client.watch('session-1', options: const WatchOptions(assistantStream: true)).listen(events.add);
      addTearDown(watch.cancel);
      await _until(() => events.whereType<AssistantChunkEvent>().isNotEmpty, what: '流式帧经隧道返回');
      expect(events.whereType<SessionSnapshotEvent>(), isNotEmpty);
      expect(events.whereType<AssistantStreamStarted>(), isNotEmpty);
      expect(events.whereType<AssistantChunkEvent>().single.chunk, isA<TextDeltaChunk>());
      await client.prompt('session-1', '你好');
      expect(jsonEncode(prompted), contains('你好'));

      // SSH drops: the link reconnects, reuses the running dsh web and keeps the
      // same local forward + client (watch resyncs through it).
      server.last.drop();
      await _until(
        () => server.transports.length >= 2 && link.status.isConnected,
        what: 'SSH 断线后自动重连',
      );
      expect(phases, contains(HostLinkPhase.reconnecting));
      expect(phases.last, HostLinkPhase.connected);
      expect(server.connects, hasLength(2));
      expect(server.remote.launches, 1, reason: '复用远端已运行的 DSH，不重复启动');
      expect(link.localPort, portBefore, reason: '重连后本地端口不变');
      expect(identical(client, link.currentClient), isTrue);
      expect((await client.listSessions()).map((s) => s.sessionId), ['session-1']);
      await _until(() => events.whereType<SessionSnapshotEvent>().length >= 2, what: 'watch 在重连后重新同步');
      expect(events.whereType<AssistantChunkEvent>(), isNotEmpty);
    });

    testWidgets('D1-10_ssh_auth_failure_shows_error', (tester) async {
      const password = 'pw-SENTINEL-do-not-show';
      final server = BridgeSshServer(forwardPort: 9, token: 'unused');
      server.failNext.add(
        const HostLinkError(
          HostLinkErrorKind.authFailed,
          '用户名或密码不对',
          detail: 'SSH auth failed: permission denied',
        ),
      );
      final secrets = MemorySecretStore();
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: const SshHostFormPage(),
          brightness: Brightness.light,
          overrides: [
            secretStoreProvider.overrideWithValue(secrets),
            sshTransportFactoryProvider.overrideWithValue(server.connect),
          ],
        ),
      );
      await tester.pump();
      await tester.enterText(find.byType(TextField).at(0), '书房电脑');
      await tester.enterText(find.byType(TextField).at(1), '10.0.0.8');
      await tester.enterText(find.byType(TextField).at(2), 'me');
      await tester.enterText(find.byType(TextField).at(4), password);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
      await tester.pump();

      await tester.tap(find.text('测试连接'));
      await _pumpUntil(tester, () => find.text('用户名或密码不对').evaluate().isNotEmpty, what: '认证失败错误');
      expect(server.connects, hasLength(1), reason: '“测试连接”不自动重试认证失败');
      expect(server.transports, isEmpty);
      expect(server.remote.launches, 0);
      expect(secrets.values, isEmpty);
      expect((await SharedPreferences.getInstance()).getString(HostsController.prefsKey), isNull);

      // 详情 has the diagnostic, never the password.
      await tester.ensureVisible(find.text('详情'));
      await tester.pump();
      await tester.tap(find.text('详情'));
      await tester.pump();
      expect(find.textContaining('permission denied'), findsOneWidget);
      final errorTexts = tester.widgetList<SelectableText>(
        find.descendant(of: find.byType(LinkErrorBox), matching: find.byType(SelectableText)),
      );
      expect(errorTexts, isNotEmpty);
      expect(errorTexts.every((t) => !(t.data ?? '').contains(password)), isTrue);
    });

    test('D1-10_ssh_private_key_error_does_not_echo_key', () async {
      const sentinel = 'SENTINELPRIVATEKEYMATERIAL';
      const pem = '-----BEGIN OPENSSH PRIVATE KEY-----\n'
          '$sentinel\n'
          '-----END OPENSSH PRIVATE KEY-----';
      await expectLater(
        DartSshTransport.decodePrivateKey(pem, null),
        throwsA(
          isA<HostLinkError>()
              .having((e) => e.kind, 'kind', HostLinkErrorKind.badPrivateKey)
              .having((e) => e.detail ?? '', 'detail', isNot(contains(sentinel))),
        ),
      );
    });

    testWidgets('D1-10_ssh_private_key_error_detail_hides_key', (tester) async {
      const sentinel = 'SENTINELPRIVATEKEYMATERIAL';
      const pem = '-----BEGIN OPENSSH PRIVATE KEY-----\n'
          '$sentinel\n'
          '-----END OPENSSH PRIVATE KEY-----';
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: const SshHostFormPage(),
          brightness: Brightness.light,
          overrides: [secretStoreProvider.overrideWithValue(MemorySecretStore())],
        ),
      );
      await tester.pump();
      await tester.enterText(find.byType(TextField).at(0), '书房电脑');
      await tester.enterText(find.byType(TextField).at(1), '10.0.0.8');
      await tester.enterText(find.byType(TextField).at(2), 'me');
      await tester.tap(find.text('私钥'));
      await tester.pump();
      await tester.enterText(find.byType(TextField).at(4), pem);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
      await tester.pump();

      await tester.tap(find.text('测试连接'));
      await _pumpUntil(tester, () => find.text('私钥无法读取').evaluate().isNotEmpty, what: '私钥解析错误');
      await tester.ensureVisible(find.text('详情'));
      await tester.pump();
      await tester.tap(find.text('详情'));
      await tester.pump();
      final detail = tester
          .widgetList<SelectableText>(
            find.descendant(of: find.byType(LinkErrorBox), matching: find.byType(SelectableText)),
          )
          .map((t) => t.data ?? '')
          .join();
      expect(detail, isNot(contains(sentinel)), reason: '错误详情不得回显私钥内容');
      expect(detail, contains('multiple of four'), reason: '仍保留可诊断的解析原因');
      expect((await SharedPreferences.getInstance()).getString(HostsController.prefsKey), isNull);
    });

    test('D1-10_ssh_host_key_mismatch_fails_closed', () async {
      final server = BridgeSshServer(forwardPort: 9, token: 'unused');
      var prompted = false;
      final link = SshHostLink(
        config: bridgeSshConfig(fingerprint: 'SHA256:OLDFINGERPRINToldfingerprintoldfingerprint000'),
        loadSecrets: () async => const SshSecrets(password: 'pw'),
        promptHostKey: (_) async {
          prompted = true;
          return true;
        },
        transportFactory: server.connect,
        retryFirstOpen: false,
      );
      addTearDown(link.close);
      await expectLater(
        link.open(),
        throwsA(
          isA<HostLinkError>()
              .having((e) => e.kind, 'kind', HostLinkErrorKind.hostKeyMismatch)
              .having((e) => e.detail ?? '', 'saved fingerprint', contains('OLDFINGERPRINT'))
              .having((e) => e.detail ?? '', 'presented fingerprint', contains(server.hostKey.fingerprint)),
        ),
      );
      expect(prompted, isFalse, reason: '指纹变了不能再用 TOFU 提示覆盖');
      expect(link.status.phase, HostLinkPhase.failed);
      expect(server.transports, isEmpty, reason: '拒绝的指纹不建立认证连接');
      expect(server.remote.scripts, isEmpty);
    });

    test('D1-10_ssh_start_failure_leaves_no_tunnel', () async {
      final server = BridgeSshServer(forwardPort: 9, token: 'unused');
      server.remote.crashOnStart = true;
      final link = SshHostLink(
        config: bridgeSshConfig(fingerprint: bridgeHostKey.fingerprint),
        loadSecrets: () async => const SshSecrets(password: 'pw'),
        transportFactory: server.connect,
        retryFirstOpen: false,
      );
      addTearDown(link.close);
      await expectLater(
        link.open(),
        throwsA(
          isA<HostLinkError>()
              .having((e) => e.kind, 'kind', HostLinkErrorKind.dshStartFailed)
              .having((e) => e.detail ?? '', 'detail', contains('EADDRINUSE')),
        ),
      );
      expect(link.status.phase, HostLinkPhase.failed);
      expect(server.transports, hasLength(1));
      expect(server.last.tunnels, isEmpty, reason: '远端起不来就不建立隧道');
      expect(server.last.scripts, isNotEmpty);
    });
  });

  // The bridge must also feed the app's real session list (not only DshClient).
  test('D1-10_ssh_active_host_loads_session_rows', () async {
    final dsh = await FakeDsh.start();
    addTearDown(dsh.close);
    dsh.handlers['session/list'] = (_) => {
      'ok': true,
      'value': {
        'items': [
          {
            'sessionId': 'session-1',
            'updatedAt': 1786000000000,
            'projections': {
              'asOfSeq': 0,
              'values': {'title': '远端会话'},
            },
          },
        ],
      },
    };
    final server = BridgeSshServer(forwardPort: dsh.port, token: FakeDsh.token);
    final secrets = MemorySecretStore();
    final config = bridgeSshConfig(fingerprint: bridgeHostKey.fingerprint);
    final container = ProviderContainer(
      overrides: [
        secretStoreProvider.overrideWithValue(secrets),
        localConnectionProvider.overrideWith(_NoLocal.new),
        networkKicksProvider.overrideWithValue(const Stream<void>.empty()),
        sshTransportFactoryProvider.overrideWithValue(server.connect),
      ],
    );
    addTearDown(container.dispose);
    await container.read(hostsProvider.notifier).ready;
    await container
        .read(hostsProvider.notifier)
        .saveSsh(config, secrets: const SshSecrets(password: 'pw'));
    final keep = container.listen(activeConnectionProvider, (_, _) {}, fireImmediately: true);
    addTearDown(keep.close);
    container.read(activeHostProvider.notifier).select(HostRef.ssh(config.id));
    await until(container, activeConnectionProvider, (s) => s.value != null, what: 'SSH 主机已连接');
    expect(container.read(activeConnectionProvider).value!.label, '电脑 · SSH');
    final rows = await container.read(sessionsProvider.future).timeout(const Duration(seconds: 20));
    expect(rows.map((r) => r.sessionId), ['session-1']);
    expect(rows.single.title, '远端会话');
  });
}
