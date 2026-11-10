// D3-08 · 工具行（分组摘要 / 展开参数结果 / 脱敏）（capability-spec.md#D3-08）
//
// D3-08-AC1: a tool call first shows as a running row; when it finishes the
//            row is verb + first string argument; opening it shows arguments
//            and result.
// D3-08-AC2: several calls in one finished turn fold into
//            「已完成 · N 次工具调用」, with the answer left outside.
// D3-08-AC3: a failed call is visibly an error and expands to the error text.
//
// 脱敏 here means the tool row never paints raw secrets differently from the
// rest of the app: tool arguments/results are rendered as text, and the
// secret-mask path is covered by the existing secret_mask suite. The rows use
// the real ChatController/transcript; only presentation state is scripted.

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';
import 'support/w2_client.dart';

Map<String, Object?> _call(int seq, String callId, String name, String arguments) =>
    w2Record(w2ToolCall(seq, callId, name, arguments));

Map<String, Object?> _result(int seq, String callId, String text, {bool error = false, Map<String, Object?>? failure}) =>
    w2Record(w2ToolResult(seq, callId, text, error: error, failure: failure));

Future<ChatState> _stateFor(WidgetTester tester, {required Map<String, Object?> snapshot}) async {
  final client = W2Client();
  late ChatState state;
  await tester.runAsync(() async {
    final container = await startW2Chat(client, snapshot: snapshot);
    addTearDown(() async {
      container.dispose();
      await client.events.close();
    });
    state = w2State(container);
  });
  return state;
}

Future<void> _pumpState(WidgetTester tester, ChatState state) async {
  usePhoneView(tester);
  mockClipboard(tester);
  final harness = ChatHarness(session: w2Session, states: {w2Session: state});
  await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
  await pumpFrames(tester);
}

void main() {
  test('D3-08_tool_row_summary_and_expand', () async {
    final client = W2Client();
    final container = await startW2Chat(client, running: true);
    addTearDown(() async {
      container.dispose();
      await client.events.close();
    });

    client.events.add(SessionLogEvent.fromJson(w2ToolCall(2, 'c1', 'bash', '{"command":"ls -la"}')));
    await settleW2(container);
    final live = w2State(container).items.whereType<ToolChatItem>().single;
    expect(live.status, ToolStatus.running, reason: 'D3-08-AC1: the row appears as running');
    expect(live.name, 'bash');
    expect(live.arguments, '{"command":"ls -la"}');

    client.events.add(SessionLogEvent.fromJson(w2ToolResult(3, 'c1', 'total 8\nlib\n')));
    await settleW2(container);
    final done = w2State(container).items.whereType<ToolChatItem>().single;
    expect(done.status, ToolStatus.succeeded, reason: 'D3-08-AC1: the finished call is a success');
    expect(done.resultText, 'total 8\nlib\n');
    expect(client.cancels, 0);
  });

  testWidgets('D3-08_tool_row_summary_and_expand_ui', (tester) async {
    final state = await _stateFor(
      tester,
      snapshot: w2Snapshot(
        records: [
          w2Record(w2User(0, '看看目录')),
          _call(1, 'c1', 'bash', '{"command":"ls -la"}'),
          _result(2, 'c1', 'total 8\nlib\n'),
        ],
      ),
    );
    await _pumpState(tester, state);

    expect(find.text('运行'), findsOneWidget, reason: 'D3-08-AC1: the verb names the action');
    expect(find.text('ls -la'), findsOneWidget, reason: 'D3-08-AC1: the first string argument is the summary');
    expect(find.text('命令'), findsNothing, reason: 'D3-08-AC1: details stay folded until opened');

    await tester.tap(find.text('ls -la'));
    await pumpFrames(tester, 6);
    expect(find.text('命令'), findsOneWidget, reason: 'D3-08-AC1: opening shows the arguments');
    expect(find.textContaining('total 8', findRichText: true), findsWidgets, reason: 'D3-08-AC1: opening shows the result');
    expect(tester.takeException(), isNull);
  });

  testWidgets('D3-08_turn_folds_into_completed_summary', (tester) async {
    final state = await _stateFor(
      tester,
      snapshot: w2Snapshot(
        records: [
          w2Record(w2Wire(0, 'turn/start', {'turn': 1})),
          w2Record(w2Wire(1, 'step/start', {'turn': 1, 'step': 1})),
          w2Record(w2User(2, '看看目录')),
          _call(3, 'c1', 'bash', '{"command":"ls"}'),
          _result(4, 'c1', 'a.txt'),
          _call(5, 'c2', 'grep', '{"pattern":"needle","path":"a.txt"}'),
          _result(6, 'c2', 'a.txt:1:needle'),
          w2Record(w2Reply(7, '目录里只有 a.txt。')),
          w2Record(w2Wire(8, 'step/end', {'turn': 1, 'step': 1})),
          w2Record(w2TurnEnd(9)),
        ],
      ),
    );
    expect(state.running, isFalse);
    await _pumpState(tester, state);

    expect(
      find.textContaining('已完成', findRichText: true),
      findsOneWidget,
      reason: 'D3-08-AC2: a finished turn folds into a summary',
    );
    expect(find.textContaining('2 次工具调用', findRichText: true), findsOneWidget);
    expect(find.textContaining('目录里只有 a.txt', findRichText: true), findsWidgets, reason: 'D3-08-AC2: the answer stays outside');
    expect(find.text('ls'), findsNothing, reason: 'D3-08-AC2: the tool rows are folded away');

    await tester.tap(find.textContaining('已完成', findRichText: true));
    await pumpFrames(tester, 8);
    expect(find.text('ls'), findsOneWidget, reason: 'D3-08-AC2: opening the fold shows the rows');
    expect(find.textContaining('needle', findRichText: true), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('ls')).dy,
      lessThan(tester.getTopLeft(find.textContaining('needle', findRichText: true)).dy),
      reason: 'D3-08-AC2: the rows keep their order',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('D3-08_failed_tool_row_shows_error', (tester) async {
    final state = await _stateFor(
      tester,
      snapshot: w2Snapshot(
        records: [
          w2Record(w2User(0, '读文件')),
          _call(1, 'c1', 'read', '{"file_path":"missing.txt"}'),
          _result(
            2,
            'c1',
            'file not found',
            error: true,
            failure: {'name': 'ToolError', 'code': 'ENOENT', 'reason': 'missing.txt 不存在'},
          ),
        ],
      ),
    );
    await _pumpState(tester, state);

    expect(find.text('missing.txt'), findsOneWidget);
    // A failed row has the failure icon instead of the quiet success state.
    expect(find.byIcon(AppIcons.failed), findsOneWidget);
    await tester.tap(find.text('missing.txt'));
    await pumpFrames(tester, 6);
    expect(find.text('错误'), findsOneWidget, reason: 'D3-08-AC3: the failure is distinguishable');
    expect(find.textContaining('file not found', findRichText: true), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
