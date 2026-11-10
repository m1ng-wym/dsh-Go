// D1-04 引擎日志与启动失败诊断（capability-spec.md#D1-04）的 L1/L2 自动化部分。
//
// 真实引擎的日志序号/快照与「失败后仍可读 last failure」由 L4 覆盖
// （`tooling/ios/engine-smoke/d1-02-lifecycle-check.mjs`：真引擎起停 + getLogSnapshot/
// getLogs/failureLog）。这里覆盖：
//   - AC1：日志环形缓冲有上限（1000 行展示上限）、seq 单调、先订阅再取快照且
//          只接 seq > throughSeq 的批次（无重复/漏行）——characterization（行为已存在，
//          更细的并发覆盖见 test/runtime/runtime_logs_test.dart）；
//   - AC2：启动失败显示本次原因（不是旧错误），引擎不可用时「查看日志」仍可打开并
//          复制诊断输出、失败页的「导出诊断包」入口可用；
//   - AC3：日志里的 API Key/Token 按既有脱敏规则（`redactDiagnostics`）打码，
//          展示与复制都不出现完整凭据。

import 'dart:async';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/common/app_sheet.dart';
import 'package:dsh_app/ui/engine/engine_screen.dart';
import 'package:dsh_app/ui/engine/log_view.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../safe_mode/support.dart';
import '../shell/golden_harness.dart';

RuntimeLogEntry _entry(int seq, [String? line]) => RuntimeLogEntry(seq, line ?? 'line $seq', 'stdout');

/// 假 EngineChannel 的日志部分：快照可挂起，事件按批注入。
class _LogBridge extends RuntimeBridge {
  final _events = StreamController<RuntimeEvent>.broadcast(sync: true);
  final snapshot = Completer<RuntimeLogSnapshot>();
  int snapshotCalls = 0;

  @override
  Stream<RuntimeEvent> get events => _events.stream;

  @override
  Future<RuntimeStatus> status() async => const RuntimeStatus(phase: RuntimePhase.installed);

  @override
  Future<RuntimeLogSnapshot> logSnapshot({int lines = 300}) {
    snapshotCalls++;
    return snapshot.future;
  }

  void batch(List<RuntimeLogEntry> entries) => _events.add(RuntimeLogsEvent(entries));

  Future<void> close() => _events.close();
}

Future<void> _settle() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

ProviderContainer _logContainer(_LogBridge bridge) {
  final container = ProviderContainer(overrides: [runtimeBridgeProvider.overrideWithValue(bridge)]);
  addTearDown(container.dispose);
  return container;
}

/// 引擎不可用：读 last failure 会失败，页面必须仍能展示并复制日志。
class _UnavailableBridge extends FakeBridge {
  @override
  Future<List<String>> failureLog() async =>
      throw PlatformException(code: 'ios_runtime_error', message: 'engine unavailable');
}

const _execError = '/bin/sh: 1: exec: /usr/local/bin/dsh: Bad address';

RuntimeFailure _launchFailure() => RuntimeFailure(
  kind: FailureKind.launchFailed,
  at: DateTime.utc(2026, 11, 10),
  exitCode: 126,
  summary: _execError,
  recent: const ['old-plugin-line'],
);

