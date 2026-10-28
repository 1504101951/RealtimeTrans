import 'dart:math' as math;
import 'dart:ui';

import '../common/utils/geometry.dart';

/// 可拖动矩形的控制点：八个方向调整大小，move 平移，rotate 旋转（#106、#103）。
enum BoxHandle {
  nw,
  n,
  ne,
  e,
  se,
  s,
  sw,
  w,
  move,
  rotate;

  /// 无参数；返回文字框使用的控制点：文字框高度随内容，上下边按移动处理。
  BoxHandle get widthOnly => this == n || this == s ? move : this;
}

/// 可旋转矩形；rect 为未旋转时的位置，rotation 为绕 rect 中心的弧度（屏幕坐标 y 向下，正值为顺时针）。
class BoxFrame {
  /// rect 与 rotation 含义见类说明；rotation 缺省为不旋转。
  const BoxFrame(this.rect, [this.rotation = 0]);
  final Rect rect;
  final double rotation;

  /// other 为比较对象；返回矩形与角度是否相同。
  @override
  bool operator ==(Object other) =>
      other is BoxFrame && other.rect == rect && other.rotation == rotation;

  /// 无参数；返回与 == 一致的哈希值。
  @override
  int get hashCode => Object.hash(rect, rotation);

  /// 无参数；返回便于测试失败时阅读的描述。
  @override
  String toString() => 'BoxFrame($rect, $rotation)';
}

/// 拖动规则；不同对象只以规则区分。
class BoxRules {
  /// area 为平移时允许的范围（null 不限制）；minSide 为拉伸后的最小边长；
  /// ratio 为锁定的宽高比（null 为自由，比例修正时需要 area）；keepRatio 为保持拖动开始时的宽高比（⇧）；
  /// snapRotation 为旋转时按 15° 吸附（⇧）。
  const BoxRules({
    this.area,
    this.minSide = 0,
    this.ratio,
    this.keepRatio = false,
    this.snapRotation = false,
  });
  final Rect? area;
  final double minSide;
  final double? ratio;
  final bool keepRatio;
  final bool snapRotation;
}

/// 旋转吸附步长：15°。
const _rotationSnap = math.pi / 12;

/// point 为全局坐标点，center 为旋转中心，angle 为弧度；返回绕 center 旋转 angle 后的点。
Offset _rotate(Offset point, Offset center, double angle) {
  final dx = point.dx - center.dx;
  final dy = point.dy - center.dy;
  final cos = math.cos(angle);
  final sin = math.sin(angle);
  return Offset(
    center.dx + dx * cos - dy * sin,
    center.dy + dx * sin + dy * cos,
  );
}

/// frame 为可旋转矩形，point 为全局坐标；返回该点在矩形未旋转坐标系中的位置。
Offset _local(BoxFrame frame, Offset point) =>
    _rotate(point, frame.rect.center, -frame.rotation);

/// frame 为可旋转矩形，point 为全局坐标；pad 为控制点命中半径，edgePad 为边线半宽（缺省同 pad），
/// rotateDistance 为旋转手柄在上边中点之上的距离（null 表示不可旋转）。
/// 返回命中的控制点：旋转手柄优先，其次角、边、框内，未命中为 null。
BoxHandle? hitBoxHandle(
  BoxFrame frame,
  Offset point, {
  required double pad,
  double? edgePad,
  double? rotateDistance,
}) {
  final local = _local(frame, point);
  final rect = frame.rect;
  // near 判断点是否落在控制点 pad 半径的方框内。
  bool near(Offset target) =>
      (target.dx - local.dx).abs() <= pad &&
      (target.dy - local.dy).abs() <= pad;
  if (rotateDistance != null &&
      near(Offset(rect.center.dx, rect.top - rotateDistance))) {
    return BoxHandle.rotate;
  }
  final points = {
    BoxHandle.nw: rect.topLeft,
    BoxHandle.ne: rect.topRight,
    BoxHandle.sw: rect.bottomLeft,
    BoxHandle.se: rect.bottomRight,
    BoxHandle.n: rect.topCenter,
    BoxHandle.s: rect.bottomCenter,
    BoxHandle.w: rect.centerLeft,
    BoxHandle.e: rect.centerRight,
  };
  // 映射顺序即优先级：角优先于边中点。
  for (final entry in points.entries) {
    if (near(entry.value)) return entry.key;
  }
  final edge = edgePad ?? pad;
  final withinX = local.dx >= rect.left && local.dx <= rect.right;
  final withinY = local.dy >= rect.top && local.dy <= rect.bottom;
  if ((local.dy - rect.top).abs() <= edge && withinX) return BoxHandle.n;
  if ((local.dy - rect.bottom).abs() <= edge && withinX) return BoxHandle.s;
  if ((local.dx - rect.left).abs() <= edge && withinY) return BoxHandle.w;
  if ((local.dx - rect.right).abs() <= edge && withinY) return BoxHandle.e;
  if (rect.contains(local)) return BoxHandle.move;
  return null;
}

