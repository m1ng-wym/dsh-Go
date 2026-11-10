// T18 · PERSIST-01 会话持久化 / 引擎重启恢复 / 崩溃恢复（Phase 1 · Wave 3）
//
// AC 逐条对应：
// - PERSIST-01-AC1 杀 App 重开：会话列表含该会话、消息完整、可继续；本机引擎自动启动
// - PERSIST-01-AC2 引擎停止/重启（不杀 App）：原会话可继续，草稿/附件按 D4-07 约定恢复
// - PERSIST-01-AC3 工具执行到一半杀 App：横幅提示结果未知；确认前不确认；确认后不重跑
// - PERSIST-01-AC4 引擎崩溃（退出码 70）：App 存活、可重启，重启后不重复执行已完成的调用
//
// 真引擎 L4（真进程 / 模拟器）按任务约定留 T22；本文件覆盖 App 侧状态机与
// 可执行的 L2 行为，报告逐条标注 L4 缺口。

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/ask_ai.dart';
import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/engine_control.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/unknown_results.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:dsh_app/ui/chat/widgets/unknown_results_banner.dart';
import 'package:dsh_app/ui/engine/engine_screen.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../chat/support/harness.dart';
import '../../safe_mode/support.dart';
import '../../shell/golden_harness.dart';

// ── Fakes ──────────────────────────────────────────────────────────────────

/// A local runtime that can be stopped and started while the app stays up.
class _Runtime extends LocalRuntimeController {
  _Runtime(this.initial);
  final LocalRuntimeState initial;
  final calls = <String>[];

  @override
  LocalRuntimeState build() => initial;

  @override
  Future<void> stop() async {
    calls.add('stop');
    state = LocalRuntimeState(
      loaded: true,
      status: RuntimeStatus(
        phase: RuntimePhase.installed,
        installedVersion: initial.status.installedVersion,
        bundledVersion: initial.status.bundledVersion,
      ),
    );
  }

  @override
  Future<void> start() async {
    calls.add('start');
    state = LocalRuntimeState(
      loaded: true,
      status: RuntimeStatus(
        phase: RuntimePhase.running,
        installedVersion: initial.status.installedVersion,
        bundledVersion: initial.status.bundledVersion,
        baseUrl: 'http://127.0.0.1:3080',
        token: 'synthetic-persist-token',
      ),
    );
  }
}

/// The crash card's retry must really bring a stopped engine back.
class _CrashRuntime extends RecordingRuntime {
  _CrashRuntime(super.initial);

  @override
  Future<void> start() async {
    starts.add('start');
    state = LocalRuntimeState(
      loaded: true,
      status: const RuntimeStatus(
        phase: RuntimePhase.running,
        installedVersion: 'test-runtime',
        bundledVersion: 'test-runtime',
        baseUrl: 'http://127.0.0.1:3080',
        token: 'synthetic-persist-token',
      ),
    );
  }
}

class _Chat extends ChatController {
  _Chat(super.sessionId);
  @override
  ChatState build() => const ChatState(loading: false);
}

// ── Fixtures ───────────────────────────────────────────────────────────────

final _fixture = jsonDecode(
  File('../packages/dsh_client/test/fixtures/lifecycle-real-unknown.json').readAsStringSync(),
) as Map<String, dynamic>;
final _session = _fixture['sessionId'] as String;
Map<String, dynamic> _state(String key) => jsonDecode(jsonEncode(_fixture[key])) as Map<String, dynamic>;

LocalRuntimeState _running() => LocalRuntimeState(
  loaded: true,
  status: const RuntimeStatus(
    phase: RuntimePhase.running,
    installedVersion: 'test-runtime',
    bundledVersion: 'test-runtime',
    baseUrl: 'http://127.0.0.1:3080',
    token: 'synthetic-persist-token',
  ),
);

