import 'package:sqlite3/sqlite3.dart';

/// 分页位置；时间与自增 ID 一起保证同毫秒记录及新增记录不会造成重复分页。
typedef HistoryCursor = ({int completedAt, int id});

/// 一条完整成功的翻译记录。
class TranslationRecord {
  const TranslationRecord({
    required this.id,
    required this.sourceText,
    required this.translatedText,
    required this.detectedLanguage,
    required this.targetLanguage,
    required this.providerId,
    required this.completedAt,
    this.model,
    this.sourceLabel,
  });

  final int id;
  final String sourceText;
  final String translatedText;
  final String detectedLanguage;
  final String targetLanguage;
  final String providerId;
  final String? model;
  final int completedAt;

  /// 来源应用显示名称或「截图」；未记录来源的已有数据为空，不推断其来源。
  final String? sourceLabel;

  /// 无参数；返回供下一页查询使用的稳定时间/ID 游标。
  HistoryCursor get cursor => (completedAt: completedAt, id: id);

  /// map 为主引擎返回的完整历史字段；返回用于卡片展示的记录。
  factory TranslationRecord.fromMap(Map<Object?, Object?> map) =>
      TranslationRecord(
        id: map['id'] as int,
        sourceText: map['sourceText'] as String,
        translatedText: map['translatedText'] as String,
        detectedLanguage: map['detectedLanguage'] as String,
        targetLanguage: map['targetLanguage'] as String,
        providerId: map['providerId'] as String,
        completedAt: map['completedAt'] as int,
        model: map['model'] as String?,
        sourceLabel: map['sourceLabel'] as String?,
      );
}

