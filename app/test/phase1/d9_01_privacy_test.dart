// D9-01 · 隐私告知与匿名统计开关 — Phase 1 acceptance tests (L2).
//
// AC1 首次启动的欢迎页有开关（默认开）与说明，设置 › 隐私与分享可再看/关；
// AC2 关闭后不计数、不发送，状态跨重启保持；AC3 隐私页列出采集的数据类别，
// 明确不含对话/文件/账号。
//
// iOS boundary (spec D9-01 错误/边界): app/ios/Runner/UsageChannel.swift states
// "nothing is sent from iOS" because the share host only takes Android ABI
// names. The test below proves that from the Dart side: the iOS device facts
// fail the payload check and the day is dropped before any POST. This is not a
// claim that iOS reporting was implemented or disabled — there is no iOS
// reporting path in Phase 1.

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/ui/onboarding/welcome_page.dart';
import 'package:dsh_app/ui/settings/privacy_page.dart';
import 'package:dsh_app/usage/usage_ledger.dart';
import 'package:dsh_app/usage/usage_net.dart';
import 'package:dsh_app/usage/usage_stats.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../engine_settings/support.dart' as engine;
import '../shell/golden_harness.dart';
import '../usage/support.dart';

const _switch = ValueKey('usage-notice-switch');
const _iosDevice = UsageDevice(app: '1.0.14', build: 10140000, sdk: 26, abi: 'arm64', maker: 'apple');

