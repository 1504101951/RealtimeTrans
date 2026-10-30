import 'package:translate_app/src/common/widgets/native_glass.dart';
import 'package:translate_app/src/common/constants/preference_keys.dart';
import 'package:translate_app/src/screenshot/drawing_preferences.dart';

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:translate_app/src/screenshot/screenshot_app.dart';
import 'package:translate_app/src/common/constants/screenshot_actions.dart';
import 'package:translate_app/src/common/constants/method_names.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/common/constants/screenshot_enums.dart';
import 'package:translate_app/src/screenshot/drawing_controls.dart';
import 'package:translate_app/src/common/constants/drawing_metrics.dart';
import 'package:translate_app/src/screenshot/drawing_style.dart';
import 'package:translate_app/src/screenshot/edit_document.dart';

import 'support/capture_pixels.dart';

/// 生成带逐列颜色差异的48px原图，用于区分真实马赛克与纯色覆盖。
Future<Uint8List> fixture() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  for (var x = 0; x < 48; x++) {
    canvas.drawRect(
      Rect.fromLTWH(x.toDouble(), 0, 1, 48),
      Paint()..color = Color.fromARGB(255, x * 5, 30, 200),
    );
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(48, 48);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return bytes!.buffer.asUint8List();
}

/// bytes为PNG；返回逐像素RGBA，调用者可以断言输出而非绘图调用次数。
Future<Uint8List> rgba(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
  frame.image.dispose();
  codec.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('所有具体图形与画笔模式在切换和持久化后仍独立', () {
    // 两个画笔宽度取范围端点，四种图形取不同颜色，捕获共享槽覆盖。
    var prefs = DrawingPreferences();
    const colors = [Colors.red, Colors.blue, Colors.green, Colors.yellow];
    for (var i = 0; i < ShapeVariant.values.length; i++) {
      prefs = prefs.copyWith(
        tool: ScreenshotTool.rect,
        shape: ShapeVariant.values[i],
        style: DrawingStyle(color: colors[i], strokeWidth: 2.0 + i),
      );
    }
    prefs = prefs.copyWith(
      tool: ScreenshotTool.brush,
      brushMode: ShapeMode.solid,
      style: const DrawingStyle(color: Colors.purple, strokeWidth: 1),
    );
    prefs = prefs.copyWith(
      tool: ScreenshotTool.brush,
      brushMode: ShapeMode.mosaic,
      style: const DrawingStyle(strokeWidth: 20),
    );
    final restored = DrawingPreferences.fromMap(prefs.toMap());
    for (var i = 0; i < ShapeVariant.values.length; i++) {
      final style = restored.styleFor(
        ScreenshotTool.rect,
        shape: ShapeVariant.values[i],
      );
      expect(style.color.toARGB32(), colors[i].toARGB32());
      expect(style.strokeWidth, 2.0 + i);
    }
    expect(
      restored
          .styleFor(ScreenshotTool.brush, brushMode: ShapeMode.solid)
          .strokeWidth,
      1,
    );
    expect(
      restored
          .styleFor(ScreenshotTool.brush, brushMode: ShapeMode.solid)
          .color
          .toARGB32(),
      Colors.purple.toARGB32(),
    );
    expect(
      restored
          .styleFor(ScreenshotTool.brush, brushMode: ShapeMode.mosaic)
          .strokeWidth,
      20,
    );
    expect(restored.styleFor(ScreenshotTool.arrow).strokeWidth, 3);
  });

  test('每工具样式独立持久化，模式与填充色不覆盖其他工具', () {
    // 往返保存后保留箭头5pt、画笔12pt及真圆模式，覆盖非默认值与上边界。
    final saved = DrawingPreferences()
        .copyWith(
          tool: ScreenshotTool.arrow,
          style: const DrawingStyle(color: Colors.blue, strokeWidth: 5),
        )
        .copyWith(
          tool: ScreenshotTool.brush,
          style: const DrawingStyle(color: Colors.green, strokeWidth: 12),
          shape: ShapeVariant.filledCircle,
          brushMode: ShapeMode.mosaic,
        );
    final restored = DrawingPreferences.fromMap(saved.toMap());
    expect(restored.styles[ScreenshotTool.rect]!.strokeWidth, 3);
    expect(
      restored.styles[ScreenshotTool.arrow]!.color.toARGB32(),
      Colors.blue.toARGB32(),
    );
    expect(restored.styles[ScreenshotTool.arrow]!.strokeWidth, 5);
    expect(restored.styleFor(ScreenshotTool.brush).strokeWidth, 12);
    expect(restored.shape, ShapeVariant.filledCircle);
    expect(restored.brushMode, ShapeMode.mosaic);
    expect(
      () => DrawingPreferences.fromMap({
        'tools': {
          'brush': {'color': 0xFF000000, 'width': 21},
        },
      }),
      throwsFormatException,
    );
  });

  test('圆形填充与圆形描边仅改变对应像素，马赛克画笔不覆盖轨迹外', () async {
    final source = await fixture();
    final doc = EditDocument()..loadCapture(await decodePng(source));
    doc.addAnnotation(
      EditAnnotation(
        id: '',
        kind: AnnotationKind.rectangle,
        bounds: const Rect.fromLTWH(12, 12, 24, 24),
        shape: ShapeVariant.filledCircle,
        color: Colors.black,
      ),
    );
    final raw = await rgba(source);
    List<int> pixel(Uint8List bytes, int x, int y) =>
        bytes.sublist((y * 48 + x) * 4, (y * 48 + x) * 4 + 3);
    var data = await rgba(await doc.renderPng());
    expect(pixel(data, 24, 24), [0, 0, 0]);
    expect(pixel(data, 12, 12), pixel(raw, 12, 12));
    doc.undo();
    doc.addAnnotation(
      EditAnnotation(
        id: '',
        kind: AnnotationKind.rectangle,
        bounds: const Rect.fromLTWH(12, 12, 24, 24),
        shape: ShapeVariant.circle,
        color: Colors.black,
        strokeWidth: 3,
      ),
    );
    data = await rgba(await doc.renderPng());
    expect(pixel(data, 24, 24), pixel(raw, 24, 24));
    expect(pixel(data, 24, 12), [0, 0, 0]);
    doc.undo();
    doc.addAnnotation(
      EditAnnotation(
        id: '',
        kind: AnnotationKind.stroke,
        bounds: const Rect.fromLTWH(6, 24, 36, 0),
        points: const [Offset(6, 24), Offset(42, 24)],
        shapeMode: ShapeMode.mosaic,
        strokeWidth: 12,
      ),
    );
    data = await rgba(await doc.renderPng());
    expect(pixel(data, 13, 24), pixel(data, 21, 24));
    expect(pixel(data, 13, 17), pixel(raw, 13, 17));
    final mosaic = data;
    doc.undo();
    expect(await rgba(await doc.renderPng()), raw);
    doc.redo();
    expect(await rgba(await doc.renderPng()), mosaic);
  });

  test('马赛克以12px分块采样原图，区域外不变且可撤销', () async {
    final source = await fixture();
    final doc = EditDocument()..loadCapture(await decodePng(source));
    doc.addAnnotation(
      EditAnnotation(
        id: '',
        kind: AnnotationKind.mask,
        bounds: const Rect.fromLTWH(12, 12, 24, 24),
        shapeMode: ShapeMode.mosaic,
      ),
    );
    final original = await rgba(source);
    final output = await rgba(await doc.renderPng());
    // 同一格首尾保持一致，相邻格保留不同源图颜色，边界外保持原像素。
    List<int> pixel(Uint8List data, int x, int y) =>
        data.sublist((y * 48 + x) * 4, (y * 48 + x) * 4 + 4);
    expect(pixel(output, 12, 12), pixel(output, 23, 23));
    expect(pixel(output, 12, 12), isNot(pixel(output, 24, 12)));
    expect(pixel(output, 11, 12), pixel(original, 11, 12));
    expect(pixel(output, 36, 35), pixel(original, 36, 35));
    expect(pixel(output, 12, 12), pixel(original, 18, 18));
    doc.undo();
    expect(await rgba(await doc.renderPng()), original);
    doc.redo();
    expect(await rgba(await doc.renderPng()), output);
  });

  test('马赛克缓存跟随源图：同一区域换一张源图后按新图采样', () async {
    // 作用：马赛克按区域栅格化后缓存（#68），换图后不能沿用上一张图的缓存。
    // 边界：两张源图的马赛克区域完全相同，只有颜色不同；第二张图的输出必须等于第二张图块中心的颜色。
    const bounds = Rect.fromLTWH(12, 12, 24, 24);
    List<int> pixel(Uint8List data, int x, int y) =>
        data.sublist((y * 48 + x) * 4, (y * 48 + x) * 4 + 4);
    final first = EditDocument()..loadCapture(await decodePng(await fixture()));
    first.addAnnotation(
      EditAnnotation(
        id: '',
        kind: AnnotationKind.mask,
        bounds: bounds,
        shapeMode: ShapeMode.mosaic,
      ),
    );
    await first.renderPng();
    // 第二张图整幅纯绿，与 fixture 的逐列蓝紫渐变任何一格都不同。
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 48, 48),
      Paint()..color = const Color(0xFF00FF00),
    );
    final picture = recorder.endRecording();
    final green = await picture.toImage(48, 48);
    picture.dispose();
    final second = EditDocument()..loadCapture(green);
    second.addAnnotation(
      EditAnnotation(
        id: '',
        kind: AnnotationKind.mask,
        bounds: bounds,
        shapeMode: ShapeMode.mosaic,
      ),
    );
    final output = await rgba(await second.renderPng());
    expect(pixel(output, 12, 12), [0, 255, 0, 255]);
    expect(pixel(output, 35, 35), [0, 255, 0, 255]);
  });

  test('标注只读视图在文档未变更时复用同一对象，变更后换新并包含新标注', () async {
    // 作用：画布按视图对象判断是否重绘（#68）；未变更时必须是同一对象，变更后必须换新，否则画布不会重绘。
    // 边界：连续两次读取之间没有任何变更；随后加入一条标注。
    final doc = EditDocument()..loadCapture(await decodePng(await fixture()));
    final before = doc.annotations;
    expect(identical(doc.annotations, before), isTrue);
    doc.addAnnotation(
      EditAnnotation(
        id: '',
        kind: AnnotationKind.rectangle,
        bounds: const Rect.fromLTWH(4, 4, 12, 12),
      ),
    );
    expect(identical(doc.annotations, before), isFalse);
    expect(doc.annotations, hasLength(1));
    doc.undo();
    expect(doc.annotations, isEmpty);
  });

  test('颜色与线宽快照隔离，更新目标只产生一次可撤销变化', () async {
    final doc = EditDocument()..loadCapture(await decodePng(await fixture()));
    const style = DrawingStyle(color: Colors.red, strokeWidth: 3);
    final first = doc.addAnnotation(
      EditAnnotation(
        id: '',
        kind: AnnotationKind.rectangle,
        bounds: const Rect.fromLTWH(4, 4, 12, 12),
        style: style,
      ),
    );
    doc.addAnnotation(
      EditAnnotation(
        id: '',
        kind: AnnotationKind.rectangle,
        bounds: const Rect.fromLTWH(28, 28, 12, 12),
        style: style,
      ),
    );
    final before = await rgba(await doc.renderPng());
    final selected = doc.annotations.firstWhere((a) => a.id == first);
    doc.updateAnnotation(
      selected.copyWith(
        style: selected.style.copyWith(color: Colors.blue, strokeWidth: 8),
      ),
    );
    expect(doc.annotations.first.color, Colors.blue);
    expect(doc.annotations.first.strokeWidth, 8);
    expect(doc.annotations.last.style, style);
    final changed = await rgba(await doc.renderPng());
    expect(changed, isNot(before));
    doc.undo();
    expect(await rgba(await doc.renderPng()), before);
    doc.redo();
    expect(await rgba(await doc.renderPng()), changed);
  });

  testWidgets('调色盘非法HEX不提交，应用自定义色，取消不提交', (tester) async {
    ColorFill? result;
    var cancelled = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ColorPicker(
            initial: (color: Colors.black, gradient: null),
            onApply: (v) => result = v,
            onCancel: () => cancelled = true,
          ),
        ),
      ),
    );
    await tester.enterText(find.byKey(const Key('color-hex')), 'GG1234');
    await tester.pump();
    expect(find.text('请输入6位十六进制颜色'), findsOneWidget);
    await tester.tap(find.byKey(const Key('apply-color')));
    expect(result, isNull);
    await tester.enterText(find.byKey(const Key('color-hex')), '#123ABC');
    await tester.pump();
    await tester.tap(find.byKey(const Key('apply-color')));
    expect(result, (color: const Color(0xFF123ABC), gradient: null));
    result = null;
    await tester.tap(find.byKey(const Key('palette-007AFF')));
    await tester.tap(find.text('取消'));
    expect(cancelled, isTrue);
    expect(result, isNull);
  });

  testWidgets('线宽1到20pt只在应用时提交', (tester) async {
    double? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StrokeWidthPicker(
            initial: 3,
            onApply: (v) => result = v,
            onCancel: () {},
          ),
        ),
      ),
    );
    final slider = find.byKey(const Key('stroke-width-slider'));
    await tester.tapAt(tester.getRect(slider).centerRight - const Offset(1, 0));
    await tester.pump();
    expect(result, isNull);
    await tester.tap(find.byKey(const Key('apply-stroke-width')));
    expect(result, 20);
  });
  testWidgets('工具属性在第二行独立记忆，并在重新打开编辑器后恢复', (tester) async {
    // 用真实控件修改并重建编辑器；持久化只替换平台存储边界，避免仅测序列化。
    tester.view.physicalSize = const Size(640, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final source = await tester.runAsync(fixture);
    final capture = await tester.runAsync(() => capturePixels(source!));
    const channel = MethodChannel('test/tool-properties');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    Map<Object?, Object?>? saved;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {
          'id': 'properties',
          ...capture!,
          'width': 48,
          'height': 48,
          PreferenceKeys.screenshotDrawing: ?saved,
        };
      }
      if (call.method == MethodNames.saveDrawingPreferences) {
        saved = Map<Object?, Object?>.from(call.arguments as Map);
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    Future<void> tap(String id) async {
      final finder = find.byKey(Key(id));
      await tester.ensureVisible(finder);
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    Future<void> color(String expected, String next) async {
      await tap(ScreenshotActions.palette);
      final field = find.byKey(const Key('color-hex'));
      expect(tester.widget<TextField>(field).controller!.text, expected);
      await tester.enterText(field, next);
      await tap('apply-color');
    }

    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    // 源图异步建好后文档才有图。
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();
    // 默认截图组显示采集入口；绘图属性仅在切到对应绘图工具后出现。
    expect(find.byKey(const Key(ScreenshotActions.record)), findsOneWidget);
    expect(find.byKey(const Key(ScreenshotActions.palette)), findsNothing);
    await tap(ScreenshotActions.rect);
    expect(
      tester.getRect(find.byKey(const Key('screenshot-attributes-row'))).top,
      tester.getRect(find.byKey(const Key('screenshot-tools-row'))).bottom + 4,
    );
    await tap('${ScreenshotActions.shapePrefix}circle');
    await color('FF3B30', 'FF9500');
    await tap(ScreenshotActions.width);
    final slider = find.byKey(const Key('stroke-width-slider'));
    await tester.tapAt(tester.getRect(slider).centerRight - const Offset(1, 0));
    await tester.pump();
    await tap('apply-stroke-width');
    await tap(ScreenshotActions.arrow);
    await color('FF3B30', '007AFF');
    await tap(ScreenshotActions.brush);
    // 两种画笔使用不同线宽；切回普通画笔不能继承马赛克设置。
    await tap(ScreenshotActions.width);
    await tester.tapAt(tester.getRect(slider).centerRight - const Offset(1, 0));
    await tester.pump();
    await tap('apply-stroke-width');
    await tap('${ScreenshotActions.brushPrefix}mosaic');
    final modeMaterial = find.ancestor(
      of: find.byKey(Key('${ScreenshotActions.brushPrefix}mosaic')),
      matching: find.byType(NativeGlassSurface),
    );
    expect(modeMaterial, findsOneWidget);
    expect(tester.widget<NativeGlassSurface>(modeMaterial).material, isTrue);
    expect(find.byKey(const Key(ScreenshotActions.palette)), findsNothing);
    await tap(ScreenshotActions.width);
    expect(
      tester.widget<Slider>(find.byKey(const Key('stroke-width-slider'))).value,
      3,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tap('${ScreenshotActions.brushPrefix}solid');
    await tap(ScreenshotActions.width);
    expect(tester.widget<Slider>(slider).value, 20);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tap('${ScreenshotActions.brushPrefix}mosaic');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    // 源图异步建好后文档才有图。
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();
    await tap(ScreenshotActions.rect);
    await color('FF9500', 'FF9500');
    await tap(ScreenshotActions.width);
    expect(
      tester.widget<Slider>(find.byKey(const Key('stroke-width-slider'))).value,
      20,
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(DrawingPreferences.fromMap(saved).shape, ShapeVariant.circle);
    await tap(ScreenshotActions.arrow);
    await color('007AFF', '007AFF');
    await tap(ScreenshotActions.text);
    await color('FF3B30', 'FF3B30');
    // 编辑已有红字颜色不能覆盖后续文字的蓝色默认值。
    await tester.tapAt(const Offset(200, 120));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('screenshot-text-field')),
      'existing object',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tap(ScreenshotActions.arrow);
    await tap(ScreenshotActions.text);
    await color('FF3B30', '007AFF');
    // 文字工具下单击是选中，紧接着再次点击同一文字框才进入编辑。
    await tester.tapAt(const Offset(230, 130));
    await tester.tapAt(const Offset(230, 130));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('screenshot-text-field')), findsOneWidget);
    await color('FF3B30', '000000');
    expect(
      DrawingPreferences.fromMap(saved).styles[ScreenshotTool.text]!.color
          .toARGB32(),
      0xFF007AFF,
    );
    expect(DrawingPreferences.fromMap(saved).fontSize, 18);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tap(ScreenshotActions.brush);
    expect(find.byKey(const Key(ScreenshotActions.palette)), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('编辑器选中矩形应用颜色和线宽后导出，撤销恢复原样', (tester) async {
    // 480×400原图与1倍窗口一致，避免把屏幕和图像坐标混为一谈。
    tester.view.physicalSize = const Size(480, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final png = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.white, BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(480, 400);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      return bytes!.buffer.asUint8List();
    });
    final capture = await tester.runAsync(() => capturePixels(png!));
    const channel = MethodChannel('test/drawing-integration');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    Uint8List? exported;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.getScreenshot) {
        return {'id': 'drawing', ...capture!};
      }
      if (call.method == MethodNames.copyScreenshot) {
        exported = (call.arguments as Map)['bytes'] as Uint8List;
        return {};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const ScreenshotApp(channel: channel));
    // 源图异步建好后文档才有图。
    await awaitCaptureSource(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key(ScreenshotActions.rect)));
    await tester.dragFrom(const Offset(100, 100), const Offset(160, 120));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key(ScreenshotActions.cursor)));
    await tester.tapAt(const Offset(100, 150));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key(ScreenshotActions.palette)), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const Key(ScreenshotActions.palette)),
    );
    await tester.tap(find.byKey(const Key(ScreenshotActions.palette)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('color-hex')), '007AFF');
    await tester.tap(find.byKey(const Key('apply-color')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key(ScreenshotActions.width)));
    await tester.tap(find.byKey(const Key(ScreenshotActions.width)));
    await tester.pumpAndSettle();
    final slider = find.byKey(const Key('stroke-width-slider'));
    await tester.tapAt(tester.getRect(slider).centerRight - const Offset(1, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('apply-stroke-width')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key(ScreenshotActions.copy)));
    // PNG引擎编码需要真实异步区间，不能在fakeAsync里触发后只等待墙钟。
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key(ScreenshotActions.copy)));
      for (var i = 0; i < 100 && exported == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
    expect(exported, isNotNull);
    final data = await tester.runAsync(() => rgba(exported!));
    expect(data!.sublist((150 * 480 + 106) * 4, (150 * 480 + 106) * 4 + 3), [
      0,
      122,
      255,
    ]);
    // 撤销只有系统快捷键 ⌘Z；连按两次撤回两步。
    for (var step = 0; step < 2; step++) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
    }
    exported = null;
    await tester.ensureVisible(find.byKey(const Key(ScreenshotActions.copy)));
    // PNG引擎编码需要真实异步区间，不能在fakeAsync里触发后只等待墙钟。
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key(ScreenshotActions.copy)));
      for (var i = 0; i < 100 && exported == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
    final restored = await tester.runAsync(() => rgba(exported!));
    expect(
      restored!.sublist((150 * 480 + 100) * 4, (150 * 480 + 100) * 4 + 3),
      [255, 59, 48],
    );
    // 画笔第二行切换马赛克；隐藏颜色但保留轨迹粗细。
    await tester.ensureVisible(find.byKey(const Key(ScreenshotActions.brush)));
    await tester.tap(find.byKey(const Key(ScreenshotActions.brush)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const Key('${ScreenshotActions.brushPrefix}mosaic')),
    );
    await tester.tap(
      find.byKey(const Key('${ScreenshotActions.brushPrefix}mosaic')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key(ScreenshotActions.palette)), findsNothing);
    expect(find.byKey(const Key(ScreenshotActions.width)), findsOneWidget);
    // 编辑中的文字打开/取消调色盘不能消失，应用颜色仍保留输入焦点与草稿。
    await tester.ensureVisible(find.byKey(const Key(ScreenshotActions.text)));
    await tester.tap(find.byKey(const Key(ScreenshotActions.text)));
    await tester.pump();
    await tester.tapAt(const Offset(120, 270));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('screenshot-text-field')),
      'keep draft',
    );
    await tester.ensureVisible(
      find.byKey(const Key(ScreenshotActions.palette)),
    );
    await tester.tap(find.byKey(const Key(ScreenshotActions.palette)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('screenshot-text-field')), findsOneWidget);
    expect(find.text('keep draft'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('调色盘渐变页签：预设、编辑结束色与方向后应用带渐变的值，切回纯色应用不带渐变（#103）', (tester) async {
    // 边界：选预设「海洋」后改结束色为 #112233、方向为 →，应用值的起始色为海洋起始色；
    // 再切回「纯色」应用，渐变为 null。
    final results = <ColorFill>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ColorPicker(
            initial: (color: Colors.black, gradient: null),
            onApply: results.add,
            onCancel: () {},
          ),
        ),
      ),
    );
    await tester.tap(find.text('渐变'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('gradient-preset-1')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('gradient-end')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('color-hex')), '112233');
    await tester.tap(find.byKey(const Key('gradient-direction-right')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('apply-color')));
    expect(results.single, (
      color: DrawingMetrics.gradients[1].from,
      gradient: const FillGradient(
        end: Color(0xFF112233),
        direction: GradientDirection.right,
      ),
    ));
    await tester.tap(find.text('纯色'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('apply-color')));
    expect(results.last.gradient, isNull);
    expect(results.last.color, DrawingMetrics.gradients[1].from);
  });

  test('渐变填充图形：左端为起始色、右端为结束色；绘图偏好往返保留渐变，缺失即纯色（#103）', () async {
    // 边界：48px 宽的实心矩形，方向 →，红到蓝；第 1 列接近红、第 46 列接近蓝。
    final doc = EditDocument()..loadCapture(await decodePng(await fixture()));
    doc.addAnnotation(
      EditAnnotation(
        id: 'g',
        kind: AnnotationKind.rectangle,
        shape: ShapeVariant.filledRectangle,
        bounds: const Rect.fromLTWH(0, 0, 48, 48),
        style: const DrawingStyle(
          color: Color(0xFFFF0000),
          gradient: FillGradient(
            end: Color(0xFF0000FF),
            direction: GradientDirection.right,
          ),
        ),
      ),
    );
    final pixels = await rgba(await doc.renderPng());
    (int, int) redBlue(int x) =>
        (pixels[(24 * 48 + x) * 4], pixels[(24 * 48 + x) * 4 + 2]);
    expect(redBlue(1).$1, greaterThan(240));
    expect(redBlue(46).$2, greaterThan(240));

    final prefs = DrawingPreferences().copyWith(
      tool: ScreenshotTool.arrow,
      style: const DrawingStyle(gradient: FillGradient(end: Color(0xFF00FF00))),
    );
    final restored = DrawingPreferences.fromMap(prefs.toMap());
    expect(
      restored.styleFor(ScreenshotTool.arrow).gradient,
      const FillGradient(end: Color(0xFF00FF00)),
    );
    expect(restored.styleFor(ScreenshotTool.text).gradient, isNull);
  });
}

