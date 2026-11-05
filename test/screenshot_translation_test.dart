import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:translate_app/src/common/constants/error_codes.dart';
import 'package:translate_app/src/history/translation_history.dart';
import 'package:translate_app/src/screenshot/screenshot_translation.dart';
import 'package:translate_app/src/translation/language_direction.dart';
import 'package:translate_app/src/translation/segmented_translation.dart';
import 'package:translate_app/src/translation/translation_types.dart';

/// 用受控事件驱动真实截图翻译业务；不替换历史库或成功判断。
class _Provider extends TranslationProvider {
  /// events 为一次请求产生的完整业务事件序列。
  _Provider(this.events);
  final Stream<TranslationEvent> events;
  @override
  String get id => 'test-model';

  /// request 为 OCR 原文及方向；返回受控事件流以覆盖完成、失败及取消边界。
  @override
  Stream<TranslationEvent> translate(TranslationRequest request) => events;
}

/// 按真实分片原文提供独立输入流，使后续片是否开始消费可观察。
class _SegmentProvider extends TranslationProvider {
  /// segments 为分片原文到事件流的映射；仅包含当前用例明确准备的输入。
  _SegmentProvider(this.segments);
  final Map<String, Stream<TranslationEvent>> segments;

  @override
  String get id => 'segmented-model';

  /// request 为实际分片请求；返回该片独立的事件输入，不代替分片调度。
  @override
  Stream<TranslationEvent> translate(TranslationRequest request) =>
      segments[request.sourceText]!;
}

