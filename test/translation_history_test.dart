import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:translate_app/src/history/translation_history.dart';

/// 无参数；验证真实 SQLite 的排序、分页、持久化与已有数据保留。
void main() {
  test('同毫秒的重复原文独立保存，分页期间新增记录不挤动后续页', () {
    // 12 条跨越 10 条边界；相同时间和原文验证 ID 次序与不去重。
    final database = sqlite3.openInMemory();
    addTearDown(database.close);
    final store = TranslationHistoryStore(
      database,
      now: () => DateTime.fromMillisecondsSinceEpoch(0),
    );
    for (var i = 0; i < 12; i++) {
      store.insert(
        sourceText: 'same source',
        translatedText: 't$i',
        detectedLanguage: 'en',
        targetLanguage: 'zh-CN',
        providerId: 'model-service',
        model: 'example-model',
        completedAt: 1000,
        sourceLabel: 'Safari',
      );
    }
    final first = store.page();
    expect(first, hasLength(10));
    expect(first.first.translatedText, 't11');
    expect(first.last.translatedText, 't2');
    expect(first.first.sourceLabel, 'Safari');
    expect(first.first.model, 'example-model');
    store.insert(
      sourceText: 'new',
      translatedText: '新',
      detectedLanguage: 'en',
      targetLanguage: 'zh-CN',
      providerId: 'google',
      completedAt: 1001,
      sourceLabel: '截图',
    );
    final second = store.page(before: first.last.cursor);
    expect(second.map((item) => item.translatedText), ['t1', 't0']);
    expect(store.page(before: second.last.cursor), isEmpty);
    expect(store.page().first.sourceLabel, '截图');
  });

  test('关闭并重开数据库后保留记录及关闭开关，重新启用后可继续记录', () {
    // 磁盘库模拟重启；关闭记录不能删除原有结果或在重启后自动开启。
    final directory = Directory.systemTemp.createTempSync(
      'translation-history-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/history.sqlite';
    var database = sqlite3.open(path);
    var store = TranslationHistoryStore(
      database,
      now: () => DateTime.fromMillisecondsSinceEpoch(0),
    );
    store.insert(
      sourceText: 'Hello',
      translatedText: '你好',
      detectedLanguage: 'en',
      targetLanguage: 'zh-CN',
      providerId: 'google',
      completedAt: 1000,
      sourceLabel: 'Safari',
    );
    store.recordingEnabled = false;
    database.close();
    database = sqlite3.open(path);
    addTearDown(database.close);
    store = TranslationHistoryStore(
      database,
      now: () => DateTime.fromMillisecondsSinceEpoch(0),
    );
    expect(store.recordingEnabled, isFalse);
    store.insert(
      sourceText: 'ignored',
      translatedText: 'ignored',
      detectedLanguage: 'en',
      targetLanguage: 'zh-CN',
      providerId: 'google',
      completedAt: 2000,
    );
    expect(store.page().single.sourceText, 'Hello');
    expect(store.page().single.sourceLabel, 'Safari');
    expect(store.page().single.detectedLanguage, 'en');
    expect(store.page().single.targetLanguage, 'zh-CN');
    expect(store.page().single.providerId, 'google');
    expect(store.page().single.completedAt, 1000);
    store.recordingEnabled = true;
    store.insert(
      sourceText: 'Hello',
      translatedText: '你好',
      detectedLanguage: 'en',
      targetLanguage: 'zh-CN',
      providerId: 'google',
      completedAt: 3000,
    );
    expect(store.page(), hasLength(2));
  });

  test('新增来源字段保留已有记录和关闭偏好，不猜测旧记录来源', () {
    // 使用已交付的数据库结构，验证扩展字段时没有清库或覆盖用户设置。
    final database = sqlite3.openInMemory();
    addTearDown(database.close);
    database.execute('''
      CREATE TABLE translation_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT, source_text TEXT NOT NULL,
        translated_text TEXT NOT NULL, detected_language TEXT NOT NULL,
        target_language TEXT NOT NULL, provider_id TEXT NOT NULL,
        model TEXT, completed_at INTEGER NOT NULL
      );
      INSERT INTO translation_history VALUES(1, 'old', '旧译文', 'en', 'zh-CN', 'google', NULL, 1000);
      CREATE TABLE history_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      INSERT INTO history_meta VALUES('recording', '0');
    ''');
    final store = TranslationHistoryStore(
      database,
      now: () => DateTime.fromMillisecondsSinceEpoch(0),
    );
    expect(store.page().single.translatedText, '旧译文');
    expect(store.page().single.sourceLabel, isNull);
    expect(store.recordingEnabled, isFalse);
  });

  test('搜索原文译文、来源与日期交集，关键词符号不作为通配符', () {
    // 同一天起点包含、下一天起点排除；11 条命中项跨越固定10条游标边界。
    final database = sqlite3.openInMemory();
    addTearDown(database.close);
    final store = TranslationHistoryStore(
      database,
      now: () => DateTime(2026, 11, 3),
    );
    final from = DateTime(2026, 11, 2).millisecondsSinceEpoch;
    final to = DateTime(2026, 11, 3).millisecondsSinceEpoch;
    for (var index = 0; index < 11; index++) {
      store.insert(
        sourceText: index.isEven ? 'Needle_%' : 'other',
        translatedText: index.isOdd ? 'needle_%译文' : 'other',
        detectedLanguage: 'en',
        targetLanguage: 'zh',
        providerId: 'test',
        completedAt: from + index,
        sourceLabel: 'Safari',
      );
    }
    store.insert(
      sourceText: 'needle_%',
      translatedText: 'before',
      detectedLanguage: 'en',
      targetLanguage: 'zh',
      providerId: 'test',
      completedAt: from - 1,
      sourceLabel: 'Safari',
    );
    store.insert(
      sourceText: 'needle_%',
      translatedText: 'end',
      detectedLanguage: 'en',
      targetLanguage: 'zh',
      providerId: 'test',
      completedAt: to,
      sourceLabel: 'Safari',
    );
    store.insert(
      sourceText: 'needle_%',
      translatedText: 'unknown',
      detectedLanguage: 'en',
      targetLanguage: 'zh',
      providerId: 'test',
      completedAt: from,
    );
    store.insert(
      sourceText: 'needleZZ',
      translatedText: 'wildcard',
      detectedLanguage: 'en',
      targetLanguage: 'zh',
      providerId: 'test',
      completedAt: from,
      sourceLabel: 'Safari',
    );
    final first = store.page(
      query: 'needle_%',
      source: 'Safari',
      from: from,
      to: to,
    );
    final second = store.page(
      query: 'needle_%',
      source: 'Safari',
      from: from,
      to: to,
      before: first.last.cursor,
    );
    expect(first, hasLength(10));
    expect(second.single.completedAt, from);
    expect(store.page(source: '未记录来源').single.translatedText, 'unknown');
    expect(store.sources(), ['Safari', '未记录来源']);
  });

  test('首次默认期限等待确认，确认事务仅清理翻译历史且边界包含', () {
    // 30天边界前1毫秒过期、恰在边界保留；模拟已有库无期限偏好。
    final database = sqlite3.openInMemory();
    addTearDown(database.close);
    final now = DateTime(2026, 11, 3);
    var store = TranslationHistoryStore(database, now: () => now);
    store.setRetention(0);
    final cutoff = now
        .subtract(const Duration(days: 30))
        .millisecondsSinceEpoch;
    for (final stamp in [cutoff - 1, cutoff, now.millisecondsSinceEpoch]) {
      store.insert(
        sourceText: 'source',
        translatedText: '$stamp',
        detectedLanguage: 'en',
        targetLanguage: 'zh',
        providerId: 'test',
        completedAt: stamp,
      );
    }
    database.execute("DELETE FROM history_meta WHERE key LIKE 'retention_%'");
    database.execute(
      "CREATE TABLE vocabulary (word TEXT); INSERT INTO vocabulary VALUES('keep');",
    );
    store = TranslationHistoryStore(database, now: () => now);
    expect(store.retentionDays, 30);
    expect(store.retentionConfirmed, isFalse);
    expect(store.expiredCount(30), 1);
    expect(store.page(), hasLength(3));
    // 预览其他期限不提交，模拟取消后重开仍待确认且数据完整。
    expect(store.expiredCount(90), 0);
    store = TranslationHistoryStore(database, now: () => now);
    expect(store.retentionConfirmed, isFalse);
    expect(store.page(), hasLength(3));
    store.setRetention(30);
    expect(store.retentionConfirmed, isTrue);
    expect(store.page().map((row) => row.completedAt), [
      now.millisecondsSinceEpoch,
      cutoff,
    ]);
    store.delete(store.page().first.id);
    expect(store.page().single.completedAt, cutoff);
    store.clear();
    expect(store.page(), isEmpty);
    expect(
      database.select('SELECT word FROM vocabulary').single['word'],
      'keep',
    );
  });

  test('读取只按期限过滤不删除；改为永久时已过期记录不再出现', () {
    // 作用：列表与来源读取不写库（#68）。边界：时间前进 1 毫秒跨过 30 天下界，库中行仍在；随后改为永久，该行已按原期限删除。
    final database = sqlite3.openInMemory();
    addTearDown(database.close);
    var now = DateTime(2026, 11, 3);
    final store = TranslationHistoryStore(database, now: () => now);
    store.insert(
      sourceText: 'edge',
      translatedText: '边界',
      detectedLanguage: 'en',
      targetLanguage: 'zh',
      providerId: 'test',
      completedAt: now
          .subtract(const Duration(days: 30))
          .millisecondsSinceEpoch,
    );
    now = now.add(const Duration(milliseconds: 1));
    expect(store.page(), isEmpty);
    expect(store.sources(), isEmpty);
    expect(
      database.select('SELECT COUNT(*) AS c FROM translation_history').single['c'],
      1,
    );
    store.setRetention(0);
    expect(store.page(), isEmpty);
  });

  test('已确认期限随时钟清理，永久与只读失败保持设置和数据', () {
    // 时间前进1毫秒跨越30天边界；真实只读SQLite拒绝写入，随后恢复可继续提交。
    final database = sqlite3.openInMemory();
    addTearDown(database.close);
    var now = DateTime(2026, 11, 3);
    final store = TranslationHistoryStore(database, now: () => now);
    store.insert(
      sourceText: 'edge',
      translatedText: '边界',
      detectedLanguage: 'en',
      targetLanguage: 'zh',
      providerId: 'test',
      completedAt: now
          .subtract(const Duration(days: 30))
          .millisecondsSinceEpoch,
    );
    expect(store.page(), hasLength(1));
    now = now.add(const Duration(milliseconds: 1));
    expect(store.page(), isEmpty);
    store.setRetention(0);
    store.insert(
      sourceText: 'old',
      translatedText: '永久',
      detectedLanguage: 'en',
      targetLanguage: 'zh',
      providerId: 'test',
      completedAt: 1,
    );
    database.execute('PRAGMA query_only = ON');
    expect(() => store.setRetention(365), throwsA(isA<SqliteException>()));
    expect(store.retentionDays, 0);
    expect(store.page().single.sourceText, 'old');
    database.execute('PRAGMA query_only = OFF');
    store.setRetention(365);
    expect(store.page(), isEmpty);
  });
}
