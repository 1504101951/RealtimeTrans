import 'dart:async';
import 'dart:ui' as ui;

import 'package:translate_app/src/common/constants/error_codes.dart';
import 'package:translate_app/src/common/widgets/native_glass.dart';
import 'package:translate_app/src/common/constants/method_names.dart';
import 'package:translate_app/src/common/constants/channel_names.dart';
import 'package:translate_app/src/common/constants/preference_keys.dart';
import 'package:translate_app/src/common/constants/text_mode.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/settings/settings_app.dart';
import 'package:translate_app/src/settings/sticker_upload_dialog.dart';
import 'package:flutter/gestures.dart';

/// 无参数；验证真实表单在菜单刷新时保留草稿，并阻止过期设置覆盖。
void main() {
  testWidgets('菜单更新不会覆盖未保存编辑，显式重新加载才替换表单', (tester) async {
    const channel = MethodChannel(ChannelNames.settings);
    const codec = StandardMethodCodec();
    var revision = 0;
    final pending = Completer<void>();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true};
      }
      if (call.method == MethodNames.saveSettings) {
        final draft = Map<String, Object?>.from(call.arguments as Map);
        await pending.future;
        if (draft['revision'] != revision) {
          throw PlatformException(
            code: ErrorCodes.settingsConflict,
            message: '设置版本冲突',
          );
        }
        return {...draft, 'revision': ++revision};
      }
      if (call.method == MethodNames.getSettings) {
        return {
          PreferenceKeys.primaryLanguage: revision == 0 ? 'zh-CN' : 'ja',
          PreferenceKeys.secondaryLanguage: 'en',
          'revision': revision,
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('翻译'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is NativeGlassSwitchTile && w.title == '仅使用快捷键',
        ),
        matching: find.byType(NativeGlassSwitch),
      ),
    );
    await tester.pumpAndSettle();
    revision = 1;
    pending.complete();
    await messenger.handlePlatformMessage(
      ChannelNames.settings,
      codec.encodeMethodCall(const MethodCall(MethodNames.refreshSettings)),
      (_) {},
    );
    await tester.pumpAndSettle();
    // 草稿仍保留中文和开启的仅快捷键开关，不用检查通道调用次数代替用户结果。
    expect(find.text('简体中文'), findsOneWidget);
    expect(
      tester
          .widget<NativeGlassSwitch>(find.byType(NativeGlassSwitch).first)
          .value,
      isTrue,
    );
    await tester.scrollUntilVisible(find.text('重新加载设置'), 300);
    await tester.pumpAndSettle();
    expect(find.text('保存设置'), findsNothing);
    expect(find.text('重试自动保存'), findsNothing);
    await tester.tap(find.text('重新加载设置'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, 1800));
    await tester.pumpAndSettle();
    expect(find.text('日本語'), findsOneWidget);
    expect(
      tester
          .widget<NativeGlassSwitch>(find.byType(NativeGlassSwitch).first)
          .value,
      isFalse,
    );
  });

  testWidgets('录制数字组合后显示真实快捷键，取消保留当前组合', (tester) async {
    const channel = MethodChannel(ChannelNames.settings);
    var cancel = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true};
      }
      if (call.method == MethodNames.getSettings) return {'revision': 0};
      if (call.method == MethodNames.saveSettings) {
        final draft = Map<String, Object?>.from(call.arguments as Map);
        return {...draft, 'revision': (draft['revision'] as int) + 1};
      }
      if (call.method == MethodNames.recordShortcut) {
        return cancel ? null : {'keyCode': 18, 'modifiers': 4352, 'label': '1'};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('翻译'));
    await tester.pumpAndSettle();
    // 分段导航后热键更靠下；先滚入视口再录制，避免点到不可命中区域。
    await tester.scrollUntilVisible(find.byKey(const ValueKey('全局翻译快捷键')), 300);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('全局翻译快捷键')));
    await tester.pumpAndSettle();
    expect(find.text('⌃ ⌘ 1'), findsOneWidget);
    cancel = true;
    await tester.tap(find.byKey(const ValueKey('全局翻译快捷键')));
    await tester.pumpAndSettle();
    expect(find.text('⌃ ⌘ 1'), findsOneWidget);
  });
  testWidgets('添加服务、测试草稿、默认切换和删除通过保存形成实际状态', (tester) async {
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var state = <String, Object?>{'revision': 0};
    var credentialIds = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true};
      }
      if (call.method == MethodNames.getSettings) {
        return {...state, MethodNames.credentialIds: credentialIds};
      }
      if (call.method == MethodNames.testService) {
        // 测试连接不得使主偏好提前包含新服务。
        expect(state[PreferenceKeys.services], isNull);
        return '你好，世界。';
      }
      if (call.method == MethodNames.saveSettings) {
        final draft = Map<String, Object?>.from(call.arguments as Map);
        final credentials = draft.remove('credentials') as Map;
        final services = draft[PreferenceKeys.services] as List;
        credentialIds = services
            .map((e) => (e as Map)['id'] as String)
            .toList();
        if (credentials.isNotEmpty && services.isNotEmpty) {
          expect(credentials[credentialIds.single], {
            'apiKey': 'test-key',
            'appId': 'test-app',
          });
          expect((services.single as Map).containsKey('apiKey'), false);
        }
        state = {...draft, 'revision': (state['revision'] as int) + 1};
        return {...state, MethodNames.credentialIds: credentialIds};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('翻译'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加服务'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();
    expect(find.text('请填写 API Key／密钥，百度翻译还需要 App ID。'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('百度 App ID')), 'test-app');
    await tester.enterText(find.byKey(const ValueKey('百度密钥')), 'test-key');
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();
    expect(find.text('连接成功：你好，世界。'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('百度翻译'), findsWidgets);
    final selector = find.descendant(
      of: find.byWidgetPredicate(
        (w) => w is NativeGlassDropdown<String> && w.label == '默认翻译服务',
      ),
      matching: find.byType(TextButton),
    );
    await tester.tap(selector);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, '百度翻译'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('仅使用快捷键'), 250);
    await tester.tap(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is NativeGlassSwitchTile && w.title == '仅使用快捷键',
        ),
        matching: find.byType(NativeGlassSwitch),
      ),
    );
    await tester.pumpAndSettle();
    expect(state[PreferenceKeys.defaultServiceId], credentialIds.single);
    expect(state[PreferenceKeys.automatic], false);
    expect(find.text('已自动保存'), findsNothing);
    // 保存后视口在底部；向上拖回服务列表再删，避免 scrollUntilVisible 在边界抛错。
    await tester.drag(find.byType(ListView), const Offset(0, 1200));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('删除 百度翻译'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('删除 百度翻译'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(state[PreferenceKeys.services], isEmpty);
    expect(state[PreferenceKeys.defaultServiceId], 'unofficial-google');
  });

  testWidgets('设置分段：截图与翻译控件互斥，切换保留草稿', (tester) async {
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true, 'loginItems': 'enabled'};
      }
      if (call.method == MethodNames.getSettings) {
        return {
          PreferenceKeys.primaryLanguage: 'zh-CN',
          PreferenceKeys.secondaryLanguage: 'en',
          'revision': 0,
          PreferenceKeys.screenshotSaveDirectory: '/tmp/shots',
        };
      }
      if (call.method == MethodNames.saveSettings) {
        final draft = Map<String, Object?>.from(call.arguments as Map);
        return {...draft, 'revision': (draft['revision'] as int) + 1};
      }
      if (call.method == MethodNames.chooseScreenshotDirectory) {
        return '/tmp/chosen';
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();

    // 默认通用段：登录/排除可见，翻译与截图控件不可见。
    expect(find.text('通用'), findsOneWidget);
    expect(find.text('翻译'), findsOneWidget);
    expect(find.text('截图'), findsOneWidget);
    expect(find.text('排除应用'), findsOneWidget);
    expect(find.text('登录时启动'), findsOneWidget);
    expect(find.text('屏幕录制权限'), findsOneWidget);
    expect(find.text('翻译语言'), findsNothing);
    expect(find.text('截图目录'), findsNothing);

    await tester.tap(find.text('翻译'));
    await tester.pumpAndSettle();
    expect(find.text('翻译语言'), findsOneWidget);
    expect(find.text('仅使用快捷键'), findsOneWidget);
    expect(find.byKey(const ValueKey('全局翻译快捷键')), findsOneWidget);
    expect(find.text('截图目录'), findsNothing);
    expect(find.text('排除应用'), findsNothing);

    await tester.tap(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is NativeGlassSwitchTile && w.title == '仅使用快捷键',
        ),
        matching: find.byType(NativeGlassSwitch),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('截图'));
    await tester.pumpAndSettle();
    expect(find.text('截图目录'), findsOneWidget);
    expect(find.text('/tmp/shots'), findsOneWidget);
    expect(find.byKey(const ValueKey('区域截图快捷键')), findsOneWidget);
    expect(find.text('屏幕录制权限'), findsNothing);
    expect(find.text('翻译语言'), findsNothing);
    expect(find.text('仅使用快捷键'), findsNothing);
    expect(find.text('排除应用'), findsNothing);

    await tester.tap(find.text('选择…'));
    await tester.pumpAndSettle();
    expect(find.text('/tmp/chosen'), findsOneWidget);

    // 配置入口在截图页底部默认收起；展开后仍在当前页，且只包含顶层工具。
    final section = find.byKey(const ValueKey('screenshot-toolbar-section'));
    expect(find.text('设置快捷键'), findsNothing);
    // 截图页高于窗口，列表按需构建；先滚到底部入口再比较两者位置。
    await tester.scrollUntilVisible(
      section,
      150,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(section).dy,
      greaterThan(tester.getTopLeft(find.byKey(const ValueKey('区域截图快捷键'))).dy),
    );
    await tester.tap(find.text('截图工具栏'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(
      find.byKey(const ValueKey('toolbar-row-screenshot-tool-cursor')),
      findsOneWidget,
    );
    expect(find.text('增大字号'), findsNothing);
    expect(find.text('在 Finder 中显示'), findsNothing);
    await tester.tap(find.text('截图工具栏'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('翻译'));
    await tester.pumpAndSettle();
    expect(find.text('翻译语言'), findsOneWidget);
    expect(
      tester
          .widget<NativeGlassSwitch>(find.byType(NativeGlassSwitch).first)
          .value,
      isTrue,
    );
  });
  testWidgets('截图页保存GIF帧率与最大宽度，留空恢复原宽且非法值不保存', (tester) async {
    // 600是有效压缩上限；0非法、空值是不限制，保存后的重新加载必须保留用户选择。
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var settings = <String, Object?>{'revision': 0};
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true};
      }
      if (call.method == MethodNames.getSettings) return settings;
      if (call.method == MethodNames.saveSettings) {
        settings = {
          ...Map<String, Object?>.from(call.arguments as Map),
          'revision': (settings['revision'] as int) + 1,
        };
        return settings;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('截图'));
    await tester.pumpAndSettle();
    expect(find.text('默认截图存放路径'), findsOneWidget);
    expect(find.text('每次询问'), findsNothing);
    expect(find.text('10 fps'), findsOneWidget);
    final width = find.byKey(const Key('gif-maximum-width'));
    await tester.ensureVisible(width);
    await tester.enterText(width, '600');
    await tester.pumpAndSettle();
    expect(settings[PreferenceKeys.gifMaximumWidth], 600);
    // 输入框滚动后帧率下拉可能位于固定导航下方，点击前先滚入可见区域。
    await tester.ensureVisible(find.text('10 fps'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('10 fps'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('15 fps'));
    await tester.tap(find.text('15 fps'));
    await tester.pumpAndSettle();
    expect(settings[PreferenceKeys.gifFramesPerSecond], 15);
    await tester.enterText(width, '0');
    await tester.pumpAndSettle();
    expect(settings[PreferenceKeys.gifMaximumWidth], 600);
    await tester.scrollUntilVisible(
      find.textContaining('最大宽度须为正整数'),
      150,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(find.textContaining('最大宽度须为正整数'), findsOneWidget);
    // 滚到底部提示后输入框可能已移出按需构建范围，反向滚回。
    await tester.scrollUntilVisible(
      width,
      -150,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.enterText(width, '');
    await tester.pumpAndSettle();
    expect(settings.containsKey(PreferenceKeys.gifMaximumWidth), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('截图'));
    await tester.pumpAndSettle();
    expect(find.text('15 fps'), findsOneWidget);
    expect(tester.widget<TextField>(width).controller!.text, isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets('贴纸：添加时按原图比例给出默认大小，拖角缩小后保存；删除移除设置与文件（#103）', (tester) async {
    // 边界：1000×500 的图默认 512×256pt；把右下角拖到预览中心右 50pt、下 10pt 处，宽度决定大小，长边变为
    // 100/预览比例 ≈ 173pt（短于 512 但大于 16）；提交的 stickers 宽高与说明一致；删除后列表为空并请求删除文件。
    final png = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(const Color(0xFFFF0000), BlendMode.src);
      final image = await recorder.endRecording().toImage(1000, 500);
      return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
          .asUint8List();
    });
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var settings = <String, Object?>{'revision': 0};
    final saved = <String>[];
    final deleted = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case MethodNames.systemStatus:
          return {'accessibility': true};
        case MethodNames.getSettings:
          return settings;
        case MethodNames.importStickerImage:
          return {'bytes': png, 'width': 1000, 'height': 500};
        case MethodNames.saveSticker:
          saved.add((call.arguments as Map)['id'] as String);
          return '/tmp/x.png';
        case MethodNames.deleteSticker:
          deleted.add((call.arguments as Map)['id'] as String);
          return null;
        case MethodNames.saveSettings:
          final draft = Map<String, Object?>.from(call.arguments as Map)
            ..remove('credentials');
          settings = {...draft, 'revision': (settings['revision'] as int) + 1};
          return settings;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('截图'));
    await tester.pumpAndSettle();
    expect(find.text('还没有贴纸'), findsOneWidget);
    await tester.ensureVisible(find.text('添加图片…'));
    await tester.tap(find.text('添加图片…'));
    await tester.pumpAndSettle();
    expect(find.text('默认大小 512 × 256 pt'), findsOneWidget);
    final handle = find.byKey(const ValueKey('sticker-handle-3'));
    final preview = find
        .ancestor(of: handle, matching: find.byType(SizedBox))
        .first;
    final center = tester.getCenter(preview);
    // 分步移动越过手势判定距离，最终指针在中心右 50pt、下 10pt：横向决定大小。
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await gesture.moveBy(const Offset(-30, -30));
    await gesture.moveTo(center + const Offset(50, 10));
    await gesture.up();
    await tester.pumpAndSettle();
    final long = (100 / StickerUploadDialog.previewScale).round();
    await tester.tap(find.widgetWithText(FilledButton, '添加'));
    await tester.pumpAndSettle();
    final stickers = settings[PreferenceKeys.stickers] as List;
    expect(saved, hasLength(1));
    expect((stickers.single as Map)['id'], saved.single);
    expect(((stickers.single as Map)['width'] as num).round(), long);

    final thumbnail = find.byKey(ValueKey('sticker-${saved.single}'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(thumbnail));
    addTearDown(mouse.removePointer);
    await tester.pump();
    await tester.tap(find.byTooltip('删除贴纸'));
    await tester.pumpAndSettle();
    expect(settings[PreferenceKeys.stickers], isEmpty);
    expect(deleted, saved);
  });

  testWidgets('翻译语言分段：切到输入翻译只修改输入翻译的一组语言，全局不变（#99）', (tester) async {
    // 边界：全局 zh-CN/en，输入翻译未设置时显示复制的 zh-CN/en；切到「输入翻译」把次要语言改为日本語，
    // 提交后输入翻译次要语言为 ja，全局次要语言仍为 en。
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var settings = <String, Object?>{
      'revision': 0,
      PreferenceKeys.primaryLanguage: 'zh-CN',
      PreferenceKeys.secondaryLanguage: 'en',
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true};
      }
      if (call.method == MethodNames.getSettings) return settings;
      if (call.method == MethodNames.saveSettings) {
        final draft = Map<String, Object?>.from(call.arguments as Map)
          ..remove('credentials');
        settings = {...draft, 'revision': (settings['revision'] as int) + 1};
        return settings;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('翻译').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('输入翻译').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('English').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('日本語').last);
    await tester.pumpAndSettle();
    expect(settings[PreferenceKeys.inputSecondaryLanguage], 'ja');
    expect(settings[PreferenceKeys.secondaryLanguage], 'en');
    expect(settings[PreferenceKeys.inputPrimaryLanguage], 'zh-CN');
    expect(tester.takeException(), isNull);
  });
  testWidgets('提示词：四个字段、恢复默认、空提示词不能保存，保存后自动提交提示词与思考开关', (tester) async {
    // 边界：初始润色为自定义值时「恢复默认」可用，点击后回到默认值且按钮禁用；
    // 纠错清空时显示「提示词不能为空。」且「保存」禁用；填回后保存，提交的偏好含四种提示词；
    // 弹窗恰有翻译、润色、纠错、解释四个字段，只打开润色思考开关时只有 polishThinking 为 true。
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var settings = <String, Object?>{
      'revision': 0,
      PreferenceKeys.prompts[TextMode.polish]!: '自定义润色',
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true};
      }
      if (call.method == MethodNames.getSettings) return settings;
      if (call.method == MethodNames.saveSettings) {
        final draft = Map<String, Object?>.from(call.arguments as Map)
          ..remove('credentials');
        settings = {...draft, 'revision': (settings['revision'] as int) + 1};
        return settings;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('翻译'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('编辑提示词…'));
    await tester.tap(find.text('编辑提示词…'));
    await tester.pumpAndSettle();

    for (final label in ['翻译', '润色', '纠错', '解释']) {
      expect(find.byKey(ValueKey('提示词-$label')), findsOneWidget);
      expect(find.byKey(ValueKey('思考-$label')), findsOneWidget);
    }
    await tester.tap(find.byKey(const ValueKey('思考-润色')));
    await tester.pumpAndSettle();

    TextButton restore(String label) =>
        tester.widget<TextButton>(find.byKey(ValueKey('恢复默认-$label')));
    expect(restore('润色').onPressed, isNotNull);
    expect(restore('纠错').onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('恢复默认-润色')));
    await tester.pumpAndSettle();
    expect(restore('润色').onPressed, isNull);

    await tester.enterText(find.byKey(const ValueKey('提示词-纠错')), '');
    await tester.pumpAndSettle();
    expect(find.text('提示词不能为空。'), findsOneWidget);
    FilledButton save() =>
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, '保存'));
    expect(save().onPressed, isNull);
    await tester.enterText(find.byKey(const ValueKey('提示词-纠错')), '只纠错');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(
      settings[PreferenceKeys.prompts[TextMode.polish]!],
      defaultPrompts[TextMode.polish],
    );
    expect(settings[PreferenceKeys.prompts[TextMode.correct]!], '只纠错');
    expect(settings[PreferenceKeys.thinking[TextMode.polish]!], isTrue);
    for (final mode in [
      TextMode.translate,
      TextMode.correct,
      TextMode.explain,
    ]) {
      expect(settings[PreferenceKeys.thinking[mode]!], isFalse);
    }
    expect(
      settings[PreferenceKeys.prompts[TextMode.explain]!],
      defaultPrompts[TextMode.explain],
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('截图页确认动作：下拉只提供复制图片与复制并保存，选择后自动保存（#111）', (tester) async {
    // 边界：缺省为复制图片；下拉恰好两项，选「复制并保存」后提交的偏好值为 copyAndSave。
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var settings = <String, Object?>{'revision': 0};
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true};
      }
      if (call.method == MethodNames.getSettings) return settings;
      if (call.method == MethodNames.saveSettings) {
        final draft = Map<String, Object?>.from(call.arguments as Map)
          ..remove('credentials');
        settings = {...draft, 'revision': (settings['revision'] as int) + 1};
        return settings;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('截图'));
    await tester.pumpAndSettle();
    final scrollable = find
        .descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('复制图片'),
      150,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制图片'));
    await tester.pumpAndSettle();
    expect(find.text('复制并保存'), findsWidgets);
    await tester.tap(find.text('复制并保存').last);
    await tester.pumpAndSettle();
    expect(settings[PreferenceKeys.screenshotConfirmAction], 'copyAndSave');
    expect(tester.takeException(), isNull);
  });
  testWidgets('术语表：管理弹窗内添加、编辑与删除即时自动保存，同一目标语言下重复时留在编辑弹窗提示', (tester) async {
    // 边界：新增 api 与已有 API 只差大小写，视为重复；编辑条目本身不算与自己重复；
    // 原文术语为空时「确定」不可用；译法留空显示为保留原文。
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var state = <String, Object?>{
      'revision': 0,
      PreferenceKeys.primaryLanguage: 'zh-CN',
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true};
      }
      if (call.method == MethodNames.getSettings) {
        return {...state, MethodNames.credentialIds: <String>[]};
      }
      if (call.method == MethodNames.saveSettings) {
        final draft = Map<String, Object?>.from(call.arguments as Map)
          ..remove('credentials');
        state = {...draft, 'revision': (state['revision'] as int) + 1};
        return {...state, MethodNames.credentialIds: <String>[]};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('翻译'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('管理术语（0）'));
    await tester.pumpAndSettle();
    expect(find.text('暂无术语'), findsOneWidget);

    /// term/translation 为弹窗输入；打开添加弹窗、填写并点击确定。
    Future<void> add(String term, String translation) async {
      await tester.tap(find.text('添加术语'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确定'))
            .onPressed,
        isNull,
      );
      await tester.enterText(find.byKey(const ValueKey('原文术语')), term);
      await tester.enterText(find.byKey(const ValueKey('译法')), translation);
      await tester.pump();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
    }

    /// 无参数；返回已保存偏好中的术语表。
    List<Object?> saved() => state[PreferenceKeys.glossary] as List;

    await add('API', '应用接口');
    expect(saved(), [
      {'term': 'API', 'translation': '应用接口', 'language': 'zh-CN'},
    ]);
    expect(find.text('API → 应用接口'), findsOneWidget);

    await add('api', '接口');
    expect(find.text('该目标语言下已有此术语。'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('原文术语')), 'Kubernetes');
    await tester.enterText(find.byKey(const ValueKey('译法')), '');
    await tester.pump();
    expect(find.text('该目标语言下已有此术语。'), findsNothing);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('Kubernetes（保留原文）'), findsOneWidget);
    expect(saved(), hasLength(2));

    await tester.tap(find.byTooltip('编辑 API'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('译法')), '接口');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect((saved().first as Map)['translation'], '接口');

    await tester.tap(find.byTooltip('删除 Kubernetes'));
    await tester.pumpAndSettle();
    expect(saved(), [
      {'term': 'API', 'translation': '接口', 'language': 'zh-CN'},
    ]);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('管理术语（1）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('截图页「长截图 → 滚动方式」默认手动滚动，选自动滚动后自动保存到偏好（#112）', (tester) async {
    // 边界：偏好缺省时显示「手动滚动」；选「自动滚动」后偏好值为 automatic。
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var state = <String, Object?>{'revision': 0};
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true};
      }
      if (call.method == MethodNames.getSettings) {
        return {...state, MethodNames.credentialIds: <String>[]};
      }
      if (call.method == MethodNames.saveSettings) {
        final draft = Map<String, Object?>.from(call.arguments as Map)
          ..remove('credentials');
        state = {...draft, 'revision': (state['revision'] as int) + 1};
        return {...state, MethodNames.credentialIds: <String>[]};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('截图'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('手动滚动'),
      150,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('手动滚动'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自动滚动').last);
    await tester.pumpAndSettle();
    expect(state[PreferenceKeys.scrollCaptureMode], 'automatic');
    expect(tester.takeException(), isNull);
  });
  testWidgets('截图页「截图包含鼠标指针」「录制时显示鼠标点击」默认关闭，打开后自动保存到偏好', (tester) async {
    // 边界：偏好缺省为关闭；开关只在按钮上响应，打开后偏好值为 true（#105、#110）。
    const channel = MethodChannel(ChannelNames.settings);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var state = <String, Object?>{'revision': 0};
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == MethodNames.systemStatus) {
        return {'accessibility': true};
      }
      if (call.method == MethodNames.getSettings) {
        return {...state, MethodNames.credentialIds: <String>[]};
      }
      if (call.method == MethodNames.saveSettings) {
        final draft = Map<String, Object?>.from(call.arguments as Map)
          ..remove('credentials');
        state = {...draft, 'revision': (state['revision'] as int) + 1};
        return {...state, MethodNames.credentialIds: <String>[]};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const SettingsApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('截图'));
    await tester.pumpAndSettle();
    for (final (title, key) in [
      ('截图包含鼠标指针', PreferenceKeys.screenshotIncludesCursor),
      ('录制时显示鼠标点击', PreferenceKeys.recordingShowsClicks),
    ]) {
      final tile = find.byWidgetPredicate(
        (w) => w is NativeGlassSwitchTile && w.title == title,
      );
      await tester.scrollUntilVisible(
        tile,
        200,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(tester.widget<NativeGlassSwitchTile>(tile).value, isFalse);
      await tester.tap(
        find.descendant(of: tile, matching: find.byType(NativeGlassSwitch)),
      );
      await tester.pumpAndSettle();
      expect(state[key], isTrue);
    }
  });
}
