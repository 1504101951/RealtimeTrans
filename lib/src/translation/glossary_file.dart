import 'dart:convert';

import 'glossary.dart';

/// 术语文件中的一行；保留文件位置以及校验成功的条目或错误说明。
class GlossaryImportRow {
  /// position 为 CSV 起始行号或 JSON 条目序号；entry/error 分别为有效条目与错误，返回不可变预览行。
  const GlossaryImportRow({required this.position, this.entry, this.error});

  final int position;
  final GlossaryEntry? entry;
  final String? error;
}

/// 已完成格式及逐行校验的术语草稿；有错误时禁止产生提交列表。
class GlossaryImport {
  /// rows 为按文件顺序排列的预览行；返回不可变解析结果。
  GlossaryImport(List<GlossaryImportRow> rows) : rows = List.unmodifiable(rows);

  final List<GlossaryImportRow> rows;

  /// 无参数；返回错误行数，任一错误均阻止整批提交。
  int get errorCount => rows.where((row) => row.error != null).length;

  /// existing 为当前术语列表；返回文件中首次出现且当前列表没有的键数量。
  int addedCount(List<GlossaryEntry> existing) {
    final keys = existing.map((entry) => entry.key).toSet();
    return rows
        .where((row) => row.entry != null && keys.add(row.entry!.key))
        .length;
  }

  /// existing 为当前术语列表；返回与现有条目或文件前行重复的行位置。
  Set<int> duplicatePositions(List<GlossaryEntry> existing) {
    final keys = existing.map((entry) => entry.key).toSet();
    return {
      for (final row in rows)
        if (row.entry != null && !keys.add(row.entry!.key)) row.position,
    };
  }

  /// existing 为完整当前列表，overwrite 决定重复时是否覆盖；返回合并副本，有错误时抛出 FormatException。
  List<GlossaryEntry> merge(
    List<GlossaryEntry> existing, {
    required bool overwrite,
  }) {
    if (errorCount != 0) throw const FormatException('术语文件含有错误，无法导入。');
    final merged = [...existing];
    final indices = {
      for (final (index, entry) in merged.indexed) entry.key: index,
    };
    // 按文件顺序合并：保留取首条，覆盖取最后一条，现有条目的位置不变。
    for (final row in rows) {
      final entry = row.entry!;
      final index = indices[entry.key];
      if (index == null) {
        indices[entry.key] = merged.length;
        merged.add(entry);
      } else if (overwrite) {
        merged[index] = entry;
      }
    }
    return merged;
  }
}

/// text 为已解码 UTF-8 文本，format 为 csv/json；返回含位置与错误的完整预览，语言接受系统使用的语言标签。
GlossaryImport parseGlossaryFile(String text, {required String format}) {
  final rows = <GlossaryImportRow>[];
  final languageTag = RegExp(
    r'^[A-Za-z]{2,3}(?:-[A-Za-z]{3}){0,3}(?:-[A-Za-z]{4})?'
    r'(?:-(?:[A-Za-z]{2}|[0-9]{3}))?'
    r'(?:-(?:[A-Za-z0-9]{5,8}|[0-9][A-Za-z0-9]{3}))*'
    r'(?:-[0-9A-WY-Za-wy-z](?:-[A-Za-z0-9]{2,8})+)*'
    r'(?:-[xX](?:-[A-Za-z0-9]{1,8})+)?$',
  );
  // BOM 只属于文件编码标记，不作为表头或 JSON 内容的一部分。
  final source = text.startsWith('\uFEFF') ? text.substring(1) : text;
  try {
    final List<(int, Object?)> records;
    switch (format) {
      case 'csv':
        // _parseCsv 保留跨行字段，并报告格式错误所在的物理行。
        final csv = _parseCsv(source);
        if (csv.isEmpty ||
            csv.first.$2.join(',') != 'term,translation,language' ||
            csv.first.$2.length != 3) {
          throw const FormatException('CSV 表头必须为 term,translation,language。');
        }
        // 整行为空的记录（空行）不是术语，跳过而不计为错误。
        records = [
          for (final row in csv.skip(1))
            if (row.$2.length != 1 || row.$2.single.isNotEmpty) (row.$1, row.$2),
        ];
      case 'json':
        final decoded = jsonDecode(source);
        if (decoded is! List) throw const FormatException('JSON 须为术语对象数组。');
        records = [
          for (final (index, row) in decoded.indexed) (index + 1, row),
        ];
      default:
        throw const FormatException('仅支持 CSV 或 JSON 术语文件。');
    }
    for (final (position, record) in records) {
      try {
        final Object? term;
        final Object? translation;
        final Object? language;
        if (format == 'csv') {
          final fields = record as List<String>;
          if (fields.length != 3) {
            throw const FormatException('每行须有 term、translation、language 三列。');
          }
          [term, translation, language] = fields;
        } else {
          if (record is! Map) throw const FormatException('每项须为术语对象。');
          term = record['term'];
          translation = record['translation'];
          language = record['language'];
        }
        if (term is! String || translation is! String || language is! String) {
          throw const FormatException('term、translation、language 均须为字符串。');
        }
        if (term.trim().isEmpty) throw const FormatException('原文术语不能为空。');
        // 系统首选语言可以不在设置下拉列表中；校验标签结构并保留原码，判重仍使用既有规范键。
        if (!languageTag.hasMatch(language.replaceAll('_', '-'))) {
          throw FormatException('目标语言码无效：$language。');
        }
        rows.add(
          GlossaryImportRow(
            position: position,
            entry: GlossaryEntry(
              term: term.trim(),
              translation: translation.trim(),
              language: language,
            ),
          ),
        );
      } on FormatException catch (error) {
        rows.add(GlossaryImportRow(position: position, error: error.message));
      }
    }
  } on FormatException catch (error) {
    final position = format == 'json' && error.offset != null
        ? '\n'.allMatches(source.substring(0, error.offset!)).length + 1
        : error.offset ?? 1;
    rows.add(GlossaryImportRow(position: position, error: error.message));
  }
  return GlossaryImport(rows);
}

