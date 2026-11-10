// T17 · D4-07 附件上传（相册/文件 + 待发送条）（Phase 1 · Wave 3）
//
// AC 逐条对应：
// - D4-07-AC1 相册/文件 → 待发送条（可移除）→ 发送后消息带缩略图/文件卡
// - D4-07-AC2 超过 9 个或单文件超过 200 MB → 拒绝并提示，不静默截断
// - D4-07-AC3 未发送即杀 App → 草稿与待发送附件恢复（本实现选择“恢复”分支）
//
// 系统相册/文件选择器为人工 L5；本文件用 fake picker 覆盖 App 侧行为。

import 'dart:io';

import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/draft_store.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/harness.dart';

Future<void> _pumpScreen(WidgetTester tester, ChatHarness harness) async {
  usePhoneView(tester);
  mockClipboard(tester);
  await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
  await pumpFrames(tester);
}

Future<void> _attachFrom(WidgetTester tester, String label) async {
  await tester.tap(find.bySemanticsLabel('添加图片或文件'));
  await pumpFrames(tester);
  await tester.tap(find.text(label));
  await pumpFrames(tester);
}

DraftAttachment _textFile(String name, [String body = 'hello']) =>
    DraftAttachment.sniff(name, Uint8List.fromList(body.codeUnits));

/// A picker that ignores the requested room, as a misbehaving system picker
/// might: the composer must still reject the excess itself.
class _OverflowPicker extends FakePicker {
  _OverflowPicker(this.count);
  final int count;

  @override
  Future<List<DraftAttachment>> pickImages({required int limit}) async {
    calls.add('images:$limit');
    return [
      for (var i = 0; i < count; i++) DraftAttachment.sniff('pic$i.png', tinyPng),
    ];
  }
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('D4-07_attachment_tray_shows_selected_photos', (tester) async {
    final harness = ChatHarness(session: 's1')
      ..picker.images = [
        DraftAttachment.sniff('cat.png', tinyPng),
        DraftAttachment.sniff('dog.png', tinyPng),
      ];
    await _pumpScreen(tester, harness);
    await _attachFrom(tester, '相册');

    expect(harness.picker.calls, ['images:$maxAttachments']);
    final tray = tester.widget<ComposerTray>(find.byType(ComposerTray));
    expect([for (final a in tray.items) a.name], ['cat.png', 'dog.png']);
    expect(find.bySemanticsLabel('图片'), findsNWidgets(2));

    // 待发送条可移除。
    await tester.tap(find.bySemanticsLabel('移除「cat.png」'));
    await pumpFrames(tester);
    expect(find.byType(ComposerTray), findsOneWidget);
    expect(tester.widget<ComposerTray>(find.byType(ComposerTray)).items.single.name, 'dog.png');
  });

  testWidgets('D4-07_sent_message_shows_thumbnail_and_file_card', (tester) async {
    final harness = ChatHarness(session: 's1')
      ..picker.images = [DraftAttachment.sniff('cat.png', tinyPng)]
      ..picker.files = [_textFile('report.txt')];
    await _pumpScreen(tester, harness);
    await _attachFrom(tester, '相册');
    await _attachFrom(tester, '文件');

    await tester.enterText(find.byType(TextField), '看看这些');
    await tester.tap(find.byIcon(AppIcons.send));
    await pumpFrames(tester);

    final sent = harness.controllers['s1']!.sentAttachments.single;
    expect([for (final a in sent) a.name], ['cat.png', 'report.txt']);
    expect(find.byType(ComposerTray), findsNothing);

    // 发送后（乐观展示）的消息带缩略图与文件卡。
    harness.controllers['s1']!.emit(
      ChatState(
        loading: false,
        pending: [
          PendingPrompt(
            requestId: 'r1',
            text: '看看这些',
            time: DateTime(2026, 10, 23, 9),
            attachments: sent,
          ),
        ],
      ),
    );
    await pumpFrames(tester);
    expect(find.byType(SentAttachments), findsOneWidget);
    expect(find.text('看看这些'), findsOneWidget);
    expect(find.text('report.txt'), findsOneWidget);
    expect(find.bySemanticsLabel('图片'), findsWidgets);
  });

