// D4-01 · 会话抽屉（列表 / 未读 / 待确认 / 筛选）— Phase 1 验收测试。
//
//   flutter test test/sessions/d4_01_sessions_drawer_test.dart
//
// AC 依据 `docs/specs/phase1/capability-spec.md#D4-01`：
//   AC1 按最近活动排序；未读/待确认/待回答有标记；点击切换会话，消息区正确切换。
//   AC2 筛选「未读/待确认」只显示匹配会话；无匹配显示空状态；切回「全部」恢复。
//   AC3 切换主机只显示当前主机会话（不混主机）；主机断开时显示连接状态。
// 边界（spec「错误/边界」）：会话加载失败可重试；新会话插入位置。

import 'dart:convert';

import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/session_attention_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/common/capsule_chip.dart';
import 'package:dsh_app/ui/shell/drawer/session_tile.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../drawer/support.dart' show FixedPending;
import '../shell/golden_harness.dart';
import '../workspace/support.dart';

/// The stand-in chat area: shows which conversation the shell is showing, so a
/// drawer tap can be checked as a visible change, not a provider value only.
class _ChatArea extends ConsumerWidget {
  const _ChatArea();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = ref.watch(currentSessionProvider);
    return Center(child: Text('chat:${id ?? 'none'}'));
  }
}

/// Tall phone surface: the drawer keeps its rows lazily built, and the
/// ordering assertions need the whole sample list on screen.
void _tallSurface(WidgetTester tester) {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(390 * 2, 1600 * 2);
  tester.view.padding = const FakeViewPadding(top: 32 * 2, bottom: 24 * 2);
  tester.view.viewPadding = const FakeViewPadding(top: 32 * 2, bottom: 24 * 2);
  addTearDown(tester.view.reset);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 450));
  await tester.pump(const Duration(milliseconds: 450));
}

/// The local host of `sampleWorkspaceHost`: s1 运行中, s2 深色模式, s3 proot…
Finder _tile(String title) => find.widgetWithText(SessionTile, title);

/// What the phone has already seen of 本机: everything at or before [seenUntil]
/// counts as seen, so later activity is unread.
Map<String, Object> _seenPrefs(DateTime seenUntil) => {
  'drawer.seen.local.local': jsonEncode({
    'baseline': seenUntil.millisecondsSinceEpoch,
    'seen': <String, int>{},
  }),
};

Future<ProviderContainer> _startLocal(
  WidgetTester tester, {
  Map<String, Object> prefs = const {},
  Map<String, PendingKind> pending = const {},
  String? current = 's1',
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final host = sampleWorkspaceHost();
  _tallSurface(tester);
  await tester.pumpWidget(
    goldenApp(
      brightness: Brightness.light,
      home: HomeShell(chatBuilder: (_) => const _ChatArea(), initiallyOpen: true),
      overrides: [
        ...workspaceOverrides(host, prefs: const WorkspacePrefs(loaded: true), current: current),
        pendingInteractionsProvider.overrideWith(() => FixedPending(pending)),
      ],
    ),
  );
  await _settle(tester);
  final container = ProviderScope.containerOf(tester.element(find.byType(HomeShell)));
  addTearDown(container.read(activeConnectionProvider).value!.client.close);
  return container;
}

/// A Host whose `session/list` fails [failures] times, then answers.
class _FlakyHost extends FakeWorkspaceHost {
  _FlakyHost({this.failures = 1});

  int failures;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    if (endpoint == 'session/list' && failures > 0) {
      failures--;
      calls.add((endpoint, args));
      return RpcError(DshRemoteException('gateway/internal', 'list failed'));
    }
    return super.call(endpoint, args, timeout: timeout);
  }
}

/// The active host of the test, switchable through the real controller.
class _Host extends ActiveHostController {}

