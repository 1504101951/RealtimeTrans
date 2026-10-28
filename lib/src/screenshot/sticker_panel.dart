import 'dart:io';

import 'package:flutter/material.dart';

import '../common/constants/drawing_metrics.dart';
import '../common/widgets/native_glass.dart';
import 'stickers.dart';

/// 贴纸面板的选择结果：选中一张我的贴纸，或去设置管理贴纸（#103）。
sealed class StickerChoice {
  const StickerChoice();
}

/// 选中「我的贴纸」中的 entry。
final class PickedSticker extends StickerChoice {
  /// entry 为选中的贴纸。
  const PickedSticker(this.entry);
  final StickerEntry entry;
}

/// 点了「管理贴纸…」。
final class ManageStickers extends StickerChoice {
  const ManageStickers();
}

/// 贴纸面板：「我的贴纸」网格与「管理贴纸…」；选择后以 StickerChoice 关闭弹窗（#103）。
class StickerPanel extends StatelessWidget {
  /// stickers 为我的贴纸，directory 为贴纸文件目录（文件为「目录/id.png」）。
  const StickerPanel({
    super.key,
    required this.stickers,
    required this.directory,
  });
  final List<StickerEntry> stickers;
  final String directory;

  /// context 为弹窗上下文；返回宽 280pt 的贴纸网格与操作行，超过 3 行时网格内滚动。
  @override
  Widget build(BuildContext context) {
    const cell = StickerMetrics.panelCell;
    const gap = StickerMetrics.panelGap;
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
                constraints: const BoxConstraints(maxHeight: cell * 3 + gap * 2),
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
                                File('$directory/${sticker.id}.png'),
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
            Row(
              children: [
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