/// 无参数；验证截图来源记录只在全篇完成且截图有效时产生。
void main() {
  test('截图流静默等待时取消立即返回过期，不消费后续片且新截图可独立成功', () async {
    // 边界：6000+1 字超过单片上限，第一片不产生任何事件，取消必须独立于服务响应完成；
    // 已关闭截图不能继续读取第二片或写历史，新的截图使用独立取消信号与输入流。
    final database = sqlite3.openInMemory();
    addTearDown(database.close);
    final store = TranslationHistoryStore(database);
    final started = Completer<void>();
    final released = Completer<void>();
    final cancelled = Completer<void>();
    var continuationConsumed = false;
    final first = StreamController<TranslationEvent>(
      onListen: started.complete,
      onCancel: released.complete,
    );
    final continuation = StreamController<TranslationEvent>(
      onListen: () => continuationConsumed = true,
    );
    addTearDown(() {
      // 从未订阅的单订阅流，其 close Future 要等订阅；清理不等待不存在的消费者。
      unawaited(first.close());
      unawaited(continuation.close());
    });
    final initial = 'A' * translationSegmentMax;
    final translation = translateScreenshotText(
      text: '${initial}B',
      provider: _SegmentProvider({
        initial: first.stream,
        'B': continuation.stream,
      }),
      model: 'waiting-model',
      language: const LanguageDirection(primaryCode: 'zh-CN'),
      detectLanguage: (_) async => 'en',
      isCurrent: () async => true,
      cancelled: cancelled.future,
      history: store,
    );
    final assertion = expectLater(
      translation.timeout(const Duration(seconds: 1)),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          ErrorCodes.staleCapture,
        ),
      ),
    );
    await started.future.timeout(const Duration(seconds: 1));
    cancelled.complete();
    await assertion;
    await released.future.timeout(const Duration(seconds: 1));
    expect(first.hasListener, isFalse);
    expect(continuationConsumed, isFalse);
    expect(store.page(), isEmpty);

    // 关闭输入已被真实取消，迟到的成功事件不能产生历史，也不能启动剩余原文的翻译。
    first.add(const TranslationUpdate('旧截图的迟到结果'));
    first.add(const TranslationCompleted());
    await first.close();
    final translated = await translateScreenshotText(
      text: 'New screenshot',
      provider: _Provider(
        Stream.fromIterable(const [
          TranslationUpdate('新截图译文'),
          TranslationCompleted(),
        ]),
      ),
      model: 'new-model',
      language: const LanguageDirection(primaryCode: 'zh-CN'),
      detectLanguage: (_) async => 'en',
      isCurrent: () async => true,
      cancelled: Completer<void>().future,
      history: store,
    );
    expect(translated, '新截图译文');
    expect(continuationConsumed, isFalse);
    final saved = store.page().single;
    expect(saved.sourceText, 'New screenshot');
    expect(saved.translatedText, '新截图译文');
    expect(saved.model, 'new-model');
  });

  test('语言识别期间截图结束，识别迟到结果仍返回过期且不开始消费翻译输入', () async {
    // 边界：截图在本地语言识别完成之前结束；取消信号不能遗漏到网络阶段。
    final database = sqlite3.openInMemory();
    addTearDown(database.close);
    final store = TranslationHistoryStore(database);
    final detecting = Completer<void>();
    final detected = Completer<String?>();
    final cancelled = Completer<void>();
    var consumed = false;
    final events = StreamController<TranslationEvent>(
      onListen: () => consumed = true,
    );
    addTearDown(() => unawaited(events.close()));
    final translation = translateScreenshotText(
      text: 'Closed while detecting',
      provider: _Provider(events.stream),
      model: null,
      language: const LanguageDirection(primaryCode: 'zh-CN'),
      detectLanguage: (_) {
        detecting.complete();
        return detected.future;
      },
      isCurrent: () async => true,
      cancelled: cancelled.future,
      history: store,
    );
    final assertion = expectLater(
      translation,
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          ErrorCodes.staleCapture,
        ),
      ),
    );
    await detecting.future;
    cancelled.complete();
    detected.complete('en');
    await assertion;
    expect(consumed, isFalse);
    expect(store.page(), isEmpty);
  });

  test('完整截图译文落库，重复翻译分别记录，关闭开关后只返回译文', () async {
    final database = sqlite3.openInMemory();
    addTearDown(database.close);
    final store = TranslationHistoryStore(database);
    // 主要语言命中时要记录次要目标语言；同一原文翻译三次检验不去重及开关。
    for (var i = 0; i < 3; i++) {
      if (i == 2) store.recordingEnabled = false;
      final translated = await translateScreenshotText(
        text: '你好',
        provider: _Provider(
          Stream.fromIterable([
            const TranslationUpdate('Hello'),
            const TranslationCompleted(),
          ]),
        ),
        model: 'example-model',
        language: const LanguageDirection(
          primaryCode: 'zh-CN',
          secondaryCode: 'en',
        ),
        detectLanguage: (_) async => 'zh-Hans',
        isCurrent: () async => true,
        cancelled: Completer<void>().future,
        history: store,
      );
      expect(translated, 'Hello');
    }
    expect(store.page(), hasLength(2));
    final row = store.page().first;
    expect(row.sourceLabel, '截图');
    expect(row.targetLanguage, 'en');
    expect(row.detectedLanguage, 'zh-CN');
    expect(row.model, 'example-model');
  });

  test('部分流结束、业务失败和关闭截图的迟到成功均不写入', () async {
    final database = sqlite3.openInMemory();
    addTearDown(database.close);
    final store = TranslationHistoryStore(database);
    // 三种非成功边界使用同一真实流程；只改变实际输入的事件和截图生命周期。
    for (final ending in ['incomplete', 'failed', 'closed']) {
      final events = StreamController<TranslationEvent>();
      var current = true;
      final started = Completer<void>();
      final translation = translateScreenshotText(
        text: 'Hello',
        provider: _Provider(events.stream),
        model: null,
        language: const LanguageDirection(primaryCode: 'zh-CN'),
        detectLanguage: (_) async => 'en',
        isCurrent: () async {
          if (!started.isCompleted) started.complete();
          return current;
        },
        cancelled: Completer<void>().future,
        history: store,
      );
      final assertion = expectLater(
        translation,
        throwsA(isA<PlatformException>()),
      );
      await started.future;
      events.add(const TranslationUpdate('部分'));
      if (ending == 'failed') events.add(const TranslationFailure('无有效结果'));
      if (ending == 'closed') {
        current = false;
        events.add(const TranslationCompleted());
      }
      await events.close();
      await assertion;
      expect(store.page(), isEmpty);
    }
  });
}
