// D1-02 引擎启动/停止/重启/自动启动（capability-spec.md#D1-02）的 L2 自动化部分。
//
// 真实引擎的启停时序与「停止后原地再启动」由 L4 覆盖
// （`tooling/ios/engine-smoke/d1-02-lifecycle-check.mjs`，iPhone 17 Pro 模拟器 +
// 真 Node 引擎，同一进程内 start→stop→start→restart）。这里用一个假 EngineChannel
// （`_EngineChannel`，实现与 native `EngineChannel.swift` 相同的 start/stop 契约：
// start 报 starting→running；stop 报 stopping→installed）驱动真实的
// `LocalRuntimeController`/`EngineControl`/`LocalConnectionController`：
//   - AC1：start 后状态 starting→running 且 baseUrl 可用；stop 后 stopping→installed，
//          本地连接随 running 结束而断开（客户端被关闭 = 进行中的回合被终止）；
//   - AC2：已停止时再点启动只发 start（不重开 App）；重启是 stop 后同一进程内再 start；
//   - AC3：冷启动按「打开 App 时自动启动」开关决定是否 start（RootGate）；
//   - AC4：快速双击启动/停止只产生一次 native 调用，最终状态与最后一次操作一致。
//
// 测试名按 traceability.md 的 D1-02 行命名，便于追踪。

import 'dart:async';

import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/share_code/guest_fs.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/engine_control.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/shell/root_gate.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../remote/support/ready_mux.dart';
import '../safe_mode/support.dart';
import '../shell/golden_harness.dart';

const _version = 'r1-dsh0.2.0-node24.22.1';

RuntimeStatus _status(RuntimePhase phase) => RuntimeStatus(
  phase: phase,
  abi: 'arm64',
  bundledVersion: _version,
  installedVersion: _version,
  baseUrl: phase == RuntimePhase.running ? 'http://127.0.0.1:3080' : null,
  token: phase == RuntimePhase.running ? 'engine-token' : null,
);

/// 假 EngineChannel：只实现 `dsh/runtime` 里 D1-02 用到的方法，时序与 native 一致。
/// `startGate`/`stopGate` 让测试观察「请求还没返回」的时间窗（快速双击）。
class _EngineChannel extends RuntimeBridge {
  _EngineChannel({RuntimeStatus? status}) : current = status ?? _status(RuntimePhase.installed);

  RuntimeStatus current;
  final _events = StreamController<RuntimeEvent>.broadcast(sync: true);
  final starts = <String>[];
  int stops = 0;
  int reopens = 0;
  Completer<void>? startGate;
  Completer<void>? stopGate;
  Object? startError;

  @override
  Stream<RuntimeEvent> get events => _events.stream;

  @override
  Future<RuntimeStatus> status() async => current;

  @override
  Future<RuntimeLogSnapshot> logSnapshot({int lines = 300}) async => const RuntimeLogSnapshot([], 0);

  @override
  Future<void> start({
    Map<String, String> env = const {},
    bool phoneStorage = false,
    EngineMode? mode,
    bool visualReplies = true,
  }) async {
    starts.add(mode?.name ?? 'normal');
    if (startGate case final gate?) await gate.future;
    if (startError case final error?) throw error;
    _emit(_status(RuntimePhase.starting));
    _emit(_status(RuntimePhase.running));
  }

  @override
  Future<void> stop() async {
    stops++;
    if (stopGate case final gate?) await gate.future;
    _emit(_status(RuntimePhase.stopping));
    _emit(_status(RuntimePhase.installed));
  }

  @override
  Future<void> reopenApp() async => reopens++;

  void _emit(RuntimeStatus next) {
    current = next;
    _events.add(RuntimeStatusEvent(next));
  }

  Future<void> close() => _events.close();
}

class _LocalHost extends ActiveHostController {
  @override
  HostRef build() => HostRef.local;
}

/// A local client that is ready at once and records being closed.
class _Client extends DshClient {
  _Client() : super(DshConnection(Uri.parse('http://127.0.0.1:3080')));

  final _mux = ReadyMux();
  bool closed = false;

  @override
  DshMux get mux => _mux;

  @override
  Future<void> close() async {
    closed = true;
    await super.close();
  }
}

class _Logs extends LocalRuntimeLogsController {
  @override
  List<String> build() => const [];
}

Future<void> _settle() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

