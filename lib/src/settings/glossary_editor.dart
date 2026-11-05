import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/constants/glass_metrics.dart';
import '../common/constants/method_names.dart';
import '../common/widgets/native_glass.dart';
import '../translation/glossary.dart';
import '../translation/glossary_file.dart';
import 'app_settings.dart';

/// 术语表管理弹窗：维护全部术语并导入导出文件，单条改动自动保存，整批导入等待设置事务。
class GlossaryManager extends StatefulWidget {
  /// glossary 为当前列表，defaultLanguage 为新增目标语言，channel 负责系统文件面板；
  /// onChanged 接收单条改动，onImport 等待完整列表真实保存，失败抛出错误并保留导入草稿。
  const GlossaryManager({
    super.key,
    required this.glossary,
    required this.defaultLanguage,
    required this.onChanged,
    required this.channel,
    required this.onImport,
  });

  final List<GlossaryEntry> glossary;
  final String defaultLanguage;
  final ValueChanged<List<GlossaryEntry>> onChanged;
  final MethodChannel channel;
  final Future<void> Function(List<GlossaryEntry>) onImport;

  /// 无参数；返回持有弹窗内术语列表的状态。
  @override
  State<GlossaryManager> createState() => _GlossaryManagerState();
}

/// 持有弹窗内展示的术语列表；设置页保存的是每次改动后交回的完整副本。
class _GlossaryManagerState extends State<GlossaryManager> {
  late final List<GlossaryEntry> _entries = [...widget.glossary];
  bool _working = false;
  String? _message;

