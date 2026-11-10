// D2-04 · 模型切换与思考深度 — Phase 1 acceptance tests (L2).
//
// AC1 聊天内换模型 → 选择落到 session（session/selectModel）、下一条消息在同一
// session 发出；AC2 思考档位随模型声明显示/隐藏，选择携带 reasoningEffort；
// AC3 切换失败回退到上一个模型、报错、输入不丢；无模型时给配置入口。
//
// L4（mock 模型日志断言请求 model 字段）deferred to T22: this worktree has no
// Engine payload. The L2 protocol test drives the real DshClient/ChatController
// against a loopback fake host, so the request shape is real.

import 'dart:io';

import 'package:dsh_app/state/attachments.dart' show DraftAttachment;
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/providers/provider_form_page.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import '../chat/support/session_sync_host.dart';

const _previous = ModelSelection(provider: 'deepseek-official', model: 'deepseek-v4-pro', reasoningEffort: 'high');

final _multiCatalog = ModelCatalog(
  defaultSelection: _previous,
  routableProviders: const ['deepseek-official', 'openrouter'],
  groups: [
    ...testCatalog.groups,
    const ProviderGroup('openrouter', 'OpenRouter', [
      ModelInfo(provider: 'openrouter', id: 'moonshotai/kimi-k2', name: 'Kimi-K2', description: '长上下文，擅长写代码'),
    ]),
  ],
  failures: const [],
);

/// Records what the chat did, in order, so "switch first, then send" is a
/// behavioural assertion rather than a mock-call count.
class _RecordingChatController extends FakeChatController {
  _RecordingChatController(super.sessionId, super.initial) {
    applyModelSelection = true;
  }

  final order = <String>[];

  @override
  Future<bool> setModel(ModelSelection selection) async {
    order.add('model:${selection.model}');
    models.add(selection);
    state = state.copyWith(model: selection);
    return true;
  }

  @override
  Future<bool> send(
    String text, {
    List<DraftAttachment> attachments = const [],
    SendMode mode = SendMode.now,
    bool verbatim = false,
    Future<bool> Function(String requestId)? beforeDeliver,
    bool Function()? deliveryAllowed,
  }) {
    order.add('send:$text');
    return super.send(
      text,
      attachments: attachments,
      mode: mode,
      verbatim: verbatim,
      beforeDeliver: beforeDeliver,
      deliveryAllowed: deliveryAllowed,
    );
  }
}

/// A controller whose engine refuses the switch: state rolls back to the
/// previous model and carries the user-facing error.
class _FailingModelChatController extends FakeChatController {
  _FailingModelChatController(super.sessionId, super.initial) {
    modelSwitchSucceeds = false;
    modelSwitchError = '模型切换失败：渠道已被删除';
  }
}

ChatHarness _harness({
  required FakeChatController controller,
  ModelCatalog? catalog,
  AppSettings settings = const AppSettings(loaded: true, apiKey: testKey),
}) => ChatHarness(
  session: 's1',
  states: {'s1': controller.initial},
  catalog: catalog ?? testCatalog,
  settings: settings,
  chatController: (id) => controller,
);

Future<void> _openSheet(WidgetTester tester) async {
  // The composer's model pill lives in the expanded (typing) composer row.
  await tester.tap(find.byType(TextField).first);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.tap(find.byKey(const ValueKey('composer-model')));
  await pumpFrames(tester, 8);
}

