import 'package:translate_app/src/common/constants/method_names.dart';
import 'package:translate_app/src/common/constants/channel_names.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/main.dart' as app;
import 'package:translate_app/src/selection/selection_translation_app.dart';

/// 无参数；验证截图翻译和设置提交等待期间，主引擎仍能读取历史和持久化记录开关。
void main() {
  testWidgets('截图翻译与设置提交等待期间，历史分页和关闭记录可独立完成', (tester) async {
    // 设备识别保持未完成；这是网络开始前即可稳定复现的异步边界。
    final detection = Completer<String?>();
    final started = Completer<void>();
    final saving = Completer<void>();
    final saveStarted = Completer<void>();
    var holdSettings = false;
    final directory = Directory.systemTemp.createTempSync('history-channel-');
    const methods = MethodChannel(ChannelNames.macos);
    const events = MethodChannel(ChannelNames.macosEvents);
    const codec = StandardMethodCodec();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(methods, (call) async {
      switch (call.method) {
        case MethodNames.loadSettings:
          return <String, Object>{};
        case MethodNames.applicationSupportPath:
          return directory.path;
        case MethodNames.applySettings:
          if (holdSettings) {
            saveStarted.complete();
            await saving.future;
          }
          return null;
        case MethodNames.credentialIds:
          return <String>[];
        case MethodNames.detectLanguage:
          started.complete();
          return detection.future;
        case MethodNames.isCurrentScreenshot:
          return false;
        default:
          return null;
      }
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
    await app.main();
    await tester.pump();
    final history = tester
        .widget<TranslateApp>(find.byType(TranslateApp))
        .history;
    addTearDown(() {
      history.database.close();
      directory.deleteSync(recursive: true);
      messenger.setMockMethodCallHandler(methods, null);
      messenger.setMockMethodCallHandler(events, null);
      methods.setMethodCallHandler(null);
    });

    /// name/arguments 为原生向主引擎发送的请求；返回解码后的真实通道响应。
    Future<Object?> request(
      String name, [
      Map<String, Object> arguments = const {},
    ]) {
      final result = Completer<Object?>();
      unawaited(
        messenger.handlePlatformMessage(
          methods.name,
          codec.encodeMethodCall(MethodCall(name, arguments)),
          (reply) {
            try {
              result.complete(codec.decodeEnvelope(reply!));
            } catch (error, stack) {
              result.completeError(error, stack);
            }
          },
        ),
      );
      return result.future;
    }

    final translating = request(MethodNames.translatePlainText, {
      'text': 'Hello',
      'id': 'closed-shot',
    });
    final cancelled = expectLater(
      translating,
      throwsA(isA<PlatformException>()),
    );
    await started.future;
    // 同时挂起真实主引擎的设置提交；历史开关属于独立业务，不能排在设置队列后。
    holdSettings = true;
    final updating = request(MethodNames.toggleAutomatic);
    await saveStarted.future;
    await request(MethodNames.setHistoryRecording, {'enabled': false});
    expect(history.recordingEnabled, isFalse);
    expect(await request(MethodNames.historyPage, {'limit': 10}), isEmpty);
    // 新的查询与管理协议同样不等待设置队列；验证实际筛选、计数和删除结果。
    await request(MethodNames.setHistoryRetention, {'days': 0});
    await request(MethodNames.setHistoryRecording, {'enabled': true});
    for (final stamp in [1, DateTime.now().millisecondsSinceEpoch]) {
      history.insert(
        sourceText: 'source',
        translatedText: '译文',
        detectedLanguage: 'en',
        targetLanguage: 'zh',
        providerId: 'test',
        completedAt: stamp,
        sourceLabel: 'Safari',
      );
    }
    expect(await request(MethodNames.historySources), ['Safari']);
    final filtered = await request(MethodNames.historyPage, {
      'query': '译文',
      'source': 'Safari',
      'from': 1,
      'to': 2,
    }) as List;
    expect(filtered, hasLength(1));
    expect(
      (await request(MethodNames.historyRetention, {'days': 30})
          as Map)['expiredCount'],
      1,
    );
    await request(MethodNames.setHistoryRetention, {'days': 30});
    expect(history.page(), hasLength(1));
    await request(MethodNames.deleteHistory, {'id': history.page().single.id});
    expect(history.page(), isEmpty);
    history.insert(
      sourceText: 'last',
      translatedText: '最后',
      detectedLanguage: 'en',
      targetLanguage: 'zh',
      providerId: 'test',
      completedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await request(MethodNames.clearHistory);
    expect(history.page(), isEmpty);
    await request(MethodNames.setHistoryRecording, {'enabled': false});
    expect(detection.isCompleted, isFalse);
    expect(saving.isCompleted, isFalse);
    saving.complete();
    await updating;
    // 截图已经关闭，释放设备识别后应取消请求，不访问远程服务或新增历史。
    detection.complete('en');
    await cancelled;
    expect(history.page(), isEmpty);
  });
}
