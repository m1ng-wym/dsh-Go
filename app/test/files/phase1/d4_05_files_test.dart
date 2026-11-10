// T17 · D4-05 工作区文件浏览与预览（Phase 1 · Wave 3）
//
// AC 逐条对应：
// - D4-05-AC1 目录/文件列表（图标区分类型）+ 文本/图片/PDF 预览
// - D4-05-AC2 不存在 / 无权限 / 二进制不支持 → 明确提示，不崩溃、不白屏
// - D4-05-AC3 Agent 改动后文件页可见新内容；列表按会话（工作区）隔离
//
// 本文件的 L2 断言用户可见行为；iOS PDFKit 原生路径与真引擎 L4 留 T22。

import 'dart:io';

import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/workspace_state.dart';
import 'package:dsh_app/ui/chat/widgets/artifact_card.dart' show artifactIcon;
import 'package:dsh_app/ui/files/file_glyph.dart';
import 'package:dsh_app/ui/files/files_page.dart';
import 'package:dsh_app/ui/session/workspace_files.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../../chat/support/harness.dart';
import '../support/files_harness.dart';

const _files = MethodChannel('dsh/files');

/// Answers `dsh/files` as the iOS/Android side would: a guest path for local
/// files and page sizes / PNG bytes for PDFs.
void _mockFilesChannel(
  WidgetTester tester, {
  required String guestPath,
  List<Map<String, int>> pdfPages = const [
    {'width': 595, 'height': 842},
  ],
}) {
  final calls = <MethodCall>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_files, (call) async {
    calls.add(call);
    switch (call.method) {
      case 'resolveGuest':
        return guestPath;
      case 'pdfInfo':
        return pdfPages;
      case 'pdfPage':
        return tinyPng;
      case 'pdfClose':
        return null;
    }
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_files, null));
  fileChannelCalls = calls;
}

/// Calls seen by the native files channel (after the channel teardown runs).
List<MethodCall> fileChannelCalls = const [];

Future<void> _pumpFiles(WidgetTester tester, MemoryWorkspace ws, {String sessionId = 's1'}) async {
  usePhoneView(tester);
  await tester.pumpWidget(filesApp(WorkspaceFilesPage(sessionId: sessionId, now: () => DateTime(2026, 10, 24, 15)), ws));
  await pumpFrames(tester, 8);
}

