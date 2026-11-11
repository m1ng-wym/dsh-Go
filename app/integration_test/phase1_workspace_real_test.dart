// T31 · L4-Real: the real engine workspace and the 文件 UI.
//
// One real opencode-go turn (`deepseek-v4.1-flash`, thinking `max`) writes
// `notes/launch.md` in the phone's engine workspace, counts it with bash and
// reads it back; the transcript, the workspace file on disk, the 文件 page and
// its text preview are then asserted. A second conversation in a second
// workspace proves the file list is isolated per workspace (D4-05-AC3).
//
// The real key reaches the app only through the T25 loopback credential broker:
//
//   cd app && flutter test --no-pub integration_test/phase1_workspace_real_test.dart \
//     -d <simulator-udid> \
//     --dart-define=E2E_BROKER_URL=http://127.0.0.1:PORT \
//     --dart-define=E2E_BROKER_TOKEN=<64 hex>
//
// Normally started by `scripts/e2e/ios/run_workspace_real.sh` (broker, clean
// install, log, screenshots). Missing key/network/tool calls are failures,
// never skips; a timeout fails the run.

import 'dart:io';
import 'dart:math' as math;

import 'package:dsh_app/app.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/runtime/local_paths.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/secrets/secure_storage.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/locale_state.dart';
import 'package:dsh_app/state/providers_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/chat/chat_list.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/widgets/tool_row.dart';
import 'package:dsh_app/ui/chat/widgets/turn_process.dart';
import 'package:dsh_app/ui/files/files_page.dart';
import 'package:dsh_app/ui/onboarding/connect_page.dart';
import 'package:dsh_app/ui/onboarding/welcome_page.dart';
import 'package:dsh_app/ui/session/workspace_files.dart' show FilePreviewPage;
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart' show AssistantChatItem, ToolChatItem, ToolStatus;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/e2e_env.dart';
import 'support/real_provider.dart';

