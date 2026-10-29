import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

/// png 为测试图片字节；返回解码后的源图，调用方负责释放。需在真实异步中调用（widget 测试内用 runAsync）。
Future<ui.Image> decodePng(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final frame = await codec.getNextFrame();
  codec.dispose();
  return frame.image;
}

/// png 为测试图片字节；返回截图快照的源图字段：pixels 为 BGRA 原始字节、rowBytes 为每行字节数、
/// width/height 为像素尺寸，与原生 ScreenCaptureKit 冻结帧格式一致（#68 批次 A）。需在真实异步中调用。
Future<Map<String, Object>> capturePixels(Uint8List png) async {
  final image = await decodePng(png);
  final rgba = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!
      .buffer
      .asUint8List();
  // RGBA 交换 R、B 通道得到 BGRA；测试图片均不透明，预乘与否结果相同。
  final bgra = Uint8List(rgba.length);
  for (var i = 0; i < rgba.length; i += 4) {
    bgra[i] = rgba[i + 2];
    bgra[i + 1] = rgba[i + 1];
    bgra[i + 2] = rgba[i];
    bgra[i + 3] = rgba[i + 3];
  }
  final fields = {
    'pixels': bgra,
    'rowBytes': image.width * 4,
    'width': image.width,
    'height': image.height,
  };
  image.dispose();
  return fields;
}

/// tester 为测试驱动；截图引擎收到快照后用真实异步建源图，交替让出真实时间与推进帧各 5 次（每次 50ms），
/// 让源图装入文档后再继续断言，无返回值。
Future<void> awaitCaptureSource(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
}
