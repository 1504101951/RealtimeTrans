import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/screenshot/box_transform.dart';

/// 无参数；验证可拖动矩形的命中、移动、拉伸、比例与旋转规则（#106、#103）。
void main() {
  const box = BoxFrame(Rect.fromLTWH(10, 10, 80, 80));

  /// value 为实际点，expected 为期望点；比较两点误差不超过 1e-9。
  void expectOffset(Offset value, Offset expected) {
    expect(value.dx, closeTo(expected.dx, 1e-9));
    expect(value.dy, closeTo(expected.dy, 1e-9));
  }

  test('命中：角优先于边，框内为移动，框外为空；旋转手柄只在开启时命中', () {
    // 边界：pad 8 内的角点、上边中点、右边中点、中心与框外各取一点；旋转手柄在上边中点之上 20。
    expect(hitBoxHandle(box, const Offset(10, 10), pad: 8), BoxHandle.nw);
    expect(hitBoxHandle(box, const Offset(50, 10), pad: 8), BoxHandle.n);
    expect(hitBoxHandle(box, const Offset(90, 50), pad: 8), BoxHandle.e);
    expect(hitBoxHandle(box, const Offset(50, 50), pad: 8), BoxHandle.move);
    expect(hitBoxHandle(box, const Offset(0, 0), pad: 8), isNull);
    expect(hitBoxHandle(box, const Offset(50, -10), pad: 8), isNull);
    expect(
      hitBoxHandle(box, const Offset(50, -10), pad: 8, rotateDistance: 20),
      BoxHandle.rotate,
    );
    // 边界：边线半宽 3 时，距上边 2 的非中点位置仍命中上边。
    expect(
      hitBoxHandle(box, const Offset(30, 12), pad: 8, edgePad: 3),
      BoxHandle.n,
    );
  });

  test('命中：旋转 90° 后按局部坐标判断，原右上角落到屏幕右下角', () {
    // 边界：绕中心 (50,50) 顺时针 90°，局部右上角 (90,10) 的屏幕位置为 (90,90)。
    const turned = BoxFrame(Rect.fromLTWH(10, 10, 80, 80), math.pi / 2);
    expect(hitBoxHandle(turned, const Offset(90, 90), pad: 8), BoxHandle.ne);
  });

  test('文字框的上下边按移动处理，其余控制点不变', () {
    // 边界：n/s 变为 move，角点与左右边保持原值。
    expect(BoxHandle.n.widthOnly, BoxHandle.move);
    expect(BoxHandle.s.widthOnly, BoxHandle.move);
    expect(BoxHandle.ne.widthOnly, BoxHandle.ne);
    expect(BoxHandle.w.widthOnly, BoxHandle.w);
  });

  test('移动保持尺寸并停在范围边缘；无范围时不限制', () {
    // 边界：向左上拖 30 会越出 (0,0,100,100)，停在左上角；无范围时允许负坐标。
    const area = Rect.fromLTWH(0, 0, 100, 100);
    expect(
      dragBox(
        box,
        BoxHandle.move,
        from: const Offset(50, 50),
        to: const Offset(20, 20),
        rules: const BoxRules(area: area),
      ),
      const BoxFrame(Rect.fromLTWH(0, 0, 80, 80)),
    );
    expect(
      dragBox(
        box,
        BoxHandle.move,
        from: const Offset(50, 50),
        to: const Offset(20, 20),
        rules: const BoxRules(),
      ),
      const BoxFrame(Rect.fromLTWH(-20, -20, 80, 80)),
    );
  });

  test('自由拉伸：拖动边跟随指针、对边不动，越过对边时保持最小边长', () {
    // 边界：右下角拖到 (120,60)；左边拖过右边到 95，宽度被推回 minSide 8。
    expect(
      dragBox(
        box,
        BoxHandle.se,
        from: const Offset(90, 90),
        to: const Offset(120, 60),
        rules: const BoxRules(minSide: 8),
      ).rect,
      const Rect.fromLTRB(10, 10, 120, 60),
    );
    expect(
      dragBox(
        box,
        BoxHandle.w,
        from: const Offset(10, 50),
        to: const Offset(95, 50),
        rules: const BoxRules(minSide: 8),
      ).rect,
      const Rect.fromLTRB(82, 10, 90, 90),
    );
  });

  test('锁定比例与 ⇧ 保持比例：角点由指针决定宽度，另一边按比例推算', () {
    // 边界：锁定 2:1 时右下角拖到 x=130，宽 120 高 60；⇧ 保持原 1:1，右边拖到 x=50 时高随之变为 40。
    expect(
      dragBox(
        box,
        BoxHandle.se,
        from: const Offset(90, 90),
        to: const Offset(130, 200),
        rules: const BoxRules(area: Rect.fromLTWH(0, 0, 300, 300), ratio: 2),
      ).rect,
      const Rect.fromLTWH(10, 10, 120, 60),
    );
    expect(
      dragBox(
        box,
        BoxHandle.e,
        from: const Offset(90, 50),
        to: const Offset(50, 50),
        rules: const BoxRules(keepRatio: true),
      ).rect,
      const Rect.fromLTWH(10, 10, 40, 40),
    );
  });

  test('旋转绕中心转动，⇧ 时吸附到 15° 的整数倍', () {
    // 边界：从上方 (50,0) 拖到右方 (100,50) 为 90°；拖到偏 20° 的位置吸附为 15°。
    final quarter = dragBox(
      box,
      BoxHandle.rotate,
      from: const Offset(50, 0),
      to: const Offset(100, 50),
      rules: const BoxRules(),
    );
    expect(quarter.rect, box.rect);
    expect(quarter.rotation, closeTo(math.pi / 2, 1e-9));
    final angle = -math.pi / 2 + 20 * math.pi / 180;
    final snapped = dragBox(
      box,
      BoxHandle.rotate,
      from: const Offset(50, 0),
      to: Offset(50 + 50 * math.cos(angle), 50 + 50 * math.sin(angle)),
      rules: const BoxRules(snapRotation: true),
    );
    expect(snapped.rotation, closeTo(15 * math.pi / 180, 1e-9));
  });

  test('旋转后拉伸：对角在屏幕上的位置保持不变', () {
    // 边界：旋转 90° 后拖右下角，左上角（对角）拉伸前后的屏幕位置一致。
    const turned = BoxFrame(Rect.fromLTWH(10, 10, 80, 80), math.pi / 2);

    /// frame 为可旋转矩形；返回其局部左上角的屏幕位置。
    Offset topLeftOnScreen(BoxFrame frame) {
      final center = frame.rect.center;
      final d = frame.rect.topLeft - center;
      final cos = math.cos(frame.rotation);
      final sin = math.sin(frame.rotation);
      return center + Offset(d.dx * cos - d.dy * sin, d.dx * sin + d.dy * cos);
    }

    final next = dragBox(
      turned,
      BoxHandle.se,
      from: const Offset(10, 90),
      to: const Offset(0, 120),
      rules: const BoxRules(),
    );
    expect(next.rotation, turned.rotation);
    expect(next.rect.size, isNot(turned.rect.size));
    expectOffset(topLeftOnScreen(next), topLeftOnScreen(turned));
  });
}
