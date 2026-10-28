import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../common/constants/drawing_metrics.dart';
import '../common/widgets/native_glass.dart';
import '../screenshot/stickers.dart';

/// 添加贴纸的上传框：预览图片并拖动四角等比设定默认大小（长边上限 512pt）；
/// 「添加」返回默认宽高（pt），取消返回 null（#103）。
class StickerUploadDialog extends StatefulWidget {
  /// bytes 为规范化后的 PNG，pixelWidth/pixelHeight 为其像素尺寸。
  const StickerUploadDialog({
    super.key,
    required this.bytes,
    required this.pixelWidth,
    required this.pixelHeight,
  });
  final Uint8List bytes;
  final int pixelWidth;
  final int pixelHeight;

  /// 预览按长边 512pt 能完整放下的比例显示，四周留 12pt 给控制点。
  static final previewScale = math.min(
    (StickerMetrics.previewWidth - 24) / StickerMetrics.maxDefaultSize,
    (StickerMetrics.previewHeight - 24) / StickerMetrics.maxDefaultSize,
  );

  /// 无参数；返回持有当前默认大小的状态。
  @override
  State<StickerUploadDialog> createState() => _StickerUploadDialogState();
}

/// 持有默认大小（pt）；拖动四角时按指针到中心的距离等比更新。
class _StickerUploadDialogState extends State<StickerUploadDialog> {
  late (double, double) _size = initialStickerSize(
    widget.pixelWidth,
    widget.pixelHeight,
  );

  /// local 为指针在预览区内的位置；按到中心的横纵距离取较大的放大倍数，长边限制在 16–512pt。
  void _drag(Offset local) {
    final scale = StickerUploadDialog.previewScale;
    final center = const Offset(
      StickerMetrics.previewWidth / 2,
      StickerMetrics.previewHeight / 2,
    );
    final (width, height) = _size;
    final factor = math.max(
      (local.dx - center.dx).abs() * 2 / (width * scale),
      (local.dy - center.dy).abs() * 2 / (height * scale),
    );
    final long = math.max(width, height) * factor;
    final clamped = long.clamp(16.0, StickerMetrics.maxDefaultSize);
    final ratio = clamped / math.max(width, height);
    setState(() => _size = (width * ratio, height * ratio));
  }

  /// context 为弹窗上下文；返回棋盘格预览、默认大小说明与取消/添加操作。
  @override
  Widget build(BuildContext context) {
    final scale = StickerUploadDialog.previewScale;
    final (width, height) = _size;
    final shown = Size(width * scale, height * scale);
    final rect = Rect.fromCenter(
      center: const Offset(
        StickerMetrics.previewWidth / 2,
        StickerMetrics.previewHeight / 2,
      ),
      width: shown.width,
      height: shown.height,
    );
    return NativeGlassDialog(
      title: const Text('添加贴纸'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              key: _previewKey,
              width: StickerMetrics.previewWidth,
              height: StickerMetrics.previewHeight,
              child: Stack(
                children: [
                  const Positioned.fill(
                    child: CustomPaint(painter: _CheckerPainter()),
                  ),
                  Positioned.fromRect(
                    rect: rect,
                    child: Image.memory(widget.bytes, fit: BoxFit.fill),
                  ),
                  // 四角控制点：拖动任一角等比缩放。
                  for (final (index, corner) in [
                    rect.topLeft,
                    rect.topRight,
                    rect.bottomLeft,
                    rect.bottomRight,
                  ].indexed)
                    Positioned(
                      left: corner.dx - 6,
                      top: corner.dy - 6,
                      child: GestureDetector(
                        key: ValueKey('sticker-handle-$index'),
                        onPanUpdate: (details) =>
                            _drag(_previewLocal(details.globalPosition)),
                        child: Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            border: Border.all(
                              color: NativeGlassTheme.selectionBlue,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '拖动四角设置默认大小（长边最大 512pt）',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Text(
              '默认大小 ${width.round()} × ${height.round()} pt',
              key: const ValueKey('sticker-size'),
              style: Theme.of(context).textTheme.bodySmall,
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
            onPressed: () => Navigator.pop(context, _size),
            child: const Text('添加'),
          ),
        ),
      ],
    );
  }

  /// 预览区的键，用于把全局指针位置换算到预览区坐标。
  final _previewKey = GlobalKey();

  /// global 为全局指针位置；返回其在预览区内的坐标。
  Offset _previewLocal(Offset global) =>
      (_previewKey.currentContext!.findRenderObject() as RenderBox)
          .globalToLocal(global);
}

/// 预览区的灰白棋盘格背景，显示贴纸透明区域。
class _CheckerPainter extends CustomPainter {
  const _CheckerPainter();

  /// canvas/size 为绘制目标与尺寸；按 12pt 方格交替绘制浅灰与白色。
  @override
  void paint(Canvas canvas, Size size) {
    const cell = StickerMetrics.checker;
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final gray = Paint()..color = const Color(0xFFE5E5E5);
    for (var y = 0; y * cell < size.height; y++) {
      for (var x = 0; x * cell < size.width; x++) {
        if ((x + y).isOdd) {
          canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell, cell), gray);
        }
      }
    }
  }

  /// oldDelegate 为旧绘制器；棋盘格不随状态变化，返回 false。
  @override
  bool shouldRepaint(_CheckerPainter oldDelegate) => false;
}
