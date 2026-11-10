// D1-11 · DSH Remote 基础连接（T21）
//
// AC1 登录/选择在线主机/信任指纹 → Relay+Noise 通道 → 会话列表、发消息、审批。
// AC2 断线自动重连、恢复会话且不重复消息；连不上时显示错误与重试入口。
// AC3 Phase 1 不提供 Remote 终端/传文件入口（隐藏，不制造“已实现”假象）。
//
// Fake relay only: the app's real DshRemoteRelayBackend talks to the package's
// loopback FakeRemoteServer (Relay Control socket, Noise IK, RPC). No real
// DSH Remote server, account or external network is used.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/remote/relay/dsh_remote_backend.dart';
import 'package:dsh_app/remote/relay/relay_backend.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/remote/host_switcher.dart';
import 'package:dsh_app/ui/remote/remote_screen.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_remote/dsh_remote.dart' hide MemorySecretStore;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../packages/dsh_remote/test/support/fake_remote.dart';
import '../shell/golden_harness.dart';
import 'support/fake_relay.dart';
import 'support/fake_ssh.dart';
import 'support/wait.dart';

class _LoopbackBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

class _NoLocal extends LocalConnectionController {
  @override
  Future<HostConnection?> build() async => null;
}

Future<void> _until(bool Function() condition, {required String what, Duration timeout = const Duration(seconds: 25)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等待超时：$what');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<void> _untilAsync(Future<bool> Function() condition, {required String what}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等待超时：$what');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Map<String, Object?> _record(int seq, String type, Map<String, Object?> data) => {
  'type': 'event',
  'event': {'type': type, 'seq': seq, 'time': 1786000000000 + seq, 'data': data},
};

Map<String, Object?> _snapshot(String id, int cursor, List<Map<String, Object?>> records, {bool resync = false}) => {
  'type': 'snapshot',
  'header': {'version': 4, 'id': id, 'createdAt': 1786000000000, 'cwd': '/home/host/ws', 'isSeeded': false},
  'cursor': cursor,
  'records': records,
  'hasMore': false,
  'projections': {'asOfSeq': cursor, 'values': <String, Object?>{}},
  'assistantStream': {'revision': 0},
};

Map<String, Object?> _userMessage(int seq, String id, String text) => _record(seq, 'user/message', {
  'content': [
    {'type': 'text', 'text': text},
  ],
  'source': {'kind': 'user', 'rpcId': 'rpc-$seq'},
  'role': 'user',
  'id': id,
});

Map<String, Object?> _assistantMessage(int seq, String id, String text, {int turn = 1, int step = 1}) =>
    _record(seq, 'assistant/message', {
      'turn': turn,
      'step': step,
      'message': {
        'id': id,
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': text},
        ],
        'source': {'kind': 'model', 'provider': 'mock', 'model': 'mock-phase1'},
      },
    });

class _RelayFixture {
  _RelayFixture(this.server, this.host, this.backend, this.listed);

  final FakeRemoteServer server;
  final FakeRemoteHost host;
  final DshRemoteRelayBackend backend;
  final RelayHost listed;
}

Future<_RelayFixture> _relayFixture({bool approve = true, bool signIn = true}) async {
  final server = await FakeRemoteServer.start();
  addTearDown(server.close);
  final host = await FakeRemoteHost.start(server, name: '家里的 Mac');
  addTearDown(host.close);
  host.handlers['session/list'] = (_) => {
    'ok': true,
    'value': {
      'items': [
        {
          'sessionId': 'session-1',
          'updatedAt': 1786000000000,
          'projections': {
            'asOfSeq': 0,
            'values': {'title': 'Remote hello'},
          },
        },
      ],
    },
  };
  final backend = DshRemoteRelayBackend(secrets: MemorySecretStore(), serverUrl: server.url, direct: false);
  addTearDown(backend.close);
  if (!signIn) return _RelayFixture(server, host, backend, const RelayHost(id: 'none', name: 'none', online: false));
  await backend.loginWithPassword(FakeRemoteServer.account, FakeRemoteServer.password);
  await backend.listHosts();
  final listed = (await backend.listHosts()).single;
  if (approve) backend.approveHost(listed);
  return _RelayFixture(server, host, backend, listed);
}

