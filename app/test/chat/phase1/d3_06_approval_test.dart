// D3-06 · 审批卡（允许一次 / 本对话都允许 / 拒绝）（capability-spec.md#D3-06）
//
// D3-06-AC1: a tool that needs approval shows its command/file and reason;
//            「允许本次」 answers once and the tool row gets its result.
// D3-06-AC2: 「拒绝」 answers once, the tool does not run (the decision is the
//            only thing the client sends), the conversation goes on and the
//            tool row shows the refusal.
// D3-06-AC3: 「本对话都允许」 answers this and every later ordinary approval,
//            shows 「自动允许中」, and a restart asks one by one again.
//
// The actual file side effect is the engine's; L2 can only prove that the
// client sends exactly the reject decision and no execute/allow, so the L4
// file-system assertion is deferred to T22 (no Engine artifact here).

import 'dart:async';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/widgets/approval_card.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';
import 'support/w2_client.dart';

ApprovalRequest _request(String id, {String callId = 'c1', String toolName = 'bash'}) => ApprovalRequest(
  eventId: id,
  sessionId: w2Session,
  toolName: toolName,
  callId: callId,
  reason: '写入工作区文件 mock-hello.md',
);

ToolChatItem _tool({
  ToolStatus status = ToolStatus.awaitingApproval,
  ApprovalRequest? pending,
  String result = '',
}) => ToolChatItem(
  callId: 'c1',
  name: 'bash',
  arguments: '{"command":"echo hi > mock-hello.md"}',
  status: status,
  pendingApproval: pending,
  resultParts: result.isEmpty ? const [] : [TextPart(result)],
);

Future<void> _pumpState(WidgetTester tester, ChatState state) async {
  usePhoneView(tester);
  mockClipboard(tester);
  final harness = ChatHarness(session: w2Session, states: {w2Session: state});
  await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
  await pumpFrames(tester);
}

/// Holds the approval answer so a second tap can be attempted while the card
/// is still showing 「正在提交」.
class _HoldingApprovalController extends FakeChatController {
  _HoldingApprovalController(super.sessionId, super.initial);
  final gate = Completer<void>();

  @override
  Future<void> respond(ApprovalRequest request, ApprovalDecision decision) async {
    responses.add((request, decision));
    await gate.future;
  }
}

/// The decisions this client sent for [eventId].
List<ApprovalDecision> _decisions(W2Client client, String eventId) => [
  for (final entry in client.approvals)
    if (entry.$1.eventId == eventId) entry.$2,
];