  /// 无参数；经系统面板选取文件并打开预览，取消不改动列表，返回操作结束的 Future。
  Future<void> _import() async {
    setState(() {
      _working = true;
      _message = null;
    });
    try {
      final file = await widget.channel.invokeMapMethod<String, String>(
        MethodNames.openGlossaryFile,
      );
      if (file == null || !mounted) return;
      // parseGlossaryFile 一次校验整份文件，预览确认前不写设置草稿。
      final draft = parseGlossaryFile(file['text']!, format: file['format']!);
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => GlossaryImportPreview(
          name: file['name']!,
          draft: draft,
          existing: [..._entries],
          onSubmit: (entries) async {
            // onImport 等待主引擎事务，只有真实保存成功后才更新管理列表。
            await widget.onImport(entries);
            if (!mounted) return;
            setState(() {
              _entries
                ..clear()
                ..addAll(entries);
            });
          },
        ),
      );
    } on PlatformException catch (error) {
      if (mounted) setState(() => _message = error.message ?? '无法读取术语文件。');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// 无参数；选择 CSV/JSON 后用系统面板保存当前术语，取消不产生文件，返回操作结束的 Future。
  Future<void> _export() async {
    final format = await showDialog<String>(
      context: context,
      builder: (context) => NativeGlassDialog(
        title: const Text('导出术语表'),
        content: const SizedBox(width: 520, child: Text('选择导出格式。')),
        actions: [
          for (final (value, label) in [
            (null, '取消'),
            ('csv', 'CSV'),
            ('json', 'JSON'),
          ])
            NativeGlassSurface(
              material: true,
              child: TextButton(
                onPressed: () => Navigator.pop(context, value),
                child: Text(label),
              ),
            ),
        ],
      ),
    );
    if (format == null || !mounted) return;
    setState(() {
      _working = true;
      _message = null;
    });
    try {
      // exportGlossaryFile 只序列化术语字段，不读取服务设置或凭据。
      final text = exportGlossaryFile(_entries, format: format);
      final path = await widget.channel.invokeMethod<String>(
        MethodNames.saveTextFile,
        {'text': text, 'suggestedName': 'TranslateApp 术语表.$format'},
      );
      if (mounted && path != null) setState(() => _message = '已导出到 $path');
    } on PlatformException catch (error) {
      if (mounted) setState(() => _message = error.message ?? '导出失败，请重试。');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// change 修改弹窗内列表；刷新界面后把完整副本交给设置页，无返回值。
  void _change(VoidCallback change) {
    setState(change);
    widget.onChanged([..._entries]);
  }

  /// index 为待编辑术语的下标，新增时为空；确定后更新列表，取消不改变，返回编辑结束的 Future。
  Future<void> _edit([int? index]) async {
    final entry = await showDialog<GlossaryEntry>(
      context: context,
      barrierDismissible: false,
      // GlossaryEditor 只返回不与其余条目重复的术语草稿。
      builder: (_) => GlossaryEditor(
        entry: index == null ? null : _entries[index],
        others: [
          for (final (i, other) in _entries.indexed)
            if (i != index) other,
        ],
        defaultLanguage: widget.defaultLanguage,
      ),
    );
    if (entry == null || !mounted) return;
    _change(() {
      if (index == null) {
        _entries.add(entry);
      } else {
        _entries[index] = entry;
      }
    });
  }

  /// context 为弹窗上下文；返回生效范围说明、术语列表与添加/完成操作。
  @override
  Widget build(BuildContext context) => NativeGlassDialog(
    title: const Text('术语表'),
    content: SizedBox(
      width: 520,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '只对模型服务（OpenAI、DeepSeek、Anthropic）的翻译生效；译法留空表示保留原文不译。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          if (_message != null) Text(_message!),
          if (_entries.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('暂无术语'),
            )
          else
            // 条目多时只在弹窗内滚动，标题与操作保持可见。
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final (index, entry) in _entries.indexed)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        entry.translation.isEmpty
                            ? '${entry.term}（保留原文）'
                            : '${entry.term} → ${entry.translation}',
                      ),
                      subtitle: Text(
                        AppSettings.languages[entry.language] ?? entry.language,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          NativeGlassSurface(
                            material: true,
                            child: IconButton(
                              tooltip: '编辑 ${entry.term}',
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: _working ? null : () => _edit(index),
                            ),
                          ),
                          const SizedBox(width: GlassMetrics.actionGap),
                          NativeGlassSurface(
                            material: true,
                            child: IconButton(
                              tooltip: '删除 ${entry.term}',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: _working
                                  ? null
                                  : () =>
                                        _change(() => _entries.removeAt(index)),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    ),
    actions: [
      NativeGlassSurface(
        material: true,
        child: TextButton(
          onPressed: _working ? null : _import,
          child: const Text('导入…'),
        ),
      ),
      NativeGlassSurface(
        material: true,
        child: TextButton(
          onPressed: _working ? null : _export,
          child: const Text('导出…'),
        ),
      ),
      NativeGlassSurface(
        material: true,
        child: TextButton.icon(
          onPressed: _working ? null : () => _edit(),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('添加术语'),
        ),
      ),
      NativeGlassSurface(
        material: true,
        child: FilledButton(
          onPressed: _working ? null : () => Navigator.pop(context),
          child: const Text('完成'),
        ),
      ),
    ],
  );
}

/// CSV/JSON 导入预览；只在无错误并经确认后提交一次完整设置，保存失败保留草稿。
class GlossaryImportPreview extends StatefulWidget {
  /// name 为文件名，draft 为完整校验结果，existing 为当前列表；onSubmit 保存合并列表，失败抛出错误。
  const GlossaryImportPreview({
    super.key,
    required this.name,
    required this.draft,
    required this.existing,
    required this.onSubmit,
  });

  final String name;
  final GlossaryImport draft;
  final List<GlossaryEntry> existing;
  final Future<void> Function(List<GlossaryEntry>) onSubmit;

  /// 无参数；返回持有重复处理策略与提交反馈的预览状态。
  @override
  State<GlossaryImportPreview> createState() => _GlossaryImportPreviewState();
}

/// 维护本次导入的处理策略、保存中状态和错误，不修改解析草稿。
class _GlossaryImportPreviewState extends State<GlossaryImportPreview> {
  bool _overwrite = false;
  bool _saving = false;
  String? _error;

  /// 无参数；合并全部有效行并等待事务成功，失败保留弹窗与策略，返回提交结束的 Future。
  Future<void> _submit() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      // merge 使用当前重复策略；onSubmit 在主引擎真实保存成功后完成。
      final entries = widget.draft.merge(
        widget.existing,
        overwrite: _overwrite,
      );
      await widget.onSubmit(entries);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _error = switch (error) {
          PlatformException(:final message) => message ?? '导入保存失败，请重试。',
          FormatException(:final message) => message,
          _ => '导入保存失败，请重试。',
        },
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// context 提供主题；返回受窗口约束的 520pt 预览与内部滚动列表，错误存在时禁用确认。
  @override
  Widget build(BuildContext context) {
    final draft = widget.draft;
    // duplicatePositions 与 addedCount 基于同一个当前列表和输入顺序计算预览计数。
    final duplicates = draft.duplicatePositions(widget.existing);
    final added = draft.addedCount(widget.existing);
    return PopScope(
      canPop: !_saving,
      child: NativeGlassDialog(
        title: const Text('导入术语表'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.name),
              const SizedBox(height: 8),
              Text(
                '新增 $added · 重复 ${duplicates.length} · 错误 ${draft.errorCount}',
              ),
              NativeGlassDropdown<bool>(
                label: '重复术语',
                value: _overwrite,
                items: const {false: '保留已有值', true: '覆盖已有值'},
                onChanged: _saving
                    ? null
                    : (value) => setState(() => _overwrite = value),
              ),
              Text(
                '按文件顺序处理；保留取首条，覆盖取最后一条。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final row in draft.rows)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          row.error ??
                              '${row.entry!.term} → ${row.entry!.translation.isEmpty ? '（保留原文）' : row.entry!.translation}',
                          style: row.error == null
                              ? null
                              : TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                        ),
                        subtitle: Text(
                          '位置 ${row.position} · ${row.error != null
                              ? '错误'
                              : duplicates.contains(row.position)
                              ? '重复'
                              : '新增'}${row.entry == null ? '' : ' · ${row.entry!.language}'}',
                        ),
                      ),
                  ],
                ),
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
        actions: [
          NativeGlassSurface(
            material: true,
            child: TextButton(
              onPressed: _saving ? null : () => Navigator.pop(context),
              child: const Text('取消'),
            ),
          ),
          NativeGlassSurface(
            material: true,
            child: FilledButton(
              onPressed: _saving || draft.errorCount != 0 || draft.rows.isEmpty
                  ? null
                  : _submit,
              child: Text(_saving ? '保存中…' : '确认导入'),
            ),
          ),
        ],
      ),
    );
  }
}

