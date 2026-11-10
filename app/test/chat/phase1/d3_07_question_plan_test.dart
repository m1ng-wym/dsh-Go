// D3-07 · 提问卡与计划待审（capability-spec.md#D3-07）
//
// D3-07-AC1: a question shows its options; choosing and submitting answers it
//            once and the conversation goes on; a single question can also be
//            answered from the composer.
// D3-07-AC2: a plan review (one question, `intent.kind == 'plan-review'`, the
//            plan as `detail`, approve/decline options) shows the plan and
//            takes 确认执行 / 要求修改 as its answer, without submitting twice.
//
// The plan-review card is the in-chat question card with the plan rendered as
// Markdown (docs/official-parity.md:29). What happens after the answer (the
// engine leaves plan mode or waits for edits) is L4; no Engine artifact is
// available here, so it is deferred to T22.

import 'dart:async';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/widgets/question_card.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';
import 'support/w2_client.dart';

const _question = UserQuestionRequest(
  eventId: 'q1',
  sessionId: w2Session,
  questions: [
    UserQuestion(
      id: 'db',
      question: '数据库用哪一个?',
      options: [QuestionOption('SQLite', null), QuestionOption('PostgreSQL', null)],
    ),
  ],
);

const _planReview = UserQuestionRequest(
  eventId: 'p1',
  sessionId: w2Session,
  questions: [
    UserQuestion(
      id: 'plan',
      question: '执行这个计划？',
      detail: '# 计划\n\n1. 改配置\n2. 跑测试',
      options: [QuestionOption('确认执行', null), QuestionOption('要求修改', null)],
      intent: {'kind': 'plan-review', 'approve': '确认执行'},
    ),
  ],
);

class _HoldingAnswerController extends FakeChatController {
  _HoldingAnswerController(super.sessionId, super.initial);
  final gate = Completer<void>();

  @override
  Future<bool> answer(UserQuestionRequest request, List<QuestionAnswer> answers) async {
    this.answers.add((request, answers));
    await gate.future;
    return true;
  }
}

