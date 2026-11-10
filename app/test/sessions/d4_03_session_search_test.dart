// D4-03 · 会话搜索（标题即时匹配 / 多关键词 AND / 高亮 / 内容索引）— Phase 1 验收测试。
//
//   flutter test test/sessions/d4_03_session_search_test.dart
//
// AC 依据 `docs/specs/phase1/capability-spec.md#D4-03`：
//   AC1 标题即时匹配、多关键词按 AND 匹配（任意顺序）、命中高亮；清空恢复列表。
//   AC2 内容索引可用时返回正文命中；未索引/远程主机只搜标题并给出说明。
// 边界（spec「错误/边界」）：空关键词不搜；超长输入；无结果空状态。

import 'package:dsh_app/state/session_search.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/shell/session_search_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../search/support.dart';
import '../shell/golden_harness.dart';

List<Override> _searchOverrides(FakeContentSearch backend) => [
  sessionsProvider.overrideWith(() => SearchSessions(sampleSearchSessions(), sampleArchivedSessions())),
  sessionContentSearchProvider.overrideWithValue(backend),
  currentSessionProvider.overrideWith(() => FakeCurrentSession(null)),
];

Finder _tileOf(String title) => find.ancestor(of: find.text(title), matching: find.byType(SearchResultTile));

/// All highlighted runs the results show, in render order.
List<HighlightedText> _highlights(WidgetTester tester) => tester.widgetList<HighlightedText>(find.byType(HighlightedText)).toList();

Future<void> _pumpPage(WidgetTester tester, FakeContentSearch backend, {bool unsupported = false}) async {
  if (unsupported) backend.markUnsupported();
  usePhoneSurface(tester);
  await tester.pumpWidget(
    goldenApp(
      home: SessionSearchPage(now: searchNow),
      brightness: Brightness.light,
      overrides: _searchOverrides(backend),
    ),
  );
  await tester.pump();
}

