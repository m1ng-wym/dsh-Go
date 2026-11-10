// D3-19 · 消息操作（复制 / 分叉 / 重新回答 / 引用）（capability-spec.md#D3-19）
//
// D3-19-AC1: a reply's actions copy the exact text, offer share, and branch
//            into a new conversation while the source stays untouched.
// D3-19-AC2: 「重新回答」 is offered only for the conversation's last answer and
//            only when nothing is running/queued/streaming or attached; it
//            re-sends the prompt in a fork with a way back.
// D3-19-AC3: quoting a passage puts it above the composer and sends it with
//            the next message.

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/regenerate.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/widgets/quote_chip.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart' show SettingsTile;
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

const _answer = '是**超时重试**多发了一次请求。';

UserChatItem _user(int seq, String text) =>
    UserChatItem(seq: seq, time: DateTime(2026, 11, 10, 9), text: text, images: const [], files: const []);

AssistantChatItem _assistant(int seq, String text, {bool streaming = false}) => AssistantChatItem(
  id: 'a$seq',
  seq: seq,
  time: DateTime(2026, 11, 10, 9),
  text: text,
  reasoning: '',
  streaming: streaming,
);

ChatState _conversation() => ChatState(
  items: [_user(1, '帮我看看测试为什么失败'), _assistant(2, _answer)],
  title: '测试失败',
  loading: false,
);

ChatState _twoTurns() => ChatState(
  items: [
    _user(1, '第一个问题'),
    _assistant(2, '第一个回答'),
    _user(5, '第二个问题'),
    _assistant(6, '第二个回答'),
  ],
  loading: false,
);

Future<void> _pump(WidgetTester tester, ChatHarness harness) async {
  usePhoneView(tester);
  await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
  await pumpFrames(tester);
}

({List<String> copied}) _platform(WidgetTester tester) {
  final copied = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
    return null;
  });
  return (copied: copied);
}