ProviderContainer _container(_EngineChannel channel, {_Client? client}) {
  final container = ProviderContainer(
    overrides: [
      runtimeBridgeProvider.overrideWithValue(channel),
      settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
      activeHostProvider.overrideWith(_LocalHost.new),
      networkKicksProvider.overrideWithValue(const Stream.empty()),
      guestFsProvider.overrideWith((ref) async => null),
      if (client != null) localClientConnectorProvider.overrideWithValue(({required baseUri, required token}) async => client),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('D1-02_start_stop_interrupts_turn', () async {
    // AC1：start → starting → running（baseUrl 可用）；stop → stopping → installed，
    // 且随 running 建立的本地连接被关闭（客户端收到终止，进行中的回合结束）。
    final channel = _EngineChannel();
    final client = _Client();
    final c = _container(channel, client: client);
    c.listen(localConnectionProvider, (_, _) {});
    await _settle();
    expect(c.read(localRuntimeProvider).status.phase, RuntimePhase.installed);

    await EngineControl.ensureStarted(c);
    await _settle();
    expect(channel.starts, ['normal']);
    final running = c.read(localRuntimeProvider).status;
    expect(running.phase, RuntimePhase.running);
    expect(running.baseUrl, 'http://127.0.0.1:3080');

    // The engine is up: the app holds a live local client (the turn's transport).
    final connection = await c.read(localConnectionProvider.future);
    expect(connection?.client, same(client));
    expect(client.closed, isFalse);

    await c.read(localRuntimeProvider.notifier).stop();
    await _settle();
    expect(channel.stops, 1);
    expect(c.read(localRuntimeProvider).status.phase, RuntimePhase.installed);
    // Stopping the engine tears the transport down: the client is closed.
    expect(client.closed, isTrue);
    expect(c.read(localConnectionProvider).value, isNull);
  });

  test('D1-02_restart_after_stop_without_relaunch', () async {
    // AC2：已停止时再点启动只发 start；重启 = 同一进程内 stop 再 start，不重开 App。
    final channel = _EngineChannel();
    final c = _container(channel);
    c.read(localRuntimeProvider);
    await _settle();
    expect(c.read(localRuntimeProvider).status.phase, RuntimePhase.installed);

    await EngineControl.ensureStarted(c);
    await _settle();
    expect(channel.starts, ['normal']);
    expect(channel.reopens, 0);
    expect(c.read(localRuntimeProvider).status.phase, RuntimePhase.running);

    await EngineControl.restart(c);
    await _settle();
    expect(channel.stops, 1);
    expect(channel.starts, ['normal', 'normal']);
    expect(channel.reopens, 0);
    expect(c.read(localRuntimeProvider).status.phase, RuntimePhase.running);
  });

  test('D1-02_double_start_is_idempotent', () async {
    // AC4：快速双击启动只产生一次 native start；完成后状态 running；
    // 随后的停止是最后一次操作，最终状态为 installed。
    final channel = _EngineChannel()..startGate = Completer<void>();
    final c = _container(channel);
    c.read(localRuntimeProvider);
    await _settle();
    final runtime = c.read(localRuntimeProvider.notifier);

    final first = runtime.start();
    final second = runtime.start();
    expect(channel.starts, hasLength(1));
    channel.startGate!.complete();
    await Future.wait([first, second]);
    await _settle();
    expect(channel.starts, hasLength(1));
    expect(c.read(localRuntimeProvider).status.phase, RuntimePhase.running);

    await runtime.stop();
    await _settle();
    expect(channel.stops, 1);
    expect(c.read(localRuntimeProvider).status.phase, RuntimePhase.installed);
  });

  test('D1-02_double_stop_is_idempotent', () async {
    // AC4：运行中快速双击停止只产生一次 native stop，最终状态 stopped（installed）。
    final channel = _EngineChannel(status: _status(RuntimePhase.running))..stopGate = Completer<void>();
    final c = _container(channel);
    c.read(localRuntimeProvider);
    await _settle();
    expect(c.read(localRuntimeProvider).status.phase, RuntimePhase.running);
    final runtime = c.read(localRuntimeProvider.notifier);

    final first = runtime.stop();
    final second = runtime.stop();
    expect(channel.stops, 1);
    channel.stopGate!.complete();
    await Future.wait([first, second]);
    await _settle();
    expect(channel.stops, 1);
    expect(c.read(localRuntimeProvider).status.phase, RuntimePhase.installed);
  });

  group('cold start auto start', () {
    Future<RecordingRuntime> pump(WidgetTester tester, {required bool autoStart}) async {
      final logs = _Logs();
      final runtime = RecordingRuntime(
        LocalRuntimeState(
          loaded: true,
          status: RuntimeStatus(
            phase: RuntimePhase.installed,
            bundledVersion: _version,
            installedVersion: _version,
          ),
        ),
      );
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: const RootGate(home: Scaffold(body: Text('home'))),
          brightness: Brightness.light,
          overrides: [
            localRuntimeProvider.overrideWith(() => runtime),
            localRuntimeLogsProvider.overrideWith(() => logs),
            settingsProvider.overrideWith(
              () => FakeSettings(AppSettings(loaded: true, apiKey: 'key', autoStartLocal: autoStart)),
            ),
          ],
        ),
      );
      await tester.pump();
      ProviderScope.containerOf(tester.element(find.byType(RootGate))).read(localRuntimeLogsProvider);
      return runtime;
    }

    testWidgets('D1-02_auto_start_follows_setting', (tester) async {
      // AC3：开关开启时冷启动自动 start（重建不会重复触发）。
      final runtime = await pump(tester, autoStart: true);
      await tester.pump();
      expect(runtime.starts, ['start']);
    });

    testWidgets('D1-02_auto_start_follows_setting_2', (tester) async {
      // AC3：开关关闭时冷启动不 start（只连远程场景不加载引擎）。
      final runtime = await pump(tester, autoStart: false);
      await tester.pump();
      expect(runtime.starts, isEmpty);
    });
  });
}
