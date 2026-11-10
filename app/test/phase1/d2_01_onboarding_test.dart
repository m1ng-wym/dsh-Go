// D2-01 · 首次引导（本机/远程 + 最小权限）— Phase 1 acceptance tests (L2).
//
// AC1 本机/远程二选一、两条路径、可返回重选；AC2 iOS 只出现 Phase 1 需要的
// 权限（不出现 Android 专属权限）；AC3 完成后不再重复引导、远程用户跳过安装
// 不阻塞、从设置可改主机选择且不动引导状态/已有主机数据。
//
// The permission *dialogs* themselves are L5 manual (acceptance-checklist A):
// widget tests cannot tap the system sheet. What is automated here is the
// permission set the app offers on iOS and that the flow continues.

import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/access_state.dart';
import 'package:dsh_app/state/account_state.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/onboarding_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/onboarding/appearance_step.dart';
import 'package:dsh_app/ui/onboarding/connect_page.dart';
import 'package:dsh_app/ui/onboarding/onboarding_flow.dart';
import 'package:dsh_app/ui/remote/remote_screen.dart';
import 'package:dsh_app/ui/settings/settings_screen.dart';
import 'package:dsh_app/ui/shell/root_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../account/support.dart' show FixedAccount;
import '../onboarding/local_optional_support.dart';
import '../onboarding/parallel_setup_support.dart';
import '../phone/support.dart' show FixedActiveHost, FixedHosts;
import '../shell/golden_harness.dart';

