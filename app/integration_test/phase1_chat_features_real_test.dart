// T32 · L4-Real: the real engine's chat features against the real
// opencode-go model (`deepseek-v4.1-flash`, thinking `max`).
//
// One app install walks the production UI through the capabilities that only
// a real model can prove:
//
//   * C4 / D3-03 steer: a message sent while the answer streams is shown at
//     the bottom, the turn is not aborted, and the model's next step uses it
//     (the one-line summary the steer asked for);
//   * C5 / D3-04 queue: 「排队」 while a turn runs sends the message after that
//     turn, exactly once; 「撤回」 returns it to the composer and never sends
//     it;
//   * C6 / D3-05 stop: the stop key ends the turn, the generated prefix stays,
//     and the next message works;
//   * C9 / D3-08 tool row: a real `bash` call shows a row, expands to its
//     command and its `tool-row-ok` output;
//   * C10 / D3-19 message actions: copy puts the exact reply on the clipboard,
//     quote travels in front of the next message, and regenerate opens a fork
//     that re-answers while the source conversation is unchanged;
//   * C11 / D3-07 question card: the model's `ask_user_question` shows the
//     card, choosing A answers it once, and the turn continues to its end.
//
// The key reaches the app only through the T25 loopback credential broker:
//
//   cd app && flutter test --no-pub integration_test/phase1_chat_features_real_test.dart \
//     -d <simulator-udid> \
//     --dart-define=E2E_BROKER_URL=http://127.0.0.1:PORT \
//     --dart-define=E2E_BROKER_TOKEN=<64 hex>
//
// Normally started by `scripts/e2e/ios/run_chat_features_real.sh` (clone
// simulator, broker, clean install, log, screenshots). Missing key/network/
// tool call is a failure, never a skip; a wait that times out fails.
//
// Real-model budget: the steps below are written to stay under 25 provider
// requests. The completed ones are counted from the app's own turn traces
// (title requests are not turns and are counted one per conversation).

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
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/tool_view.dart';
import 'package:dsh_app/ui/chat/widgets/question_card.dart';
import 'package:dsh_app/ui/chat/widgets/quote_chip.dart';
import 'package:dsh_app/ui/chat/widgets/tool_row.dart';
import 'package:dsh_app/ui/chat/widgets/turn_process.dart';
import 'package:dsh_app/ui/chat/widgets/user_bubble.dart';
import 'package:dsh_app/ui/onboarding/connect_page.dart';
import 'package:dsh_app/ui/onboarding/welcome_page.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart' show AssistantChatItem, ToolChatItem, ToolStatus, TurnTrace, UserChatItem;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/e2e_env.dart';
import 'support/real_provider.dart';

// ---------------------------------------------------------------------------
// Prompts. Each is phrased so the assertion after it is about behaviour, not
// about a wording the model might choose.

/// C4: a deliberately long answer (300+ characters) that streams long enough
/// to send a steer while it runs.
const _longPrompt =
    '请分点详细解释 DSH 的会话、工作区、审批三层设计，至少 300 字，分 6 点说明每层的作用和边界。'
    '不要调用任何工具，只输出文字。';

/// C4: the steer. The formatting instruction is what proves the model read it.
const _steerText = '补充：每层再补充两个常见误区，至少 200 字，最后用一句话总结，单独一行，以「总结：」开头';

/// C5: the queued message and its single, unambiguous reply.
const _queuedText = '队列消息：请只回复 QUEUED_OK';
const _queuedReply = 'QUEUED_OK';

/// C5: queued and then withdrawn; it must never reach the model.
const _withdrawText = '待撤回：请只回复 WITHDRAW_OK';

/// C6: another long answer, stopped mid-stream.
const _stopPrompt =
    '请详细解释 Flutter 的渲染管线：从 Widget 到 Element 再到 RenderObject，'
    '再讲布局、绘制和合成，至少 250 字，分 5 点。不要调用任何工具，只输出文字。';

/// C6: the message after the stop.
const _continueText = '请只回复 CONTINUE_OK';
const _continueReply = 'CONTINUE_OK';

/// C9: a real bash tool call whose output is checked in the transcript.
const _toolPrompt = "请用 bash 工具运行 printf 'tool-row-ok\\n' 并告诉我输出。不要调用其他工具。";
const _toolOutput = 'tool-row-ok';

/// C10: a short deterministic answer whose actions are then exercised.
const _actionText = '请只回复 ACTION_OK，不要调用任何工具。';
const _actionReply = 'ACTION_OK';

/// C10: the quoted follow-up.
const _quoteAsk = '请只回复 QUOTE_OK';
const _quoteReply = 'QUOTE_OK';