void main() {
  _LoopbackBinding();

  setUp(() {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
  });

  test('D1-11_remote_connect_lists_sessions', () async {
    final fixture = await _relayFixture(approve: false);
    final host = fixture.host;

    // First use must fail closed until the person confirmed the fingerprint.
    await expectLater(
      fixture.backend.connectHost(fixture.listed),
      throwsA(
        isA<HostLinkError>()
            .having((e) => e.kind, 'kind', HostLinkErrorKind.hostKeyUnverified)
            .having((e) => e.retryable, 'retryable', isFalse),
      ),
    );
    fixture.backend.approveHost(fixture.listed);

    Map<String, Object?>? prompted;
    host.handlers['session/prompt'] = (args) {
      prompted = args;
      return {'ok': true, 'value': {'accepted': true}};
    };
    Map<String, Object?>? approved;
    host.handlers[r'$events/result'] = (args) {
      approved = args;
      return {'ok': true};
    };
    host.pendingWaterfalls.add({
      'type': 'waterfall',
      'event': 'approval/request',
      'eventId': 'evt-1',
      'agentId': 'session-1',
      'request': {'toolName': 'bash', 'callId': 'call-1', 'reason': 'escalate'},
    });
    host.onOpen = (stream) {
      if (stream.endpoint != 'session/follow') return;
      stream.push(_snapshot('session-1', -1, <Map<String, Object?>>[]));
    };

    final secrets = MemorySecretStore();
    final relayRef = HostRef.relay(fixture.listed.id, name: fixture.listed.name);
    final container = ProviderContainer(
      overrides: [
        relayBackendProvider.overrideWithValue(fixture.backend),
        secretStoreProvider.overrideWithValue(secrets),
        localConnectionProvider.overrideWith(_NoLocal.new),
        networkKicksProvider.overrideWithValue(const Stream<void>.empty()),
      ],
    );
    addTearDown(container.dispose);
    final keep = container.listen(activeConnectionProvider, (_, _) {}, fireImmediately: true);
    addTearDown(keep.close);
    await container.read(activeHostProvider.notifier).ready;
    await container.read(relayAccountProvider.future);
    container.read(activeHostProvider.notifier).select(relayRef);
    await until(container, activeConnectionProvider, (s) => s.value != null, what: 'DSH Remote 已连接');
    final connection = container.read(activeConnectionProvider).value!;
    expect(connection.label, '家里的 Mac · 远程');
    expect(connection.isLocal, isFalse);
    expect(connection.kind, HostKind.relay);

    // The app's real session list comes through the Relay/Noise tunnel.
    final rows = await container.read(sessionsProvider.future).timeout(const Duration(seconds: 20));
    expect(rows.map((r) => r.sessionId), ['session-1']);
    expect(rows.single.title, 'Remote hello');

    final client = connection.client;
    expect(client.isRemote, isTrue);
    expect(client.remoteCarrier, isNotNull);
    expect(client.remoteCarrier!.capabilities, contains('harness.remote.v3'));

    // A prompt and an approval travel over the same tunnel.
    await client.prompt('session-1', '在远端跑一下');
    expect(jsonEncode(prompted), contains('在远端跑一下'));
    final approvals = <ApprovalRequestedEvent>[];
    final watch = client.watch('session-1').listen((e) {
      if (e is ApprovalRequestedEvent) approvals.add(e);
    });
    addTearDown(watch.cancel);
    await _until(() => approvals.isNotEmpty, what: '审批请求经 Relay 到达');
    await client.respondApproval(approvals.single.request, ApprovalDecision.allowOnce);
    expect(approved, isNotNull);
    expect(approved!['clientId'], 'remote-client-1');
    expect(approved!['eventId'], 'evt-1');
    expect(approved!['outcome'], {'kind': 'result', 'value': 'allowed-once'});
    expect(fixture.server.protocolErrors, isEmpty, reason: 'Control/Noise 协议无违规');
  });

  test('D1-11_remote_reconnect_no_duplicate', () async {
    final fixture = await _relayFixture();
    final host = fixture.host;
    final records = <Map<String, Object?>>[
      _userMessage(0, 'm1', '第一句'),
      _assistantMessage(1, 'a1', '第一答'),
    ];
    FakeHostStream? follow;
    var snapshots = 0;
    host.onOpen = (stream) {
      if (stream.endpoint != 'session/follow') return;
      follow = stream;
      snapshots++;
      stream.push(_snapshot('session-1', records.length - 1, List.of(records), resync: snapshots > 1));
    };

    final link = RelayHostLink(
      backend: fixture.backend,
      hostId: fixture.listed.id,
      resolveHost: () async => fixture.listed,
      backoff: Backoff(initial: const Duration(milliseconds: 5), maxAttempts: 3),
    );
    addTearDown(link.close);
    final phases = <HostLinkPhase>[];
    link.statuses.listen((s) => phases.add(s.phase));
    final client = await link.open().timeout(const Duration(seconds: 20));
    final firstGeneration = client.mux.generation!.clientId;
    expect(link.status.path, RelayPath.relay);

    final transcript = ChatTranscript();
    final watch = client.watch('session-1').listen(transcript.apply);
    addTearDown(watch.cancel);
    await _until(
      () => transcript.items.whereType<UserChatItem>().isNotEmpty,
      what: '首屏会话已加载',
    );
    expect(transcript.items.whereType<UserChatItem>().map((i) => i.text), ['第一句']);
    expect(transcript.items.whereType<AssistantChatItem>().map((i) => i.text), ['第一答']);

    // A message lands while the tunnel is down; the resync snapshot must not
    // duplicate the two rows the person already saw.
    records.add(_userMessage(2, 'm2', '断线时说的'));
    host.dropClients();
    await _until(() => snapshots >= 2, what: '断线后自动重连并重新同步');
    await _until(() => transcript.items.whereType<UserChatItem>().length >= 2, what: '断线期间的消息恢复');
    expect(
      transcript.items.whereType<UserChatItem>().map((i) => i.text).toList(),
      ['第一句', '断线时说的'],
      reason: '重同步不得重复已有消息',
    );
    expect(transcript.items.whereType<AssistantChatItem>().map((i) => i.text), ['第一答']);
    expect(transcript.items.whereType<UserChatItem>().map((i) => i.seq).toSet(), {0, 2});

    // A live message after reconnect is appended exactly once.
    records.add(_assistantMessage(3, 'a2', '重连后的答复', turn: 2));
    follow!.push(records.last);
    await _until(() => transcript.items.whereType<AssistantChatItem>().length >= 2, what: '重连后的流式消息');
    expect(transcript.items.whereType<AssistantChatItem>().map((i) => i.id).toList(), ['a1', 'a3']);
    expect(transcript.items.whereType<AssistantChatItem>().map((i) => i.text), ['第一答', '重连后的答复']);
    expect(phases, contains(HostLinkPhase.reconnecting));
    expect(phases.last, HostLinkPhase.connected);
    expect(client.mux.generation!.clientId, isNot(firstGeneration), reason: '重连使用新的 mux generation');
    expect((await client.listSessions()).single.sessionId, 'session-1');
    expect(fixture.server.protocolErrors, isEmpty);
  });

  test('D1-11_remote_unreachable_shows_retry', () async {
    final fixture = await _relayFixture();
    await fixture.host.goOffline();
    await _untilAsync(
      () async => !(await fixture.backend.listHosts()).single.online,
      what: '主机已离线',
    );
    final link = RelayHostLink(
      backend: fixture.backend,
      hostId: fixture.listed.id,
      resolveHost: () async => (await fixture.backend.listHosts()).single,
      backoff: Backoff(initial: const Duration(milliseconds: 5), maxAttempts: 2),
    );
    addTearDown(link.close);
    await expectLater(
      link.open(),
      throwsA(
        isA<HostLinkError>()
            .having((e) => e.kind, 'kind', HostLinkErrorKind.hostOffline)
            .having((e) => e.retryable, 'retryable', isTrue)
            .having((e) => e.message, 'message', '主机现在不在线'),
      ),
    );
    expect(link.status.phase, HostLinkPhase.failed);

    await fixture.host.goOnline();
    await _untilAsync(
      () async => (await fixture.backend.listHosts()).single.online,
      what: '主机恢复在线',
    );
    link.retry();
    await _until(() => link.status.isConnected, what: '“重试”恢复连接');
    expect((await link.currentClient!.listSessions()).single.sessionId, 'session-1');
  });

  testWidgets('D1-11_remote_retry_is_visible_and_wired', (tester) async {
    const host = RelayHost(id: 'mac', name: '家里的 Mac', online: true);
    final relay = FakeRelayBackend(user: sampleRelayUser, hosts: const [host]);
    final recorder = _RetryRecorder(HostRef.relay(host.id, name: host.name));
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: const RemoteScreen(),
        brightness: Brightness.light,
        overrides: [
          relayBackendProvider.overrideWithValue(relay),
          secretStoreProvider.overrideWithValue(MemorySecretStore()),
          networkKicksProvider.overrideWithValue(const Stream<void>.empty()),
          localRuntimeProvider.overrideWith(
            () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
          ),
          activeHostProvider.overrideWith(() => _FixedActiveHost(recorder.host)),
          hostLinkStatusProvider.overrideWith(
            (ref, host) => Stream.value(
              const HostLinkStatus(
                HostLinkPhase.failed,
                error: HostLinkError(HostLinkErrorKind.hostOffline, '主机现在不在线', retryable: true),
              ),
            ),
          ),
          remoteConnectionProvider(recorder.host).overrideWith(() => recorder),
        ],
      ),
    );
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.text('主机现在不在线'), findsOneWidget);
    expect(find.text('重新连接'), findsOneWidget);
    await tester.tap(find.text('重新连接'));
    await tester.pump();
    expect(recorder.retries, 1);
  });

  testWidgets('D1-11_terminal_entry_hidden_phase1', (tester) async {
    final relay = FakeRelayBackend(user: sampleRelayUser, hosts: sampleRelayHosts);
    final ssh = FakeSshServer();
    final overrides = [
      relayBackendProvider.overrideWithValue(relay),
      secretStoreProvider.overrideWithValue(MemorySecretStore()),
      networkKicksProvider.overrideWithValue(const Stream<void>.empty()),
      sshTransportFactoryProvider.overrideWithValue(ssh.connect),
      hostLinkStatusProvider.overrideWith((ref, h) => Stream.value(HostLinkStatus.idle)),
      urlOpenerProvider.overrideWithValue((_) async => true),
      localRuntimeProvider.overrideWith(
        () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
      ),
    ];
    const forbidden = ['终端', '传文件', '文件传输', '远程终端', 'Terminal', 'Transfer files'];
    Set<String> labels() => {
      for (final text in tester.widgetList<Text>(find.byType(Text))) ?text.data,
      for (final rich in tester.widgetList<RichText>(find.byType(RichText)))
        if (rich.text.toPlainText().isNotEmpty) rich.text.toPlainText(),
    };
    Future<Set<String>> scan() async {
      final seen = <String>{};
      final scroll = find.byType(CustomScrollView);
      for (var i = 0; i < 12; i++) {
        seen.addAll(labels());
        if (scroll.evaluate().isEmpty) break;
        await tester.drag(scroll.first, const Offset(0, -280));
        await tester.pump();
      }
      seen.addAll(labels());
      return seen;
    }

    usePhoneSurface(tester);
    await tester.pumpWidget(goldenApp(home: const RemoteScreen(), brightness: Brightness.light, overrides: overrides));
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    final pageLabels = await scan();
    for (final word in forbidden) {
      expect(pageLabels.any((t) => t.contains(word)), isFalse, reason: 'Remote 页面不得出现「$word」入口');
    }
    for (final word in ['上传', '下载']) {
      expect(pageLabels.any((t) => t.contains(word)), isFalse);
    }
    // The only “remote transfer” setting is history compaction, not a file
    // transfer entry — and the page stays honest about Phase 1 scope.
    expect(pageLabels.any((t) => t.contains('远程传输')), isTrue);
    expect(find.byKey(const ValueKey('remote-compact-history')), findsOneWidget);

    await tester.pumpWidget(goldenApp(home: const _Launcher(), brightness: Brightness.light, overrides: overrides));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final sheetLabels = await scan();
    for (final word in forbidden) {
      expect(sheetLabels.any((t) => t.contains(word)), isFalse, reason: '主机切换面板不得出现「$word」入口');
    }
  });
}

class _FixedActiveHost extends ActiveHostController {
  _FixedActiveHost(this.host);

  final HostRef host;

  @override
  HostRef build() => host;
}

class _RetryRecorder extends RemoteConnectionController {
  _RetryRecorder(super.host);

  int retries = 0;

  @override
  Future<HostConnection?> build() async => null;

  @override
  void retry() => retries++;
}

class _Launcher extends StatelessWidget {
  const _Launcher();

  @override
  Widget build(BuildContext context) {
    return AppBackdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () => showHostSheet(context, onManage: () {}),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
  }
}