void main() {
  testWidgets('D3-19_copy_and_fork_from_message', (tester) async {
    final platform = _platform(tester);
    final harness = ChatHarness(session: 's1', states: {'s1': _conversation()});
    await _pump(tester, harness);
    final chat = harness.controllers['s1']!;
    chat.branchPoints[2] = 7;
    chat.replyIds[2] = 'm2';
    chat.emit(_conversation());
    await pumpFrames(tester);

    expect(find.byTooltip('复制'), findsOneWidget, reason: 'D3-19-AC1: copy is on the reply row');
    expect(find.byTooltip('分享'), findsOneWidget, reason: 'D3-19-AC1: a share entry exists');
    expect(find.byTooltip('从这里分叉'), findsOneWidget);

    await tester.tap(find.byTooltip('复制'));
    await pumpFrames(tester, 2);
    expect(platform.copied, [_answer], reason: 'D3-19-AC1: the clipboard gets the reply text');

    final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
    expect(container.read(currentSessionProvider), 's1');
    await tester.tap(find.byTooltip('从这里分叉'));
    await pumpFrames(tester);
    expect(chat.branched, [2], reason: 'D3-19-AC1: branching starts from that reply');
    expect(container.read(currentSessionProvider), 'fork-session', reason: 'D3-19-AC1: the fork opens as a new conversation');
    expect(find.text('已在新对话中继续'), findsOneWidget);
    // The source conversation is untouched: its state still has the reply.
    expect(harness.controllers['s1']!.state.items.whereType<AssistantChatItem>().single.text, _answer);
    await tester.tap(find.text('返回原对话'));
    await pumpFrames(tester);
    expect(container.read(currentSessionProvider), 's1', reason: 'D3-19-AC1: the way back works');
    expect(tester.takeException(), isNull);
  });

  test('D3-19_regenerate_only_on_last_answer', () {
    final state = _twoTurns();
    final first = state.items.whereType<AssistantChatItem>().first;
    final last = state.items.whereType<AssistantChatItem>().last;
    expect(regenerablePrompt(state, first), isNull, reason: 'D3-19-AC2: an earlier answer cannot be regenerated');
    final prompt = regenerablePrompt(state, last);
    expect(prompt, isNotNull, reason: 'D3-19-AC2: the last answer can be regenerated');
    expect(prompt!.text, '第二个问题');

    // Gating: generating, queued messages, a live answer, or attached files.
    expect(
      regenerablePrompt(
        ChatState(items: state.items, loading: false, running: true),
        last,
      ),
      isNull,
      reason: 'D3-19-AC2: not while generating',
    );
    expect(
      regenerablePrompt(
        ChatState(
          items: state.items,
          loading: false,
          pending: [
            PendingPrompt(requestId: 'r', text: '排队', time: DateTime(2026, 11, 10, 9), mode: SendMode.queue),
          ],
        ),
        last,
      ),
      isNull,
      reason: 'D3-19-AC2: not with queued messages',
    );
    final streaming = AssistantChatItem(
      id: last.id,
      seq: last.seq,
      time: last.time,
      text: last.text,
      reasoning: '',
      streaming: true,
    );
    expect(
      regenerablePrompt(
        ChatState(items: [state.items[0], state.items[1], state.items[2], streaming], loading: false),
        streaming,
      ),
      isNull,
      reason: 'D3-19-AC2: not while the answer is still streaming',
    );
    final withFile = UserChatItem(
      seq: 5,
      time: DateTime(2026, 11, 10, 9),
      text: '第二个问题',
      images: const [],
      files: const [FileAttachment(name: 'notes.md', bytes: 3)],
    );
    expect(
      regenerablePrompt(ChatState(items: [state.items[0], state.items[1], withFile, last], loading: false), last),
      isNull,
      reason: 'D3-19-AC2: not when the prompt carried files',
    );
  });

  testWidgets('D3-19_regenerate_resends_in_fork', (tester) async {
    _platform(tester);
    final harness = ChatHarness(session: 's1', states: {'s1': _twoTurns()});
    await _pump(tester, harness);
    final chat = harness.controllers['s1']!;
    chat.branchPoints[6] = 12;
    chat.emit(_twoTurns());
    await pumpFrames(tester);

    expect(find.byTooltip('重新回答'), findsOneWidget, reason: 'D3-19-AC2: only the last answer offers it');
    await tester.tap(find.byTooltip('重新回答'));
    await pumpFrames(tester);

    expect(chat.edited, [5], reason: 'D3-19-AC2: the fork cuts just before that prompt');
    expect(find.text('已在新对话中重新回答'), findsOneWidget);
    final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
    expect(container.read(currentSessionProvider), 'fork-session');
    expect(
      harness.controllers['fork-session']!.sent,
      ['第二个问题'],
      reason: 'D3-19-AC2: the prompt is re-sent in the fork',
    );
    expect(harness.controllers['s1']!.state.items.whereType<AssistantChatItem>().last.text, '第二个回答');
    expect(tester.takeException(), isNull);
  });

  testWidgets('D3-19_quote_block_attached_to_message', (tester) async {
    _platform(tester);
    final harness = ChatHarness(session: 's1', states: {'s1': _conversation()});
    await _pump(tester, harness);

    await tester.longPress(find.textContaining('超时重试', findRichText: true).first);
    await pumpFrames(tester);
    await tester.tap(find.widgetWithText(SettingsTile, '引用'));
    await pumpFrames(tester);

    expect(find.byType(QuoteChip), findsOneWidget, reason: 'D3-19-AC3: the quote sits above the composer');
    expect(find.textContaining('超时重试'), findsWidgets);

    await tester.enterText(find.byType(TextField), '那是为什么？');
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.send));
    await pumpFrames(tester);

    final sent = harness.controllers['s1']!.sent.single;
    expect(sent, startsWith('> '), reason: 'D3-19-AC3: the quote travels in front of the message');
    expect(sent, contains('超时重试'));
    expect(sent, contains('那是为什么？'));
    expect(tester.takeException(), isNull);
  });
}
