import 'package:flutter/material.dart';

import '../common/constants/text_mode.dart';
import '../common/widgets/native_glass.dart';

/// 提示词弹窗：编辑翻译、润色、纠错、解释的系统提示词与思考开关，提示词可分别恢复默认；
/// 保存返回完整的提示词与思考开关，取消返回 null（#100）。
class PromptEditor extends StatefulWidget {
  /// prompts 为四种模式的当前提示词，thinking 为四种模式的当前思考开关。
  const PromptEditor({
    super.key,
    required this.prompts,
    required this.thinking,
  });
  final Map<TextMode, String> prompts;
  final Map<TextMode, bool> thinking;

  /// 弹窗中四个字段的模式与名称，顺序即显示顺序。
  static const labels = {
    TextMode.translate: '翻译',
    TextMode.polish: '润色',
    TextMode.correct: '纠错',
    TextMode.explain: '解释',
  };

  /// 无参数；返回持有四个输入框与思考开关的状态。
  @override
  State<PromptEditor> createState() => _PromptEditorState();
}

/// 持有四个输入框与思考开关；只在保存时把内容交回设置页。
class _PromptEditorState extends State<PromptEditor> {
  late final _controllers = {
    for (final mode in PromptEditor.labels.keys)
      mode: TextEditingController(text: widget.prompts[mode]),
  };
  late final _thinking = {...widget.thinking};

  /// 无参数；释放四个输入框控制器。
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

  /// context 为弹窗上下文；返回说明、四个提示词字段与取消/保存操作。
  @override
  Widget build(BuildContext context) => NativeGlassDialog(
    title: const Text('提示词'),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '翻译、润色、纠错、解释使用的系统提示词与思考开关，所有模型服务共用；思考只对 DeepSeek 与 Anthropic 生效。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            for (final entry in PromptEditor.labels.entries)
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
              : () => Navigator.pop(context, (
                  prompts: {
                    for (final entry in _controllers.entries)
                      entry.key: entry.value.text,
                  },
                  thinking: _thinking,
                )),
          child: const Text('保存'),
        ),
      ),
    ],
  );

  /// mode 为处理模式，label 为字段名；返回标题行带「思考」开关与「恢复默认」的多行提示词字段，为空时在下方提示。
  Widget _field(TextMode mode, String label) {
    final controller = _controllers[mode]!;
    final fallback = defaultPrompts[mode]!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(label)),
            const Text('思考', style: TextStyle(fontSize: 13)),
            const SizedBox(width: 6),
            NativeGlassSwitch(
              key: ValueKey('思考-$label'),
              label: '$label思考',
              value: _thinking[mode]!,
              onChanged: (value) => setState(() => _thinking[mode] = value),
            ),
            const SizedBox(width: 8),
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
