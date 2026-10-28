import 'package:flutter/material.dart';

import '../common/constants/text_mode.dart';
import '../common/widgets/native_glass.dart';

/// 处理提示词弹窗：编辑润色、纠错、解释的系统提示词，可分别恢复默认；保存返回完整提示词，取消返回 null（#100）。
class AssistPromptEditor extends StatefulWidget {
  /// prompts 为当前三种模式的提示词。
  const AssistPromptEditor({super.key, required this.prompts});
  final Map<TextMode, String> prompts;

  /// 弹窗中三个字段的模式与名称，顺序即显示顺序。
  static const labels = {
    TextMode.polish: '润色',
    TextMode.correct: '纠错',
    TextMode.explain: '解释',
  };

  /// 无参数；返回持有三个输入框的状态。
  @override
  State<AssistPromptEditor> createState() => _AssistPromptEditorState();
}

/// 持有三个输入框；只在保存时把内容交回设置页。
class _AssistPromptEditorState extends State<AssistPromptEditor> {
  late final _controllers = {
    for (final mode in AssistPromptEditor.labels.keys)
      mode: TextEditingController(text: widget.prompts[mode]),
  };

  /// 无参数；释放三个输入框控制器。
  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// 无参数；返回是否有空提示词，有则禁用保存。
  bool get _hasEmpty =>
      _controllers.values.any((controller) => controller.text.trim().isEmpty);

  /// context 为弹窗上下文；返回说明、三个提示词字段与取消/保存操作。
  @override
  Widget build(BuildContext context) => NativeGlassDialog(
    title: const Text('处理提示词'),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '润色、纠错、解释使用的系统提示词，所有模型服务共用；翻译提示词在各服务中单独设置。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            for (final entry in AssistPromptEditor.labels.entries)
              _field(entry.key, entry.value),
          ],
        ),
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
          onPressed: _hasEmpty
              ? null
              : () => Navigator.pop(context, {
                  for (final entry in _controllers.entries)
                    entry.key: entry.value.text,
                }),
          child: const Text('保存'),
        ),
      ),
    ],
  );

  /// mode 为处理模式，label 为字段名；返回带「恢复默认」的多行提示词字段，为空时在下方提示。
  Widget _field(TextMode mode, String label) {
    final controller = _controllers[mode]!;
    final fallback = defaultAssistPrompts[mode]!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(label)),
            // 内容已是默认值时无需恢复。
            NativeGlassSurface(
              material: true,
              child: TextButton(
                key: ValueKey('恢复默认-$label'),
                onPressed: controller.text == fallback
                    ? null
                    : () => setState(() => controller.text = fallback),
                child: const Text('恢复默认'),
              ),
            ),
          ],
        ),
        NativeGlassField(
          label: label,
          child: TextField(
            key: ValueKey('提示词-$label'),
            controller: controller,
            minLines: 4,
            maxLines: 8,
            // 修改后重新判断「恢复默认」与「保存」是否可用。
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(),
          ),
        ),
        if (controller.text.trim().isEmpty)
          Text(
            '提示词不能为空。',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    );
  }
}
