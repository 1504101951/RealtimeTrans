import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/common/constants/screenshot_enums.dart';
import 'package:translate_app/src/screenshot/beautify.dart';
import 'package:translate_app/src/screenshot/edit_document.dart';
import 'package:translate_app/src/screenshot/stickers.dart';
import 'package:translate_app/src/settings/app_settings.dart';

/// width/height 为像素尺寸，color 为颜色；返回纯色图像。
Future<ui.Image> _solid(int width, int height, Color color) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(color, BlendMode.src);
  return recorder.endRecording().toImage(width, height);
}

/// image 为图像；返回 PNG 字节。
Future<Uint8List> _png(ui.Image image) async =>
    (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
        .asUint8List();

/// bytes 为 PNG；返回宽、高与逐像素 RGBA。
Future<(int, int, Uint8List)> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final image = (await codec.getNextFrame()).image;
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  return (image.width, image.height, data!.buffer.asUint8List());
}

/// decoded 为解码结果，x/y 为像素坐标；返回该像素的 RGB。
(int, int, int) _pixel((int, int, Uint8List) decoded, int x, int y) {
  final offset = (y * decoded.$1 + x) * 4;
  return (decoded.$3[offset], decoded.$3[offset + 1], decoded.$3[offset + 2]);
}

/// 无参数；验证贴纸标注的位图绘制、旋转与美化背景上的导出（#103）。
void main() {
  const blue = Color(0xFF0000FF);
  const red = (255, 0, 0);

  /// rotation 为旋转弧度，bounds 为贴纸范围；返回装好 48×48 蓝色截图与红色贴纸的文档。
  Future<EditDocument> document(Rect bounds, {double rotation = 0}) async {
    final doc = EditDocument()
      ..loadCapture(await _png(await _solid(48, 48, blue)), 48, 48);
    doc.stickerImages['red'] = await _solid(10, 10, const Color(0xFFFF0000));
    doc.addAnnotation(
      EditAnnotation(
        id: '',
        kind: AnnotationKind.sticker,
        bounds: bounds,
        stickerId: 'red',
        rotation: rotation,
      ),
    );
    return doc;
  }

  test('贴纸位图画满 bounds，旋转 90° 后横条变为竖条', () async {
    // 边界：20×8 的横向贴纸以 (24,24) 为中心；旋转前 (16,24) 为红、(24,16) 为蓝；旋转 90° 后相反。
    const bounds = Rect.fromLTWH(14, 20, 20, 8);
    final flat = await _decode(await (await document(bounds)).renderPng());
    expect(_pixel(flat, 16, 24), red);
    expect(_pixel(flat, 24, 16), (0, 0, 255));
    final turned = await _decode(
      await (await document(bounds, rotation: math.pi / 2)).renderPng(),
    );
    expect(_pixel(turned, 24, 16), red);
    expect(_pixel(turned, 16, 24), (0, 0, 255));
  });

  test('开启美化时贴纸可画在背景留白区，不美化时选区外部分被裁掉', () async {
    // 边界：贴纸 (-8,-8)–(8,8) 一半在截图外；美化内边距 10 时画布 (4,4) 对应源图 (-6,-6)，为红；
    // 不美化时输出只有截图范围，(2,2) 对应源图内的贴纸部分仍为红、尺寸为 48×48。
    final doc = await document(const Rect.fromLTWH(-8, -8, 16, 16));
    final framed = await _decode(
      await doc.renderPng(
        beautify: const BeautifyStyle(
          background: (color: Color(0xFFFFFFFF), gradient: null),
          padding: 10,
          shadow: false,
        ),
      ),
    );
    expect((framed.$1, framed.$2), (68, 68));
    expect(_pixel(framed, 4, 4), red);
    final plain = await _decode(await doc.renderPng());
    expect((plain.$1, plain.$2), (48, 48));
    expect(_pixel(plain, 2, 2), red);
  });

  test('贴纸默认大小：长边取原图与 512pt 的较小值并保持比例；设置往返与校验（#103）', () {
    // 边界：1000×500 → 512×256；300×200 不放大；长边 513pt 或宽为 0 时校验失败。
    expect(initialStickerSize(1000, 500), (512.0, 256.0));
    expect(initialStickerSize(300, 200), (300.0, 200.0));
    final settings = AppSettings(primaryLanguage: 'zh-CN')
      ..stickers.add(const StickerEntry(id: 'a', width: 120, height: 60));
    final restored = AppSettings.fromMap(settings.toMap());
    expect(restored.stickers.single.toMap(), {
      'id': 'a',
      'width': 120.0,
      'height': 60.0,
    });
    expect(restored.validate, returnsNormally);
    restored.stickers.add(const StickerEntry(id: 'b', width: 513, height: 10));
    expect(restored.validate, throwsFormatException);
    restored.stickers
      ..removeLast()
      ..add(const StickerEntry(id: 'c', width: 0, height: 10));
    expect(restored.validate, throwsFormatException);
  });
}
