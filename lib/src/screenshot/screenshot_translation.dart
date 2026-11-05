import 'dart:async';

import 'package:flutter/services.dart';

import '../common/constants/error_codes.dart';
import '../history/translation_history.dart';
import '../translation/language_direction.dart';
import '../translation/segmented_translation.dart';
import '../translation/translation_types.dart';

/// 截图已关闭或被替换时的提示，与原生截图窗口的过期错误同一文案（#124）。
const _staleCaptureMessage = '截图已关闭或被替换，请重新截图。';

/// text 为 OCR 原文，provider/language 为启动时配置，detectLanguage 使用本地识别，
/// isCurrent 核对截图生命周期，cancelled 在截图结束时完成，history 管理持久化；
/// 返回完整译文，失败或取消不写记录，取消传播至当前 Provider 并停止后续分片。
Future<String> translateScreenshotText({
  required String text,
  required TranslationProvider provider,
  required String? model,
  required LanguageDirection language,
  required Future<String?> Function(String) detectLanguage,
  required Future<bool> Function() isCurrent,
  required Future<void> cancelled,
  required TranslationHistoryStore history,
}) async {
  if (text.trim().isEmpty) {
    throw PlatformException(code: ErrorCodes.ocrEmpty, message: '没有可翻译的文字。');
  }
  var ended = false;
  StreamIterator<TranslationEvent>? events;
  // 主引擎持有取消信号；即使服务暂时没有返回增量，也立即停止读取与网络工作。
  unawaited(
    cancelled.then((_) async {
      ended = true;
      await events?.cancel();
    }),
  );
  // 本地识别完成后再核对截图，关闭或替换的旧截图不能发起新的网络请求。
  final detected = await detectLanguage(text);
  final current = !ended && await isCurrent();
  if (ended || !current) {
    throw PlatformException(
      code: ErrorCodes.staleCapture,
      message: _staleCaptureMessage,
    );
  }
  // 使用启动时冻结的语言方向，避免请求期间设置更新污染历史元数据。
  final direction = language.resolve(detected);
  final buffer = StringBuffer();
  var completed = false;
  // 分片只在全篇完成时报告成功；部分输出不构成一条历史记录。
  final iterator = StreamIterator(
    translateSegmented(
      provider.translate,
      TranslationRequest(
        sourceText: text,
        detectedLanguage: direction.detectedLanguage,
        targetLanguage: direction.targetLanguage,
      ),
      usesSlidingContext: provider.usesSlidingContext,
    ),
  );
  events = iterator;
  try {
    while (await iterator.moveNext()) {
      if (ended) break;
      switch (iterator.current) {
        case TranslationUpdate(:final addition):
          buffer.write(addition);
        case TranslationCompleted():
          completed = true;
        case TranslationFailure(:final message):
          throw PlatformException(
            code: ErrorCodes.translateFailed,
            message: message,
          );
      }
    }
  } finally {
    // StreamIterator.cancel 逐层取消当前分片和服务连接；完成路径同样释放订阅。
    await iterator.cancel();
  }
  // 核对身份之后再决定成功；取消不被误判为一次不完整但仍可重试的截图。
  final stillCurrent = !ended && await isCurrent();
  if (ended || !stillCurrent) {
    throw PlatformException(
      code: ErrorCodes.staleCapture,
      message: _staleCaptureMessage,
    );
  }
  if (!completed) {
    throw PlatformException(
      code: ErrorCodes.translateFailed,
      message: incompleteTranslationMessage,
    );
  }
  final translated = buffer.toString();
  // Store 在写入时检查记录开关；关闭记录不会删除之前的结果。
  history.insert(
    sourceText: text,
    translatedText: translated,
    detectedLanguage: direction.detectedLanguage ?? '',
    targetLanguage: direction.targetLanguage,
    providerId: provider.id,
    model: model,
    completedAt: DateTime.now().millisecondsSinceEpoch,
    sourceLabel: '截图',
  );
  return translated;
}