const String _workspaceRelPath = 'notes/launch.md';
const String _prompt =
    '请在工作区目录创建 notes/launch.md，写入 5 条上线检查（每行一条，以 - 开头）；'
    '然后用 bash 统计行数，并读回文件第一行。完成后告诉我结果。\n'
    '请严格按顺序调用工具，不要跳过任何一步：\n'
    '1. write 工具写入 notes/launch.md（正好 5 行，每行以 "- " 开头）；\n'
    '2. bash 工具执行 wc -l notes/launch.md；\n'
    '3. read 工具读取 notes/launch.md 的第一行。\n'
    '最后用一句话总结：文件行数、第一行内容。';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('T31_L4_real_workspace_files_preview_and_workspace_isolation', (tester) async {
    WidgetController.hitTestWarningShouldBeFatal = true;
    _step('preconditions: broker defines, real paths, clean first launch');
    E2eConfig.requireBroker();
    await LocalPaths.load();
    expect(LocalPaths.workspace, startsWith('/'), reason: 'the engine workspace path was not resolved');
    await _resetDeviceState();
    runApp(const ProviderScope(child: DshApp()));

    await _waitFor(
      tester,
      'the app reaches a real first screen',
      () =>
          find.byType(WelcomePage).evaluate().isNotEmpty ||
          find.byType(ConnectPage).evaluate().isNotEmpty ||
          find.byType(HomeShell).evaluate().isNotEmpty,
      timeout: const Duration(minutes: 3),
    );
    final container = _container(tester);

    _step('first run: onboarding chooses the local engine');
    await _finishOnboarding(tester);
    await _waitFor(
      tester,
      'home shell after onboarding',
      () => find.byType(HomeShell).evaluate().isNotEmpty,
      timeout: const Duration(minutes: 3),
    );

    _step('local engine installs and reaches running');
    await _waitForRuntimeRunning(tester, container);

    _step('real provider: key over loopback, opencode-go route, model catalog, thinking max');
    final real = await createRealProvider(tester, container);
    _log('real provider ready: $real');

    _step('real turn: write notes/launch.md, bash wc -l, read the first line');
    if (container.read(currentSessionProvider) != null) {
      container.read(currentSessionProvider.notifier).select(null);
      await tester.pump();
    }
    final sessionId = await _sendFromComposer(tester, container, _prompt);
    expect(container.read(currentSessionProvider), sessionId, reason: 'the first send did not select its session');

    final file = File('${LocalPaths.workspace}/$_workspaceRelPath');
    if (file.existsSync()) file.deleteSync();
    expect(file.existsSync(), isFalse, reason: 'notes/launch.md existed before the real turn');

    final turn = await _waitForRealTurn(tester, container, sessionId);
    final chat = turn.chat;
    expect(chat.running, isFalse, reason: 'the real turn never ended');
    expect(chat.error, isNull, reason: 'the real turn failed: ${chat.error}');
    expect(chat.pending, isEmpty, reason: 'the sent prompt never settled');
    _log('turn ended after ${turn.elapsed.inSeconds}s; stream observations=${turn.streamingPrefixes.length}; '
        'approvals=${turn.approvals}');

    // D3-02: a real stream, not one final blob.
    expect(
      turn.streamingPrefixes.length,
      greaterThanOrEqualTo(2),
      reason: 'the real reply did not stream as growing assistant prefixes '
          '(${turn.streamingPrefixes.length} observed)',
    );
    expect(
      turn.streamingPrefixes.any((text) => text.length < turn.finalText.length),
      isTrue,
      reason: 'no partial prefix preceded the final answer',
    );

    // At least one real tool call succeeded, and the file task actually ran.
    final tools = chat.items.whereType<ToolChatItem>().toList();
    final succeeded = tools.where((item) => item.status == ToolStatus.succeeded).toList();
    expect(tools, isNotEmpty, reason: 'the real turn produced no tool row');
    expect(succeeded, isNotEmpty, reason: 'no tool row succeeded: ${_toolSummary(tools)}');
    _log('tool calls: ${_toolSummary(tools)}');

    await _waitFor(
      tester,
      'the engine workspace file on disk',
      () => file.existsSync(),
      timeout: const Duration(minutes: 2),
    );
    final content = file.readAsStringSync();
    final checklist = content
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    expect(checklist.length, 5, reason: 'notes/launch.md must hold exactly 5 checklist lines; got:\n$content');
    expect(
      checklist.every((line) => line.startsWith('- ')),
      isTrue,
      reason: 'every checklist line must start with "- "; got:\n$content',
    );
    final firstLine = checklist.first;
    final firstLineText = firstLine.replaceFirst(RegExp(r'^-\s*'), '');
    // What the Markdown preview renders: inline markers are gone from the text.
    final previewSnippet = firstLineText.replaceAll(RegExp(r'[*_`#>\[\]()]'), '').trim();
    _log('workspace file: ${file.path} (${content.length} chars; the preview shows the file byte size)');
    _log('workspace file content:\n$content');

    // bash wc -l ran and its result is in the transcript.
    final wcTools = succeeded
        .where((item) => item.name == 'bash' && item.arguments.contains('wc'))
        .toList();
    expect(wcTools, isNotEmpty, reason: 'no successful bash wc -l call: ${_toolSummary(tools)}');
    final wcTool = wcTools.last;
    expect(wcTool.resultText.trim(), isNotEmpty, reason: 'the bash wc -l call returned no result');
    _log('wc result: ${_oneLine(wcTool.resultText)}');

    // The first line was read back: the read tool, or a bash head/cat result.
    final readTools = succeeded
        .where((item) => item.name == 'read' && item.arguments.contains('launch.md'))
        .toList();
    final readTool = readTools.isEmpty ? null : readTools.last;
    final headTool = succeeded
        .where((item) => item.name == 'bash' && item != wcTool && item.resultText.contains(firstLineText))
        .firstOrNull;
    expect(
      readTool != null || headTool != null,
      isTrue,
      reason: 'the model never read the first line back (read tool or bash output); tools: ${_toolSummary(tools)}',
    );
    final readBackTool = readTool ?? headTool!;
    if (readTool != null) {
      expect(
        readTool.resultText.contains(firstLineText),
        isTrue,
        reason: 'the read tool did not return the first line "$firstLineText"',
      );
    }
    _log('read-back tool: ${readBackTool.name}');

    final finalSnippet = _uiSnippet(turn.finalText);
    await _waitFor(
      tester,
      'the final real answer in the chat UI',
      () => find.textContaining(finalSnippet, findRichText: true).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 30),
    );
    _log('final answer visible in the chat; snippet="$finalSnippet"');

    // Visible transcript: expand any folded process and the relevant tool rows.
    await _revealToolRows(tester, sessionId, container, wcTool: wcTool, readTool: readBackTool);

    final wcOut = _firstNonEmptyLine(wcTool.resultText);
    await _waitFor(
      tester,
      'the wc -l result in the transcript',
      () => find.textContaining(wcOut, findRichText: true).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 30),
    );
    await _waitFor(
      tester,
      'the read-back first line in the transcript',
      () => find.textContaining(firstLineText, findRichText: true).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 30),
    );
    _log('transcript shows tool rows, wc output and the first line');

    _step('D4-05: open 文件 from 全部功能, list notes/, preview launch.md');
    await _openFilesFromFeatures(tester);
    await _waitFor(
      tester,
      'the workspace root listing',
      () => find.text('notes').evaluate().isNotEmpty,
      timeout: const Duration(minutes: 2),
    );
    _log('files page lists the workspace root (notes/ visible)');
    await _holdForScreenshot(tester, 'files');
    await _tapFirst(tester, find.text('notes'), 'notes folder');
    await _waitFor(
      tester,
      'launch.md in notes/',
      () => find.text('launch.md').evaluate().isNotEmpty,
      timeout: const Duration(minutes: 1),
    );
    await _tapFirst(tester, find.text('launch.md'), 'launch.md row');
    await _waitFor(
      tester,
      'the text preview page',
      () => find.byType(FilePreviewPage).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 60),
    );
    await _waitFor(
      tester,
      'the previewed checklist content',
      () => find.textContaining(previewSnippet, findRichText: true).evaluate().isNotEmpty,
      timeout: const Duration(minutes: 1),
    );
    expect(find.textContaining('launch.md', findRichText: true), findsWidgets,
        reason: 'the preview page does not name the file');
    _log('preview shows "$previewSnippet"');
    await _holdForScreenshot(tester, 'preview');

    _step('leave the preview; create a second workspace and conversation');
    // 文件 → 全部功能 → chat, one route at a time with the transitions settled.
    final navigator = Navigator.of(tester.element(find.byType(FilePreviewPage)));
    navigator.pop();
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await tester.pump();
    navigator.pop();
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await tester.pump();
    navigator.pop();
    await Future<void>.delayed(const Duration(milliseconds: 900));
    await tester.pump();
    await _waitFor(
      tester,
      'back on the chat after the preview',
      () => find.byType(HomeShell).evaluate().isNotEmpty && find.byType(Composer).evaluate().isNotEmpty,
      timeout: const Duration(minutes: 1),
    );

    final isolationDir = Directory('${LocalPaths.workspace}/isolation-b');
    if (isolationDir.existsSync()) isolationDir.deleteSync(recursive: true);
    await isolationDir.create(recursive: true);
    var workspace = container
        .read(workspacesProvider)
        .workspaces
        .where((candidate) => candidate.path == isolationDir.path)
        .firstOrNull;
    workspace ??= await container.read(workspacesProvider.notifier).add(isolationDir.path);
    await container.read(workspacePrefsProvider.notifier).select(workspace.workspaceId);
    final secondSession = await container.read(sessionsProvider.notifier).create();
    container.read(currentSessionProvider.notifier).select(secondSession);
    await tester.pump();
    await _waitFor(
      tester,
      'the second conversation selected',
      () => container.read(currentSessionProvider) == secondSession,
      timeout: const Duration(seconds: 60),
    );
    _log('second conversation $secondSession in workspace ${workspace.path}');
    await _waitFor(
      tester,
      'the second conversation composer',
      () => find.byType(Composer).evaluate().isNotEmpty,
      timeout: const Duration(minutes: 1),
    );

    _step('D4-05-AC3: the second workspace list does not contain the first file');
    await _openFilesFromFeatures(tester);
    await _waitFor(
      tester,
      'the second workspace listing (empty)',
      () => find.text(appL10n.botsEmptyFolder).evaluate().isNotEmpty,
      timeout: const Duration(minutes: 2),
    );
    expect(find.text('notes'), findsNothing,
        reason: 'workspace isolation: the second workspace lists session A\'s notes/ folder');
    expect(find.text('launch.md'), findsNothing,
        reason: 'workspace isolation: the second workspace lists session A\'s launch.md');
    _log('isolation verified: ${workspace.path} lists no entry from ${LocalPaths.workspace}');
    await _holdForScreenshot(tester, 'isolation');

    _step('done: real workspace + 文件 UI + isolation');
    expect(container.read(chatProvider(secondSession)).error, isNull);
  });
}

