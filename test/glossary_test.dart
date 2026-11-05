import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/settings/app_settings.dart';
import 'package:translate_app/src/translation/glossary.dart';
import 'package:translate_app/src/translation/glossary_file.dart';

/// 无参数；验证术语的整词与子串匹配、目标语言筛选、保留原文输出及设置往返与校验（#104）。
void main() {
  /// term 为原文术语；返回目标语言为简体中文、译法为「译」的条目。
  GlossaryEntry entry(String term) =>
      GlossaryEntry(term: term, translation: '译', language: 'zh-CN');

  test('拉丁字母一侧按整词、不区分大小写匹配，汉字与符号一侧按子串匹配', () {
    // 边界：API 不能命中 capital 内部；C++ 末尾是符号，后面紧跟字母仍算命中，但前面紧跟字母不算；
    // 汉字术语没有词边界，出现在更长的汉字串中也要命中。
    expect(entry('API').occursIn('Call the api, please.'), isTrue);
    expect(entry('API').occursIn('The capital city'), isFalse);
    expect(entry('API').occursIn('API_KEY'), isTrue);
    expect(entry('C++').occursIn('I write C++daily'), isTrue);
    expect(entry('C++').occursIn('ABC++'), isFalse);
    expect(entry('机器学习').occursIn('深度机器学习模型'), isTrue);
    expect(entry('Node.js').occursIn('Nodexjs'), isFalse);
  });

  test('只返回目标语言一致且在任一原文中出现的术语，保留原文时译法等于术语', () {
    // 边界：zh-Hans 与 zh-CN 规范为同一语言；法语条目即使原文命中也不进入中文请求；
    // 命中出现在批次的第二段原文中。
    final glossary = [
      const GlossaryEntry(
        term: 'Kubernetes',
        translation: '',
        language: 'zh-CN',
      ),
      const GlossaryEntry(term: 'API', translation: '接口', language: 'zh-CN'),
      const GlossaryEntry(
        term: 'API',
        translation: 'interface',
        language: 'fr',
      ),
      const GlossaryEntry(
        term: 'Swift',
        translation: 'Swift 语言',
        language: 'zh-CN',
      ),
    ];
    expect(
      glossaryHits(glossary, ['Hello', 'Run the API on kubernetes'], 'zh-Hans'),
      [
        {'term': 'Kubernetes', 'translation': 'Kubernetes'},
        {'term': 'API', 'translation': '接口'},
      ],
    );
    expect(glossaryHits(glossary, ['No terms here'], 'zh-CN'), isEmpty);
    expect(glossaryHits(const [], ['API'], 'zh-CN'), isEmpty);
  });

  test('术语表随偏好往返；同一目标语言下大小写不同的同一术语或空术语被拒绝', () {
    // 边界：API 与 api 在同一目标语言下重复；同一术语换目标语言可以共存。
    final settings = AppSettings(
      primaryLanguage: 'zh-CN',
      glossary: [
        const GlossaryEntry(term: 'API', translation: '接口', language: 'zh-CN'),
        const GlossaryEntry(term: 'api', translation: 'API', language: 'ja'),
      ],
    );
    settings.validate();
    final restored = AppSettings.fromMap(settings.toMap());
    expect(
      restored.glossary.map((e) => e.toMap()),
      settings.glossary.map((e) => e.toMap()),
    );
    restored.glossary.add(
      const GlossaryEntry(term: 'api', translation: '应用接口', language: 'zh-CN'),
    );
    expect(restored.validate, throwsFormatException);
    restored.glossary
      ..removeLast()
      ..add(const GlossaryEntry(term: ' ', translation: '', language: 'zh-CN'));
    expect(restored.validate, throwsFormatException);
  });

  test('CSV 与 JSON 保留引号逗号换行和空译法，并只导出术语字段', () {
    // 边界：字段内同时含引号、逗号和换行，空译法不得变成原文；系统语言 sv 不在设置下拉中仍可往返。
    final entries = [
      const GlossaryEntry(
        term: 'say "Hello", API\nnext',
        translation: '第一行\r\n"第二行",尾',
        language: 'sv',
      ),
      const GlossaryEntry(
        term: 'Kubernetes',
        translation: '',
        language: 'zh-CN',
      ),
    ];
    for (final format in ['csv', 'json']) {
      final text = exportGlossaryFile(entries, format: format);
      final draft = parseGlossaryFile('\uFEFF$text', format: format);
      expect(draft.errorCount, 0);
      expect(
        draft.merge([], overwrite: false).map((entry) => entry.toMap()),
        entries.map((entry) => entry.toMap()),
      );
      expect(draft.rows.last.entry!.translation, isEmpty);
    }
  });

  test('CSV 引用与分隔结构错误，以及错误列数，均阻止整批导入', () {
    // 边界：缺列、多列、未闭合引号、裸引号和引号后多余文字不是可接受的术语行。
    for (final line in [
      'API,接口',
      'API,接口,zh-CN,extra',
      '"API,接口,zh-CN',
      'A"PI,接口,zh-CN',
      '"API"tail,接口,zh-CN',
    ]) {
      final draft = parseGlossaryFile(
        'term,translation,language\n$line',
        format: 'csv',
      );
      expect(draft.errorCount, 1, reason: line);
      expect(() => draft.merge([], overwrite: false), throwsFormatException);
    }
  });

  test('CSV 精确校验表头，错误报告跨行字段之后的真实行号', () {
    // 边界：表头列名、顺序、列数必须精确；第一个字段跨两行后，下一条无效行从第 4 行开始。
    for (final header in [
      '',
      'term,language,translation',
      'term,translation,language,extra',
    ]) {
      expect(parseGlossaryFile(header, format: 'csv').errorCount, 1);
    }
    final draft = parseGlossaryFile(
      'term,translation,language\r\n"multi\r\nline",译,zh-CN\r\n,译,zh-CN\r\n',
      format: 'csv',
    );
    expect(draft.rows.map((row) => row.position), [2, 4]);
    expect(draft.rows.first.entry!.term, 'multi\r\nline');
    expect(draft.rows.last.error, '原文术语不能为空。');
  });

  test('JSON 收集全部字段类型与语言错误，任何错误均使有效行不可提交', () {
    // 边界：三字段都必须存在且为字符串；空术语、空语言、非语言标签、非对象条目分别报告，不跳过后续行。
    final draft = parseGlossaryFile(
      '[{"term":"API","translation":"接口","language":"zh-CN"},'
      '{"term":3,"translation":"","language":"en"},'
      '{"term":"API","translation":null,"language":"en"},'
      '{"term":"API","translation":""},'
      '{"term":" ","translation":"","language":"en"},'
      '{"term":"API","translation":"","language":""},'
      '{"term":"API","translation":"","language":"invalid-language"},'
      '[]]',
      format: 'json',
    );
    expect(draft.rows.length, 8);
    expect(draft.errorCount, 7);
    expect(draft.rows.first.entry!.translation, '接口');
    expect(() => draft.merge([], overwrite: true), throwsFormatException);
  });

  test('JSON 顶层和真实语法错误保留为可预览错误，文件格式不接受其他类型', () {
    // 边界：数组以外的合法 JSON 不是术语文件；真实断裂 JSON 在第 2 行报告错误。
    for (final source in ['{}', 'null', '"API"']) {
      expect(parseGlossaryFile(source, format: 'json').errorCount, 1);
    }
    final broken = parseGlossaryFile('[\n{"term": }]', format: 'json');
    expect(broken.errorCount, 1);
    expect(broken.rows.single.position, 2);
    expect(parseGlossaryFile('API', format: 'txt').errorCount, 1);
    expect(() => exportGlossaryFile([], format: 'txt'), throwsFormatException);
  });

  test('语言标签允许系统语言与脚本地区，拒绝非法结构', () {
    // 边界：脚本、地区及系统下划线写法可往返；二位数字地区、缺失子标签、语言名称及自动检测不是目标码。
    for (final language in ['sv', 'zh-Hant-TW', 'pt_BR', 'es-419']) {
      final draft = parseGlossaryFile(
        'term,translation,language\nAPI,,$language',
        format: 'csv',
      );
      expect(draft.errorCount, 0, reason: language);
      expect(draft.rows.single.entry!.language, language);
    }
    for (final language in [
      'en-22',
      'en-',
      '-en',
      'English',
      'auto',
      'zh CN',
    ]) {
      expect(
        parseGlossaryFile(
          'term,translation,language\nAPI,,$language',
          format: 'csv',
        ).errorCount,
        1,
        reason: language,
      );
    }
  });

  test('重复键沿输入顺序预览与合并：保留取首条和已有值，覆盖取末条', () {
    // 边界：术语忽略大小写、中文规范码相同；同术语换目标语言可新增；文件内部重复与现有重复共用策略。
    final existing = [
      const GlossaryEntry(term: 'API', translation: '现有', language: 'zh-CN'),
    ];
    final draft = parseGlossaryFile(
      '[{"term":"api","translation":"第一条","language":"zh-Hans"},'
      '{"term":"NEW","translation":"首条","language":"en"},'
      '{"term":"new","translation":"末条","language":"en"},'
      '{"term":"API","translation":"新增语言","language":"ja"}]',
      format: 'json',
    );
    expect(draft.addedCount(existing), 2);
    expect(draft.duplicatePositions(existing), {1, 3});
    expect(
      draft.merge(existing, overwrite: false).map((entry) => entry.translation),
      ['现有', '首条', '新增语言'],
    );
    expect(
      draft.merge(existing, overwrite: true).map((entry) => entry.translation),
      ['第一条', '末条', '新增语言'],
    );
    expect(existing.single.translation, '现有');
  });

  test('CSV 中间与末尾的空行跳过，不计为错误', () {
    // 作用：编辑器保存的 CSV 常带空行，不能因此阻止整批导入。边界：表头后一个空行、两条术语之间一个空行、文件末尾两个空行。
    final draft = parseGlossaryFile(
      'term,translation,language\r\n\r\nA,甲,zh-CN\r\n\r\nB,乙,zh-CN\r\n\r\n\r\n',
      format: 'csv',
    );
    expect(draft.errorCount, 0);
    expect([for (final row in draft.rows) row.entry!.term], ['A', 'B']);
  });

  test('空术语表导出后可以预览为空批次，不构造空术语', () {
    // 边界：仅 CSV 表头与 JSON 空数组都表示零条记录；末尾换行不是一条空记录。
    for (final format in ['csv', 'json']) {
      final draft = parseGlossaryFile(
        exportGlossaryFile([], format: format),
        format: format,
      );
      expect(draft.rows, isEmpty);
      expect(draft.errorCount, 0);
      expect(draft.merge([], overwrite: false), isEmpty);
    }
  });
}