Future<void> _dismissSheet(WidgetTester tester) async {
  await tester.tapAt(const Offset(10, 100));
  await pumpFrames(tester, 6);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('D2-04_switch_model_applies_to_next_turn', (tester) async {
    usePhoneView(tester);
    mockClipboard(tester);
    final controller = _RecordingChatController('s1', const ChatState(loading: false, model: _previous));
    final harness = _harness(controller: controller);
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await pumpFrames(tester, 6);

    await _openSheet(tester);
    await tester.tap(find.text('V41 Flash'));
    await pumpFrames(tester, 6);
    // The session selection was written and the visible pill follows it.
    expect(controller.models.single.model, 'deepseek-flash');
    expect(controller.state.model!.model, 'deepseek-flash');
    expect(find.textContaining('V41 Flash'), findsWidgets);

    await _dismissSheet(tester);
    await tester.enterText(find.byType(TextField).first, '下一轮用新模型');
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.send));
    await pumpFrames(tester, 4);

    expect(controller.sent, ['下一轮用新模型']);
    expect(controller.order, [
      'model:deepseek-flash',
      'send:下一轮用新模型',
    ], reason: 'the switch lands before the next message is sent');
  });

  testWidgets('D2-04_thinking_levels_hidden_when_unsupported', (tester) async {
    usePhoneView(tester);
    mockClipboard(tester);
    final controller = _RecordingChatController('s1', const ChatState(loading: false, model: _previous));
    final harness = _harness(controller: controller, catalog: _multiCatalog);
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await pumpFrames(tester, 6);

    await _openSheet(tester);
    // V4 Pro declares thinking levels: 不思考 + every declared level.
    expect(find.text('思考深度'), findsOneWidget);
    for (final label in ['不思考', '低', '高', '最高']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    await tester.tap(find.text('最高'));
    await pumpFrames(tester, 10);
    expect(controller.models.single.reasoningEffort, 'max');

    // A model without declared levels hides the whole selector.
    await _openSheet(tester);
    await tester.tap(find.text('OpenRouter'));
    await pumpFrames(tester, 4);
    await tester.tap(find.text('Kimi K2'));
    await pumpFrames(tester, 6);
    expect(find.text('思考深度'), findsNothing);
    expect(controller.models.last.model, 'moonshotai/kimi-k2');
    expect(controller.models.last.reasoningEffort, isNull);
  });

  test('D2-04_model_selection_persists_via_select_model', () async {
    final requests = <Map<String, Object?>>[];
    await HttpOverrides.runWithHttpOverrides(() async {
      final h = await SyncHarness.start();
      try {
        h.host.handlers['session/selectModel'] = (args) {
          final request = Map<String, Object?>.from(args['request']! as Map);
          requests.add(request);
          return {
            'ok': true,
            'value': {
              'selected': request,
              'defaultSave': {'status': 'saved'},
            },
          };
        };
        const selection = ModelSelection(
          provider: 'deepseek-official',
          model: 'deepseek-flash',
          reasoningEffort: 'max',
        );
        expect(await h.chat.setModel(selection), isTrue);
        expect(h.state.model!.toJson(), selection.toJson());
        expect(h.state.error, isNull);
        expect(h.state.defaultModelSaveFailed, isFalse);
        // The request that persists the next-chat default carries the model
        // and the thinking level.
        expect(requests.single, {
          'sessionId': 'S',
          'provider': 'deepseek-official',
          'model': 'deepseek-flash',
          'reasoningEffort': 'max',
        });
      } finally {
        await h.close();
      }
    }, RealSyncHttp());
  });

  test('D2-04_switch_failure_keeps_previous_model', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final h = await SyncHarness.start();
      try {
        var fail = false;
        h.host.handlers['session/selectModel'] = (args) {
          final request = args['request']! as Map;
          if (fail) {
            return {
              'ok': false,
              'error': {'code': 'gateway/internal', 'message': 'model unavailable', 'details': {}},
            };
          }
          return {
            'ok': true,
            'value': {'selected': request},
          };
        };
        expect(await h.chat.setModel(_previous), isTrue);
        final before = h.state;
        fail = true;
        const gone = ModelSelection(provider: 'deepseek-official', model: 'deleted-model');
        expect(await h.chat.setModel(gone), isFalse);
        expect(h.state.model!.toJson(), _previous.toJson());
        expect(h.state.error, isNotNull);
        expect(h.state.items, before.items);
        expect(h.state.pending, before.pending);
      } finally {
        await h.close();
      }
    }, RealSyncHttp());
  });

  testWidgets('D2-04_switch_failure_keeps_previous_model_and_draft', (tester) async {
    usePhoneView(tester);
    mockClipboard(tester);
    final controller = _FailingModelChatController('s1', const ChatState(loading: false, model: _previous));
    final harness = _harness(controller: controller);
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await pumpFrames(tester, 6);

    const draft = '这条草稿不能丢';
    await tester.enterText(find.byType(TextField).first, draft);
    await tester.pump();
    await _openSheet(tester);
    await tester.tap(find.text('V41 Flash'));
    await pumpFrames(tester, 6);

    // The failure is readable, the previous model stays selected, and the
    // composer still holds what was typed.
    expect(find.text('模型切换失败：渠道已被删除'), findsOneWidget);
    expect(find.textContaining('V4 Pro'), findsWidgets);
    expect(tester.widget<TextField>(find.byType(TextField).first).controller!.text, draft);
    expect(controller.models.single.model, 'deepseek-flash');
  });

  testWidgets('D2-04_no_models_offers_configuration_entry', (tester) async {
    usePhoneView(tester);
    mockClipboard(tester);
    final harness = ChatHarness(
      session: 's1',
      states: const {'s1': ChatState(loading: false)},
      settings: const AppSettings(loaded: true),
      catalog: ModelCatalog.fromJson(const {'groups': <Object?>[]}),
    );
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await pumpFrames(tester, 6);
    await _openSheet(tester);
    expect(find.text('需要 API Key'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '添加其他渠道'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '添加其他渠道'));
    await pumpFrames(tester, 6);
    expect(find.byType(ProviderFormPage), findsOneWidget);
  });
}