// ---------------------------------------------------------------------------
// Real turn

class _RealTurn {
  const _RealTurn({
    required this.chat,
    required this.finalText,
    required this.streamingPrefixes,
    required this.approvals,
    required this.elapsed,
  });

  final ChatState chat;
  final String finalText;
  final Set<String> streamingPrefixes;
  final int approvals;
  final Duration elapsed;
}

Future<_RealTurn> _waitForRealTurn(
  WidgetTester tester,
  ProviderContainer container,
  String sessionId,
) async {
  final streamingPrefixes = <String>{};
  // Polling can miss short-lived deltas; every state notification is recorded,
  // the same way phase1_test proves a growing stream (D3-02).
  final subscription = container.listen<ChatState>(chatProvider(sessionId), (previous, next) {
    for (final item in next.items.whereType<AssistantChatItem>()) {
      if (item.streaming && item.text.trim().isNotEmpty) streamingPrefixes.add(item.text);
    }
  }, fireImmediately: true);
  final clock = Stopwatch()..start();
  var approvals = 0;
  ChatState chat = container.read(chatProvider(sessionId));
  try {
    while (clock.elapsed < const Duration(minutes: 8)) {
      chat = container.read(chatProvider(sessionId));
      if (chat.error != null) {
        _dumpTexts(tester);
        fail('the real turn failed: ${chat.error}');
      }
    if (chat.openApproval != null) {
      approvals++;
      expect(approvals, lessThanOrEqualTo(4), reason: 'the real model keeps asking for approvals; stopping');
      _log('approval requested (#$approvals); allowing once');
      await _tapFirst(tester, find.text(appL10n.chatAllowOnce), 'allow once');
      continue;
    }
      final finalItems = chat.items
          .whereType<AssistantChatItem>()
          .where((item) => !item.streaming && item.text.trim().isNotEmpty)
          .toList();
      if (!chat.running && finalItems.isNotEmpty) {
        final text = finalItems.map((item) => item.text.trim()).join('\n').trim();
        return _RealTurn(
          chat: chat,
          finalText: text,
          streamingPrefixes: streamingPrefixes,
          approvals: approvals,
          elapsed: clock.elapsed,
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    }
    _dumpTexts(tester);
    fail(
      'the real turn did not end within 8 minutes '
      '(running=${chat.running}, tools=${_toolSummary(chat.items.whereType<ToolChatItem>().toList())})',
    );
  } finally {
    subscription.close();
  }
}

Future<String> _sendFromComposer(WidgetTester tester, ProviderContainer container, String prompt) async {
  await _waitFor(
    tester,
    'the chat composer',
    () => find.byType(Composer).evaluate().isNotEmpty,
    timeout: const Duration(minutes: 1),
  );
  final field = find.descendant(of: find.byType(Composer), matching: find.byType(TextField));
  expect(field, findsOneWidget, reason: 'the composer has no text field');
  for (var attempt = 0; attempt < 3; attempt++) {
    await tester.enterText(field, prompt);
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await tester.pump();
    if (tester.widget<TextField>(field).controller?.text == prompt) break;
    _log('composer draft was reset by the new-chat switch (attempt ${attempt + 1}), re-entering');
  }
  expect(tester.widget<TextField>(field).controller?.text, prompt, reason: 'the composer keeps clearing the prompt');

  final send = find.descendant(of: find.byType(Composer), matching: find.byIcon(AppIcons.send));
  await _waitFor(
    tester,
    'the send key enabled after typing',
    () {
      final composers = tester.widgetList<Composer>(find.byType(Composer)).toList();
      return send.evaluate().isNotEmpty &&
          composers.isNotEmpty &&
          composers.every((composer) => composer.connected && composer.sessionReady && !composer.busy);
    },
    timeout: const Duration(seconds: 90),
  );
  await _tapFirst(tester, send, 'send');
  await _waitFor(
    tester,
    'a session created by the first send',
    () => container.read(currentSessionProvider) != null,
    timeout: const Duration(seconds: 90),
  );
  final sessionId = container.read(currentSessionProvider)!;
  _log('session created: $sessionId');
  return sessionId;
}

Future<void> _revealToolRows(
  WidgetTester tester,
  String sessionId,
  ProviderContainer container, {
  required ToolChatItem wcTool,
  required ToolChatItem readTool,
}) async {
  // A finished turn folds its process open first, then collapses to a summary.
  await Future<void>.delayed(const Duration(seconds: 4));
  await tester.pump();

  final chatList = find.byType(ChatList);
  expect(chatList, findsOneWidget, reason: 'the chat list is not on screen');
  // The vertical chat scroller; nested horizontal rows (change chips, …) are
  // not what must move here.
  final scrollable = find
      .descendant(
        of: chatList,
        matching: find.byWidgetPredicate((widget) => widget is Scrollable && widget.axisDirection == AxisDirection.down),
      )
      .first;

  // The conversation is centre-anchored; jump to its oldest content so the
  // completed turn's process row (folded above the answer) is built.
  final scrollState = tester.state<ScrollableState>(scrollable);
  scrollState.position.jumpTo(scrollState.position.minScrollExtent);
  await Future<void>.delayed(const Duration(milliseconds: 500));
  await tester.pump();
  _log('chat scroll after jump: '
      'pixels=${scrollState.position.pixels.toStringAsFixed(1)} '
      'min=${scrollState.position.minScrollExtent.toStringAsFixed(1)} '
      'max=${scrollState.position.maxScrollExtent.toStringAsFixed(1)} '
      'turnProcess=${find.byType(TurnProcess).evaluate().length} '
      'toolRows=${find.byType(ToolRow).evaluate().length}');

  Future<void> nudge() async {
    await tester.drag(scrollable, const Offset(0, 300));
    await Future<void>.delayed(const Duration(milliseconds: 350));
    await tester.pump();
  }

  Future<void> tapNow(Finder finder, String what) async {
    if (finder.evaluate().isEmpty) {
      _dumpTexts(tester);
      fail('cannot tap $what: not found');
    }
    try {
      await tester.ensureVisible(finder);
      await tester.pump();
      await tester.tap(finder, warnIfMissed: false);
    } on StateError {
      // The lazy list rebuilt between finding the row and hitting it; the
      // caller scrolls and retries.
      _log('$what moved during the tap; retrying');
    }
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 350));
    await tester.pump();
  }

  // The answer and the turn footnote fill the viewport; the folded process (or
  // plain tool rows) sits above it, so scroll up until it is built, then open
  // it. A short delay after the scroll lets the list settle before the tap.
  var hasToolRows = false;
  for (var attempt = 0; attempt < 12; attempt++) {
    if (find.byType(ToolRow).evaluate().isNotEmpty) {
      hasToolRows = true;
      break;
    }
    final process = find.byType(TurnProcess);
    _log('tool row search #$attempt: turnProcess=${process.evaluate().length} '
        'toolRows=${find.byType(ToolRow).evaluate().length}');
    if (process.evaluate().isNotEmpty) {
      await tapNow(process.last, 'the folded turn process');
      if (find.byType(ToolRow).evaluate().isNotEmpty) {
        hasToolRows = true;
        break;
      }
    }
    await nudge();
  }
  expect(hasToolRows, isTrue, reason: 'the chat UI exposes no expandable tool row for the real turn');

  Future<void> expand(ToolChatItem target, String what) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final rows = tester.widgetList<ToolRow>(find.byType(ToolRow)).toList();
      final index = rows.indexWhere((row) => identical(row.item, target));
      if (index < 0) {
        await nudge();
        continue;
      }
      await tapNow(find.byType(ToolRow).at(index), what);
      if (find.byType(ToolRow).evaluate().isNotEmpty) return;
      await nudge();
    }
    fail('$what: its tool row is not in the transcript');
  }

  // The tool row defaults to collapsed; tap it so the result text is on screen.
  await expand(wcTool, 'the wc tool row');
  if (readTool != wcTool) await expand(readTool, 'the read-back tool row');
  await Future<void>.delayed(const Duration(milliseconds: 400));
  await tester.pump();
  expect(container.read(chatProvider(sessionId)).items.whereType<ToolChatItem>(), isNotEmpty);
}