void main() {
  setUp(useSavedHost);
  tearDown(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('D2-01_onboarding_choice_local_vs_remote', (tester) async {
    final rig = await pumpGate(tester, prefs: const OnboardingPrefs(loaded: true));

    // A truly fresh install starts on the welcome page.
    expect(find.text('开始'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '开始'));
    await frames(tester);

    // The choice: both ways, one 继续.
    expect(find.text('DSH 在哪里运行？'), findsOneWidget);
    expect(find.byKey(const ValueKey('runtime-option-local')), findsOneWidget);
    expect(find.byKey(const ValueKey('runtime-option-remote')), findsOneWidget);
    expect(find.text('本机'), findsWidgets);
    expect(find.text('远程主机'), findsWidgets);
    expect(find.widgetWithText(FilledButton, '继续'), findsOneWidget);

    // 远程主机 → the host list, not an unpack.
    await tester.tap(find.byKey(const ValueKey('runtime-option-remote')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithText(FilledButton, '继续'));
    await frames(tester);
    expect(find.byType(RemoteScreen), findsOneWidget);
    expect(rig.runtime.calls, isEmpty);

    // Back returns to the same choice, and 本机 can still be picked.
    await tester.tap(find.byTooltip('返回'));
    await frames(tester);
    expect(find.text('DSH 在哪里运行？'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('runtime-option-local')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithText(FilledButton, '继续'));
    await frames(tester);
    expect(find.byType(AppearanceStepPage), findsOneWidget);
    expect(rig.runtime.calls, ['install']);
    expect(rig.prefs.setupStep, SetupStep.appearance);
    expect(rig.prefs.localDeclined, isFalse);
  });

  test('D2-01_ios_access_walk_has_no_android_only_permission', () {
    // iOS has notifications and the microphone; files, windows over other
    // apps, phone control and background running are Android-only.
    expect(accessFeaturesFor('ios'), const [AccessFeature.alerts, AccessFeature.voice]);
    final walk = accessWalk(accessFeaturesFor('ios'), null);
    expect(walk, const [AccessItem.mic, AccessItem.notifications]);
    for (final androidOnly in const [
      AccessItem.storage,
      AccessItem.battery,
      AccessItem.accessibility,
      AccessItem.overlay,
      AccessItem.popup,
      AccessItem.vendorBackground,
      AccessItem.autostart,
    ]) {
      expect(walk, isNot(contains(androidOnly)), reason: '$androidOnly is not an iOS permission');
    }
  });

  testWidgets('D2-01_onboarding_minimal_permissions', (tester) async {
    // The simulator's OS is iOS; the walk must offer only what iOS can ask for.
    await pumpGate(tester, overrides: [operatingSystemProvider.overrideWithValue('ios')]);
    await chooseThisPhone(tester);
    await tester.tap(find.widgetWithText(FilledButton, '继续'));
    await frames(tester);

    expect(find.text('想让 DSH Go 帮你做哪些事'), findsOneWidget);
    expect(find.text('回复提醒'), findsOneWidget);
    expect(find.text('语音输入'), findsOneWidget);
    for (final androidOnly in const ['读写手机里的文件', '桌宠与悬浮窗', '手机操控', '后台持续运行']) {
      expect(find.text(androidOnly), findsNothing, reason: androidOnly);
    }

    // Skipping the optional permissions does not block first run.
    await tester.tap(find.widgetWithText(TextButton, '跳过'));
    await frames(tester);
    expect(find.byType(ConnectPage), findsOneWidget);
  });

  testWidgets('D2-01_onboarding_not_repeated_after_complete', (tester) async {
    // The gate's decision, once the first run is over.
    const fresh = OnboardingPrefs(loaded: true, welcomeSeen: true);
    expect(initialOnboardingStep(status: missingStatus, hasApiKey: false, prefs: fresh), OnboardingStep.runtime);
    expect(initialOnboardingStep(status: stoppedStatus, hasApiKey: true, prefs: fresh), isNull);
    expect(
      initialOnboardingStep(status: stoppedStatus, hasApiKey: false, prefs: fresh.copyWith(keySkipped: true)),
      isNull,
    );
    expect(
      initialOnboardingStep(status: missingStatus, hasApiKey: false, prefs: fresh.copyWith(localDeclined: true)),
      isNull,
      reason: 'a remote-only phone does not get the local setup again',
    );

    // Walk a whole first run, then launch again with the same prefs.
    final rig = await pumpGate(tester);
    await chooseThisPhone(tester);
    rig.runtime.finish();
    await frames(tester, 20);
    await pastAppearance(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, '使用 API Key'));
    await frames(tester);
    await tester.enterText(find.byType(TextField), 'sk-4c1f0e7b9a2d4e6f8a1b3c5d7e9fa3f9');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '保存并继续'));
    await frames(tester);
    expect(find.text('home'), findsOneWidget);

    await pumpGate(
      tester,
      runtime: const LocalRuntimeState(loaded: true, status: stoppedStatus),
      settings: const AppSettings(loaded: true, apiKey: 'sk-4c1f0e7b9a2d4e6f8a1b3c5d7e9fa3f9'),
      prefs: rig.prefs,
    );
    expect(find.text('home'), findsOneWidget);
    expect(find.text('DSH 在哪里运行？'), findsNothing);
    expect(find.text('开始'), findsNothing);
  });

  testWidgets('D2-01_onboarding_skip_install_does_not_block', (tester) async {
    final rig = await pumpGate(tester);
    await tester.tap(find.byKey(const ValueKey('runtime-option-remote')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithText(FilledButton, '继续'));
    await frames(tester);
    expect(find.byType(RemoteScreen), findsOneWidget);

    await tester.tap(find.text('电脑'));
    await frames(tester);
    expect(find.text('home'), findsOneWidget);
    expect(rig.prefs.localDeclined, isTrue);
    expect(rig.prefs.setupStep, isNull);
    expect(rig.runtime.calls, isEmpty, reason: 'a remote user skips the local install entirely');
  });

  testWidgets('D2-01_settings_can_change_host_without_resetting_onboarding', (tester) async {
    // From 设置: the hub's host card opens the host page; switching back to
    // 本机 there leaves the saved SSH host and the first-run state as they were.
    SharedPreferences.setMockInitialValues({});
    usePhoneSurface(tester);
    const remote = HostRef.ssh('lab');
    await tester.pumpWidget(
      goldenApp(
        home: const SettingsScreen(),
        brightness: Brightness.light,
        prefs: const OnboardingPrefs(loaded: true, welcomeSeen: true, localDeclined: true),
        overrides: [
          localRuntimeProvider.overrideWith(
            () => FakeRuntime(const LocalRuntimeState(loaded: true, status: stoppedStatus)),
          ),
          settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
          accountProvider.overrideWith(() => FixedAccount(const AccountState(phase: AccountPhase.signedOut))),
          activeHostProvider.overrideWith(() => FixedActiveHost(remote)),
          hostsProvider.overrideWith(FixedHosts.new),
          hostLinkStatusProvider.overrideWith(
            (ref, host) => Stream.value(const HostLinkStatus(HostLinkPhase.connected)),
          ),
          networkKicksProvider.overrideWithValue(const Stream.empty()),
          secretStoreProvider.overrideWithValue(MemorySecretStore()),
        ],
      ),
    );
    await frames(tester);
    // The hub's 主机 section is below the first screenful.
    await tester.scrollUntilVisible(find.text('远程主机'), 300, scrollable: find.byType(Scrollable).first);
    await tester.pump();
    final remoteRow = find.text('远程主机');
    expect(remoteRow, findsWidgets);
    await tester.tap(remoteRow.last);
    await frames(tester);
    expect(find.byType(RemoteScreen), findsOneWidget);
    expect(find.text('切回本机'), findsOneWidget);

    await tester.tap(find.text('切回本机'));
    await tester.pump();
    final container = ProviderScope.containerOf(tester.element(find.byType(RemoteScreen)));
    expect(container.read(activeHostProvider), HostRef.local);
    expect(container.read(onboardingPrefsProvider).setupStep, isNull);
    expect(container.read(onboardingPrefsProvider).localDeclined, isTrue);
    expect(container.read(hostsProvider).ssh.single.id, 'lab', reason: 'the saved host is not touched');
  });
}