RuntimeStatus _failedStatus() => RuntimeStatus(
  phase: RuntimePhase.error,
  abi: 'arm64',
  bundledVersion: 'r1-test',
  installedVersion: 'r1-test',
  error: 'DSH exited unexpectedly (code 126)',
  failure: _launchFailure(),
  mainFailure: RuntimeFailure(
    kind: FailureKind.startupFailed,
    at: DateTime.utc(2026, 11, 9),
    exitCode: 1,
    summary: 'older failure summary',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLocale.use(AppLocale.zhCN);
  });
  tearDown(() => AppLocale.use(AppLocale.zhCN));

  test('D1-04_log_snapshot_does_not_overlap_events', () async {
    final bridge = _LogBridge();
    final c = _logContainer(bridge);
    // Subscribe first: batches that arrive before the snapshot must be replayed once.
    c.read(localRuntimeLogsProvider);
    bridge.batch([_entry(1), _entry(2), _entry(3)]);
    bridge.snapshot.complete(RuntimeLogSnapshot([_entry(1), _entry(2)], 2));
    await _settle();
    expect(c.read(localRuntimeLogsProvider), ['line 1', 'line 2', 'line 3']);

    // A late duplicate of the snapshot overlap changes nothing and publishes nothing.
    var notifications = 0;
    c.listen(localRuntimeLogsProvider, (_, _) => notifications++);
    bridge.batch([_entry(1), _entry(2), _entry(3)]);
    bridge.batch([]);
    expect(notifications, 0);
    bridge.batch([_entry(4)]);
    expect(c.read(localRuntimeLogsProvider), ['line 1', 'line 2', 'line 3', 'line 4']);

    // The ring buffer keeps the newest 1000 lines; seq stays monotonic.
    bridge.batch([for (var seq = 5; seq <= 3000; seq++) _entry(seq)]);
    final tail = c.read(localRuntimeLogsProvider);
    expect(tail, hasLength(1000));
    final seqs = [for (final line in tail) int.parse(line.split(' ').last)];
    expect(seqs, List.generate(1000, (i) => 3000 - 999 + i));
  });

  testWidgets('D1-04_start_failure_shows_reason', (tester) async {
    final bridge = _UnavailableBridge();
    final runtime = RecordingRuntime(LocalRuntimeState(loaded: true, status: _failedStatus()));
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: const EngineScreen(),
        brightness: Brightness.light,
        overrides: [
          localRuntimeProvider.overrideWith(() => runtime),
          runtimeBridgeProvider.overrideWithValue(bridge),
          localRuntimeLogsProvider.overrideWithBuild(
            (ref, notifier) => const ['[dsh-app] controlled crash diagnostic'],
          ),
          settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
        ],
      ),
    );
    await tester.pump();

    // This failure's reason, not the older one.
    expect(find.textContaining(_execError), findsWidgets);
    expect(find.textContaining('older failure summary'), findsNothing);
    // Diagnostics stay reachable while the engine is unavailable.
    expect(find.text(appL10n.phoneDiagnosticsExport), findsOneWidget);

    // The failure log opens and falls back to the buffered log when native has none.
    await tester.tap(find.text(appL10n.commonViewLogs));
    await tester.pumpAndSettle();
    expect(find.text(appL10n.phoneSafeFailureLog), findsOneWidget);
    expect(find.textContaining('controlled crash diagnostic'), findsWidgets);

    // One click copies the diagnostic output (engine unavailable, still works).
    final copied = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (
      call,
    ) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map<Object?, Object?>)['text'] as String);
      }
      return null;
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.tap(
      find.descendant(of: find.byType(SheetHeader), matching: find.byTooltip(appL10n.phoneLogCopyAll)),
    );
    await tester.pump();
    expect(copied, isNotEmpty);
    expect(copied.single, contains('controlled crash diagnostic'));
  });

  test('D1-04_logs_mask_credentials', () async {
    final bridge = _LogBridge();
    final c = _logContainer(bridge);
    c.read(localRuntimeLogsProvider);
    bridge.snapshot.complete(const RuntimeLogSnapshot([], 0));
    await _settle();
    bridge.batch([
      _entry(1, 'dsh web: http://127.0.0.1:3080/?token=Zx9.k_~-%2Fq'),
      _entry(2, '[llm] using key sk-4c1f0e7b9a2d4e6f8a1b3c5d7e9fa3f9 for deepseek'),
      _entry(3, 'Authorization: Bearer abcdef123456'),
      _entry(4, 'DEEPSEEK_API_KEY=abcdefgh12345678'),
      _entry(5, 'plain line'),
    ]);
    final lines = c.read(localRuntimeLogsProvider);
    expect(lines, [
      'dsh web: http://127.0.0.1:3080/?token=•••',
      '[llm] using key sk-••• for deepseek',
      'Authorization: Bearer •••',
      'DEEPSEEK_API_KEY=•••',
      'plain line',
    ]);
    // Copying the log (engine screen / failure sheet use the same lines) cannot
    // carry a complete credential.
    final copied = LogActions.joined(lines);
    for (final secret in ['Zx9.k_~-%2Fq', '4c1f0e7b9a2d4e6f8a1b3c5d7e9fa3f9', 'abcdef123456', 'abcdefgh12345678']) {
      expect(copied, isNot(contains(secret)));
    }
  });
}