/// C11: the question the model must ask through the tool.
const _questionPrompt =
    '请调用 ask_user_question 工具问我：选择 A 还是 B？选项 A、B；拿到我的答案后再继续。'
    '必须真的调用该工具，不要自己直接回答这个问题。不要设置 timeout 参数，我会马上回答。';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('T32_L4_real_chat_features_steer_queue_stop_tool_actions_question', (tester) async {
    // A tap that lands elsewhere is caught by the effect assertions below
    // (the composer clears, the sheet opens, the reply appears); the live
    // simulator's synthetic positions can miss an animating composer key, so
    // the framework's fatal hit-test warning is not used for this suite.
    WidgetController.hitTestWarningShouldBeFatal = false;
    // integration_test leaves the platform text input alone, so typing opens
    // the simulator's software keyboard; it animates the composer under the
    // pointer and cancels taps that land during the transition. Drive the same
    // TextField through the test text input instead: deterministic layout,
    // still the production editor and send path.
    tester.testTextInput.register();
    addTearDown(tester.testTextInput.unregister);
    final whole = Stopwatch()..start();
    _step('preconditions: broker defines, real paths, clean first launch');
    E2eConfig.requireBroker();
    await LocalPaths.load();
    expect(LocalPaths.workspace, startsWith('/'), reason: 'the engine workspace path was not resolved');
    await _resetDeviceState();
    runApp(
      ProviderScope(
        child: Listener(behavior: HitTestBehavior.translucent, child: const DshApp()),
      ),
    );

    await _waitUntil(
      tester,
      'the app reaches a real first screen',
      () =>
          find.byType(WelcomePage).evaluate().isNotEmpty ||
          find.byType(ConnectPage).evaluate().isNotEmpty ||
          find.byType(HomeShell).evaluate().isNotEmpty,
      timeout: const Duration(minutes: 3),
    );
    final container = _container(tester);
    _approvals = (container: container, sessionId: null, handled: <String>{});

    _step('first run: onboarding chooses the local engine');
    await _finishOnboarding(tester);
    await _waitUntil(
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

    _step('one new conversation for every chat feature below');
    if (container.read(currentSessionProvider) != null) {
      container.read(currentSessionProvider.notifier).select(null);
      await tester.pump();
    }
    await _waitUntil(
      tester,
      'new chat state',
      () => container.read(currentSessionProvider) == null,
      timeout: const Duration(seconds: 30),
    );

    // -----------------------------------------------------------------------
    _step('C4/C5: long real answer; steer it, withdraw a queued message, queue one');
    final sessionId = await _sendFirstMessage(tester, container, _longPrompt);
    _approvals = (container: container, sessionId: sessionId, handled: _approvals!.handled);
    final c4 = await _waitForRunning(tester, container, sessionId, 'the long C4 turn to start');

    await _waitUntil(
      tester,
      'the long answer to start streaming',
      () => container
          .read(chatProvider(sessionId))
          .items
          .whereType<AssistantChatItem>()
          .any((item) => item.streaming && item.text.trim().isNotEmpty),
      timeout: const Duration(minutes: 4),
    );
    _log('the long answer is streaming');

    // C4: send the steer through the composer (a normal send while running is
    // a steer in the production UI).
    await _typeIntoComposer(tester, _steerText);
    await _tapSend(tester, expectedText: _steerText);
    var sawSteerBubble = false;
    await _waitFor(tester, 'the steer to wait at the bottom of the running conversation', () {
      final chat = container.read(chatProvider(sessionId));
      // Before the Host reports the inbox slot the bubble says 插话中; once the
      // slot is known it says 插话 · 下一步生效. Both are the same optimistic
      // bubble at the bottom of the conversation.
      final label = find.text(appL10n.chatSteering).evaluate().isNotEmpty
          ? appL10n.chatSteering
          : find.text(appL10n.chatSteerNextStep).evaluate().isNotEmpty
          ? appL10n.chatSteerNextStep
          : null;
      if (label != null && find.text(_steerText).evaluate().isNotEmpty) {
        sawSteerBubble = true;
        _log('steer bubble visible: «$label» + message');
      }
      final pending = chat.pending
          .where((prompt) => prompt.text == _steerText && prompt.mode == SendMode.steer)
          .firstOrNull;
      if (pending != null) return pending;
      // A very fast Host can echo the steer before the bubble was sampled.
      return chat.items.whereType<UserChatItem>().any((item) => item.text == _steerText) ? chat : null;
    }, timeout: const Duration(seconds: 60));
    expect(sawSteerBubble, isTrue, reason: 'D3-03-AC1: the steer bubble ("插话中"/"插话 · 下一步生效") was never visible');
    expect(
      container.read(chatProvider(sessionId)).running,
      isTrue,
      reason: 'D3-03-AC1: sending a steer must not abort the running turn',
    );
    _log('steer is pending and visible while the turn runs');
    await _holdForScreenshot(tester, 'steer');

    final steerSeq = await _waitUserEcho(tester, container, sessionId, _steerText, timeout: const Duration(minutes: 3));
    _log('steer echoed into the transcript at seq $steerSeq');
    expect(
      container.read(chatProvider(sessionId)).items.whereType<UserChatItem>().where((item) => item.text == _steerText),
      hasLength(1),
      reason: 'D3-03-AC1: the steer must appear in the running conversation exactly once',
    );

    // C5 comes first, while the steered step still runs: queue the withdraw
    // candidate, withdraw it, then queue the QUEUED_OK message. Waiting for
    // the summary first would end the turn and make the "queue" send at once.
    await _typeIntoComposer(tester, _withdrawText);
    await _queueFromSendOptions(tester);
    await _waitUntil(
      tester,
      'the Host to hold the withdraw candidate in the inbox',
      () => container
          .read(chatProvider(sessionId))
          .pending
          .any((prompt) => prompt.text == _withdrawText && prompt.inboxId != null),
      timeout: const Duration(seconds: 90),
    );
    await _waitUntil(
      tester,
      'the queued label for the withdraw candidate',
      () => find.text(appL10n.chatQueuedAfterTurn).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 30),
    );
    final queuedBubble = find.ancestor(of: find.text(_withdrawText), matching: find.byType(UserBubble));
    expect(queuedBubble, findsOneWidget, reason: 'the queued bubble for the withdraw candidate is not on screen');
    await _tapFirst(
      tester,
      find.descendant(of: queuedBubble, matching: find.text(appL10n.chatWithdraw)),
      'withdraw the queued message',
    );
    await _waitUntil(
      tester,
      'D3-04-AC2: the withdrawn text back in the composer',
      () => _composerText(tester) == _withdrawText,
      timeout: const Duration(seconds: 60),
    );
    expect(find.text(appL10n.chatWithdrawnEditable), findsOneWidget, reason: 'the withdrawn notice is not shown');
    expect(
      container.read(chatProvider(sessionId)).pending.where((prompt) => prompt.text == _withdrawText),
      isEmpty,
      reason: 'D3-04-AC2: the withdrawn message still waits in the queue',
    );
    _log('withdraw returned the text to the composer');
    await _clearComposer(tester);
    await Future<void>.delayed(const Duration(seconds: 2));
    await tester.pump();
    expect(
      container
          .read(chatProvider(sessionId))
          .items
          .whereType<UserChatItem>()
          .where((item) => item.text == _withdrawText),
      isEmpty,
      reason: 'D3-04-AC2: a withdrawn message was sent anyway',
    );

    // C5-b: queue the real queued message; it goes after this turn, once.
    await _typeIntoComposer(tester, _queuedText);
    await _queueFromSendOptions(tester);
    await _waitUntil(
      tester,
      'the Host to report the queued message in its next-turn inbox',
      () => container
          .read(chatProvider(sessionId))
          .pending
          .any((prompt) => prompt.text == _queuedText && prompt.inboxId != null),
      timeout: const Duration(seconds: 90),
    );
    await _waitUntil(
      tester,
      'the queued message label',
      () => find.text(appL10n.chatQueuedAfterTurn).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 30),
    );
    expect(
      container.read(chatProvider(sessionId)).pending.singleWhere((prompt) => prompt.text == _queuedText).mode,
      SendMode.queue,
      reason: 'D3-04-AC1: the queue send option did not queue the message',
    );
    _log('queued the QUEUED_OK message while the turn runs');

    // C4 result: the steer's summary landed after the steer echo, while the
    // turn (not a new one) kept going.
    final steerAnswer = await _waitFor(tester, 'the steered summary after the steer echo', () {
      final chat = container.read(chatProvider(sessionId));
      final after = chat.items
          .whereType<AssistantChatItem>()
          .where((item) => item.seq != null && item.seq! > steerSeq && item.text.contains('总结') && !item.streaming)
          .toList();
      return after.isEmpty ? null : chat;
    }, timeout: const Duration(minutes: 5));
    final summaryItem = steerAnswer.items
        .whereType<AssistantChatItem>()
        .where((item) => item.seq != null && item.seq! > steerSeq && item.text.contains('总结'))
        .last;
    _log('steered answer: «${_oneLine(summaryItem.text)}»');

    // The steer echo is inside the turn that was already running: that is the
    // structural steer contract (not a queued next turn).
    final c4Turns = steerAnswer.turns;
    final steerTurn = c4Turns.where((turn) => turn.startSeq <= steerSeq).last;
    expect(
      steerTurn.turn,
      c4.turn.turn,
      reason: 'D3-03-AC1: the steer started a new turn instead of joining the running one',
    );
    expect(steerTurn.startSeq, lessThanOrEqualTo(steerSeq), reason: 'the steer is outside the running turn');
    expect(steerTurn.endReason?.isAborted ?? false, isFalse, reason: 'D3-03-AC1: the turn was aborted after the steer');
    expect(
      summaryItem.seq!,
      greaterThan(steerSeq),
      reason: 'D3-03-AC1: no answer after the steer used it (no final summary)',
    );
    expect(
      container.read(chatProvider(sessionId)).error,
      isNull,
      reason: 'the steer turn failed: ${container.read(chatProvider(sessionId)).error}',
    );
    _log('steer used by the running turn ${steerTurn.turn} at seq $steerSeq; summary at seq ${summaryItem.seq}');

    // C5 result: after the first turn ends the queued message starts the next
    // turn, exactly once, and its answer is QUEUED_OK.
    final queued = await _waitFor(tester, 'the queued message to run after the turn and answer QUEUED_OK', () {
      final chat = container.read(chatProvider(sessionId));
      final echoed = chat.items.whereType<UserChatItem>().where((item) => item.text == _queuedText).toList();
      final answers = chat.items
          .whereType<AssistantChatItem>()
          .where((item) => !item.streaming && item.text.contains(_queuedReply))
          .toList();
      return !chat.running && echoed.length == 1 && answers.length == 1 ? chat : null;
    }, timeout: const Duration(minutes: 5));
    final queuedEcho = queued.items.whereType<UserChatItem>().singleWhere((item) => item.text == _queuedText);
    expect(queuedEcho.seq, isNotNull);
    final queuedTurn = queued.turns.where((turn) => turn.startSeq <= queuedEcho.seq).last;
    final queuedTurnIndex = queued.turns.indexOf(queuedTurn);
    expect(queuedTurnIndex, greaterThan(0), reason: 'the queued message did not start a new turn');
    final previousTurn = queued.turns[queuedTurnIndex - 1];
    expect(previousTurn.endSeq, isNotNull, reason: 'D3-04-AC1: the queued message ran before the previous turn ended');
    expect(
      queuedTurn.startSeq,
      greaterThan(previousTurn.endSeq!),
      reason: 'D3-04-AC1: the queued message was not held until after the turn',
    );
    expect(
      queued.items.whereType<UserChatItem>().where((item) => item.text == _queuedText),
      hasLength(1),
      reason: 'D3-04-AC1: the queued message was sent more than once',
    );
    _log('queue auto-sent exactly once in turn ${queuedTurn.turn} (seq ${queuedEcho.seq})');
    _countModelSteps(container, sessionId);

    // -----------------------------------------------------------------------
    _step('C6/D3-05: stop a streaming real answer, keep the prefix, send again');
    await _typeIntoComposer(tester, _stopPrompt);
    await _tapSend(tester, expectedText: _stopPrompt);
    await _waitForRunning(tester, container, sessionId, 'the stop turn to start');
    await _waitUntil(tester, 'the stop turn to stream a meaningful prefix', () {
      final chat = container.read(chatProvider(sessionId));
      final streaming = chat.items
          .whereType<AssistantChatItem>()
          .where((item) => item.streaming && item.text.trim().length >= 40)
          .toList();
      if (streaming.isNotEmpty) return true;
      // The model must not finish before we can stop it.
      expect(chat.running, isTrue, reason: 'the stop turn ended before a stoppable prefix appeared');
      return false;
    }, timeout: const Duration(minutes: 4));
    final prefix = container
        .read(chatProvider(sessionId))
        .items
        .whereType<AssistantChatItem>()
        .lastWhere((item) => item.text.trim().isNotEmpty)
        .text;
    _log('stop test: generated prefix length ${prefix.length}');
    await _tapFirst(
      tester,
      find.descendant(of: find.byType(Composer), matching: find.byIcon(AppIcons.stopGenerating)),
      'stop generating',
    );
    await _waitUntil(tester, 'D3-05-AC1: the turn to end after stop', () {
      final chat = container.read(chatProvider(sessionId));
      return !chat.running && !chat.stopping;
    }, timeout: const Duration(minutes: 2));
    final stopped = container.read(chatProvider(sessionId));
    expect(stopped.error, isNull, reason: 'the stop failed: ${stopped.error}');
    final kept = stopped.items.whereType<AssistantChatItem>().lastWhere((item) => item.text.trim().isNotEmpty);
    expect(
      kept.text,
      contains(prefix.substring(0, math.min(24, prefix.length))),
      reason: 'D3-05-AC1: the generated prefix was not kept after stop',
    );
    expect(stopped.running, isFalse, reason: 'D3-05-AC1: the UI did not go idle after stop');
    // The key swaps back to send with a short fade; the outgoing stop icon is
    // still in the tree for that frame. Wait for it to leave before asserting.
    await _waitUntil(
      tester,
      'the stop key to leave the composer',
      () =>
          find.descendant(of: find.byType(Composer), matching: find.byIcon(AppIcons.stopGenerating)).evaluate().isEmpty,
      timeout: const Duration(seconds: 15),
    );
    expect(
      find.descendant(of: find.byType(Composer), matching: find.byIcon(AppIcons.stopGenerating)),
      findsNothing,
      reason: 'D3-05-AC1: the stop key is still on screen',
    );
    _log('stopped after ${prefix.length} generated characters; kept ${kept.text.length}');
    await _holdForScreenshot(tester, 'stop');

    await _typeIntoComposer(tester, _continueText);
    await _tapSend(tester, expectedText: _continueText);
    final continued = await _waitForAssistantReply(
      tester,
      container,
      sessionId,
      _continueReply,
      'D3-05-AC1: the next message after a stop',
    );
    expect(continued.error, isNull, reason: 'the message after the stop failed: ${continued.error}');
    _log('next message after stop answered CONTINUE_OK');
    _countModelSteps(container, sessionId);

    // -----------------------------------------------------------------------
    _step('C9/D3-08: a real bash call shows a tool row with command and result');
    await _typeIntoComposer(tester, _toolPrompt);
    await _tapSend(tester, expectedText: _toolPrompt);
    final toolChat = await _waitFor(tester, 'the bash tool turn to finish', () {
      final chat = container.read(chatProvider(sessionId));
      if (chat.error != null) fail('the tool turn failed: ${chat.error}');
      final tools = chat.items.whereType<ToolChatItem>().where((item) => item.name == 'bash').toList();
      final answered = chat.items.whereType<AssistantChatItem>().any(
        (item) => !item.streaming && item.text.trim().isNotEmpty,
      );
      return !chat.running && tools.any((item) => item.status == ToolStatus.succeeded) && answered ? chat : null;
    }, timeout: const Duration(minutes: 6));
    final bash = toolChat.items.whereType<ToolChatItem>().lastWhere(
      (item) => item.name == 'bash' && item.status == ToolStatus.succeeded,
    );
    final command = ToolView.of(bash).command ?? bash.arguments;
    expect(command, contains('printf'), reason: 'D3-08-AC1: the bash row does not carry the requested command');
    expect(command, contains(_toolOutput), reason: 'D3-08-AC1: the bash command is not the requested one');
    expect(
      bash.resultText,
      contains(_toolOutput),
      reason: 'D3-08-AC1: the bash result does not contain "$_toolOutput"',
    );
    _log('bash tool ${bash.status.name}: «${_oneLine(command)}» -> «${_oneLine(bash.resultText)}»');
    _countModelSteps(container, sessionId);

    // The finished turn folds its process: open it, then open the bash row.
    // Both rows can be rebuilt between a wait and a tap, so re-resolve by the
    // visible header / call id and verify the effect each round instead of
    // holding a positional finder across the rebuild.
    final toolClock = Stopwatch()..start();
    var toolRowOpen = false;
    bool expanded() =>
        find.text(appL10n.chatCommand).evaluate().isNotEmpty && find.text(appL10n.chatOutput).evaluate().isNotEmpty;
    while (!toolRowOpen && toolClock.elapsed < const Duration(seconds: 90)) {
      final row = _toolRowFor(tester, bash);
      if (row != null) {
        await tester.tap(row.first, warnIfMissed: false);
      } else {
        final header = find.textContaining('已完成', findRichText: true);
        if (_safeEvaluate(header).isNotEmpty) {
          await tester.tap(header.first, warnIfMissed: false);
        } else if (_safeEvaluate(find.byType(TurnProcess)).isNotEmpty) {
          await tester.tap(find.byType(TurnProcess).last, warnIfMissed: false);
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 350));
      await tester.pump();
      toolRowOpen = expanded();
    }
    expect(toolRowOpen, isTrue, reason: 'D3-08-AC1: the bash tool row did not expand to its command and output');
    expect(
      find.textContaining('printf', findRichText: true),
      findsWidgets,
      reason: 'D3-08-AC1: the expanded row does not show the command',
    );
    expect(
      find.textContaining(_toolOutput, findRichText: true),
      findsWidgets,
      reason: 'D3-08-AC1: the expanded row does not show the result',
    );
    _log('the tool row opened: 命令 + 输出 with "$_toolOutput"');
    await _holdForScreenshot(tester, 'tool');

    // -----------------------------------------------------------------------
    _step('C10/D3-19: copy, quote and regenerate the last answer');
    await _typeIntoComposer(tester, _actionText);
    await _tapSend(tester, expectedText: _actionText);
    await _waitForAssistantReply(tester, container, sessionId, _actionReply, 'the message-actions answer');
    _countModelSteps(container, sessionId);

    final actionChat = container.read(chatProvider(sessionId));
    final actionMessage = actionChat.items.whereType<AssistantChatItem>().lastWhere(
      (item) => !item.streaming && item.text.contains(_actionReply),
    );
    await _waitUntil(
      tester,
      'the reply action row',
      () => find.byTooltip(appL10n.commonCopy).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 60),
    );

    // 复制: the exact reply text reaches the system clipboard.
    await _tapFirst(tester, find.byTooltip(appL10n.commonCopy).last, 'copy the last answer');
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    expect(clipboard?.text, actionMessage.text, reason: 'D3-19-AC1: copy did not put the exact reply on the clipboard');
    _log('copy verified against the system clipboard (${actionMessage.text.length} chars)');

    // 引用: the passage sits above the composer and travels with the next send.
    // Long-press the reply text like a person; if the live list has disposed
    // the text while settling, the same action row's ⋯ opens the same menu.
    final snippet = _uiSnippet(actionMessage.text);
    var quoteMenuOpen = false;
    for (var attempt = 1; attempt <= 3 && !quoteMenuOpen; attempt++) {
      final text = find.textContaining(snippet, findRichText: true);
      if (text.evaluate().isNotEmpty) {
        await _longPressFirst(tester, text.last, 'the last answer');
      } else {
        final more = find.byTooltip(appL10n.commonMore);
        if (more.evaluate().isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await tester.pump();
          continue;
        }
        _log('the reply text is no longer built; opening the message menu through ⋯');
        await _tapFirst(tester, more.last, 'the reply menu (⋯)');
      }
      final menuClock = Stopwatch()..start();
      while (menuClock.elapsed < const Duration(seconds: 5)) {
        if (find.text(appL10n.chatQuote).evaluate().isNotEmpty) {
          quoteMenuOpen = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
        await tester.pump();
      }
      if (!quoteMenuOpen) _log('quote menu did not open on attempt $attempt; opening it again');
    }
    expect(quoteMenuOpen, isTrue, reason: 'D3-19-AC3: the message menu with 引用 never opened');
    await _tapFirst(tester, find.text(appL10n.chatQuote).last, 'quote the last answer');
    await _waitUntil(
      tester,
      'the quote chip above the composer',
      () => find.byType(QuoteChip).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 30),
    );
    expect(
      find.descendant(of: find.byType(QuoteChip), matching: find.textContaining(snippet, findRichText: true)),
      findsWidgets,
      reason: 'D3-19-AC3: the quote chip does not show the quoted passage',
    );
    await _holdForScreenshot(tester, 'actions');
    await _typeIntoComposer(tester, _quoteAsk);
    await _tapSend(tester, expectedText: _quoteAsk);
    await _waitUntil(
      tester,
      'D3-19-AC3: the quote in front of the sent message',
      () => container
          .read(chatProvider(sessionId))
          .items
          .whereType<UserChatItem>()
          .any((item) => item.text.startsWith('> ') && item.text.contains(snippet) && item.text.contains(_quoteAsk)),
      timeout: const Duration(minutes: 3),
    );
    await _waitForAssistantReply(tester, container, sessionId, _quoteReply, 'the quoted follow-up');
    _countModelSteps(container, sessionId);
    _log('quote sent in front of the message and answered');
    await _scrollChatToBottom(tester);

    // 重新回答: a fork opens, the prompt is re-answered there, the source is
    // untouched, and the toast leads back.
    final original = container.read(chatProvider(sessionId));
    final originalAnswer = original.items.whereType<AssistantChatItem>().lastWhere((item) => !item.streaming);
    final originalItemCount = original.items.length;
    final holdOriginal = container.listen(chatProvider(sessionId), (_, _) {});
    ProviderSubscription<ChatState>? holdFork;
    try {
      await _waitUntil(
        tester,
        'the 重新回答 key on the last answer',
        () => find.byTooltip(appL10n.chatRegenerate).evaluate().isNotEmpty,
        timeout: const Duration(seconds: 60),
      );
      await _tapFirst(tester, find.byTooltip(appL10n.chatRegenerate).last, 'regenerate the last answer');
      await _waitUntil(
        tester,
        'D3-19-AC2: the fork opens as a new conversation',
        () => container.read(currentSessionProvider) != sessionId,
        timeout: const Duration(minutes: 2),
      );
      final forkSession = container.read(currentSessionProvider)!;
      holdFork = container.listen(chatProvider(forkSession), (_, _) {});
      _log('regenerate opened fork $forkSession');
      // The fork switch and its notice are separate frames; wait for the
      // notice and the way back it carries instead of sampling one instant.
      await _waitUntil(
        tester,
        'D3-19-AC2: the new-conversation notice',
        () => find.text(appL10n.chatRegeneratedInNewChat).evaluate().isNotEmpty,
        timeout: const Duration(seconds: 30),
      );
      expect(
        find.text(appL10n.chatRegeneratedInNewChat),
        findsOneWidget,
        reason: 'D3-19-AC2: the new-conversation notice is missing',
      );
      await _tapFirst(tester, find.text(appL10n.chatReturnToOriginal), 'return to the original conversation');
      await _waitUntil(
        tester,
        'D3-19-AC2: back in the original conversation',
        () => container.read(currentSessionProvider) == sessionId,
        timeout: const Duration(seconds: 60),
      );

      // The fork re-answers even though the screen went back; the source did
      // not change.
      await _waitUntil(tester, 'D3-19-AC2: the prompt re-answered in the fork', () {
        final chat = container.read(chatProvider(forkSession));
        final asked = chat.items.whereType<UserChatItem>().any((item) => item.text.contains(_quoteAsk));
        final answered = chat.items.whereType<AssistantChatItem>().any(
          (item) => !item.streaming && item.text.trim().isNotEmpty,
        );
        return !chat.running && asked && answered;
      }, timeout: const Duration(minutes: 5));
      final forkChat = container.read(chatProvider(forkSession));
      expect(forkChat.error, isNull, reason: 'regenerate failed in the fork: ${forkChat.error}');
      _countModelSteps(container, forkSession);

      // The source conversation still has its answer and its items.
      final source = container.read(chatProvider(sessionId));
      expect(
        source.items,
        hasLength(originalItemCount),
        reason: 'D3-19-AC2: regenerating changed the source conversation',
      );
      expect(
        source.items.whereType<AssistantChatItem>().lastWhere((item) => !item.streaming).text,
        originalAnswer.text,
        reason: 'D3-19-AC2: the source answer changed',
      );
      _log('source conversation unchanged ($originalItemCount items)');
    } finally {
      holdFork?.close();
      holdOriginal.close();
    }
    _countModelSteps(container, sessionId);

    // -----------------------------------------------------------------------
    _step('C11/D3-07: the real model asks a question, A is answered once, the turn continues');
    final beforeQuestion = container.read(chatProvider(sessionId));
    final turnsBeforeQuestion = beforeQuestion.turns.length;
    final finalsBeforeQuestion = beforeQuestion.items
        .whereType<AssistantChatItem>()
        .where((item) => !item.streaming && item.text.trim().isNotEmpty)
        .length;
    await _typeIntoComposer(tester, _questionPrompt);
    await _tapSend(tester, expectedText: _questionPrompt);
    await _waitUntil(
      tester,
      'D3-07-AC1: the real ask_user_question card',
      () =>
          container.read(chatProvider(sessionId)).questions.isNotEmpty &&
          find.byType(QuestionCard).evaluate().isNotEmpty,
      timeout: const Duration(minutes: 4),
    );
    final questionChat = container.read(chatProvider(sessionId));
    expect(questionChat.questions, hasLength(1), reason: 'D3-07-AC1: the model asked more than one question request');
    final request = questionChat.questions.single;
    expect(
      request.questions,
      hasLength(1),
      reason: 'D3-07-AC1: the question request does not carry exactly one question',
    );
    final question = request.questions.single;
    expect(find.text(appL10n.chatOneQuestion), findsOneWidget, reason: 'the question card is not titled as a question');
    expect(
      question.question,
      contains('A'),
      reason: 'the card does not carry the requested question: ${question.question}',
    );
    final labels = question.options.map((option) => option.label).toList();
    _log('question card: «${question.question}» options=$labels');
    final optionA = labels.where((label) => label.trim().startsWith('A')).firstOrNull;
    final optionB = labels.where((label) => label.trim().startsWith('B')).firstOrNull;
    expect(optionA, isNotNull, reason: 'D3-07-AC1: the card has no A option (options: $labels)');
    expect(optionB, isNotNull, reason: 'D3-07-AC1: the card has no B option (options: $labels)');
    await _holdForScreenshot(tester, 'question');

    // Answer once, on the card itself: choose A, then submit. The card is
    // matched by its request id, so a rebuild at the end of the transcript
    // cannot turn a positional finder into another card (or none).
    final card = find.byWidgetPredicate(
      (widget) => widget is QuestionCard && widget.request.eventId == request.eventId,
      description: 'the question card ${request.eventId}',
    );
    await _waitUntil(
      tester,
      'the question card to remain on screen',
      () => card.evaluate().isNotEmpty,
      timeout: const Duration(seconds: 30),
    );
    if (_safeEvaluate(find.descendant(of: card, matching: find.text(optionA!))).isEmpty) {
      await _scrollChatToBottom(tester);
      await tester.pump();
    }
    // The model can attach a timed wait to the question; the card then closes
    // at its deadline while the question stays answerable from the composer.
    // Tap the card first, and answer from the composer if it did not settle.
    final optionFinder = find.descendant(of: card, matching: find.text(optionA));
    if (_safeEvaluate(optionFinder).isNotEmpty) {
      await tester.tap(optionFinder.first, warnIfMissed: false);
      await tester.pump();
      final submitFinder = find.descendant(of: card, matching: find.widgetWithText(FilledButton, appL10n.chatSubmit));
      if (_safeEvaluate(submitFinder).isNotEmpty) {
        await tester.tap(submitFinder.first, warnIfMissed: false);
        await tester.pump();
        _log('submitted A on the question card');
      }
    }
    final cardClock = Stopwatch()..start();
    while (cardClock.elapsed < const Duration(seconds: 10)) {
      if (container.read(chatProvider(sessionId)).questions.isEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await tester.pump();
    }
    if (container.read(chatProvider(sessionId)).questions.isNotEmpty) {
      _log('the card did not settle; answering the single question from the composer');
      await _typeIntoComposer(tester, optionA);
      await _tapSend(tester, expectedText: optionA);
    }
    await _waitUntil(
      tester,
      'D3-07-AC1: the answered card settles',
      () => container.read(chatProvider(sessionId)).questions.isEmpty && find.byType(QuestionCard).evaluate().isEmpty,
      timeout: const Duration(minutes: 1),
    );
    _log('the card accepted A once and settled');
    // No duplicate answer: a second submission would come back as another
    // request/error; the card stays gone and the turn continues in place.
    await Future<void>.delayed(const Duration(seconds: 2));
    await tester.pump();
    expect(
      container.read(chatProvider(sessionId)).questions,
      isEmpty,
      reason: 'D3-07-AC1: the question card came back after being answered',
    );

    final answered = await _waitFor(tester, 'D3-07-AC1: the model continues after the answer', () {
      final chat = container.read(chatProvider(sessionId));
      if (chat.error != null) fail('the question turn failed after the answer: ${chat.error}');
      final continuation = chat.items
          .whereType<AssistantChatItem>()
          .where((item) => !item.streaming && item.text.trim().isNotEmpty)
          .toList();
      return !chat.running && continuation.isNotEmpty ? chat : null;
    }, timeout: const Duration(minutes: 4));
    expect(answered.questions, isEmpty, reason: 'D3-07-AC1: an unanswered question was left behind');
    expect(
      answered.turns.length,
      turnsBeforeQuestion + 1,
      reason: 'D3-07-AC1: the answer did not continue the same turn exactly once',
    );
    expect(
      answered.turns.last.endReason?.isCompleted ?? false,
      isTrue,
      reason: 'D3-07-AC1: the continuing turn did not complete: ${answered.turns.last.endReason?.kind}',
    );
    final finalsAfterQuestion = answered.items
        .whereType<AssistantChatItem>()
        .where((item) => !item.streaming && item.text.trim().isNotEmpty)
        .length;
    expect(
      finalsAfterQuestion,
      greaterThan(finalsBeforeQuestion),
      reason: 'D3-07-AC1: the model did not produce a new answer after the question was answered',
    );
    final continuation = answered.items.whereType<AssistantChatItem>().lastWhere((item) => !item.streaming);
    expect(continuation.text.trim(), isNotEmpty, reason: 'D3-07-AC1: the model did not continue after the answer');
    _log('model continued in turn ${answered.turns.last.turn}: «${_oneLine(continuation.text)}»');
    _countModelSteps(container, sessionId);

    // -----------------------------------------------------------------------
    _step('budget + wrap-up');
    final sessions = {..._counted.keys};
    final steps = _counted.values.fold<int>(0, (sum, value) => sum + value);
    // The engine asks the provider for one session title per conversation;
    // the turns themselves are the provider requests this test caused.
    final estimate = steps + sessions.length;
    _log('provider request estimate: $steps turn step(s) + ${sessions.length} title request(s) = $estimate');
    expect(estimate, lessThan(25), reason: 'the real-model budget (<25 provider requests) was exceeded: $estimate');
    _log('ALL FEATURES PASSED in ${whole.elapsed.inSeconds}s; sessions=$sessions');
  });
}