void main() {
  test('D3-06_allow_once_executes_tool_once', () async {
    final client = W2Client();
    final container = await startW2Chat(client, running: true);
    addTearDown(() async {
      container.dispose();
      await client.events.close();
    });

    client.events.add(
      SessionLogEvent.fromJson(
        w2Wire(2, 'tool/call', {
          'turn': 1,
          'step': 1,
          'callId': 'c1',
          'name': 'bash',
          'arguments': '{"command":"echo hi > mock-hello.md"}',
        }),
      ),
    );
    client.events.add(ApprovalRequestedEvent(_request('a1')));
    await settleW2(container);

    final waiting = w2State(container).items.whereType<ToolChatItem>().single;
    expect(waiting.status, ToolStatus.awaitingApproval, reason: 'D3-06-AC1: the call waits for the card');
    expect(w2State(container).approvals.single.eventId, 'a1');

    await w2Chat(container).respond(_request('a1'), ApprovalDecision.allowOnce);
    expect(
      _decisions(client, 'a1'),
      [ApprovalDecision.allowOnce],
      reason: 'D3-06-AC1: exactly one allow-once answer',
    );

    // The engine ran it once and reports the result; the card is withdrawn.
    client.events.add(
      SessionLogEvent.fromJson(
        w2Wire(3, 'tool/result', {
          'turn': 1,
          'step': 1,
          'message': {
            'id': 't3',
            'role': 'tool',
            'toolCallId': 'c1',
            'content': [
              {'type': 'text', 'text': 'wrote mock-hello.md'},
            ],
            'source': {'kind': 'tool'},
          },
        }),
      ),
    );
    client.events.add(const HostRequestCancelledEvent('a1'));
    await settleW2(container);

    final done = w2State(container).items.whereType<ToolChatItem>().single;
    expect(done.status, ToolStatus.succeeded, reason: 'D3-06-AC1: the tool row shows the result');
    expect(done.resultText, 'wrote mock-hello.md');
    expect(w2State(container).approvals, isEmpty, reason: 'D3-06-AC1: the answered card is gone');
    expect(client.approvals, hasLength(1), reason: 'D3-06-AC1: the tool did not ask or run twice');
  });

  test('D3-06_deny_approval_blocks_tool', () async {
    final client = W2Client();
    final container = await startW2Chat(client, running: true);
    addTearDown(() async {
      container.dispose();
      await client.events.close();
    });

    client.events.add(
      SessionLogEvent.fromJson(
        w2Wire(2, 'tool/call', {
          'turn': 1,
          'step': 1,
          'callId': 'c1',
          'name': 'bash',
          'arguments': '{"command":"echo hi > mock-hello.md"}',
        }),
      ),
    );
    client.events.add(ApprovalRequestedEvent(_request('a1')));
    await settleW2(container);

    await w2Chat(container).respond(_request('a1'), ApprovalDecision.reject);
    expect(
      _decisions(client, 'a1'),
      [ApprovalDecision.reject],
      reason: 'D3-06-AC2: the only thing sent is one rejection',
    );
    expect(
      client.approvals.where((entry) => entry.$2 == ApprovalDecision.allowOnce),
      isEmpty,
      reason: 'D3-06-AC2: a denial never allows the tool to execute',
    );
    expect(client.prompts, isEmpty, reason: 'D3-06-AC2: denying does not resend anything');

    // The Host records the decision and the call ends without a success.
    client.events.add(
      SessionLogEvent.fromJson(
        w2Wire(3, 'approval/asked', {'id': 'a1', 'toolName': 'bash', 'callId': 'c1', 'reason': 'write'}),
      ),
    );
    client.events.add(
      SessionLogEvent.fromJson(
        w2Wire(4, 'approval/decided', {'id': 'a1', 'outcome': 'rejected'}),
      ),
    );
    client.events.add(
      SessionLogEvent.fromJson(
        w2Wire(5, 'tool/result', {
          'turn': 1,
          'step': 1,
          'message': {
            'id': 't5',
            'role': 'tool',
            'toolCallId': 'c1',
            'isError': true,
            'content': [
              {'type': 'text', 'text': 'permission denied by user'},
            ],
            'source': {'kind': 'tool'},
          },
        }),
      ),
    );
    client.events.add(const HostRequestCancelledEvent('a1'));
    await settleW2(container);

    final refused = w2State(container).items.whereType<ToolChatItem>().single;
    expect(refused.status, ToolStatus.denied, reason: 'D3-06-AC2: the tool row shows the refusal');
    expect(refused.status, isNot(ToolStatus.succeeded), reason: 'D3-06-AC2: nothing executed');
    expect(refused.resultText, 'permission denied by user');
    expect(w2State(container).running, isTrue, reason: 'D3-06-AC2: the conversation continues');
    expect(client.approvals, hasLength(1), reason: 'D3-06-AC2: the decision event was sent only once');
  });

  test('D3-06_auto_allow_resets_after_restart', () async {
    final client = W2Client();
    final container = await startW2Chat(client, running: true);
    addTearDown(() async {
      container.dispose();
      await client.events.close();
    });

    client.events.add(ApprovalRequestedEvent(_request('a1')));
    await settleW2(container);
    await w2Chat(container).allowAll(_request('a1'));
    expect(w2State(container).autoApprove, isTrue);
    expect(_decisions(client, 'a1'), [ApprovalDecision.allowOnce]);

    // Later ordinary approvals are allowed automatically, once per id.
    client.events.add(ApprovalRequestedEvent(_request('a2')));
    client.events.add(ApprovalRequestedEvent(_request('a2')));
    await settleW2(container);
    expect(
      client.approvals.where((entry) => entry.$1.eventId == 'a2'),
      hasLength(1),
      reason: 'D3-06-AC3: a redelivered request is not answered twice',
    );

    // Restart: a fresh controller remembers nothing and asks one by one.
    container.dispose();
    final client2 = W2Client();
    final restarted = await startW2Chat(client2, running: true);
    addTearDown(() async {
      restarted.dispose();
      await client2.events.close();
    });
    expect(w2State(restarted).autoApprove, isFalse, reason: 'D3-06-AC3: the consent is in memory only');
    client2.events.add(ApprovalRequestedEvent(_request('a3')));
    await settleW2(restarted);
    expect(client2.approvals, isEmpty, reason: 'D3-06-AC3: after a restart the card waits for the person');
    expect(w2State(restarted).approvals.single.eventId, 'a3');
  });

  testWidgets('D3-06_allow_once_card_shows_command_and_reason', (tester) async {
    final request = _request('a1');
    await _pumpState(
      tester,
      ChatState(
        loading: false,
        running: true,
        items: [_tool(pending: request)],
        approvals: [request],
      ),
    );

    expect(find.byType(ApprovalCard), findsOneWidget);
    expect(find.text('允许运行这条命令？'), findsOneWidget, reason: 'D3-06-AC1: the card names the action');
    expect(find.text('echo hi > mock-hello.md'), findsOneWidget, reason: 'D3-06-AC1: the command is visible');
    expect(find.text('写入工作区文件 mock-hello.md'), findsOneWidget, reason: 'D3-06-AC1: the reason is visible');
    expect(find.text('允许本次'), findsOneWidget);
    expect(find.text('拒绝'), findsOneWidget);
    expect(find.text('本对话都允许'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('D3-06_deny_sends_one_decision', (tester) async {
    usePhoneView(tester);
    mockClipboard(tester);
    final request = _request('a1');
    final harness = ChatHarness(
      session: w2Session,
      states: {
        w2Session: ChatState(
          loading: false,
          running: true,
          items: [_tool(pending: request)],
          approvals: [request],
        ),
      },
      controllerFactory: _HoldingApprovalController.new,
    );
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await pumpFrames(tester);

    await tester.tap(find.text('拒绝'));
    await pumpFrames(tester);
    final controller = harness.controllers[w2Session] as _HoldingApprovalController;
    expect(controller.responses, hasLength(1), reason: 'D3-06-AC2: the first tap sends the decision');
    expect(controller.responses.single.$2, ApprovalDecision.reject);

    // While the answer is in flight the other buttons are disabled: a second
    // tap cannot send the decision again.
    expect(tester.widget<OutlinedButton>(find.byType(OutlinedButton).first).onPressed, isNull);
    await tester.tap(find.byType(OutlinedButton).first, warnIfMissed: false);
    await tester.pump();
    expect(controller.responses, hasLength(1), reason: 'D3-06-AC2: the decision is sent only once');

    controller.gate.complete();
    await pumpFrames(tester);
    expect(controller.responses, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('D3-06_auto_allow_banner_can_be_turned_off', (tester) async {
    usePhoneView(tester);
    mockClipboard(tester);
    final harness = ChatHarness(
      session: w2Session,
      states: {w2Session: const ChatState(loading: false, autoApprove: true)},
    );
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await pumpFrames(tester);

    expect(find.text('自动允许中'), findsOneWidget, reason: 'D3-06-AC3: the banner stays visible while auto-allowing');
    await tester.tap(find.text('自动允许中'));
    await pumpFrames(tester);
    expect(
      harness.controllers[w2Session]!.autoApproveToggles,
      [false],
      reason: 'D3-06-AC3: tapping the banner turns it off',
    );
    expect(tester.takeException(), isNull);
  });
}