// ---------------------------------------------------------------------------
// 文件 page from the app's own feature entry

Future<void> _openFilesFromFeatures(WidgetTester tester) async {
  await _waitFor(
    tester,
    'the chat menu key',
    () => find.byKey(const ValueKey('chat-menu')).evaluate().isNotEmpty,
    timeout: const Duration(seconds: 60),
  );
  await _tapFirst(tester, find.byKey(const ValueKey('chat-menu')), 'chat menu');
  await _waitFor(
    tester,
    'the 全部功能 entry in the drawer',
    () => find.byTooltip(appL10n.hubSettingsAllFeatures).evaluate().isNotEmpty,
    timeout: const Duration(seconds: 60),
  );
  await _tapFirst(tester, find.byTooltip(appL10n.hubSettingsAllFeatures), '全部功能');
  await _waitFor(
    tester,
    'the 文件 feature entry',
    () => find.text(appL10n.catalogFiles).evaluate().isNotEmpty,
    timeout: const Duration(seconds: 60),
  );
  await _tapFirst(tester, find.text(appL10n.catalogFiles).first, '文件');
  await _waitFor(
    tester,
    'the 文件 page',
    () => find.byType(WorkspaceFilesPage).evaluate().isNotEmpty,
    timeout: const Duration(seconds: 60),
  );
}