// ---------------------------------------------------------------------------
// Steer / queue / stop turn drivers

class _RunningTurn {
  const _RunningTurn(this.chat, this.turn);
  final ChatState chat;
  final TurnTrace turn;
}

/// The open conversation whose approvals the wait helpers may need to answer.
/// Set once the first conversation exists; the engine's bash starts under the
/// `workspace-write` + `ask` preset, so `允许本次` has to be tapped like a
/// person would.
({ProviderContainer container, String? sessionId, Set<String> handled})? _approvals;

Future<void> _approveOnce(WidgetTester tester) async {
  final scope = _approvals;
  final sessionId = scope?.sessionId;
  if (scope == null || sessionId == null) return;
  final chat = scope.container.read(chatProvider(sessionId));
  final request = chat.openApproval;
  if (request == null || scope.handled.contains(request.eventId)) return;
  final allow = find.text(appL10n.chatAllowOnce);
  if (allow.evaluate().isEmpty) return;
  scope.handled.add(request.eventId);
  _log('approval ${request.eventId}: allowing once');
  await tester.tap(allow.first, warnIfMissed: false);
  await tester.pump();
}

/// Waits for the conversation to report a running turn and returns it.
Future<_RunningTurn> _waitForRunning(
  WidgetTester tester,
  ProviderContainer container,
  String sessionId,
  String what,
) async {
  final chat = await _waitFor(tester, what, () {
    final chat = container.read(chatProvider(sessionId));
    return chat.running && chat.runningTurn != null ? chat : null;
  }, timeout: const Duration(minutes: 2));
  return _RunningTurn(chat, chat.runningTurn!);
}