  testWidgets('D4-07_reject_more_than_nine_attachments', (tester) async {
    final picker = _OverflowPicker(10);
    final harness = ChatHarness(session: 's1', picker: picker);
    await _pumpScreen(tester, harness);
    await _attachFrom(tester, '相册');

    expect(harness.picker.calls, ['images:$maxAttachments']);
    expect(find.text('每条消息最多 $maxAttachments 个附件'), findsOneWidget);
    final tray = tester.widget<ComposerTray>(find.byType(ComposerTray));
    expect(tray.items, hasLength(maxAttachments), reason: '多出的 1 个被拒绝，而不是静默截断');
    expect([for (final a in tray.items) a.name], [for (var i = 0; i < maxAttachments; i++) 'pic$i.png']);

    // 已经 9 个时再选：直接拒绝并提示，不再打开选择器。
    await tester.pump(const Duration(seconds: 5)); // 让第一条提示自行消失，别挡住“＋”
    await tester.pumpAndSettle();
    await _attachFrom(tester, '相册');
    expect(picker.calls, ['images:$maxAttachments']);
    expect(find.text('每条消息最多 $maxAttachments 个附件'), findsWidgets);
    expect(tester.widget<ComposerTray>(find.byType(ComposerTray)).items, hasLength(maxAttachments));
  });

  testWidgets('D4-07_reject_file_over_200mb', (tester) async {
    final harness = ChatHarness(session: 's1')
      ..picker.files = [
        DraftAttachment(name: 'huge.zip', bytes: Uint8List(maxFileBytes + 1)),
        _textFile('ok.txt'),
      ];
    await _pumpScreen(tester, harness);
    await _attachFrom(tester, '文件');

    expect(find.textContaining('超过 200 MB'), findsOneWidget);
    final tray = tester.widget<ComposerTray>(find.byType(ComposerTray));
    expect([for (final a in tray.items) a.name], ['ok.txt'], reason: '超限文件被拒绝，正常文件保留');
  });

  testWidgets('D4-07_draft_attachments_survive_relaunch', (tester) async {
    final dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('dsh-d4-07-drafts')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    final rootOverride = draftAttachmentRootProvider.overrideWithValue(() async => dir);

    // 第一次启动：选图、打字、把草稿写盘。
    final first = ChatHarness(session: 's1', extra: [rootOverride])
      ..picker.images = [DraftAttachment.sniff('cat.png', tinyPng)];
    await _pumpScreen(tester, first);
    final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
    for (var i = 0; i < 20 && !container.read(draftStoreProvider).loaded; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(container.read(draftStoreProvider).loaded, isTrue, reason: 'saved drafts are read before saving');
    // No 400 ms pump between the pick and flush: the flush below owns the write.
    await tester.tap(find.bySemanticsLabel('添加图片或文件'));
    await pumpFrames(tester); // the ＋ sheet is up; nothing saved yet
    await tester.tap(find.text('相册'));
    await tester.pump(); // the pick lands and schedules its 400 ms save
    await tester.enterText(find.byType(TextField), '还没发出去的说明');
    await tester.runAsync(() => container.read(draftStoreProvider.notifier).flush());
    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    // 杀 App 后重开：草稿和待发送附件都回来。
    final second = ChatHarness(session: 's1', extra: [rootOverride]);
    usePhoneView(tester);
    mockClipboard(tester);
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: second.overrides));
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
      if (find.byType(ComposerTray).evaluate().isNotEmpty &&
          tester.widget<TextField>(find.byType(TextField)).controller!.text.isNotEmpty) {
        break;
      }
    }
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '还没发出去的说明');
    expect(find.byType(ComposerTray), findsOneWidget);
    final tray = tester.widget<ComposerTray>(find.byType(ComposerTray));
    expect(tray.items.single.name, 'cat.png');
    expect(tray.items.single.bytes, tinyPng);
    expect(tray.items.single.isImage, isTrue);
  });
}