/// entries 为待导出的完整术语列表，format 为 csv/json；返回仅包含术语三个字段的 UTF-8 文本内容。
String exportGlossaryFile(
  List<GlossaryEntry> entries, {
  required String format,
}) {
  if (format == 'json') {
    return const JsonEncoder.withIndent('  ')
        .convert([for (final entry in entries) entry.toMap()]);
  }
  if (format != 'csv') throw const FormatException('仅支持 CSV 或 JSON 术语文件。');
  // CSV 所有字段统一引用，双引号加倍转义，保持逗号和多行内容完整。
  return 'term,translation,language\r\n${entries.map((entry) => [entry.term, entry.translation, entry.language].map((value) => '"${value.replaceAll('"', '""')}"').join(',')).join('\r\n')}';
}

/// text 为 CSV 全文；返回起始物理行号及字段列表，严格拒绝未闭合引号和引用字段外的非分隔字符。
List<(int, List<String>)> _parseCsv(String text) {
  final records = <(int, List<String>)>[];
  var fields = <String>[];
  var field = StringBuffer();
  var quoted = false;
  var closed = false;
  var line = 1;
  var startLine = 1;
  for (var index = 0; index < text.length; index += 1) {
    final character = text[index];
    if (quoted) {
      if (character == '"') {
        if (index + 1 < text.length && text[index + 1] == '"') {
          field.write('"');
          index += 1;
        } else {
          quoted = false;
          closed = true;
        }
      } else {
        field.write(character);
        if (character == '\n' ||
            character == '\r' &&
                (index + 1 == text.length || text[index + 1] != '\n')) {
          line += 1;
        }
      }
      continue;
    }
    if (character == ',' || character == '\r' || character == '\n') {
      fields.add(field.toString());
      field = StringBuffer();
      closed = false;
      if (character == ',') continue;
      records.add((startLine, fields));
      fields = [];
      if (character == '\r' &&
          index + 1 < text.length &&
          text[index + 1] == '\n') {
        index += 1;
      }
      line += 1;
      startLine = line;
      continue;
    }
    if (closed) throw FormatException('引用字段结束后只能出现逗号或换行。', null, line);
    if (character == '"') {
      if (field.isNotEmpty) throw FormatException('双引号只能出现在字段开头。', null, line);
      quoted = true;
      continue;
    }
    field.write(character);
  }
  if (quoted) throw FormatException('引用字段的双引号未闭合。', null, startLine);
  if (field.isNotEmpty || fields.isNotEmpty || closed) {
    records.add((startLine, [...fields, field.toString()]));
  }
  return records;
}