/// Waits for a non-streaming assistant message that contains [needle].
Future<ChatState> _waitForAssistantReply(
  WidgetTester tester,
  ProviderContainer container,
  String sessionId,
  String needle,
  String what,
) {
  return _waitFor(tester, what, () {
    final chat = container.read(chatProvider(sessionId));
    if (chat.error != null) fail('$what: ${chat.error}');
    final answered = chat.items.whereType<AssistantChatItem>().any(
      (item) => !item.streaming && item.text.contains(needle),
    );
    return !chat.running && answered ? chat : null;
  }, timeout: const Duration(minutes: 5));
}

/// Waits until the transcript echoes [text] and returns its seq.
Future<int> _waitUserEcho(
  WidgetTester tester,
  ProviderContainer container,
  String sessionId,
  String text, {
  required Duration timeout,
}) async {
  final echo = await _waitFor(
    tester,
    'the transcript echo of "$text"',
    () => container
        .read(chatProvider(sessionId))
        .items
        .whereType<UserChatItem>()
        .where((item) => item.text == text)
        .firstOrNull,
    timeout: timeout,
  );
  return echo.seq;
}

/// Long-press send, then choose 「排队」 in the send-options sheet.
Future<void> _queueFromSendOptions(WidgetTester tester) async {
  final send = find.descendant(of: find.byType(Composer), matching: find.byIcon(AppIcons.send));
  for (var attempt = 1; attempt <= 3; attempt++) {
    await _waitUntil(tester, 'the send key for the queue options', () {
      final composers = tester.widgetList<Composer>(find.byType(Composer)).toList();
      return send.evaluate().isNotEmpty &&
          composers.isNotEmpty &&
          composers.every((composer) => composer.connected && composer.sessionReady && !composer.busy);
    }, timeout: const Duration(seconds: 60));
    await _waitForKeySettled(tester, send);
    await tester.longPress(send.first, warnIfMissed: false);
    final sheetClock = Stopwatch()..start();
    while (sheetClock.elapsed < const Duration(seconds: 5)) {
      if (find.text(appL10n.chatSendMode).evaluate().isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await tester.pump();
    }
    if (find.text(appL10n.chatSendMode).evaluate().isEmpty) {
      _log('queue sheet did not open on attempt $attempt; long-pressing again');
      continue;
    }
    expect(find.text(appL10n.chatQueue), findsOneWidget, reason: 'D3-04-AC1: 排队 is missing from the send options');
    await _tapFirst(tester, find.text(appL10n.chatQueue), 'queue');
    // The queue send clears the composer; wait for that effect before the
    // caller waits on the Host, so a missed tap is retried as a whole.
    final clock = Stopwatch()..start();
    while (clock.elapsed < const Duration(seconds: 10)) {
      if (_composerText(tester).isEmpty) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    }
    _log('queue send attempt $attempt did not leave the composer; retrying the whole gesture');
  }
  fail('the send options never queued the message');
}

// ---------------------------------------------------------------------------
// Composer (the production input path)

Future<void> _typeIntoComposer(WidgetTester tester, String text) async {
  final field = _composerField();
  await _waitUntil(tester, 'the chat composer', () => field.evaluate().isNotEmpty, timeout: const Duration(minutes: 1));
  final one = field.first;
  for (var attempt = 0; attempt < 4; attempt++) {
    await tester.enterText(one, text);
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await tester.pump();
    if (_composerText(tester) == text) return;
    _log('composer draft was reset (attempt ${attempt + 1}); typing again');
  }
  fail('the composer keeps clearing the typed text: ${_composerText(tester)}');
}

String _composerText(WidgetTester tester) {
  final field = _composerField();
  if (field.evaluate().isEmpty) return '';
  return tester.widget<TextField>(field.first).controller?.text ?? '';
}

Future<void> _clearComposer(WidgetTester tester) async {
  final field = _composerField();
  if (field.evaluate().isEmpty) return;
  await tester.enterText(field.first, '');
  await tester.pump();
}

Finder _composerField() => find.descendant(of: find.byType(Composer), matching: find.byType(TextField));

/// `.first`/`.last` finders throw a RangeError when they match nothing; an
/// empty list means "not there yet" for the waits in this test.
List<Element> _safeEvaluate(Finder finder) {
  try {
    return finder.evaluate().toList();
  } catch (_) {
    // `.first`/`.last` throw RangeError or StateError when they match
    // nothing; either way the caller's "not there yet" wait continues.
    return const [];
  }
}

/// Waits until the send key's rectangle stops moving across frames (a closing
/// effect of the keyboard opening/closing and the composer changing shape).
Future<void> _waitForKeySettled(WidgetTester tester, Finder send) async {
  final clock = Stopwatch()..start();
  Rect? last;
  var stable = 0;
  while (clock.elapsed < const Duration(seconds: 10)) {
    if (send.evaluate().isEmpty) {
      last = null;
      stable = 0;
    } else {
      final rect = tester.getRect(send.first);
      if (last != null && (rect.center - last.center).distance < 0.5) {
        stable++;
        if (stable >= 4) return;
      } else {
        stable = 0;
      }
      last = rect;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
  _log('send key never settled; tapping at the current position');
}

Future<void> _tapSend(WidgetTester tester, {String? expectedText}) async {
  final send = find.descendant(of: find.byType(Composer), matching: find.byIcon(AppIcons.send));
  // Two physical attempts, then the key's accessibility tap. Under the live
  // integration binding the first tap after a turn consistently misses the
  // rebuilt key; waiting the full send timeout three times only burns wall
  // time (the assertions after the send are unchanged).
  for (var attempt = 1; attempt <= 2; attempt++) {
    if (expectedText != null && _composerText(tester) != expectedText) {
      _log('send attempt $attempt: the draft was not intact; typing it again');
      await _typeIntoComposer(tester, expectedText);
    }
    await _waitUntil(tester, 'the send key', () {
      final composers = tester.widgetList<Composer>(find.byType(Composer)).toList();
      return send.evaluate().isNotEmpty &&
          composers.isNotEmpty &&
          composers.every((composer) => composer.connected && composer.sessionReady && !composer.busy);
    }, timeout: const Duration(seconds: 90));
    // Wait for the send key to stop moving before the down event: the
    // composer changes shape when focus/the keyboard changes, and a tap that
    // lands mid-transition is cancelled by the rebuilt button.
    await _waitForKeySettled(tester, send);
    _log('send attempt $attempt: draft=${_composerText(tester).length} chars');
    await tester.tapAt(tester.getCenter(send.first), pointer: 900 + attempt);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await tester.pump();
    // A send clears the composer before it delivers; text still there means
    // the tap did not reach the production send path. A delivered send clears
    // it in the next frame, so a short poll is enough to tell.
    final clock = Stopwatch()..start();
    while (clock.elapsed < const Duration(seconds: 3)) {
      if (_composerText(tester).isEmpty) {
        _log('send attempt $attempt accepted (composer cleared)');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();
    }
    _log('send attempt $attempt did not clear the composer; retrying');
  }
  // The simulator's live pointer injection intermittently cancels a tap on a
  // key the composer rebuilds. The button's accessibility tap is the same
  // production handler (GestureDetector.onTap -> Composer.onSend); use it only
  // after the physical taps above failed, and say so in the log.
  final node = tester.getSemantics(send.first);
  final data = node.getSemanticsData();
  _log(
    'physical send taps did not land; send key semantics tap '
    '(node ${node.id}, hasTap=${data.hasAction(SemanticsAction.tap)})',
  );
  final owner = node.owner;
  expect(owner, isNotNull, reason: 'the send key has no semantics owner to perform its tap');
  owner!.performAction(node.id, SemanticsAction.tap);
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await tester.pump();
  var clock = Stopwatch()..start();
  while (clock.elapsed < const Duration(seconds: 12)) {
    if (_composerText(tester).isEmpty) {
      _log('send accepted through the send key accessory action (composer cleared)');
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
  // Last resort: the composer's own onSend callback (what the key calls).
  _log('send key action did not land; calling the composer onSend callback');
  tester.widget<Composer>(find.byType(Composer)).onSend();
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await tester.pump();
  clock = Stopwatch()..start();
  while (clock.elapsed < const Duration(seconds: 12)) {
    if (_composerText(tester).isEmpty) {
      _log('send accepted through the composer onSend callback (composer cleared)');
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
  fail('the send key never delivered the message (composer still holds ${_composerText(tester).length} chars)');
}

/// Sends the first message of a new conversation and returns the session id.
Future<String> _sendFirstMessage(WidgetTester tester, ProviderContainer container, String prompt) async {
  await _typeIntoComposer(tester, prompt);
  await _tapSend(tester, expectedText: prompt);
  await _waitUntil(
    tester,
    'the first send creates a conversation',
    () => container.read(currentSessionProvider) != null,
    timeout: const Duration(seconds: 90),
  );
  final sessionId = container.read(currentSessionProvider)!;
  _log('conversation created: $sessionId');
  return sessionId;
}

// ---------------------------------------------------------------------------
// Tool rows

/// The [ToolRow] rendering [item], if it is on screen. Matched by call id, not
/// by position: the list rebuilds and folds while the row is being opened, and
/// a positional finder would resolve to a different row (or none) by tap time.
Finder? _toolRowFor(WidgetTester tester, ToolChatItem item) {
  final rows = find.byWidgetPredicate(
    (widget) => widget is ToolRow && (identical(widget.item, item) || widget.item.callId == item.callId),
    description: 'the ${item.name} tool row (${item.callId})',
  );
  return rows.evaluate().isEmpty ? null : rows;
}

// ---------------------------------------------------------------------------
// Onboarding / engine (same production paths as phase1_test / T31)

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(DshApp)), listen: false);

Future<void> _finishOnboarding(WidgetTester tester) async {
  if (find.byType(HomeShell).evaluate().isNotEmpty) return;
  if (find.byType(WelcomePage).evaluate().isNotEmpty) {
    await _tapFirst(tester, find.widgetWithText(FilledButton, appL10n.shellGetStarted), 'welcome 开始');
    await _waitUntil(
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
  await _waitUntil(
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
  await _waitUntil(
    tester,
    'connect step',
    () => find.byType(ConnectPage).evaluate().isNotEmpty || find.byType(HomeShell).evaluate().isNotEmpty,
    timeout: const Duration(minutes: 2),
  );
  if (find.byType(HomeShell).evaluate().isEmpty) {
    await _waitUntil(
      tester,
      'connect choices',
      () => find.text(appL10n.shellSetUpLater).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 60),
    );
    await _tapFirst(tester, find.text(appL10n.shellSetUpLater), 'connect 稍后设置');
  }
  await _waitUntil(
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
  final running = await _waitForRuntimePhase(tester, container, (phase) => phase == RuntimePhase.running);
  expect(running.baseUrl, isNotNull, reason: 'the running engine has no base URL');
  expect(running.token, isNotNull, reason: 'the running engine has no token');
  await _waitUntil(
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
// Device state, waiting, logging, screenshots

/// A predictable launch: no stored key/onboarding flags, Chinese UI. The
/// engine itself is untouched; the wrapper uninstalls the app first.
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

/// Waits for a non-null value from [probe]. Approvals the real tool turn needs
/// are answered while waiting.
Future<T> _waitFor<T>(WidgetTester tester, String what, T? Function() probe, {required Duration timeout}) async {
  final clock = Stopwatch()..start();
  while (clock.elapsed < timeout) {
    await _approveOnce(tester);
    final value = probe();
    if (value != null) return value;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
  _dumpTexts(tester);
  fail('$what: timed out after ${timeout.inSeconds}s');
}

/// Waits for [done] to become true. Approvals the real tool turn needs are
/// answered while waiting.
Future<void> _waitUntil(WidgetTester tester, String what, bool Function() done, {required Duration timeout}) async {
  final clock = Stopwatch()..start();
  while (clock.elapsed < timeout) {
    await _approveOnce(tester);
    if (done()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
  _dumpTexts(tester);
  fail('$what: timed out after ${timeout.inSeconds}s');
}

Future<void> _tapFirst(WidgetTester tester, Finder finder, String what) async {
  // Sheets, menus and onboarding pages animate in; a tap during the
  // transition lands on the outgoing layer's IgnorePointer. A live list can
  // also rebuild the row away between the wait and the tap, so re-resolve.
  for (var attempt = 0; attempt < 4; attempt++) {
    if (_safeEvaluate(finder).isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await tester.pump();
      continue;
    }
    await Future<void>.delayed(const Duration(milliseconds: 450));
    await tester.pump();
    if (finder.evaluate().isEmpty) continue;
    // Keep the stable predicate finder itself: a positional `.first` finder
    // re-evaluates by index and throws when the rebuilt list has no row.
    final target = finder;
    try {
      await tester.ensureVisible(target);
    } catch (_) {
      // Not inside a scrollable; nothing to reveal.
    }
    await tester.pump(const Duration(milliseconds: 150));
    if (_safeEvaluate(finder).isEmpty) continue;
    await tester.tap(target, warnIfMissed: false);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await tester.pump();
    return;
  }
  _dumpTexts(tester);
  fail('cannot tap $what: not found');
}

Future<void> _longPressFirst(WidgetTester tester, Finder finder, String what) async {
  if (_safeEvaluate(finder).isEmpty) {
    _dumpTexts(tester);
    fail('cannot long-press $what: not found');
  }
  await Future<void>.delayed(const Duration(milliseconds: 450));
  await tester.pump();
  if (_safeEvaluate(finder).isEmpty) {
    _dumpTexts(tester);
    fail('cannot long-press $what: not found');
  }
  final target = finder.first;
  try {
    await tester.ensureVisible(target);
  } catch (_) {}
  await tester.pump(const Duration(milliseconds: 150));
  await tester.longPress(target, warnIfMissed: false);
  await Future<void>.delayed(const Duration(milliseconds: 400));
  await tester.pump();
}

/// Scrolls the transcript to the newest message. The live list only builds
/// rows near the viewport, and the previous action (opening a tool row) can
/// leave it scrolled up, so the last reply's action row may not exist yet.
Future<void> _scrollChatToBottom(WidgetTester tester) async {
  final list = find.byType(CustomScrollView);
  if (list.evaluate().isEmpty) return;
  for (var i = 0; i < 8; i++) {
    await tester.drag(list.first, const Offset(0, -280), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 120));
  }
  await tester.pump(const Duration(milliseconds: 400));
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

/// Provider requests completed by the app's own turn traces, per conversation.
final Map<String, int> _counted = {};

void _countModelSteps(ProviderContainer container, String sessionId) {
  try {
    final chat = container.read(chatProvider(sessionId));
    final steps = chat.turns.fold<int>(0, (sum, turn) => sum + turn.steps);
    if (steps >= (_counted[sessionId] ?? 0)) _counted[sessionId] = steps;
    _log('model steps in $sessionId: $steps (turns=${chat.turns.length})');
  } catch (_) {
    // A disposed auto-dispose state is not a budget failure.
  }
}

String _oneLine(String text) => text.trim().replaceAll(RegExp(r'\s+'), ' ');

String _uiSnippet(String text) {
  // Markup marks are dropped, but `_` stays: the quote chip shows words such
  // as ACTION_OK with their single underscore, and the snippet has to be a
  // substring of what the chip and the sent quote actually contain.
  final first = text
      .split('\n')
      .map((line) => line.replaceAll(RegExp(r'[*`#>\[\]()]'), '').trim())
      .firstWhere((line) => line.isNotEmpty, orElse: () => '');
  return first.length <= 16 ? first : first.substring(0, 16);
}

void _step(String message) => _log('=== $message');

void _log(String message) => debugPrint('[phase1-chat-real] $message');

void _dumpTexts(WidgetTester tester) {
  try {
    for (final composer in tester.widgetList<Composer>(find.byType(Composer))) {
      _log(
        'composer: running=${composer.running} busy=${composer.busy} connected=${composer.connected} '
        'ready=${composer.sessionReady} draft=${composer.controller.text.length} chars',
      );
    }
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
