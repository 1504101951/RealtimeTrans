import 'dart:io';

import 'package:flutter/material.dart';

import '../common/constants/drawing_metrics.dart';
import '../common/widgets/native_glass.dart';
import 'stickers.dart';

/// 贴纸面板的选择结果：选中一张我的贴纸、输入一个表情，或去设置管理贴纸（#103）。
sealed class StickerChoice {
  const StickerChoice();
}

/// 选中「我的贴纸」中的 entry。
final class PickedSticker extends StickerChoice {
  /// entry 为选中的贴纸。
  const PickedSticker(this.entry);
  final StickerEntry entry;
}

/// 在「表情与符号」面板中点选了 emoji。
final class PickedEmoji extends StickerChoice {
  /// emoji 为一个字素簇的表情字符。
  const PickedEmoji(this.emoji);
  final String emoji;
}

/// 点了「管理贴纸…」。
final class ManageStickers extends StickerChoice {
  const ManageStickers();
}

/// 贴纸面板：「我的贴纸」网格、Emoji 输入框与操作行；选择后以 StickerChoice 关闭弹窗（#103）。
class StickerPanel extends StatefulWidget {
  /// stickers 为我的贴纸，directory 为贴纸文件目录（文件为「目录/id.png」）；
  /// onEmojiInput 在 Emoji 输入框获得焦点后调用，由调用方切换按键路由并打开系统表情面板。
  const StickerPanel({
    super.key,
    required this.stickers,
    required this.directory,
    required this.onEmojiInput,
  });
  final List<StickerEntry> stickers;
  final String directory;
  final VoidCallback onEmojiInput;

  /// 无参数；返回持有 Emoji 输入状态的面板状态。
  @override
  State<StickerPanel> createState() => _StickerPanelState();
}

/// 持有 Emoji 输入框是否显示；输入第一个字素簇即关闭面板。
class _StickerPanelState extends State<StickerPanel> {
  bool _emoji = false;

  /// 无参数；显示 Emoji 输入框，待其在本帧获得焦点后通知调用方，无返回值。
  void _startEmoji() {
    setState(() => _emoji = true);
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onEmojiInput());
  }

  /// context 为弹窗上下文；返回宽 280pt 的贴纸网格、Emoji 输入框与操作行，超过 3 行时网格内滚动。
  @override
  Widget build(BuildContext context) {
    const cell = StickerMetrics.panelCell;
    const gap = StickerMetrics.panelGap;
    final stickers = widget.stickers;
    return SizedBox(
      width: DrawingMetrics.paletteWidth,
      child: Padding(
        padding: const EdgeInsets.all(DrawingMetrics.padding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '我的贴纸',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: DrawingMetrics.gap),
            if (stickers.isEmpty)
              Text('还没有贴纸', style: Theme.of(context).textTheme.bodySmall)
            else
              ConstrainedBox(
                // 最多显示 3 行，更多时在网格内滚动。
                constraints: const BoxConstraints(
                  maxHeight: cell * 3 + gap * 2,
                ),
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      for (final sticker in stickers)
                        Tooltip(
                          message: '贴纸',
                          child: InkWell(
                            key: ValueKey('sticker-cell-${sticker.id}'),
                            borderRadius: BorderRadius.circular(
                              StickerMetrics.cellRadius,
                            ),
                            onTap: () =>
                                Navigator.pop(context, PickedSticker(sticker)),
                            child: SizedBox.square(
                              dimension: cell,
                              child: Image.file(
                                File('${widget.directory}/${sticker.id}.png'),
                                fit: BoxFit.contain,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: DrawingMetrics.gap),
            if (_emoji) ...[
              // 与调色盘十六进制输入框同一形式：高 32pt 的单行输入框。
              SizedBox(
                height: StickerMetrics.emojiInputHeight,
                child: TextField(
                  key: const ValueKey('sticker-emoji-input'),
                  autofocus: true,
                  // 系统表情面板写入的第一个字素簇即为贴纸。
                  onChanged: (value) {
                    if (value.characters.isEmpty) return;
                    Navigator.pop(context, PickedEmoji(value.characters.first));
                  },
                  decoration: const InputDecoration(
                    hintText: '在表情面板中点选表情',
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: StickerMetrics.emojiInputGap),
            ],
            Row(
              children: [
                NativeGlassSurface(
                  material: true,
                  child: TextButton(
                    key: const ValueKey('sticker-emoji'),
                    onPressed: _startEmoji,
                    child: const Text('Emoji…'),
                  ),
                ),
                const SizedBox(width: StickerMetrics.actionGap),
                NativeGlassSurface(
                  material: true,
                  child: TextButton(
                    onPressed: () =>
                        Navigator.pop(context, const ManageStickers()),
                    child: const Text('管理贴纸…'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