/// 添加或编辑一条术语的弹窗；只持有草稿，确定后返回条目，由设置页自动保存（#104）。
class GlossaryEditor extends StatefulWidget {
  /// entry 为待编辑条目（新增时为空），others 为其余条目用于查重，defaultLanguage 为新增时的目标语言。
  const GlossaryEditor({
    super.key,
    this.entry,
    required this.others,
    required this.defaultLanguage,
  });

  final GlossaryEntry? entry;
  final List<GlossaryEntry> others;
  final String defaultLanguage;

  /// 无参数；返回维护术语草稿的弹窗状态。
  @override
  State<GlossaryEditor> createState() => _GlossaryEditorState();
}

/// 持有原文术语、译法与目标语言草稿及重复提示；取消时不返回任何条目。
class _GlossaryEditorState extends State<GlossaryEditor> {
  final _term = TextEditingController();
  final _translation = TextEditingController();
  late String _language;
  bool _duplicate = false;

  /// 无参数；编辑时载入原条目，新增时目标语言取主要语言，无返回值。
  @override
  void initState() {
    super.initState();
    _term.text = widget.entry?.term ?? '';
    _translation.text = widget.entry?.translation ?? '';
    _language = widget.entry?.language ?? widget.defaultLanguage;
  }

  /// 无参数；释放输入控制器，无返回值。
  @override
  void dispose() {
    _term.dispose();
    _translation.dispose();
    super.dispose();
  }

  /// 无参数；去掉首尾空白后查重，重复时留在弹窗内提示，否则关闭并返回条目，无返回值。
  void _submit() {
    final entry = GlossaryEntry(
      term: _term.text.trim(),
      translation: _translation.text.trim(),
      language: _language,
    );
    if (widget.others.any((other) => other.key == entry.key)) {
      setState(() => _duplicate = true);
      return;
    }
    Navigator.pop(context, entry);
  }

  /// context 为弹窗上下文；返回术语字段、目标语言下拉与取消/确定操作。
  @override
  Widget build(BuildContext context) => NativeGlassDialog(
    title: Text(widget.entry == null ? '添加术语' : '编辑术语'),
    content: SizedBox(
      width: 520,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          NativeGlassField(
            label: '原文术语',
            child: TextField(
              key: const ValueKey('原文术语'),
              controller: _term,
              // 修改术语后重新判断「确定」是否可用，并清除旧的重复提示。
              onChanged: (_) => setState(() => _duplicate = false),
              decoration: const InputDecoration(),
            ),
          ),
          NativeGlassField(
            label: '译法',
            helper: '留空表示保留原文不译',
            child: TextField(
              key: const ValueKey('译法'),
              controller: _translation,
              decoration: const InputDecoration(),
            ),
          ),
          NativeGlassDropdown<String>(
            label: '目标语言',
            value: _language,
            // 主要语言可能是列表外的系统语言，保留当前值作为选项。
            items: {
              ...AppSettings.languages,
              if (!AppSettings.languages.containsKey(_language))
                _language: _language,
            },
            onChanged: (value) => setState(() {
              _language = value;
              _duplicate = false;
            }),
          ),
          if (_duplicate)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: Text('该目标语言下已有此术语。'),
            ),
        ],
      ),
    ),
    actions: [
      NativeGlassSurface(
        material: true,
        child: TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ),
      NativeGlassSurface(
        material: true,
        child: FilledButton(
          onPressed: _term.text.trim().isEmpty ? null : _submit,
          child: const Text('确定'),
        ),
      ),
    ],
  );
}
