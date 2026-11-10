// D1-01 本机运行环境安装（capability-spec.md#D1-01）的 L2 自动化部分。
//
// AC1 的“进度事件 → installing → installed”与 AC2 的“杀进程后重开、断点续装”
// 属于真机/模拟器层，由 `tooling/ios/engine-smoke/d1-01-install-check.mjs` 用
// T3 的真引擎产物覆盖（L4）；这里覆盖状态机与失败诊断的 L2 部分：
//   - 失败原因必须可读（AC3），而不是通用一句「解压时出错」；
//   - 重试走同一个安装入口，且进行中/已就绪时的重复请求幂等（AC 错误/边界）。
//
// 测试名按 traceability.md 的 D1-01 行命名，便于追踪。

import 'dart:async';

import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/onboarding_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/onboarding/runtime_setup_page.dart';
import 'package:dsh_app/ui/onboarding/setup_progress.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../onboarding/local_optional_support.dart';
import '../onboarding/parallel_setup_support.dart';
import '../shell/golden_harness.dart';

/// 记录安装请求，供“完成态幂等/进行中合并”两个 L2 用例断言不再触发 native 调用。
class _Runtime extends FakeRuntime {
  _Runtime(super.initial);

  final installs = <String>[];

  @override
  Future<void> install() async => installs.add('install');

  @override
  Future<void> installDroppingKept() async => installs.add('install-drop-kept');
}

/// 桥接层的替身：真实 `LocalRuntimeController` 经过它，用来验证“请求被桥接层拒绝”
/// 时失败原因（code + message）如何进入 UI（AC3）。
class _Bridge extends RuntimeBridge {
  _Bridge(this.current, {this.installError});

  final RuntimeStatus current;
  final Object? installError;
  final installs = <String>[];

  @override
  Stream<RuntimeEvent> get events => const Stream.empty();

  @override
  Future<RuntimeStatus> status() async => current;

  @override
  Future<void> install({bool dropKept = false}) async {
    installs.add('install');
    if (installError case final error?) throw error;
  }
}

/// 由测试驱动进度/完成，模拟 native `install` 的异步状态事件。
class _ProgressRuntime extends FakeRuntime {
  _ProgressRuntime() : super(const LocalRuntimeState(loaded: true, status: missingStatus));

  final installs = <String>[];
  final _done = Completer<void>();

  @override
  Future<void> install() {
    installs.add('install');
    return _done.future;
  }

  void installing(double fraction) => state = LocalRuntimeState(
    loaded: true,
    status: const RuntimeStatus(phase: RuntimePhase.installing, bundledVersion: bundled, abi: 'arm64-v8a'),
    progress: unpackProgress(fraction),
  );

  void installed() {
    state = const LocalRuntimeState(loaded: true, status: stoppedStatus);
    if (!_done.isCompleted) _done.complete();
  }
}

Future<void> _pump(WidgetTester tester, FakeRuntime runtime) async {
  SharedPreferences.setMockInitialValues({});
  usePhoneSurface(tester);
  await tester.pumpWidget(
    goldenApp(
      home: RuntimeSetupPage(onDone: () {}),
      brightness: Brightness.light,
      overrides: [
        localRuntimeProvider.overrideWith(() => runtime),
        settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
        footprint(roomyPhone),
      ],
    ),
  );
  await frames(tester);
}

Future<void> _pumpBridge(WidgetTester tester, _Bridge bridge) async {
  SharedPreferences.setMockInitialValues({});
  usePhoneSurface(tester);
  await tester.pumpWidget(
    goldenApp(
      home: RuntimeSetupPage(onDone: () {}),
      brightness: Brightness.light,
      overrides: [
        runtimeBridgeProvider.overrideWithValue(bridge),
        settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
        footprint(roomyPhone),
      ],
    ),
  );
  await frames(tester);
}

ProviderContainer _container(FakeRuntime runtime) {
  SharedPreferences.setMockInitialValues({});
  final container = ProviderContainer(
    overrides: [
      localRuntimeProvider.overrideWith(() => runtime),
      onboardingPrefsProvider.overrideWith(FakeOnboardingPrefs.new),
    ],
  );
  addTearDown(container.dispose);
  container.read(runtimeInstallProvider);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('D1-01_install_failure_shows_retry', (tester) async {
    final bridge = _Bridge(
      missingStatus,
      installError: PlatformException(code: 'ios_payload_missing', message: 'App 里没有运行时载荷。'),
    );
    await _pumpBridge(tester, bridge);

    // 页面进入失败态：原因来自桥接层稳定可读的 message，而不是只有通用提示。
    expect(bridge.installs, ['install']);
    expect(find.textContaining('App 里没有运行时载荷'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '重试'), findsOneWidget);
    final container = ProviderScope.containerOf(tester.element(find.byType(RuntimeSetupPage)));
    expect(container.read(localRuntimeProvider).installFailure?.code, 'ios_payload_missing');

    // 重试入口走同一个安装入口；一次点击只发一次请求。
    await tester.tap(find.widgetWithText(FilledButton, '重试'));
    await tester.pump();
    expect(bridge.installs, ['install', 'install']);
    expect(tester.takeException(), isNull);
  });

  test('D1-01_install_is_idempotent_when_current', () async {
    // 已安装且版本一致：再次安装应立即完成，不再触发一次 native 校验/解压。
    final runtime = _Runtime(const LocalRuntimeState(loaded: true, status: stoppedStatus));
    final container = _container(runtime);

    await container.read(runtimeInstallProvider.notifier).install();
    expect(runtime.installs, isEmpty);
    expect(container.read(localRuntimeProvider).status.phase, RuntimePhase.installed);
  });

  test('D1-01_install_in_flight_requests_share_one_native_call', () async {
    final runtime = _ProgressRuntime();
    final container = _container(runtime);

    final first = container.read(runtimeInstallProvider.notifier).install();
    final second = container.read(runtimeInstallProvider.notifier).install();
    expect(runtime.installs, ['install']);
    runtime.installed();
    await Future.wait([first, second]);
    expect(runtime.installs, ['install']);
  });

  test('D1-01_install_progress_to_installed', () async {
    // AC1 的 L2 状态机：installing（带进度）→ installed，进度随完成清空。
    final runtime = _ProgressRuntime();
    final container = _container(runtime);

    final install = container.read(runtimeInstallProvider.notifier).install();
    runtime.installing(0.25);
    expect(container.read(localRuntimeProvider).status.phase, RuntimePhase.installing);
    expect(container.read(localRuntimeProvider).progress?.fraction, 0.25);

    runtime.installing(0.9);
    expect(container.read(localRuntimeProvider).progress?.fraction, 0.9);

    runtime.installed();
    await install;
    expect(container.read(localRuntimeProvider).status.phase, RuntimePhase.installed);
    expect(runtime.installs, ['install']);
  });

  testWidgets('D1-01_install_progress_is_shown_while_installing', (tester) async {
    // AC1 的 L2 可见部分：安装中页面显示进度，而不是空白/等待页。
    final runtime = _ProgressRuntime();
    await _pump(tester, runtime);
    runtime.installing(0.4);
    await frames(tester);
    expect(find.byKey(const ValueKey('pct')), findsOneWidget);
    expect(find.byType(RuntimeSetupPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