/// SQLite 翻译历史；只在整篇成功后写入。database 由调用方提供以便测试用内存库。
class TranslationHistoryStore {
  /// database 为唯一历史数据库，now 为期限比较的时钟；初始化表及持久偏好。
  TranslationHistoryStore(
    this.database, {
    this.onChanged,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    database.execute('''
CREATE TABLE IF NOT EXISTS translation_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  source_text TEXT NOT NULL,
  translated_text TEXT NOT NULL,
  detected_language TEXT NOT NULL,
  target_language TEXT NOT NULL,
  provider_id TEXT NOT NULL,
  model TEXT,
  completed_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS history_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
''');
    // 本地已有历史不能因新增来源字段丢失；只扩展表结构，不伪造旧记录的来源。
    final columns = database.select('PRAGMA table_info(translation_history)');
    if (!columns.any((column) => column['name'] == 'source_label')) {
      database.execute(
        'ALTER TABLE translation_history ADD COLUMN source_label TEXT',
      );
    }
    database.execute('''CREATE INDEX IF NOT EXISTS history_completed_order
      ON translation_history(completed_at DESC, id DESC)''');
    // 仅在缺少开关记录时填入默认值，主键冲突保留用户已有选择。
    database.execute('''
INSERT INTO history_meta(key, value) VALUES('recording', '1')
ON CONFLICT(key) DO NOTHING
''');
    // 默认期限先等待已有过期记录的确认；无过期记录时可直接应用。
    database.execute('''
INSERT INTO history_meta(key, value) VALUES('retention_days', '30')
ON CONFLICT(key) DO NOTHING;
INSERT INTO history_meta(key, value) VALUES('retention_confirmed', '0')
ON CONFLICT(key) DO NOTHING;
''');
    if (!retentionConfirmed && expiredCount(retentionDays) == 0) {
      database.execute(
        "UPDATE history_meta SET value = '1' WHERE key = 'retention_confirmed'",
      );
    }
    // 启动时按已确认期限清理一次，之后由写入与设置期限继续清理。
    _prune();
  }

  final Database database;
  final DateTime Function() _now;

  /// 没有来源名称的记录在筛选与列表中显示的名称，Store 与窗口共用。
  static const unknownSource = '未记录来源';

  /// 可用保留天数；0 表示永久，Store 与窗口使用同一组选项。
  static const retentionOptions = {
    30: '30 天',
    90: '90 天',
    365: '365 天',
    0: '永久保留',
  };

  /// 无参数；返回已存期限天数，0 表示永久。
  int get retentionDays => int.parse(
    database
            .select(
              "SELECT value FROM history_meta WHERE key = 'retention_days'",
            )
            .single['value']
        as String,
  );

  /// 无参数；返回期限是否已获确认并允许自动清理。
  bool get retentionConfirmed =>
      database
          .select(
            "SELECT value FROM history_meta WHERE key = 'retention_confirmed'",
          )
          .single['value'] ==
      '1';

  /// days 为待应用天数；返回严格早于完成时间边界的记录数，永久为 0。
  int expiredCount(int days) {
    if (!retentionOptions.containsKey(days)) {
      throw ArgumentError.value(days, 'days');
    }
    if (days == 0) return 0;
    final cutoff = _now().subtract(Duration(days: days)).millisecondsSinceEpoch;
    return database.select(
          'SELECT COUNT(*) AS count FROM translation_history WHERE completed_at < ?',
          [cutoff],
        ).single['count']
        as int;
  }

  /// days 为用户确认的期限；事务保存偏好并清理过期记录，无返回值。
  void setRetention(int days) {
    if (!retentionOptions.containsKey(days)) {
      throw ArgumentError.value(days, 'days');
    }
    database.execute('BEGIN');
    try {
      // 先按原期限删除已过期记录：读取只过滤不删除，改为更长期限时不能让已过期记录重新出现。
      _prune();
      database.execute(
        "UPDATE history_meta SET value = ? WHERE key = 'retention_days'",
        ['$days'],
      );
      database.execute(
        "UPDATE history_meta SET value = '1' WHERE key = 'retention_confirmed'",
      );
      // 清理和偏好处于同一事务，失败不能留下已应用的设置。
      _prune();
      database.execute('COMMIT');
    } catch (_) {
      database.execute('ROLLBACK');
      rethrow;
    }
    onChanged?.call();
  }

  /// 无参数；返回已确认期限的完成时间下界（毫秒），未确认或永久保留时为 null。
  int? _cutoff() {
    if (!retentionConfirmed || retentionDays == 0) return null;
    return _now().subtract(Duration(days: retentionDays)).millisecondsSinceEpoch;
  }

  /// 无参数；按已确认期限删除过期记录，无返回值；只在写入、设置期限与启动时调用，调用方负责通知。
  void _prune() {
    final cutoff = _cutoff();
    if (cutoff == null) return;
    database.execute('DELETE FROM translation_history WHERE completed_at < ?', [
      cutoff,
    ]);
  }

  /// id 为待删记录主键；只删除该翻译记录，成功后通知，无返回值。
  void delete(int id) {
    database.execute('DELETE FROM translation_history WHERE id = ?', [id]);
    if (database.updatedRows > 0) onChanged?.call();
  }

  /// 无参数；清空全部翻译历史并通知，不操作其他表，无返回值。
  void clear() {
    database.execute('DELETE FROM translation_history');
    if (database.updatedRows > 0) onChanged?.call();
  }

  /// 无参数；返回期限内的来源名称，空来源统一为 unknownSource。
  List<String> sources() {
    // 与列表查询使用同一期限下界，读取不删除记录。
    final cutoff = _cutoff();
    return [
      for (final row in database.select(
        "SELECT DISTINCT COALESCE(NULLIF(source_label, ''), ?) AS source FROM translation_history"
        '${cutoff == null ? '' : ' WHERE completed_at >= ?'} ORDER BY source COLLATE NOCASE',
        [unknownSource, ?cutoff],
      ))
        row['source'] as String,
    ];
  }

  /// 成功落库后的变更信号，不包含原文等隐私内容。
  final void Function()? onChanged;

  /// 无参数；默认开启记录。
  bool get recordingEnabled {
    final rows = database.select(
      "SELECT value FROM history_meta WHERE key = 'recording'",
    );
    return rows.first['value'] == '1';
  }

  /// value 为是否记录后续成功翻译；保存偏好而不改动已有记录，无返回值。
  set recordingEnabled(bool value) {
    database.execute(
      "INSERT INTO history_meta(key, value) VALUES('recording', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
      [value ? '1' : '0'],
    );
  }

  /// 文本、语言、服务及可选模型/来源为完整成功结果，completedAt 为完成毫秒；写入后通知，无返回值。
  void insert({
    required String sourceText,
    required String translatedText,
    required String detectedLanguage,
    required String targetLanguage,
    required String providerId,
    String? model,
    required int completedAt,
    String? sourceLabel,
  }) {
    if (!recordingEnabled) return;
    database.execute(
      '''INSERT INTO translation_history(
        source_text, translated_text, detected_language, target_language, provider_id, model, completed_at, source_label
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        sourceText,
        translatedText,
        detectedLanguage,
        targetLanguage,
        providerId,
        model,
        completedAt,
        sourceLabel,
      ],
    );
    // 新增记录同样执行已确认期限，成功写入只发一次变更。
    _prune();
    onChanged?.call();
  }

  /// before 为末条游标；query 匹配原文/译文，source 匹配来源；from 含、to 不含毫秒。
  /// limit 为正数；返回全部条件交集内按完成时间与 ID 倒序的记录。
  List<TranslationRecord> page({
    HistoryCursor? before,
    int limit = 10,
    String? query,
    String? source,
    int? from,
    int? to,
  }) {
    if (limit < 1) throw ArgumentError.value(limit, 'limit', '必须为正数');
    final conditions = <String>[];
    final parameters = <Object?>[];
    // 读取按已确认期限过滤，不删除记录；删除只在写入、设置期限与启动时进行。
    final cutoff = _cutoff();
    if (cutoff != null) {
      conditions.add('completed_at >= ?');
      parameters.add(cutoff);
    }
    if (before != null) {
      conditions.add('(completed_at, id) < (?, ?)');
      parameters.addAll([before.completedAt, before.id]);
    }
    if (query != null && query.isNotEmpty) {
      // instr 将 %、_ 视为普通关键词字符；ASCII 通过 lower 忽略大小写。
      conditions.add(
        '(instr(lower(source_text), lower(?)) > 0 OR instr(lower(translated_text), lower(?)) > 0)',
      );
      parameters.addAll([query, query]);
    }
    if (source != null && source.isNotEmpty) {
      conditions.add("COALESCE(NULLIF(source_label, ''), ?) = ?");
      parameters.addAll([unknownSource, source]);
    }
    if (from != null) {
      conditions.add('completed_at >= ?');
      parameters.add(from);
    }
    if (to != null) {
      conditions.add('completed_at < ?');
      parameters.add(to);
    }
    // 使用稳定游标，浏览过程中新增翻译不会挤动 OFFSET 导致重复或漏项。
    final rows = database.select(
      '''SELECT id, source_text, translated_text, detected_language, target_language, provider_id, model, completed_at, source_label
         FROM translation_history
         ${conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}'}
         ORDER BY completed_at DESC, id DESC LIMIT ?''',
      [...parameters, limit],
    );
    return [
      for (final row in rows)
        TranslationRecord(
          id: row['id'] as int,
          sourceText: row['source_text'] as String,
          translatedText: row['translated_text'] as String,
          detectedLanguage: row['detected_language'] as String,
          targetLanguage: row['target_language'] as String,
          providerId: row['provider_id'] as String,
          model: row['model'] as String?,
          completedAt: row['completed_at'] as int,
          sourceLabel: row['source_label'] as String?,
        ),
    ];
  }
}