void main() {
  setUpAll(loadTestFonts);
  setUp(() {
    AppLocale.use(AppLocale.zhCN);
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() => AppLocale.use(AppLocale.zhCN));

  Future<void> waitFor(WidgetTester tester, Finder finder, {String? reason}) async {
    for (var i = 0; i < 60 && finder.evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(finder, findsWidgets, reason: reason);
  }

  testWidgets('PERSIST-01_relaunch_keeps_conversation', (tester) async {
    SharedPreferences.setMockInitialValues({
      'last_session_selection': jsonEncode({'host': 'local:local', 'sessionId': 's1'}),
    });
    final harness = ChatHarness(
      session: null,
      restoreSelection: true,
      states: {
        's1': const ChatState(
          loading: false,
          items: [AssistantChatItem(id: 'a1', seq: 1, text: '上次的回复', reasoning: '')],
        ),
      },
    );
    usePhoneView(tester);
    mockClipboard(tester);
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    for (var i = 0; i < 40 && find.text('上次的回复').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(find.text('上次的回复'), findsOneWidget, reason: '重开时恢复上次的会话与消息');

    // 仍可继续对话。
    await tester.enterText(find.byType(TextField), '继续聊');
    await tester.pump(); // the send key enables with the text
    await tester.tap(find.byIcon(AppIcons.send));
    await pumpFrames(tester);
    expect(harness.controllers['s1']!.sent, ['继续聊']);
  });

  testWidgets('PERSIST-01_engine_auto_starts_after_relaunch', (tester) async {
    final runtime = _Runtime(
      const LocalRuntimeState(
        loaded: true,
        status: RuntimeStatus(
          phase: RuntimePhase.installed,
          installedVersion: 'test-runtime',
          bundledVersion: 'test-runtime',
        ),
      ),
    );
    final container = ProviderContainer(overrides: [localRuntimeProvider.overrideWith(() => runtime)]);
    addTearDown(container.dispose);

    final status = container.read(localRuntimeProvider).status;
    expect(EngineControl.shouldAutoStart(status), isTrue, reason: '正常退出/重开应自动启动本机引擎');
    await EngineControl.ensureStarted(container);
    expect(runtime.calls, ['start']);
    expect(container.read(localRuntimeProvider).status.phase, RuntimePhase.running);
  });

  testWidgets('PERSIST-01_engine_restart_keeps_conversation_and_draft', (tester) async {
    final runtime = _Runtime(_running());
    final harness = ChatHarness(
      session: 's1',
      runtime: () => runtime,
      states: {
        's1': const ChatState(
          loading: false,
          items: [AssistantChatItem(id: 'a1', seq: 1, text: '重启前的回复', reasoning: '')],
        ),
      },
    )..picker.images = [DraftAttachment.sniff('cat.png', tinyPng)];
    usePhoneView(tester);
    mockClipboard(tester);
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await pumpFrames(tester);
    expect(find.text('重启前的回复'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('添加图片或文件'));
    await pumpFrames(tester);
    await tester.tap(find.text('相册'));
    await pumpFrames(tester);
    await tester.enterText(find.byType(TextField), '引擎重启时还没发的草稿');

    final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
    expect(await EngineControl.restart(container), isTrue);
    await tester.pump();
    expect(runtime.calls, ['stop', 'start'], reason: '先停后起，App 不重启');
    expect(container.read(localRuntimeProvider).status.phase, RuntimePhase.running);

    expect(find.text('重启前的回复'), findsOneWidget, reason: '原会话仍可继续');
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '引擎重启时还没发的草稿');
    expect(find.byType(ComposerTray), findsOneWidget, reason: '未发送附件按 D4-07 约定保留');
  });

  testWidgets('PERSIST-01_unknown_result_blocks_reexecution', (tester) async {
    HttpOverrides.global = null;
    final requests = <(String, String, String)>[];
    var acknowledged = false;
    late HttpServer server;
    late DshClient client;
    await tester.runAsync(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final body = await utf8.decodeStream(request);
        requests.add((request.method, request.uri.path, body));
        if (request.method == 'POST') acknowledged = true;
        final value = _state(acknowledged ? 'acknowledged' : 'unknown');
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(value));
        await request.response.close();
      });
      client = DshClient(DshConnection(Uri.parse('http://127.0.0.1:${server.port}')));
    });
    var closed = false;
    addTearDown(() async {
      if (closed) return;
      await tester.runAsync(() async {
        await client.close();
        await server.close(force: true);
      });
    });
    final connection = HostConnection(client: client, label: 'test', isLocal: true);
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(
        Scaffold(body: UnknownResultsBanner(sessionId: _session)),
        overrides: [
          activeConnectionProvider.overrideWithValue(AsyncData<HostConnection?>(connection)),
          durableCallsHostProvider.overrideWithValue(true),
          chatProvider.overrideWith2(_Chat.new),
          askAiAvailableProvider.overrideWithValue(false),
        ],
      ),
    );
    await waitFor(tester, find.text(appL10n.harmonyUnknownResults), reason: '结果未知横幅');
    expect(requests.map((r) => r.$1), ['GET'], reason: '只读状态，不确认、不重跑');

    await tester.tap(find.text(appL10n.harmonyUnknownResultsReview));
    await tester.pumpAndSettle();
    await tester.tap(find.text(appL10n.harmonyUnknownResultsContinue));
    await tester.pumpAndSettle();
    List<(String, String, String)> posts() => requests.where((r) => r.$1 == 'POST').toList();
    for (var i = 0; i < 60 && posts().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    for (var i = 0; i < 60 && find.text(appL10n.harmonyUnknownResults).evaluate().isNotEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(find.text(appL10n.harmonyUnknownResults), findsNothing, reason: '确认后横幅应消失');

    expect(posts(), hasLength(1), reason: '确认只发生一次');
    final decoded = jsonDecode(posts().single.$3) as Map<String, dynamic>;
    expect(decoded['operation'], 'acknowledgeUnknown');
    expect(decoded['sessionId'], _session);
    // 没有任何“再执行工具”的请求：这条未知调用不会重跑。
    for (final (_, path, _) in requests) {
      expect(path, isNot(contains('tool')));
      expect(path, isNot(contains('prompt')));
      expect(path, isNot(contains('execute')));
    }
    expect(tester.takeException(), isNull);

    // The real client keeps its HTTP connection pooled; close it inside the
    // test so its keep-alive timer does not outlive the widget tree.
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      closed = true;
      await client.close();
      await server.close(force: true);
    });
    await tester.pump(const Duration(seconds: 16));
  });

  testWidgets('PERSIST-01_engine_crash_recoverable', (tester) async {
    final failure = RuntimeFailure(
      kind: FailureKind.crashedLate,
      at: DateTime(2026, 10, 24, 15),
      exitCode: 70,
      summary: 'fatal uncaught exception: synthetic crash',
    );
    final runtime = _CrashRuntime(
      LocalRuntimeState(
        loaded: true,
        status: RuntimeStatus(
          phase: RuntimePhase.error,
          installedVersion: 'test-runtime',
          bundledVersion: 'test-runtime',
          failure: failure,
          mainFailure: failure,
        ),
      ),
    );
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        overrides: [
          localRuntimeProvider.overrideWith(() => runtime),
          runtimeBridgeProvider.overrideWithValue(FakeBridge()),
          localRuntimeLogsProvider.overrideWithBuild((ref, notifier) => const []),
          settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
        ],
        home: const EngineScreen(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    // App 存活：崩溃卡片说明原因并给出重试。
    expect(find.text(appL10n.phoneFailureCrashedLate), findsOneWidget);
    expect(find.text(appL10n.commonRetry), findsWidgets);
    expect(tester.takeException(), isNull);

    // crashedLate 的主按钮是「进入安全模式」；「重试」是留在卡片上的重启入口。
    await tester.tap(find.widgetWithText(OutlinedButton, appL10n.commonRetry));
    await tester.pumpAndSettle();
    expect(runtime.starts, ['start'], reason: '可重启，且只请求一次启动');
    expect(find.text(appL10n.phoneFailureCrashedLate), findsNothing);
    expect(find.byType(EngineScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