void main() {
  group('D4-01 会话抽屉', () {
    testWidgets('D4-01_drawer_lists_and_switches_sessions', (tester) async {
      final container = await _startLocal(tester, current: null);

      // AC1：抽屉按最近活动排序（s1 > s2 > s3 今天；s4/s5 更早）。
      expect(_tile('修复登录按钮重复提交'), findsOneWidget);
      expect(_tile('给设置页加深色模式'), findsOneWidget);
      expect(_tile('写一篇 proot 入门'), findsOneWidget);
      final s1 = tester.getTopLeft(_tile('修复登录按钮重复提交')).dy;
      final s2 = tester.getTopLeft(_tile('给设置页加深色模式')).dy;
      final s3 = tester.getTopLeft(_tile('写一篇 proot 入门')).dy;
      expect(s1, lessThan(s2), reason: 'D4-01-AC1: 最近活动的会话在前');
      expect(s2, lessThan(s3), reason: 'D4-01-AC1: 最近活动的会话在前');

      // AC1：点击切换会话，消息区跟着切换。
      expect(find.text('chat:none'), findsOneWidget);
      await tester.tap(_tile('给设置页加深色模式'));
      await _settle(tester);
      expect(container.read(currentSessionProvider), 's2', reason: 'D4-01-AC1: 点击会话切换当前会话');
      expect(find.text('chat:s2'), findsOneWidget, reason: 'D4-01-AC1: 消息区显示被选中的会话');
      expect(find.text('chat:none'), findsNothing);
    });

    testWidgets('D4-01_drawer_marks_unread_pending_and_question', (tester) async {
      final midnight = DateTime(sampleNow.year, sampleNow.month, sampleNow.day);
      // 本机此前只看到今天 00:00:01；s2（00:00:02）之后的活动即未读。
      await _startLocal(
        tester,
        prefs: _seenPrefs(midnight.add(const Duration(seconds: 1))),
        pending: {'s3': PendingKind.approval, 's4': PendingKind.question},
        current: 's1',
      );

      // 未读：s2 有一枚未读点。
      expect(
        find.descendant(of: _tile('给设置页加深色模式'), matching: find.byKey(const ValueKey('unread'))),
        findsAtLeastNWidgets(1),
        reason: 'D4-01-AC1: 未读会话有标记',
      );
      // 待确认 / 待回答：标记文字在各自行内。
      expect(
        find.descendant(of: _tile('写一篇 proot 入门'), matching: find.text('待确认')),
        findsOneWidget,
        reason: 'D4-01-AC1: 待确认会话有标记',
      );
      expect(
        find.descendant(of: _tile('重构 sessions_state 的刷新逻辑'), matching: find.text('待回答')),
        findsOneWidget,
        reason: 'D4-01-AC1: 待回答会话有标记',
      );
      // 运行中：s1 的运行点。
      expect(
        find.descendant(of: _tile('修复登录按钮重复提交'), matching: find.byKey(const ValueKey('running'))),
        findsAtLeastNWidgets(1),
        reason: 'D4-01-AC1: 运行中的会话有标记',
      );
    });

    testWidgets('D4-01_drawer_filters_unread', (tester) async {
      final midnight = DateTime(sampleNow.year, sampleNow.month, sampleNow.day);
      final container = await _startLocal(
        tester,
        prefs: _seenPrefs(midnight.add(const Duration(seconds: 1))),
        pending: {'s3': PendingKind.approval},
        current: 's1',
      );

      // AC2：未读筛选只剩 s2。
      await tester.tap(find.widgetWithText(CapsuleChoiceChip, '未读 1'));
      await _settle(tester);
      expect(_tile('给设置页加深色模式'), findsOneWidget);
      expect(_tile('修复登录按钮重复提交'), findsNothing, reason: 'D4-01-AC2: 未读筛选隐藏已读会话');
      expect(_tile('写一篇 proot 入门'), findsNothing);

      // AC2：待确认筛选只剩 s3。
      await tester.tap(find.widgetWithText(CapsuleChoiceChip, '待确认 1'));
      await _settle(tester);
      expect(_tile('写一篇 proot 入门'), findsOneWidget);
      expect(_tile('给设置页加深色模式'), findsNothing, reason: 'D4-01-AC2: 待确认筛选隐藏其它会话');

      // AC2：无匹配显示空状态（筛选「未读」，但把 s2 标记为已读后没有未读）。
      container.read(currentSessionProvider.notifier).select('s2');
      await _settle(tester);
      container.read(currentSessionProvider.notifier).select(null);
      await _settle(tester);
      await tester.tap(find.widgetWithText(CapsuleChoiceChip, '未读'));
      await _settle(tester);
      expect(find.text('没有未读对话'), findsOneWidget, reason: 'D4-01-AC2: 无匹配显示空状态');

      // AC2：切回「全部」恢复完整列表。
      await tester.tap(find.widgetWithText(CapsuleChoiceChip, '全部'));
      await _settle(tester);
      expect(_tile('修复登录按钮重复提交'), findsOneWidget);
      expect(_tile('给设置页加深色模式'), findsOneWidget);
      expect(_tile('写一篇 proot 入门'), findsOneWidget);
    });

    testWidgets('D4-01_sessions_follow_current_host', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final local = sampleWorkspaceHost();
      final remote = FakeWorkspaceHost()
        ..seedSession('r1', '远程主机的对话', DateTime(sampleNow.year, sampleNow.month, sampleNow.day, 9));
      _tallSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          brightness: Brightness.light,
          home: HomeShell(chatBuilder: (_) => const _ChatArea(), initiallyOpen: true),
          overrides: [
            activeHostProvider.overrideWith(_Host.new),
            activeConnectionProvider.overrideWith((ref) {
              final host = ref.watch(activeHostProvider);
              return AsyncData(host.isLocal ? workspaceHost(local) : workspaceHost(remote, local: false));
            }),
            localRuntimeProvider.overrideWith(
              () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
            ),
            settingsProvider.overrideWith(() => FakeSettings(AppSettings(loaded: true, phoneStorage: true))),
            workspacePrefsProvider.overrideWith(() => FixedWorkspacePrefs(const WorkspacePrefs(loaded: true))),
            currentSessionProvider.overrideWith(() => FakeCurrentSession(null)),
          ],
        ),
      );
      await _settle(tester);
      expect(_tile('修复登录按钮重复提交'), findsOneWidget);

      final container = ProviderScope.containerOf(tester.element(find.byType(HomeShell)));
      addTearDown(container.read(activeConnectionProvider).value!.client.close);
      container.read(activeHostProvider.notifier).select(const HostRef.ssh('pc'));
      await _settle(tester);

      // AC3：只显示当前主机的会话，旧主机的行不混进来。
      expect(_tile('修复登录按钮重复提交'), findsNothing, reason: 'D4-01-AC3: 切换主机后不混入旧主机会话');
      expect(_tile('给设置页加深色模式'), findsNothing);
      expect(_tile('远程主机的对话'), findsOneWidget, reason: 'D4-01-AC3: 显示当前主机的会话');
    });

    testWidgets('D4-01_disconnected_host_shows_connection_state', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final local = sampleWorkspaceHost();
      _tallSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          brightness: Brightness.light,
          home: HomeShell(chatBuilder: (_) => const _ChatArea(), initiallyOpen: true),
          overrides: [
            activeHostProvider.overrideWith(_Host.new),
            // 远程主机没有连接：抽屉应显示连接状态，而不是空列表或旧行。
            activeConnectionProvider.overrideWith((ref) {
              final host = ref.watch(activeHostProvider);
              return host.isLocal ? AsyncData(workspaceHost(local)) : const AsyncData(null);
            }),
            localRuntimeProvider.overrideWith(
              () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
            ),
            settingsProvider.overrideWith(() => FakeSettings(AppSettings(loaded: true, phoneStorage: true))),
            workspacePrefsProvider.overrideWith(() => FixedWorkspacePrefs(const WorkspacePrefs(loaded: true))),
            currentSessionProvider.overrideWith(() => FakeCurrentSession(null)),
          ],
        ),
      );
      await _settle(tester);
      expect(_tile('修复登录按钮重复提交'), findsOneWidget);

      final container = ProviderScope.containerOf(tester.element(find.byType(HomeShell)));
      addTearDown(container.read(activeConnectionProvider).value!.client.close);
      container.read(activeHostProvider.notifier).select(const HostRef.ssh('pc'));
      await _settle(tester);

      expect(_tile('修复登录按钮重复提交'), findsNothing, reason: 'D4-01-AC3: 断开的远程主机不显示本机会话');
      expect(find.textContaining('正在连接'), findsOneWidget, reason: 'D4-01-AC3: 主机断开时显示连接状态');
    });

    testWidgets('D4-01_drawer_load_failure_retries', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final host = _FlakyHost(failures: 100);
      host.seedSession('s1', '修复登录按钮重复提交', DateTime(sampleNow.year, sampleNow.month, sampleNow.day));
      _tallSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          brightness: Brightness.light,
          home: HomeShell(chatBuilder: (_) => const _ChatArea(), initiallyOpen: true),
          overrides: workspaceOverrides(host, prefs: const WorkspacePrefs(loaded: true), current: null),
        ),
      );
      await _settle(tester);

      // 边界：加载失败显示错误与重试入口。
      expect(find.text('对话列表加载失败'), findsOneWidget, reason: 'D4-01 边界: 加载失败有错误态');
      // 让 Host 恢复，再点重试：列表要真的重新读出来。
      host.failures = 0;
      await tester.tap(find.text('重试'));
      await _settle(tester);
      // 重试后真的重新读了列表（不是只关掉错误）。
      expect(find.text('对话列表加载失败'), findsNothing);
      expect(_tile('修复登录按钮重复提交'), findsOneWidget, reason: 'D4-01 边界: 重试后列表恢复');
      expect(host.argsOf('session/list').length, greaterThanOrEqualTo(2));
    });

    testWidgets('D4-01_new_session_inserted_in_order', (tester) async {
      final container = await _startLocal(tester, current: null);
      final midnight = DateTime(sampleNow.year, sampleNow.month, sampleNow.day);

      // 边界：新会话按最近活动插到列表最前，而不是追加到末尾。
      final host = container.read(activeConnectionProvider).value!.client.carrier as FakeWorkspaceHost;
      host.seedSession('s0', '刚新建的对话', midnight.add(const Duration(seconds: 9)));
      await container.read(sessionsProvider.notifier).refresh();
      await _settle(tester);

      final newest = tester.getTopLeft(_tile('刚新建的对话')).dy;
      final oldTop = tester.getTopLeft(_tile('修复登录按钮重复提交')).dy;
      expect(newest, lessThan(oldTop), reason: 'D4-01 边界: 新会话按最近活动插入最前');
    });
  });
}