// ---------------------------------------------------------------------------
// Onboarding / engine (same production paths as phase1_test)

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(DshApp)), listen: false);

Future<void> _finishOnboarding(WidgetTester tester) async {
  if (find.byType(HomeShell).evaluate().isNotEmpty) return;
  if (find.byType(WelcomePage).evaluate().isNotEmpty) {
    await _tapFirst(tester, find.widgetWithText(FilledButton, appL10n.shellGetStarted), 'welcome 开始');
    await _waitFor(
      tester,
      'runtime choice',
      () => find.byKey(const ValueKey('runtime-option-local')).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 30),
    );
    await _tapFirst(tester, find.byKey(const ValueKey('runtime-option-local')), 'choose 本机');
    await _tapFirst(tester, find.widgetWithText(FilledButton, appL10n.commonContinue), 'runtime 继续');
  }
  if (find.byKey(const ValueKey('setup-appearance-card')).evaluate().isNotEmpty) {
    await _tapFirst(tester, find.widgetWithText(FilledButton, appL10n.commonContinue), 'appearance 继续');
  }
  await _waitFor(
    tester,
    'access step (or later)',
    () =>
        find.text(appL10n.accessSkip).evaluate().isNotEmpty ||
        find.byType(ConnectPage).evaluate().isNotEmpty ||
        find.byType(HomeShell).evaluate().isNotEmpty,
    timeout: const Duration(minutes: 2),
  );
  if (find.text(appL10n.accessSkip).evaluate().isNotEmpty) {
    await _tapFirst(tester, find.text(appL10n.accessSkip), 'access 跳过');
  }
  await _waitFor(
    tester,
    'connect step',
    () => find.byType(ConnectPage).evaluate().isNotEmpty || find.byType(HomeShell).evaluate().isNotEmpty,
    timeout: const Duration(minutes: 2),
  );
  if (find.byType(HomeShell).evaluate().isEmpty) {
    await _waitFor(
      tester,
      'connect choices',
      () => find.text(appL10n.shellSetUpLater).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 60),
    );
    await _tapFirst(tester, find.text(appL10n.shellSetUpLater), 'connect 稍后设置');
  }
  await _waitFor(
    tester,
    'home shell after onboarding',
    () => find.byType(HomeShell).evaluate().isNotEmpty,
    timeout: const Duration(minutes: 3),
  );
}