void main() {
  test('D3-07_question_answer_submits_once', () async {
    final client = W2Client();
    final container = await startW2Chat(client, running: true);
    addTearDown(() async {
      container.dispose();
      await client.events.close();
    });

    client.events.add(const UserQuestionRequestedEvent(_question));
    await settleW2(container);
    expect(w2State(container).questions.single.eventId, 'q1');

    final ok = await w2Chat(container).answer(_question, [
      const QuestionAnswer('db', selected: ['PostgreSQL']),
    ]);
    expect(ok, isTrue);
    expect(client.answers, hasLength(1), reason: 'D3-07-AC1: the answer is submitted once');
    expect(client.answers.single.$2.single.id, 'db');
    expect(client.answers.single.$2.single.selected, ['PostgreSQL']);

    // The Host settles the waterfall; the card goes and the turn goes on.
    client.events.add(const HostRequestCancelledEvent('q1'));
    await settleW2(container);
    expect(w2State(container).questions, isEmpty, reason: 'D3-07-AC1: the answered card is gone');
    expect(w2State(container).running, isTrue, reason: 'D3-07-AC1: the conversation continues');
  });

  test('D3-07_answer_failure_keeps_card_retryable', () async {
    final client = W2Client();
    final container = await startW2Chat(client, running: true);
    addTearDown(() async {
      container.dispose();
      await client.events.close();
    });

    client.events.add(const UserQuestionRequestedEvent(_question));
    await settleW2(container);

    client.answerError = StateError('offline');
    expect(
      await w2Chat(container).answer(_question, [const QuestionAnswer('db', selected: ['SQLite'])]),
      isFalse,
    );
    await settleW2(container);
    expect(w2State(container).questions, hasLength(1), reason: 'D3-07 错误/边界: a failed answer keeps the card');
    expect(w2State(container).error, isNotNull, reason: 'D3-07 错误/边界: the failure is visible');

    client.answerError = null;
    expect(
      await w2Chat(container).answer(_question, [const QuestionAnswer('db', selected: ['SQLite'])]),
      isTrue,
      reason: 'D3-07 错误/边界: the card can be answered again',
    );
    expect(client.answers, hasLength(2));
  });

  testWidgets('D3-07_question_answer_from_composer', (tester) async {
    usePhoneView(tester);
    mockClipboard(tester);
    final harness = ChatHarness(
      session: w2Session,
      states: {
        w2Session: const ChatState(loading: false, running: true, questions: [_question]),
      },
    );
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await pumpFrames(tester);

    final field = find.descendant(of: find.byType(Composer), matching: find.byType(TextField));
    expect(tester.widget<TextField>(field).decoration!.hintText, '输入回答…');
    await tester.enterText(field, '用 PostgreSQL');
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.send));
    await pumpFrames(tester);

    final controller = harness.controllers[w2Session]!;
    expect(controller.answers, hasLength(1), reason: 'D3-07-AC1: one question can be answered from the composer');
    expect(controller.answers.single.$2.single.custom, '用 PostgreSQL');
    expect(controller.sent, isEmpty, reason: 'D3-07-AC1: the text answers the card, not a new prompt');
    expect(tester.takeException(), isNull);
  });

  testWidgets('D3-07_plan_review_answer_is_sent_once', (tester) async {
    usePhoneView(tester);
    mockClipboard(tester);
    final harness = ChatHarness(
      session: w2Session,
      states: {
        w2Session: const ChatState(loading: false, running: true, questions: [_planReview]),
      },
    );
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await pumpFrames(tester);

    expect(find.text('计划待审'), findsOneWidget, reason: 'D3-07-AC2: a plan review is named as such');
    expect(
      find.textContaining('改配置', findRichText: true),
      findsOneWidget,
      reason: 'D3-07-AC2: the plan body is shown as Markdown',
    );
    expect(find.text('要求修改'), findsOneWidget, reason: 'D3-07-AC2: asking for changes is the other choice');

    await tester.tap(find.text('确认执行'));
    await tester.pump();
    await tester.tap(find.text('提交'));
    await pumpFrames(tester);
    final controller = harness.controllers[w2Session]!;
    expect(controller.answers, hasLength(1), reason: 'D3-07-AC2: approve submits exactly one answer');
    expect(controller.answers.single.$1.eventId, 'p1');
    expect(controller.answers.single.$2.single.selected, ['确认执行']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('D3-07_plan_review_request_changes_is_sent_once', (tester) async {
    usePhoneView(tester);
    mockClipboard(tester);
    final harness = ChatHarness(
      session: w2Session,
      states: {
        w2Session: const ChatState(loading: false, running: true, questions: [_planReview]),
      },
    );
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await pumpFrames(tester);

    await tester.tap(find.text('要求修改'));
    await tester.pump();
    await tester.tap(find.text('提交'));
    await pumpFrames(tester);
    final controller = harness.controllers[w2Session]!;
    expect(controller.answers, hasLength(1), reason: 'D3-07-AC2: 要求修改 submits exactly one answer');
    expect(controller.answers.single.$2.single.selected, ['要求修改']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('D3-07_question_submit_is_not_duplicated', (tester) async {
    final gate = Completer<void>();
    var submitted = 0;
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: QuestionCard(
            request: _question,
            onAnswer: (_, _) async {
              submitted++;
              await gate.future;
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('SQLite'));
    await tester.pump();
    await tester.tap(find.text('提交'));
    await tester.pump();
    expect(submitted, 1);
    // While the answer is in flight the submit button is disabled.
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '提交')).onPressed, isNull);
    await tester.tap(find.byType(FilledButton).first, warnIfMissed: false);
    await tester.pump();
    expect(submitted, 1, reason: 'D3-07 错误/边界: a double tap does not submit twice');
    gate.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('D3-07_question_holding_answer_sends_once', (tester) async {
    usePhoneView(tester);
    mockClipboard(tester);
    final harness = ChatHarness(
      session: w2Session,
      states: {
        w2Session: const ChatState(loading: false, running: true, questions: [_question]),
      },
      controllerFactory: _HoldingAnswerController.new,
    );
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await pumpFrames(tester);
    await tester.tap(find.text('SQLite'));
    await tester.pump();
    await tester.tap(find.text('提交'));
    await tester.pump();

    final controller = harness.controllers[w2Session] as _HoldingAnswerController;
    expect(controller.answers, hasLength(1));
    await tester.tap(find.byType(FilledButton).first, warnIfMissed: false);
    await tester.pump();
    expect(controller.answers, hasLength(1), reason: 'D3-07-AC1: the answer is submitted once');
    controller.gate.complete();
    await pumpFrames(tester);
    expect(tester.takeException(), isNull);
  });
}
