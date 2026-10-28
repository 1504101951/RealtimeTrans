import 'dart:ui';

import '../common/constants/screenshot_enums.dart';

/// 双色线性渐变；起始色由所属样式的颜色提供，这里只记录结束色与方向（#103）。
class FillGradient {
  /// end 为结束色（不透明 sRGB），direction 为渐变方向。
  const FillGradient({
    required this.end,
    this.direction = GradientDirection.downRight,
  });
  final Color end;
  final GradientDirection direction;

  /// start 为起始色，bounds 为渐变铺满的矩形，opacity 为整体不透明度；
  /// 返回按方向从 bounds 一侧到另一侧的线性渐变着色器。
  Shader shader(Color start, Rect bounds, {double opacity = 1}) {
    final (from, to) = switch (direction) {
      GradientDirection.right => (bounds.centerLeft, bounds.centerRight),
      GradientDirection.down => (bounds.topCenter, bounds.bottomCenter),
      GradientDirection.downRight => (bounds.topLeft, bounds.bottomRight),
      GradientDirection.upRight => (bounds.bottomLeft, bounds.topRight),
    };
    return Gradient.linear(from, to, [
      start.withValues(alpha: opacity),
      end.withValues(alpha: opacity),
    ]);
  }

  /// 无参数；返回可写入偏好的字典 {to, direction}。
  Map<String, Object> toMap() => {
    'to': end.toARGB32(),
    'direction': direction.name,
  };

  /// value 为偏好中的渐变字典；返回渐变，结束色不是不透明颜色或方向未知时抛 FormatException。
  factory FillGradient.fromMap(Map<Object?, Object?> value) {
    final argb = value['to'] as int;
    if (argb < 0xFF000000 || argb > 0xFFFFFFFF) {
      throw const FormatException('渐变颜色无效。');
    }
    return FillGradient(
      end: Color(argb),
      direction: GradientDirection.values.byName(value['direction'] as String),
    );
  }

  /// other 为比较对象；返回结束色与方向是否相同。
  @override
  bool operator ==(Object other) =>
      other is FillGradient && other.end == end && other.direction == direction;

  /// 无参数；返回与 == 一致的哈希值。
  @override
  int get hashCode => Object.hash(end, direction);
}

/// 调色盘的结果：颜色（渐变时为起始色）与可选渐变（#103）。
typedef ColorFill = ({Color color, FillGradient? gradient});

/// 各标注组合使用的不可变样式；颜色为不透明sRGB（渐变时为起始色），线宽为图像坐标单位，gradient 为空即纯色。
class DrawingStyle {
  const DrawingStyle({
    this.color = ScreenshotDefaults.strokeColor,
    this.strokeWidth = 3,
    this.gradient,
  });

  final Color color;
  final double strokeWidth;
  final FillGradient? gradient;

  /// 无参数；返回颜色与渐变组成的调色盘值。
  ColorFill get fill => (color: color, gradient: gradient);

  /// 传入需替换的线宽或填充（fill 同时替换颜色与渐变），返回独立快照，不改变已绘制对象。
  DrawingStyle copyWith({Color? color, double? strokeWidth, ColorFill? fill}) =>
      DrawingStyle(
        color: fill?.color ?? color ?? this.color,
        strokeWidth: strokeWidth ?? this.strokeWidth,
        gradient: fill != null ? fill.gradient : gradient,
      );
}

/// tool为当前工具；返回是否支持线宽，避免控件与绘制器分别推断能力。
bool supportsStrokeWidth(ScreenshotTool tool) => const {
  ScreenshotTool.rect,
  ScreenshotTool.arrow,
  ScreenshotTool.brush,
}.contains(tool);

/// tool为工具、mode为图形模式；返回是否支持颜色，马赛克不消耗颜色，编号只调整颜色。
bool supportsDrawingColor(ScreenshotTool tool, ShapeMode mode) =>
    (tool == ScreenshotTool.brush && mode != ShapeMode.mosaic) ||
    tool == ScreenshotTool.rect ||
    tool == ScreenshotTool.arrow ||
    tool == ScreenshotTool.step ||
    tool == ScreenshotTool.text;