/// Lets the debounce run out and the fake Host answer.
Future<void> _settleSearch(WidgetTester tester) async {
  await tester.pump(SessionSearchController.debounce);
  await tester.pump();
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('D4-03 会话搜索', () {
    testWidgets('D4-03_search_multi_keyword_and_highlight', (tester) async {
      final backend = FakeContentSearch();
      await _pumpPage(tester, backend);

      // AC1：标题即时匹配（不等 Host、不等防抖）。
      await tester.enterText(find.byType(TextField), '登录');
      await tester.pump();
      expect(_tileOf('修复登录按钮重复提交'), findsOneWidget, reason: 'D4-03-AC1: 标题随输入即时匹配');
      expect(_tileOf('登录页加上记住密码'), findsOneWidget);
      expect(_tileOf('给设置页加深色模式'), findsNothing);
      expect(backend.calls, isEmpty, reason: 'D4-03-AC1: 防抖前只做本地标题匹配');

      // AC1：多关键词按 AND 匹配（两个词都要在标题里）。
      await tester.enterText(find.byType(TextField), '登录 密码');
      await tester.pump();
      expect(_tileOf('登录页加上记住密码'), findsOneWidget, reason: 'D4-03-AC1: 多关键词 AND 命中');
      expect(_tileOf('修复登录按钮重复提交'), findsNothing, reason: 'D4-03-AC1: 缺一个关键词就不命中');

      // AC1：关键词顺序不影响结果。
      await tester.enterText(find.byType(TextField), '密码 登录');
      await tester.pump();
      expect(_tileOf('登录页加上记住密码'), findsOneWidget, reason: 'D4-03-AC1: 关键词顺序不影响匹配');

      // AC1：命中高亮——标题的两个词各自是一段高亮。
      final title = _highlights(tester).where((h) => h.text == '登录页加上记住密码').toList();
      expect(title, isNotEmpty, reason: 'D4-03-AC1: 命中文本走高亮渲染');
      expect(
        title.first.ranges.length,
        2,
        reason: 'D4-03-AC1: 两个关键词各自高亮（实际 ${title.first.ranges}）',
      );
      expect(title.first.text.substring(title.first.ranges[0].start, title.first.ranges[0].end), '登录');
      expect(title.first.text.substring(title.first.ranges[1].start, title.first.ranges[1].end), '密码');

      // AC1：清空恢复列表（回到主机提示，不再有结果）。
      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      expect(find.byType(SearchResultTile), findsNothing, reason: 'D4-03-AC1: 清空后恢复列表');
      expect(find.text('搜索「本机」上的对话'), findsOneWidget);
    });

    testWidgets('D4-03_search_content_hits_when_indexed', (tester) async {
      final backend = FakeContentSearch(results: {'登录': (items: loginHits, hasMore: false)});
      await _pumpPage(tester, backend);

      await tester.enterText(find.byType(TextField), '登录');
      await _settleSearch(tester);

      // AC2：内容索引可用时返回正文命中，并带上命中片段。
      expect(_tileOf('Retrofit 拦截器加 token 刷新'), findsOneWidget, reason: 'D4-03-AC2: 正文命中出现在结果里');
      final excerpts = tester
          .widgetList<HighlightedText>(find.descendant(of: _tileOf('Retrofit 拦截器加 token 刷新'), matching: find.byType(HighlightedText)))
          .toList();
      expect(
        excerpts.any((h) => h.text.contains('登录') && h.ranges.isNotEmpty),
        isTrue,
        reason: 'D4-03-AC2: 正文命中显示命中片段并高亮',
      );
      // 标题命中仍在（s1），子代理会话被过滤。
      expect(_tileOf('修复登录按钮重复提交'), findsOneWidget);
      expect(find.textContaining('子代理的会话不该出现'), findsNothing, reason: 'D4-03-AC2: 子代理会话不进搜索结果');
      expect(backend.calls, ['登录']);
    });

    testWidgets('D4-03_search_without_index_title_only', (tester) async {
      // 主机没有内容索引：只搜标题，并说明原因。
      final backend = FakeContentSearch(results: {'登录': (items: loginHits, hasMore: false)});
      await _pumpPage(tester, backend, unsupported: true);

      await tester.enterText(find.byType(TextField), '登录');
      await _settleSearch(tester);

      expect(find.text('这台主机仅支持按标题搜索'), findsOneWidget, reason: 'D4-03-AC2: 未索引主机给出说明');
      expect(_tileOf('修复登录按钮重复提交'), findsOneWidget, reason: 'D4-03-AC2: 仍按标题匹配');
      expect(_tileOf('Retrofit 拦截器加 token 刷新'), findsNothing, reason: 'D4-03-AC2: 未索引主机不返回正文命中');
      expect(backend.calls, isEmpty, reason: 'D4-03-AC2: 已知不支持后不再请求内容搜索');
    });

    testWidgets('D4-03_search_empty_and_overlong_queries', (tester) async {
      final backend = FakeContentSearch();
      await _pumpPage(tester, backend);

      // 边界：空关键词不搜（连 Host 都不问）。
      await tester.enterText(find.byType(TextField), '   ');
      await _settleSearch(tester);
      expect(backend.calls, isEmpty, reason: 'D4-03 边界: 空关键词不发起搜索');
      expect(find.text('搜索「本机」上的对话'), findsOneWidget);

      // 边界：超长输入被输入框截断（200 字符），不崩、不越界。
      final long = List.filled(SessionSearchController.maxContentQueryLength + 100, '长').join();
      await tester.enterText(find.byType(TextField), long);
      await _settleSearch(tester);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text.length,
        200,
        reason: 'D4-03 边界: 超长输入截断到输入框上限',
      );
      expect(backend.calls.length, lessThanOrEqualTo(1), reason: 'D4-03 边界: 只发一次查询');
      expect(tester.takeException(), isNull, reason: 'D4-03 边界: 超长输入不崩溃');
    });

    testWidgets('D4-03_search_no_results_empty_state', (tester) async {
      final backend = FakeContentSearch();
      await _pumpPage(tester, backend);

      await tester.enterText(find.byType(TextField), '不存在的关键词');
      await _settleSearch(tester);
      expect(find.byType(SearchResultTile), findsNothing);
      expect(find.text('没有相关对话'), findsOneWidget, reason: 'D4-03 边界: 无结果显示空状态');
      expect(find.text('换个关键词，或用空格分开多个词'), findsOneWidget);
    });
  });
}
