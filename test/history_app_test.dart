import 'dart:async';

import 'package:translate_app/src/common/constants/appearance_modes.dart';
import 'package:translate_app/src/common/widgets/native_glass.dart';
import 'package:translate_app/src/common/constants/method_names.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:translate_app/src/history/history_app.dart';
import 'package:translate_app/src/history/history_requests.dart';
import 'package:translate_app/src/history/translation_history.dart';

/// 无参数；用真实 SQLite 驱动窗口，验证卡片顺序、跨页浏览与保存失败反馈。
void main() {
  const channel = MethodChannel('test/history-window');
  late Database database;
  late TranslationHistoryStore store;

  setUp(() {
    database = sqlite3.openInMemory();
    store = TranslationHistoryStore(
      database,
      now: () => DateTime.fromMillisecondsSinceEpoch(0),
      onChanged: () {
        // 用原生转发的同一协议连接真实SQLite写入与历史窗口，不手工重建窗口。
        unawaited(
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .handlePlatformMessage(
                channel.name,
                const StandardMethodCodec().encodeMethodCall(
                  const MethodCall(MethodNames.historyChanged),
                ),
                (_) {},
              ),
        );
      },
    );
    // 仅替代原生转发层；查询、游标和开关均使用真实数据库结果。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          try {
            return handleHistoryRequest(store, call);
          } on SqliteException catch (error) {
            throw PlatformException(
              code: 'history_storage',
              message: error.message,
            );
          }
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    database.close();
  });

  testWidgets('历史随外观切换保持来源和正文可读，收到新增事件自动刷新', (tester) async {
    // 真实SQLite插入后由通知刷新，不重建窗口；两种主题检查实际卡片文本颜色。
    store.insert(
      sourceText: 'old source',
      translatedText: 'old translation',
      detectedLanguage: 'en',
      targetLanguage: 'zh',
      providerId: 'test',
      completedAt: 1,
      sourceLabel: 'Safari',
    );
    await tester.pumpWidget(const HistoryApp(channel: channel));
    await tester.pumpAndSettle();
    // Header三个控件分别保留12pt和8pt间距，不依赖文字本身留白。
    final refresh = tester.getRect(find.byIcon(Icons.refresh));
    final recording = tester.getRect(find.text('记录历史'));
    final toggle = tester.getRect(find.byType(NativeGlassSwitch));
    expect(recording.left - refresh.right, greaterThanOrEqualTo(12));
    expect(toggle.left - recording.right, 8);

    for (final mode in [AppearanceModes.dark, AppearanceModes.light]) {
      GlassAppearance.current.value = GlassAppearance(mode: mode);
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.text('Safari'))).brightness,
        mode == AppearanceModes.light ? Brightness.light : Brightness.dark,
      );
      final title = tester.widget<Text>(find.text('Safari'));
      final expected = mode == AppearanceModes.light
          ? Colors.black
          : Colors.white;
      expect(title.style!.color, expected);
      final content = tester.element(find.text('old translation'));
      expect(DefaultTextStyle.of(content).style.color, expected);
    }
    store.insert(
      sourceText: 'new source',
      translatedText: 'new translation',
      detectedLanguage: 'en',
      targetLanguage: 'zh',
      providerId: 'test',
      completedAt: 2,
      sourceLabel: 'Notes',
    );
    await tester.pumpAndSettle();
    expect(find.text('Notes'), findsOneWidget);
    expect(find.text('new translation'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    GlassAppearance.current.value = const GlassAppearance();
  });

  testWidgets('来源与本地日期组成标题，译文在原文上方，滚动可读第三页', (tester) async {
    // 23 条跨越两次 10 条边界；520×640 与实际历史窗口一致。
    tester.view.physicalSize = const Size(520, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (var i = 0; i < 23; i++) {
      store.insert(
        sourceText: 'source-$i',
        translatedText: '译文-$i',
        detectedLanguage: 'en',
        targetLanguage: 'zh-CN',
        providerId: 'google',
        completedAt: DateTime(2026, 9, 19, 9, 30, i).millisecondsSinceEpoch,
        sourceLabel: i == 22 ? '截图' : 'Safari',
      );
    }
    await tester.pumpWidget(const HistoryApp(channel: channel));
    await tester.pumpAndSettle();
    expect(find.text('截图'), findsOneWidget);
    expect(find.text('2026-09-19 09:30'), findsWidgets);
    expect(
      tester.getTopLeft(find.text('译文-22')).dy,
      lessThan(tester.getTopLeft(find.text('source-22')).dy),
    );
    await tester.scrollUntilVisible(
      find.text('source-0'),
      400,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
      maxScrolls: 60,
    );
    await tester.pumpAndSettle();
    expect(find.text('source-0'), findsOneWidget);
    expect(find.text('译文-0'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(find.text('已显示全部历史'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('长文及窄窗口可阅读，关闭记录保留卡片，存储失败不伪装保存成功', (tester) async {
    // 320pt 约束验证标题换行；只读 SQLite 真实触发保存失败，不能乐观切换开关。
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    store.insert(
      sourceText: '原文第一段\n\n${'long text ' * 60}',
      translatedText: '完整译文\n保留换行',
      detectedLanguage: 'en',
      targetLanguage: 'zh-CN',
      providerId: 'google',
      completedAt: 1000,
    );
    await tester.pumpWidget(const HistoryApp(channel: channel));
    await tester.pumpAndSettle();
    expect(find.text('未记录来源'), findsOneWidget);
    database.execute('PRAGMA query_only = ON');
    await tester.tap(find.byType(NativeGlassSwitch));
    await tester.pumpAndSettle();
    expect(
      tester.widget<NativeGlassSwitch>(find.byType(NativeGlassSwitch)).value,
      isTrue,
    );
    expect(find.textContaining('readonly'), findsOneWidget);
    database.execute('PRAGMA query_only = OFF');
    await tester.tap(find.byType(NativeGlassSwitch));
    await tester.pumpAndSettle();
    expect(store.recordingEnabled, isFalse);
    expect(find.text('已暂停记录；已有历史仍保留。'), findsOneWidget);
    expect(find.text('完整译文\n保留换行'), findsOneWidget);
    expect(store.page(), hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('刷新失败保留可见记录，恢复后重试首批替换而不重复追加', (tester) async {
    // 首批不足10条时已到末页；重命名真实表令刷新失败，重试仍需绕过末页状态。
    store.insert(
      sourceText: 'source',
      translatedText: '译文',
      detectedLanguage: 'en',
      targetLanguage: 'zh',
      providerId: 'test',
      completedAt: 1,
    );
    await tester.pumpWidget(const HistoryApp(channel: channel));
    await tester.pumpAndSettle();
    database.execute(
      'ALTER TABLE translation_history RENAME TO unavailable_history',
    );
    await tester.tap(find.byTooltip('刷新历史'));
    await tester.pumpAndSettle();
    expect(find.text('译文'), findsWidgets);
    expect(find.text('source'), findsOneWidget);
    database.execute(
      'ALTER TABLE unavailable_history RENAME TO translation_history',
    );
    database.execute("UPDATE translation_history SET translated_text = '刷新结果'");
    await tester.ensureVisible(find.text('重试加载'));
    await tester.tap(find.text('重试加载'));
    await tester.pumpAndSettle();
    expect(find.text('刷新结果'), findsOneWidget);
    expect(find.text('source'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('组合筛选回到首批，删除与全量清空取消不修改数据', (tester) async {
    // 11条跨页记录加一个其他来源；筛选只显示1条，清空仍必须覆盖全部12条。
    for (var index = 0; index < 11; index++) {
      store.insert(
        sourceText: 'source-$index',
        translatedText: '译文-$index',
        detectedLanguage: 'en',
        targetLanguage: 'zh',
        providerId: 'test',
        completedAt: index + 1,
        sourceLabel: 'Safari',
      );
    }
    store.insert(
      sourceText: 'unique',
      translatedText: '目标译文',
      detectedLanguage: 'en',
      targetLanguage: 'zh',
      providerId: 'test',
      completedAt: 100,
      sourceLabel: 'Notes',
    );
    await tester.pumpWidget(const HistoryApp(channel: channel));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('history-search')),
      '目标译文',
    );
    await tester.pumpAndSettle();
    expect(find.text('unique'), findsOneWidget);
    expect(find.text('source-10'), findsNothing);
    await tester.tap(find.byTooltip('删除翻译记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(store.page(limit: 20), hasLength(12));
    await tester.tap(find.byTooltip('删除翻译记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(store.page(limit: 20), hasLength(11));
    await tester.enterText(
      find.byKey(const ValueKey('history-search')),
      '译文-10',
    );
    await tester.pumpAndSettle();
    expect(find.text('source-10'), findsOneWidget);
    await tester.tap(find.text('清空全部'));
    await tester.pumpAndSettle();
    expect(find.textContaining('不受当前筛选范围限制'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(store.page(limit: 20), hasLength(11));
    await tester.tap(find.text('清空全部'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(store.page(), isEmpty);
    expect(find.text('暂无翻译历史'), findsOneWidget);
  });

  testWidgets('分页失败后重试原游标，保留已加载记录并追加剩余记录', (tester) async {
    // 11条记录形成10+1两批；SQLite真实缺表期间读取失败，恢复后不能重取首批。
    for (var index = 0; index < 11; index++) {
      store.insert(
        sourceText: 'source-$index',
        translatedText: 'result-$index',
        detectedLanguage: 'en',
        targetLanguage: 'zh',
        providerId: 'test',
        completedAt: index + 1,
      );
    }
    await tester.pumpWidget(const HistoryApp(channel: channel));
    await tester.pumpAndSettle();
    database.execute(
      'ALTER TABLE translation_history RENAME TO unavailable_history',
    );
    await tester.drag(find.byType(ListView), const Offset(0, -5000));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('重试加载'));
    database.execute(
      'ALTER TABLE unavailable_history RENAME TO translation_history',
    );
    await tester.tap(find.text('重试加载'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -1000));
    await tester.pumpAndSettle();
    expect(find.text('source-0'), findsOneWidget);
    expect(find.text('已显示全部历史'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, 5000));
    await tester.pumpAndSettle();
    expect(find.text('source-10'), findsOneWidget);
  });

  testWidgets('首次默认期限显示计数，取消不删，选择永久保留后持久生效', (tester) async {
    // 过期1条且偏好尚未确认；首次提示和90天预览均可取消，永久不清理。
    store.insert(
      sourceText: 'old',
      translatedText: '旧记录',
      detectedLanguage: 'en',
      targetLanguage: 'zh',
      providerId: 'test',
      completedAt: 1,
    );
    database.execute("DELETE FROM history_meta WHERE key LIKE 'retention_%'");
    store = TranslationHistoryStore(database, now: () => DateTime(2026, 11, 3));
    await tester.pumpWidget(const HistoryApp(channel: channel));
    await tester.pumpAndSettle();
    expect(find.textContaining('将清理 1 条记录'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(store.retentionConfirmed, isFalse);
    expect(store.page(), hasLength(1));
    await tester.tap(find.text('30 天'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('90 天'));
    await tester.pumpAndSettle();
    expect(find.textContaining('最近 90 天'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(store.retentionDays, 30);
    await tester.tap(find.text('30 天'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('永久保留'));
    await tester.pumpAndSettle();
    expect(store.retentionDays, 0);
    expect(store.retentionConfirmed, isTrue);
    expect(store.page(), hasLength(1));
    expect(find.text('旧记录'), findsOneWidget);
  });
}