/// start 为拖动开始时的矩形，handle 为控制点，from/to 为拖动起点与当前指针（全局坐标），rules 为拖动规则；
/// 返回拖动后的矩形。移动限制在 rules.area 内；拉伸时拖动边跟随指针、对边不动，短于 minSide 时推开对边；
/// 锁定比例或 ⇧ 时按比例推算另一边；旋转绕中心转动；旋转后的拉伸保持对角在屏幕上的位置不变。
BoxFrame dragBox(
  BoxFrame start,
  BoxHandle handle, {
  required Offset from,
  required Offset to,
  required BoxRules rules,
}) {
  final rect = start.rect;
  if (handle == BoxHandle.move) {
    final next = rect.shift(to - from);
    final area = rules.area;
    if (area == null) return BoxFrame(next, start.rotation);
    // 平移不改变尺寸，停在范围边缘。
    return BoxFrame(
      Rect.fromLTWH(
        next.left
            .clamp(area.left, math.max(area.left, area.right - next.width))
            .toDouble(),
        next.top
            .clamp(area.top, math.max(area.top, area.bottom - next.height))
            .toDouble(),
        next.width,
        next.height,
      ),
      start.rotation,
    );
  }
  if (handle == BoxHandle.rotate) {
    final center = rect.center;
    final turned =
        start.rotation + (to - center).direction - (from - center).direction;
    return BoxFrame(
      rect,
      rules.snapRotation
          ? (turned / _rotationSnap).round() * _rotationSnap
          : turned,
    );
  }
  // 拉伸在未旋转坐标系中计算，再平移使对角保持原屏幕位置。
  final point = _local(start, to);
  final ratio =
      rules.ratio ?? (rules.keepRatio ? rect.width / rect.height : null);
  final next = ratio == null
      ? _freeResize(rect, handle, point, rules.minSide)
      : _ratioResize(rect, handle, point, ratio, rules);
  if (start.rotation == 0) return BoxFrame(next, 0);
  final anchor = _opposite(rect, handle);
  final anchorNext = _opposite(next, handle);
  // 对角在旧矩形中的屏幕位置；新矩形绕自身中心旋转后对角应落在同一位置。
  final world = _rotate(anchor, rect.center, start.rotation);
  final placed = _rotate(anchorNext, next.center, start.rotation);
  return BoxFrame(next.shift(world - placed), start.rotation);
}

/// rect 为拉伸前矩形，handle 为八方向之一；返回拉伸时保持不动的对角或对边中点。
Offset _opposite(Rect rect, BoxHandle handle) => switch (handle) {
  BoxHandle.nw => rect.bottomRight,
  BoxHandle.ne => rect.bottomLeft,
  BoxHandle.sw => rect.topRight,
  BoxHandle.se => rect.topLeft,
  BoxHandle.n => rect.bottomCenter,
  BoxHandle.s => rect.topCenter,
  BoxHandle.w => rect.centerRight,
  BoxHandle.e => rect.centerLeft,
  _ => rect.center,
};

/// rect 为拉伸前矩形，handle 为八方向之一，point 为局部坐标指针，minSide 为最小边长；
/// 返回拖动边跟随指针后的矩形，短于 minSide 时左/上边让位，保证宽高不小于 minSide。
Rect _freeResize(Rect rect, BoxHandle handle, Offset point, double minSide) {
  var left = rect.left;
  var top = rect.top;
  var right = rect.right;
  var bottom = rect.bottom;
  if (const {BoxHandle.nw, BoxHandle.w, BoxHandle.sw}.contains(handle)) {
    left = point.dx;
  }
  if (const {BoxHandle.ne, BoxHandle.e, BoxHandle.se}.contains(handle)) {
    right = point.dx;
  }
  if (const {BoxHandle.nw, BoxHandle.n, BoxHandle.ne}.contains(handle)) {
    top = point.dy;
  }
  if (const {BoxHandle.sw, BoxHandle.s, BoxHandle.se}.contains(handle)) {
    bottom = point.dy;
  }
  return Rect.fromLTRB(
    left <= right - minSide ? left : right - minSide,
    top <= bottom - minSide ? top : bottom - minSide,
    right,
    bottom,
  );
}

/// rect 为拉伸前矩形，handle 为八方向之一，point 为局部坐标指针，ratio 为宽高比，rules 提供范围与最小边；
/// 角点由指针决定宽度，左右边只改宽度、上下边只改高度，另一边按比例推算。
/// 有范围时由 ratioRect 限制在范围内并整体缩小；无范围时只保证较短边不小于 minSide。
Rect _ratioResize(
  Rect rect,
  BoxHandle handle,
  Offset point,
  double ratio,
  BoxRules rules,
) {
  final (anchor, toward, byHeight) = switch (handle) {
    BoxHandle.nw => (rect.bottomRight, point, false),
    BoxHandle.ne => (rect.bottomLeft, point, false),
    BoxHandle.sw => (rect.topRight, point, false),
    BoxHandle.e => (rect.topLeft, Offset(point.dx, rect.bottom), false),
    BoxHandle.w => (rect.topRight, Offset(point.dx, rect.bottom), false),
    BoxHandle.s => (rect.topLeft, Offset(rect.right, point.dy), true),
    BoxHandle.n => (rect.bottomLeft, Offset(rect.right, point.dy), true),
    _ => (rect.topLeft, point, false),
  };
  final area = rules.area;
  if (area != null) {
    // ratioRect 以范围左上角为原点计算，结果平移回范围坐标。
    return ratioRect(
      anchor: anchor - area.topLeft,
      toward: toward - area.topLeft,
      ratio: ratio,
      byHeight: byHeight,
      bounds: area.size,
      minSide: rules.minSide,
    ).shift(area.topLeft);
  }
  final right = toward.dx >= anchor.dx;
  final down = toward.dy >= anchor.dy;
  var width = byHeight
      ? (toward.dy - anchor.dy).abs() * ratio
      : (toward.dx - anchor.dx).abs();
  // 较短边不小于 minSide。
  width = math.max(width, rules.minSide * math.max(1, ratio));
  final height = width / ratio;
  return Rect.fromLTWH(
    right ? anchor.dx : anchor.dx - width,
    down ? anchor.dy : anchor.dy - height,
    width,
    height,
  );
}