Future<void> _waitForRuntimeRunning(WidgetTester tester, ProviderContainer container) async {
  final status = await _waitForRuntimePhase(
    tester,
    container,
    (phase) => phase == RuntimePhase.installed || phase == RuntimePhase.running || phase == RuntimePhase.error,
  );
  expect(status.phase, isNot(RuntimePhase.error), reason: 'the runtime failed to install: ${status.error}');
  expect(status.installedVersion, isNotNull, reason: 'the runtime install reported no version');
  expect(status.installedVersion, status.bundledVersion, reason: 'the installed runtime is not the bundled one');
  if (status.phase != RuntimePhase.running) {
    await container.read(localRuntimeProvider.notifier).start();
  }
  final running = await _waitForRuntimePhase(
    tester,
    container,
    (phase) => phase == RuntimePhase.running,
  );
  expect(running.baseUrl, isNotNull, reason: 'the running engine has no base URL');
  expect(running.token, isNotNull, reason: 'the running engine has no token');
  await _waitFor(
    tester,
    'the app connects to the local engine',
    () => container.read(providerBackendProvider) != null,
    timeout: const Duration(minutes: 2),
  );
  _log('runtime running: ${running.installedVersion} dsh=${running.dshVersion} node=${running.nodeVersion}');
}

Future<RuntimeStatus> _waitForRuntimePhase(
  WidgetTester tester,
  ProviderContainer container,
  bool Function(RuntimePhase) done,
) async {
  final clock = Stopwatch()..start();
  const timeout = Duration(minutes: 3);
  while (clock.elapsed < timeout) {
    final state = container.read(localRuntimeProvider);
    if (state.loaded && done(state.status.phase)) return state.status;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pump();
  }
  final state = container.read(localRuntimeProvider);
  _dumpTexts(tester);
  fail('the engine never settled: phase=${state.status.phase.name} error=${state.status.error}');
}