Future<void> _pumpWelcome(WidgetTester tester) async {
  usePhoneSurface(tester);
  await tester.pumpWidget(
    goldenApp(
      home: WelcomePage(onStart: () {}),
      brightness: Brightness.light,
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  await tester.pump();
}

Future<Map<String, Object?>> _stored() async {
  final prefs = await SharedPreferences.getInstance();
  return {for (final k in prefs.getKeys()) k: prefs.get(k)};
}

Future<void> _settleAsync() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  final wasActive = UsageBuild.active;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UsageBuild.active = false;
  });
  tearDown(() {
    UsageBuild.active = wasActive;
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('D9-01_privacy_toggle_visible_on_first_run', (tester) async {
    await _pumpWelcome(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(WelcomePage)));
    await _settle(tester);

    // On by default, with the explanation line beside it.
    expect(tester.widget<Switch>(find.byKey(_switch)).value, isTrue);
    expect(find.text(appL10n.usageStatsTitle), findsOneWidget);
    expect(find.text(appL10n.usageNoticeBody), findsOneWidget);
    expect(container.read(usageStatsProvider).enabled, isTrue);
    expect(container.read(usageStatsProvider).noticed, isTrue);
    expect((await _stored())[UsageStatsController.noticedKey], isTrue);

    // One tap turns it off and the choice is persisted.
    await tester.tap(find.text(appL10n.usageNoticeBody));
    await _settle(tester);
    expect(container.read(usageStatsProvider).enabled, isFalse);
    expect((await _stored())[UsageStatsController.enabledKey], isFalse);

    // 设置 › 隐私与分享 shows the same switch and can turn it back on.
    // A new root: the settings page has a different override set.
    await tester.pumpWidget(const SizedBox.shrink());
    await engine.pumpPage(
      tester,
      const PrivacyPage(),
      overrides: engine.engineOverrides(DshClient.withCarrier(engine.FakeSettingsHost())),
    );
    await _settle(tester);
    final tile = find.widgetWithText(InkWell, appL10n.usageStatsTitle);
    expect(tester.widget<Switch>(find.descendant(of: tile, matching: find.byType(Switch))).value, isFalse);
    await tester.tap(tile);
    await _settle(tester);
    final privacy = ProviderScope.containerOf(tester.element(find.byType(PrivacyPage)));
    expect(privacy.read(usageStatsProvider).enabled, isTrue);
    expect((await _stored())[UsageStatsController.enabledKey], isTrue);
  });

  testWidgets('D9-01_privacy_details_reachable_from_first_run', (tester) async {
    await _pumpWelcome(tester);
    // The title is the explanation entry: tapping it opens 隐私与分享 without
    // changing the switch.
    await tester.tap(find.text(appL10n.usageStatsTitle));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(PrivacyPage), findsOneWidget);
    expect(find.text(appL10n.usageStatsFooter), findsOneWidget);
    final container = ProviderScope.containerOf(tester.element(find.byType(PrivacyPage)));
    expect(container.read(usageStatsProvider).enabled, isTrue);
  });

  test('D9-01_no_usage_network_call_when_off', () async {
    UsageBuild.active = true;
    final http = FakeUsageHttp();
    final now = DateTime(2026, 10, 28, 9);
    final ledger = UsageLedger()..count(UsageCount.turns, DateTime(2026, 10, 27, 9));
    SharedPreferences.setMockInitialValues({
      UsageStatsController.enabledKey: true,
      UsageStatsController.noticedKey: true,
      UsageStatsController.daysKey: ledger.encode(),
    });
    final container = ProviderContainer(
      overrides: usageOverrides(clock: () => now, http: http, onResumes: (_) {}, device: testDevice),
    );
    addTearDown(container.dispose);
    container.read(usageStatsProvider);
    await _settleAsync();
    // The cold start's due day went out while it was on; what follows is
    // only about the off path.
    http.requests.clear();
    http.urls.clear();

    // Turning it off drops the ledger and the install id at once.
    await container.read(usageStatsProvider.notifier).setEnabled(false);
    await _settleAsync();
    final prefs = await _stored();
    expect(prefs[UsageStatsController.enabledKey], isFalse);
    for (final key in [
      UsageStatsController.daysKey,
      UsageStatsController.iidKey,
      UsageStatsController.iidSinceKey,
      UsageStatsController.failedAtKey,
    ]) {
      expect(prefs.containsKey(key), isFalse, reason: key);
    }

    // And the reporting path sends nothing while off.
    await container.read(usageStatsProvider.notifier).foreground();
    expect(http.requests, isEmpty, reason: 'off means no request');

    // Off survives a cold start.
    final again = ProviderContainer(
      overrides: usageOverrides(clock: () => now, http: http, onResumes: (_) {}, device: testDevice),
    );
    addTearDown(again.dispose);
    again.read(usageStatsProvider);
    await _settleAsync();
    expect(again.read(usageStatsProvider).enabled, isFalse);
    expect(again.read(usageStatsProvider).collecting, isFalse);

    // Turning it back on persists too.
    await again.read(usageStatsProvider.notifier).setEnabled(true);
    await _settleAsync();
    expect((await _stored())[UsageStatsController.enabledKey], isTrue);
    final third = ProviderContainer(
      overrides: usageOverrides(clock: () => now, http: http, onResumes: (_) {}, device: testDevice),
    );
    addTearDown(third.dispose);
    third.read(usageStatsProvider);
    await _settleAsync();
    expect(third.read(usageStatsProvider).enabled, isTrue);
  });

  test('D9-01_ios_usage_facts_are_dropped_before_any_request', () async {
    UsageBuild.active = true;
    final now = DateTime(2026, 10, 28, 9);
    final record = UsageDayRecord(counts: {UsageCount.turns: 1});
    final payload = usagePayload(iid: newUsageIid(), day: '2026-10-27', record: record, device: _iosDevice, lang: 'zh');
    // The share host only takes Android ABIs; the iOS facts fail the same
    // check the sender runs, so the day is dropped on the phone.
    expect(usageProblem(payload, now), 'abi');

    final http = FakeUsageHttp();
    SharedPreferences.setMockInitialValues({
      UsageStatsController.enabledKey: true,
      UsageStatsController.noticedKey: true,
      UsageStatsController.daysKey: (UsageLedger()..count(UsageCount.turns, DateTime(2026, 10, 27, 9))).encode(),
    });
    final container = ProviderContainer(
      overrides: usageOverrides(clock: () => now, http: http, onResumes: (_) {}, device: _iosDevice),
    );
    addTearDown(container.dispose);
    container.read(usageStatsProvider);
    await _settleAsync();
    await container.read(usageStatsProvider.notifier).foreground();
    expect(http.requests, isEmpty, reason: 'nothing is sent from iOS');
  });

  testWidgets('D9-01_privacy_page_lists_data_classes', (tester) async {
    await engine.pumpPage(
      tester,
      const PrivacyPage(),
      overrides: engine.engineOverrides(DshClient.withCarrier(engine.FakeSettingsHost())),
    );
    await _settle(tester);

    // The page is where the switch and its explanation live.
    expect(find.text(appL10n.usageStatsSection), findsOneWidget);
    expect(find.text(appL10n.usageStatsFooter), findsOneWidget);
    final footer = appL10n.usageStatsFooter;
    for (final category in const ['使用次数', '版本', '手机品牌和型号', '系统版本']) {
      expect(footer, contains(category), reason: category);
    }
    // And it says what is not collected.
    expect(footer, contains('不含对话、文件和账号'));
    // No secret is rendered on this page.
    expect(
      tester.widgetList<Text>(find.byType(Text)).map((t) => t.data ?? t.textSpan?.toPlainText()),
      isNot(contains(contains('sk-'))),
    );
  });
}
