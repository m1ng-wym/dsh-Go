// D1-09 · 主机切换（本机 / SSH / DSH Remote）
//
// AC1 至少两个主机时切换 → 连接成功、会话列表跟随主机、当前主机名与状态可见。
// AC2 冷启动连回上次主机（可在远程页关闭）；已保存主机不受影响。
// AC3 切到不可达主机 → 错误 + 重试/管理入口，仍可切回上一个可用主机；数据不串。
//
// Fake host/transport only: FakeSshServer/FakeConnector/FakeRelayBackend, no
// real socket, no real SSH.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/remote/relay/relay_backend.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/remote/ssh/ssh_link.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/remote/host_switcher.dart';
import 'package:dsh_app/ui/remote/remote_screen.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import 'support/fake_relay.dart';
import 'support/fake_ssh.dart';
import 'support/wait.dart';

class _NoLocal extends LocalConnectionController {
  @override
  Future<HostConnection?> build() async => null;
}

const _relayMac = RelayHost(
  id: 'mac',
  name: '家里的 Mac',
  online: true,
  platform: 'darwin',
  fingerprint: '3F2A 9C41 07BE',
  trust: RelayTrust.pinned,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MemorySecretStore secrets;
  late FakeSshServer server;
  late FakeConnector connector;
  late FakeRelayBackend relay;

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        secretStoreProvider.overrideWithValue(secrets),
        localConnectionProvider.overrideWith(_NoLocal.new),
        networkKicksProvider.overrideWithValue(const Stream.empty()),
        relayBackendProvider.overrideWithValue(relay),
        urlOpenerProvider.overrideWithValue((_) async => true),
        sshLinkFactoryProvider.overrideWithValue(
          (ref, config) => SshHostLink(
            config: config,
            loadSecrets: () => ref.read(hostsProvider.notifier).loadSecrets(config.id),
            pinHostKey: (key) => ref.read(hostsProvider.notifier).pinHostKey(config.id, key),
            transportFactory: server.connect,
            connectClient: connector.call,
            backoff: Backoff(initial: const Duration(milliseconds: 5), maxAttempts: 2),
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<void> loaded(ProviderContainer c) async {
    await c.read(hostsProvider.notifier).ready;
    await Future<void>.delayed(Duration.zero);
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secrets = MemorySecretStore();
    server = FakeSshServer();
    connector = FakeConnector();
    relay = FakeRelayBackend(user: sampleRelayUser, hosts: const [_relayMac]);
  });

  group('D1-09 · 主机切换状态机（fake transport）', () {
    test('D1-09_switch_host_updates_sessions', () async {
      final c = container();
      await loaded(c);
      await c.read(relayAccountProvider.future);
      await c
          .read(hostsProvider.notifier)
          .saveSsh(sampleSsh, secrets: const SshSecrets(password: 'pw'));
      c.read(currentSessionProvider.notifier).select('local-session');

      final connSub = c.listen(activeConnectionProvider, (_, _) {});
      addTearDown(connSub.close);

      c.read(activeHostProvider.notifier).select(HostRef.ssh(sampleSsh.id));

      await until(c, activeConnectionProvider, (s) => s.value != null, what: 'SSH 主机连接成功');
      expect(c.read(activeConnectionProvider).value!.label, '电脑 · SSH');
      expect(c.read(activeHostProvider), HostRef.ssh(sampleSsh.id));
      // The open conversation belonged to 本机: the list is re-read for the
      // new host instead of carrying the old conversation over.
      expect(c.read(currentSessionProvider), isNull);
      // The sessions list is scoped to the host by SessionsController (rows of
      // the previous host never mix in); its content needs an L4 fake DSH host
      // and is deferred per docs/specs/phase1/mocks.md §3.

      // And the prefs record the new host for the next cold start.
      final prefs = await SharedPreferences.getInstance();
      expect(HostRef.decode(prefs.getString(ActiveHostController.prefsKey)), HostRef.ssh(sampleSsh.id));
    });

    test('D1-09_switch_cycle_local_ssh_relay', () async {
      final c = container();
      await loaded(c);
      await c.read(relayAccountProvider.future);
      await c
          .read(hostsProvider.notifier)
          .saveSsh(sampleSsh, secrets: const SshSecrets(password: 'pw'));
      final sub = c.listen(activeConnectionProvider, (_, _) {});
      addTearDown(sub.close);
      // 本机 → SSH.
      c.read(currentSessionProvider.notifier).select('s-on-phone');
      c.read(activeHostProvider.notifier).select(HostRef.ssh(sampleSsh.id));
      await until(c, activeConnectionProvider, (s) => s.value != null, what: 'SSH 已连接');
      expect(c.read(currentSessionProvider), isNull, reason: '切主机清空本机会话');
      final sshTransport = server.last;

      // SSH → DSH Remote.
      c.read(currentSessionProvider.notifier).select('s-on-ssh');
      c.read(activeHostProvider.notifier).select(const HostRef.relay('mac', name: '家里的 Mac'));
      await until(c, activeConnectionProvider, (s) => s.value?.label == '家里的 Mac · 远程', what: 'Remote 已连接');
      expect(c.read(currentSessionProvider), isNull, reason: '切主机清空 SSH 会话');
      expect(relay.connected, ['mac']);
      // The old SSH transport is released when its link is no longer watched.
      await sshTransport.done.timeout(const Duration(seconds: 5), onTimeout: () => fail('SSH 连接未释放'));
      expect(sshTransport.isClosed, isTrue);

      // DSH Remote → 本机.
      c.read(currentSessionProvider.notifier).select('s-on-relay');
      c.read(activeHostProvider.notifier).select(HostRef.local);
      await until(c, activeConnectionProvider, (s) => !s.isLoading && s.value == null, what: '已切回本机');
      expect(c.read(currentSessionProvider), isNull, reason: '切主机清空 Remote 会话');
      final prefs = await SharedPreferences.getInstance();
      expect(HostRef.decode(prefs.getString(ActiveHostController.prefsKey)), HostRef.local);
    });

    test('D1-09_reconnect_last_host_on_cold_start', () async {
      SharedPreferences.setMockInitialValues({
        HostsController.prefsKey: jsonEncode([sampleSsh.toJson()]),
        ActiveHostController.prefsKey: HostRef.ssh(sampleSsh.id).encode(),
      });
      final c = container();
      await loaded(c);
      await until(c, activeHostProvider, (h) => h == HostRef.ssh(sampleSsh.id), what: '冷启动连回上次主机');
      final sub = c.listen(activeConnectionProvider, (_, _) {});
      addTearDown(sub.close);
      await until(c, activeConnectionProvider, (s) => s.value != null, what: '上次主机连接成功');
      expect(c.read(activeConnectionProvider).value!.label, '电脑 · SSH');
      // 已保存主机不受影响.
      expect(c.read(hostsProvider).ssh.map((h) => h.id), contains(sampleSsh.id));

      // 远程页关闭"连接上次使用的主机"：下次冷启动停在本机，主机列表仍在。
      SharedPreferences.setMockInitialValues({
        HostsController.prefsKey: jsonEncode([sampleSsh.toJson()]),
        ActiveHostController.prefsKey: HostRef.ssh(sampleSsh.id).encode(),
        RemoteAutoConnectController.prefsKey: false,
      });
      final again = container();
      await loaded(again);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(again.read(activeHostProvider), HostRef.local);
      expect(again.read(hostsProvider).ssh.map((h) => h.id), contains(sampleSsh.id));
    });

    test('D1-09_unreachable_host_keeps_previous', () async {
      final c = container();
      await loaded(c);
      await c
          .read(hostsProvider.notifier)
          .saveSsh(sampleSsh, secrets: const SshSecrets(password: 'pw'));
      final sub = c.listen(activeConnectionProvider, (_, _) {});
      addTearDown(sub.close);
      final host = HostRef.ssh(sampleSsh.id);

      const failing = HostLinkError(
        HostLinkErrorKind.unreachable,
        '连不上这台电脑',
        retryable: true,
        detail: '10.0.0.9:22 connection refused',
      );
      server.failNext.addAll(List.filled(12, failing));
      c.read(activeHostProvider.notifier).select(host);
      await until(c, activeConnectionProvider, (s) => s.hasError, what: '不可达主机连接失败');
      final error = c.read(activeConnectionProvider).error;
      expect(error, isA<HostLinkError>());
      expect((error! as HostLinkError).message, '连不上这台电脑');
      expect((error as HostLinkError).detail, contains('connection refused'), reason: '可诊断的底层原因');

      // 仍可切回上一个可用主机；失败状态随之消失，旧主机的会话不被带过来。
      c.read(currentSessionProvider.notifier).select('s-on-failed');
      c.read(activeHostProvider.notifier).select(HostRef.local);
      await until(c, activeConnectionProvider, (s) => !s.isLoading && !s.hasError, what: '切回本机');
      expect(c.read(activeConnectionProvider).value, isNull);
      expect(c.read(currentSessionProvider), isNull);

      // 再切回去（相当于重试入口）能恢复。
      server.failNext.clear();
      c.read(activeHostProvider.notifier).select(host);
      await until(c, activeConnectionProvider, (s) => s.value != null, what: '重试后连接成功');
    });

    test('D1-09_saved_hosts_persist_across_restart', () async {
      final c = container();
      await loaded(c);
      await c.read(hostsProvider.notifier).saveSsh(sampleSsh, secrets: const SshSecrets(password: 'pw'));
      const second = SshHostConfig(id: 'ssh-second', name: '服务器 2', host: '10.0.0.8', user: 'me');
      await c.read(hostsProvider.notifier).saveSsh(second, secrets: const SshSecrets(password: 'pw2'));

      // 非敏感配置在 prefs，密码只在 secret store。
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(HostsController.prefsKey)!;
      expect(raw, contains(sampleSsh.id));
      expect(raw, contains('ssh-second'));
      expect(raw, isNot(contains('pw')));

      final again = container();
      await loaded(again);
      expect(again.read(hostsProvider).ssh.map((h) => h.id), [sampleSsh.id, 'ssh-second']);
      expect((await again.read(hostsProvider.notifier).loadSecrets('ssh-second')).password, 'pw2');
    });

    test('D1-09_delete_host_leaves_remote_untouched', () async {
      final c = container();
      await loaded(c);
      await c
          .read(hostsProvider.notifier)
          .saveSsh(sampleSsh, secrets: const SshSecrets(password: 'pw'));
      final sub = c.listen(activeConnectionProvider, (_, _) {});
      addTearDown(sub.close);
      c.read(activeHostProvider.notifier).select(HostRef.ssh(sampleSsh.id));
      await until(c, activeConnectionProvider, (s) => s.value != null, what: 'SSH 已连接');
      final transport = server.last;
      final remotePid = server.remote.pid;
      final scriptsBefore = transport.scripts.length;

      // 删除主机只清手机侧：配置、密码、连接；远端 dsh 与其会话不受影响。
      await c.read(hostsProvider.notifier).removeSsh(sampleSsh.id);
      await until(c, activeHostProvider, (h) => h.isLocal, what: '删除活动主机后回到本机');
      expect(c.read(hostsProvider).ssh, isEmpty);
      expect((await c.read(hostsProvider.notifier).loadSecrets(sampleSsh.id)).isEmpty, isTrue);
      expect(transport.scripts.length, scriptsBefore, reason: '删除主机不向远端发任何命令');
      expect(server.remote.pid, remotePid, reason: '远端 dsh 进程仍在');
      expect(server.remote.launches, 1);
      expect(transport.isClosed, isTrue, reason: '只断开手机这侧连接');
    });

    test('D1-09_missing_saved_host_falls_back_to_phone', () async {
      // 冷启动时 prefs 指向一台已被删除/不存在的 SSH 主机（保存列表里还有
      // 别的主机）：应回落到本机，不留在"主机不存在但界面还显示远程"的半状态。
      SharedPreferences.setMockInitialValues({
        HostsController.prefsKey: jsonEncode([sampleSsh.toJson()]),
        ActiveHostController.prefsKey: const HostRef.ssh('ssh-gone').encode(),
      });
      final c = container();
      final seen = <HostRef>[];
      final sub = c.listen(activeHostProvider, (_, next) => seen.add(next));
      addTearDown(sub.close);
      await loaded(c);
      // Not a vacuous "is local at attach time": the restore first lands on the
      // saved host, then the missing-host check moves it to 本机.
      await until(
        c,
        activeHostProvider,
        (h) => h.isLocal,
        what: '不存在的主机回落到本机',
        timeout: const Duration(seconds: 2),
      );
      expect(seen.first, const HostRef.ssh('ssh-gone'), reason: '冷启动先恢复上次主机');
      expect(seen.last, HostRef.local);
      final prefs = await SharedPreferences.getInstance();
      expect(HostRef.decode(prefs.getString(ActiveHostController.prefsKey)), HostRef.local);
    });
  });

  group('D1-09 · 主机切换 UI（L2）', () {
    late StreamController<HostLinkStatus> statuses;
    setUp(() => statuses = StreamController<HostLinkStatus>.broadcast());
    tearDown(() => statuses.close());

    List<Override> widgetOverrides() => [
      secretStoreProvider.overrideWithValue(secrets),
      networkKicksProvider.overrideWithValue(const Stream.empty()),
      relayBackendProvider.overrideWithValue(relay),
      sshTransportFactoryProvider.overrideWithValue(server.connect),
      // These tests are about what the header/page show for a host and its
      // state; the connection state machine itself is covered above with real
      // fake transports.
      hostLinkStatusProvider.overrideWith(
        (ref, host) => host.isLocal ? Stream.value(HostLinkStatus.idle) : statuses.stream,
      ),
      urlOpenerProvider.overrideWithValue((_) async => true),
      localRuntimeProvider.overrideWith(
        () => FakeRuntime(
          const LocalRuntimeState(
            loaded: true,
            status: RuntimeStatus(
              phase: RuntimePhase.installed,
              bundledVersion: 'r-test',
              installedVersion: 'r-test',
            ),
          ),
        ),
      ),
    ];

    Future<ProviderContainer> pump(WidgetTester tester, Widget home) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(goldenApp(home: home, brightness: Brightness.light, overrides: widgetOverrides()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      return ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
    }

    Future<void> frames(WidgetTester tester, [int n = 12]) async {
      for (var i = 0; i < n; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
    }

    testWidgets('D1-09_first_switch_moves_header_to_remote_host', (tester) async {
      SharedPreferences.setMockInitialValues({
        HostsController.prefsKey: jsonEncode([sampleSsh.toJson()]),
      });
      final c = await pump(tester, const _SwitcherLauncher());
      expect(find.textContaining('本机'), findsWidgets, reason: '首次进入停在本机');
      await tester.tap(find.byType(HostChip));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('切换主机'), findsOneWidget);
      await tester.tap(find.text('电脑'));
      await frames(tester);
      expect(c.read(activeHostProvider), HostRef.ssh(sampleSsh.id));
      // 当前主机名与连接状态可见（抽屉头部 chip）。
      statuses.add(const HostLinkStatus(HostLinkPhase.connected));
      for (var i = 0; i < 30 && find.text('电脑 · 已连接').evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(find.text('电脑 · 已连接'), findsOneWidget);
    });

    testWidgets('D1-09_unreachable_host_shows_retry_and_manage', (tester) async {
      SharedPreferences.setMockInitialValues({
        HostsController.prefsKey: jsonEncode([sampleSsh.toJson()]),
      });
      final host = HostRef.ssh(sampleSsh.id);
      final remote = _FakeRemoteConnection(host);
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: const RemoteScreen(),
          brightness: Brightness.light,
          overrides: [
            ...widgetOverrides(),
            activeHostProvider.overrideWith(() => _FixedActiveHost(host)),
            remoteConnectionProvider(host).overrideWith(() => remote),
          ],
        ),
      );
      final c = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      statuses.add(
        const HostLinkStatus(
          HostLinkPhase.failed,
          error: HostLinkError(
            HostLinkErrorKind.unreachable,
            '连不上这台电脑',
            retryable: true,
            detail: '10.0.0.9:22 connection refused',
          ),
        ),
      );
      await frames(tester);
      // 错误 + 可诊断详情 + 重试入口，且不白屏。
      expect(find.text('连不上这台电脑'), findsOneWidget);
      expect(find.text('详情'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('切回本机'), findsOneWidget);
      await tester.tap(find.text('详情'));
      await frames(tester, 3);
      expect(find.textContaining('connection refused'), findsOneWidget);

      // 重试入口真的触发该主机的连接重试；状态恢复后错误卡片消失。
      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(remote.retries, 1);
      statuses.add(const HostLinkStatus(HostLinkPhase.connected));
      for (var i = 0; i < 30 && find.text('连不上这台电脑').evaluate().isNotEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(find.text('连不上这台电脑'), findsNothing);
      expect(find.text('已连接'), findsOneWidget);

      // 仍可切回上一个可用主机。
      await tester.tap(find.text('切回本机'));
      await tester.pump();
      expect(c.read(activeHostProvider), HostRef.local);
      expect(find.text('连不上这台电脑'), findsNothing);
    });
  });
}

/// Drawer header chip + host sheet, the way the drawer shows them.
class _SwitcherLauncher extends StatelessWidget {
  const _SwitcherLauncher();

  @override
  Widget build(BuildContext context) {
    return AppBackdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: Builder(
            builder: (context) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                HostChip(onTap: () => showHostSheet(context, onManage: () {})),
              ],
            ),
          ),
        ),
      ),
    );
  }
}


/// Active host pinned for a UI test.
class _FixedActiveHost extends ActiveHostController {
  _FixedActiveHost(this.host);

  final HostRef host;

  @override
  HostRef build() => host;
}

/// Records "重试" without opening a real link.
class _FakeRemoteConnection extends RemoteConnectionController {
  _FakeRemoteConnection(super.host);

  int retries = 0;

  @override
  Future<HostConnection?> build() async => null;

  @override
  void retry() => retries++;
}