Future<void> _openPreview(WidgetTester tester, MemoryWorkspace ws, String rel, {String sessionId = 's1'}) async {
  usePhoneView(tester);
  await tester.pumpWidget(filesApp(FilePreviewPage(sessionId: sessionId, path: '${ws.root}/$rel'), ws));
  await pumpFrames(tester, 10);
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => fileChannelCalls = const []);

  testWidgets('D4-05_workspace_lists_and_previews_text', (tester) async {
    final ws = MemoryWorkspace(
      root: '/root/work',
      files: {
        'README.md': '# 登录演示\n\n一个最小的 Flutter 登录页。\n\nflutter pub get\n',
        'lib/main.dart': 'void main() {}',
        'photo.png': 'png-bytes',
        'report.pdf': '%PDF-1.7',
      },
      folders: {'assets'},
    );
    await _pumpFiles(tester, ws);

    // 目录/文件都在，文件夹在前；图标按类型区分。
    for (final name in ['assets', 'lib', 'README.md', 'photo.png', 'report.pdf']) {
      expect(find.text(name), findsOneWidget, reason: name);
    }
    expect(find.byIcon(AppIcons.folderMark), findsWidgets);
    expect(find.byIcon(artifactIcon(ArtifactKind.image)), findsWidgets, reason: '图片有自己的图标');
    expect(find.byIcon(artifactIcon(ArtifactKind.pdf)), findsWidgets, reason: 'PDF 有自己的图标');
    expect(find.byType(FileGlyph), findsWidgets);

    // 点文本文件 → 文本预览（Markdown 渲染后的正文）。
    await tester.tap(find.text('README.md'));
    await pumpFrames(tester, 10);
    expect(find.byType(FilePreviewPage), findsOneWidget);
    expect(find.textContaining('登录演示'), findsWidgets);
    expect(find.textContaining('flutter pub get'), findsWidgets);
  });

  testWidgets('D4-05_previews_image_through_the_picture_viewer', (tester) async {
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('dsh-d4-05-img')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/chart.png');
    await tester.runAsync(() => file.writeAsBytes(tinyPng));
    _mockFilesChannel(tester, guestPath: file.path);

    final ws = sampleWorkspace()..write('out/chart.png', tinyPng);
    await _openPreview(tester, ws, 'out/chart.png');
    for (var i = 0; i < 20 && find.byType(Image).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(find.byType(Image), findsWidgets, reason: '图片应显示出来，而不是白屏');
    expect(fileChannelCalls.map((c) => c.method), contains('resolveGuest'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('D4-05_previews_pdf_page_by_page', (tester) async {
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('dsh-d4-05-pdf')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/report.pdf');
    await tester.runAsync(() => file.writeAsBytes(const [0x25, 0x50, 0x44, 0x46]));
    _mockFilesChannel(tester, guestPath: file.path);

    final ws = sampleWorkspace();
    await _openPreview(tester, ws, 'out/销售报告.pdf');
    for (var i = 0; i < 20 && find.text('共 1 页').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(find.text('共 1 页'), findsOneWidget);
    final methods = fileChannelCalls.map((c) => c.method).toList();
    expect(methods, containsAll(['resolveGuest', 'pdfInfo', 'pdfPage']));
    expect(
      fileChannelCalls.where((c) => c.method == 'pdfInfo').single.arguments,
      containsPair('path', file.path),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('D4-05_preview_missing_file_shows_error', (tester) async {
    final ws = sampleWorkspace();
    await _openPreview(tester, ws, 'nope.txt');
    expect(find.text('文件已经不在了'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('D4-05_preview_without_permission_shows_error', (tester) async {
    final ws = sampleWorkspace()..write('secret.txt', 'top secret');
    ws.failures['read secret.txt'] = const DshRemoteException(
      'workspace-file/not-allowed',
      'permission denied',
      {'path': 'secret.txt'},
    );
    await _openPreview(tester, ws, 'secret.txt');
    expect(find.text('没能打开'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('D4-05_preview_binary_and_unsupported_show_clear_notice', (tester) async {
    final ws = sampleWorkspace()..write('data.bin', 'a\u0000b');
    await _openPreview(tester, ws, 'data.bin');
    expect(find.text('无法预览'), findsOneWidget);
    expect(find.text('不是文本文件'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _openPreview(tester, ws, 'bundle.zip');
    expect(find.text('无法预览'), findsOneWidget);
    expect(find.text('压缩包 · ZIP'), findsOneWidget);
    expect(find.text('用其他应用打开'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('D4-05_workspace_refreshes_after_agent_write', (tester) async {
    final ws = sampleWorkspace();
    await _pumpFiles(tester, ws);
    expect(find.text('agent-note.md'), findsNothing);

    // Agent 写了一篇新文件：文件页不手动刷新也应看到。
    ws.write('agent-note.md', 'agent 写下的内容');
    await tester.pump(const Duration(milliseconds: 500));
    await pumpFrames(tester, 8);
    expect(find.text('agent-note.md'), findsOneWidget);

    await tester.tap(find.text('agent-note.md'));
    await pumpFrames(tester, 10);
    expect(find.textContaining('agent 写下的内容'), findsWidgets);
  });

  testWidgets('D4-05_workspace_list_is_isolated_per_session', (tester) async {
    final a = MemoryWorkspace(root: '/root/a', files: {'only-a.txt': 'A'});
    final b = MemoryWorkspace(root: '/root/b', files: {'only-b.txt': 'B'});
    List<Override> overrides() => [
      workspaceSourceProvider.overrideWith((ref, id) => id == 'a' ? a : b),
      workspaceRootProvider.overrideWith((ref, id) => id == 'a' ? a.root : b.root),
      activeConnectionProvider.overrideWithValue(AsyncData<HostConnection?>(fakeConnection)),
      artifactThumbnailProvider.overrideWith((ref, key) async => null),
    ];
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(WorkspaceFilesPage(sessionId: 'a', now: () => DateTime(2026, 10, 24, 15)), overrides: overrides()),
    );
    await pumpFrames(tester, 8);
    expect(find.text('only-a.txt'), findsOneWidget);
    expect(find.text('only-b.txt'), findsNothing);

    await tester.pumpWidget(
      testApp(WorkspaceFilesPage(sessionId: 'b', now: () => DateTime(2026, 10, 24, 15)), overrides: overrides()),
    );
    await pumpFrames(tester, 8);
    expect(find.text('only-b.txt'), findsOneWidget);
    expect(find.text('only-a.txt'), findsNothing);
  });
}
