import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../common/constants/drawing_metrics.dart';
import '../common/constants/emoji_catalog.dart';
import '../common/constants/glass_metrics.dart';
import '../common/widgets/native_glass.dart';
import 'stickers.dart';

/// 贴纸下拉框的选择结果：选中一个表情、选中一张我的贴纸，或去设置管理贴纸（#103）。
sealed class StickerChoice {
  const StickerChoice();
}

/// 选中一个表情，放置为 Emoji 贴纸。
final class PickedEmoji extends StickerChoice {
  /// emoji 为选中的表情字符。
  const PickedEmoji(this.emoji);
  final String emoji;
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

/// 下拉框顶部分段：应用内表情目录，或我的贴纸。
enum _StickerTab { emoji, mine }

/// 贴纸下拉框：顶部「Emoji」「贴纸」分段，其下为固定高度的可滚动网格；选择后以 StickerChoice 关闭弹窗（#103）。
class StickerPanel extends StatefulWidget {
  /// stickers 为我的贴纸，directory 为贴纸文件目录（文件为「目录/id.png」）。
  const StickerPanel({
    super.key,
    required this.stickers,
    required this.directory,
  });
  final List<StickerEntry> stickers;
  final String directory;

  @override
  State<StickerPanel> createState() => _StickerPanelState();
}

class _StickerPanelState extends State<StickerPanel> {
  /// 当前分段，默认 Emoji。
  _StickerTab _tab = _StickerTab.emoji;

  /// 6 列、行高 40pt、间距 4pt 的网格布局；Emoji 与我的贴纸共用。
  static const _gridDelegate = SliverGridDelegateWithFixedCrossAxisCount(
    crossAxisCount: StickerMetrics.panelColumns,
    mainAxisSpacing: StickerMetrics.panelGap,
    crossAxisSpacing: StickerMetrics.panelGap,
    mainAxisExtent: StickerMetrics.panelCell,
  );

  /// 无参数；返回 Emoji 段网格：每个类别一个标题加网格，SliverGrid 只构建可见格子（懒加载）。
  Widget _buildEmoji(BuildContext context) {
    final secondary = Theme.of(context).colorScheme.onSurfaceVariant;
    return CustomScrollView(
      slivers: [
        for (final group in EmojiCatalog.groups) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                vertical: StickerMetrics.categoryPadding,
              ),
              child: Text(
                group.title,
                style: TextStyle(
                  fontSize: StickerMetrics.categoryFontSize,
                  fontWeight: FontWeight.w600,
                  color: secondary,
                ),
              ),
            ),
          ),
          SliverGrid(
            gridDelegate: _gridDelegate,
            delegate: SliverChildBuilderDelegate((context, index) {
              final emoji = group.emoji[index];
              return InkWell(
                key: ValueKey('emoji-cell-$emoji'),
                borderRadius: BorderRadius.circular(StickerMetrics.cellRadius),
                onTap: () => Navigator.pop(context, PickedEmoji(emoji)),
                child: Center(
                  child: Text(
                    emoji,
                    style: const TextStyle(
                      fontSize: StickerMetrics.emojiFontSize,
                    ),
                  ),
                ),
              );
            }, childCount: group.emoji.length),
          ),
        ],
      ],
    );
  }

  /// 无参数；返回「贴纸」段内容：无贴纸时居中提示，否则可滚动的懒构建网格。
  Widget _buildMine(BuildContext context) {
    if (widget.stickers.isEmpty) {
      return Center(
        child: Text('还没有贴纸', style: Theme.of(context).textTheme.bodySmall),
      );
    }
    return GridView.builder(
      gridDelegate: _gridDelegate,
      itemCount: widget.stickers.length,
      itemBuilder: (context, index) {
        final sticker = widget.stickers[index];
        return Tooltip(
          message: '贴纸',
          child: InkWell(
            key: ValueKey('sticker-cell-${sticker.id}'),
            borderRadius: BorderRadius.circular(StickerMetrics.cellRadius),
            onTap: () => Navigator.pop(context, PickedSticker(sticker)),
            child: Image.file(
              File('${widget.directory}/${sticker.id}.png'),
              fit: BoxFit.contain,
            ),
          ),
        );
      },
    );
  }

  /// context 为弹窗上下文；返回宽 280pt 的玻璃菜单层：分段、260pt 高网格区，贴纸段另有「管理贴纸…」。
  @override
  Widget build(BuildContext context) {
    final mine = _tab == _StickerTab.mine;
    return Material(
      type: MaterialType.transparency,
      child: NativeGlassSurface(
        material: true,
        radius: GlassMetrics.menuRadius,
        child: SizedBox(
          width: DrawingMetrics.paletteWidth,
          child: Padding(
            padding: const EdgeInsets.all(DrawingMetrics.padding),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: NativeGlassSegments<_StickerTab>(
                    value: _tab,
                    options: const {
                      _StickerTab.emoji: 'Emoji',
                      _StickerTab.mine: '贴纸',
                    },
                    onChanged: (tab) => setState(() => _tab = tab),
                  ),
                ),
                const SizedBox(height: StickerMetrics.actionGap),
                SizedBox(
                  height: StickerMetrics.gridHeight,
                  child: mine ? _buildMine(context) : _buildEmoji(context),
                ),
                if (mine) ...[
                  const SizedBox(height: StickerMetrics.actionGap),
                  NativeGlassSurface(
                    material: true,
                    child: TextButton(
                      key: const ValueKey('sticker-manage'),
                      onPressed: () =>
                          Navigator.pop(context, const ManageStickers()),
                      child: const Text('管理贴纸…'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 贴纸下拉框的定位：左边对齐「贴纸」按钮，优先放在按钮下方，放不下时放到上方；无锚点时居中。
class StickerPanelLayout extends SingleChildLayoutDelegate {
  /// anchor 为「贴纸」按钮的全局矩形；按钮未显示（经快捷动作打开）时为 null。
  const StickerPanelLayout(this.anchor);
  final Rect? anchor;

  /// constraints 为可用区域约束；返回放宽到 0 起的子约束，让下拉框取自身大小。
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  /// size 为可用区域大小，childSize 为下拉框大小；返回下拉框左上角偏移：
  /// 横向左对齐按钮并夹在窗口左右各留 4pt 内，纵向在按钮下方 4pt，下方放不下则在上方 4pt。
  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final anchor = this.anchor;
    // 无锚点时居中。
    if (anchor == null) {
      return Offset(
        (size.width - childSize.width) / 2,
        (size.height - childSize.height) / 2,
      );
    }
    const gap = StickerMetrics.anchorGap;
    final maxLeft = math.max(gap, size.width - childSize.width - gap);
    final left = anchor.left.clamp(gap, maxLeft);
    final below = anchor.bottom + gap;
    final fitsBelow = below + childSize.height <= size.height - gap;
    return Offset(
      left,
      fitsBelow ? below : anchor.top - gap - childSize.height,
    );
  }

  @override
  bool shouldRelayout(StickerPanelLayout oldDelegate) =>
      oldDelegate.anchor != anchor;
}