// ---------------------------------------------------------------------------
// Device state, waiting, logging, screenshot hand-off

/// A predictable launch: no stored key/onboarding flags, Chinese UI. The
/// engine itself is not touched; the wrapper uninstalls the app first.
Future<void> _resetDeviceState() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.clear();
  await prefs.setString(AppLanguageController.prefsKey, AppLanguage.zh.name);
  try {
    final storage = const AppSecureStorage();
    final secrets = await storage.readAll();
    for (final key in secrets.keys) {
      await storage.delete(key: key);
    }
    _log('cleared ${secrets.length} secure-storage entries');
  } catch (error) {
    _log('secure storage could not be cleared (continuing): $error');
  }
  await AppLanguageController.load();
  AppLocale.use(AppLocale.zhCN);
  expect(AppLanguageController.initial, AppLanguage.zh, reason: 'the UI language could not be pinned to Chinese');
}

Future<void> _waitFor(
  WidgetTester tester,
  String what,
  bool Function() done, {
  required Duration timeout,
}) async {
  final clock = Stopwatch()..start();
  while (clock.elapsed < timeout) {
    if (done()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
  _dumpTexts(tester);
  fail('$what: timed out after ${timeout.inSeconds}s');
}

Future<void> _tapFirst(WidgetTester tester, Finder finder, String what) async {
  final target = finder.first;
  if (target.evaluate().isEmpty) {
    _dumpTexts(tester);
    fail('cannot tap $what: not found');
  }
  await Future<void>.delayed(const Duration(milliseconds: 400));
  await tester.pump();
  try {
    await tester.ensureVisible(target);
  } catch (_) {}
  await tester.pump(const Duration(milliseconds: 150));
  await tester.tap(target);
  await Future<void>.delayed(const Duration(milliseconds: 250));
  await tester.pump();
}

/// Tells the host wrapper to take a screenshot while this screen is up, then
/// stays on it long enough for the capture to land.
Future<void> _holdForScreenshot(WidgetTester tester, String name) async {
  _log('SCREENSHOT_READY $name');
  final clock = Stopwatch()..start();
  while (clock.elapsed < const Duration(seconds: 4)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
}

String _firstNonEmptyLine(String text) {
  for (final line in text.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty) return trimmed;
  }
  return '';
}

String _oneLine(String text) => text.trim().replaceAll(RegExp(r'\s+'), ' ');

String _uiSnippet(String text) {
  final first = text
      .split('\n')
      .map((line) => line.replaceAll(RegExp(r'[*_`#>\[\]()]'), '').trim())
      .firstWhere((line) => line.isNotEmpty, orElse: () => '');
  return first.length <= 16 ? first : first.substring(0, 16);
}

String _toolSummary(List<ToolChatItem> tools) => tools
    .map((item) => '${item.name}(${item.status.name})${item.resultText.trim().isEmpty ? '' : '=${_oneLine(item.resultText).substring(0, math.min(60, _oneLine(item.resultText).length))}'}')
    .join(' | ');

void _step(String message) => _log('=== $message');

void _log(String message) => debugPrint('[phase1-workspace-real] $message');

void _dumpTexts(WidgetTester tester) {
  try {
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data ?? text.textSpan?.toPlainText() ?? '')
        .where((text) => text.isNotEmpty)
        .take(40)
        .toList();
    _log('visible text widgets: $texts');
  } catch (error) {
    _log('could not dump widgets: $error');
  }
}
