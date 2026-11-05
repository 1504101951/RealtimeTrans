import 'package:flutter/services.dart';

import 'platform_event.dart';

/// 主引擎依赖的平台能力端口（#68「Windows 客户端架构」）。每个端口只负责一类系统能力；
/// 业务模块只依赖所需端口，组合根注入两平台共用的通道适配器，测试可注入内存实现。

/// 选区读取与输入注入：原生选区事件、补读格式化原文、输入翻译替换与失败提示。
abstract interface class SelectionPort {
  /// 无参数；返回原生选区、失效与 Escape 事件流。
  Stream<PlatformEvent> get events;

  /// sessionId 绑定当前选区；明确点击翻译后补读格式，返回原文，失效时返回 null。
  Future<String?> readSelectionForTranslation({required String sessionId});

  /// sessionId 为输入翻译会话，text 为完整译文；返回 null 表示已替换，否则为未替换原因。
  Future<String?> replaceSelection({
    required String sessionId,
    required String text,
  });

  /// sessionId 为输入翻译会话，message 为失败原因；在选中区域附近显示失败气泡，返回调度完成的 Future。
  Future<void> showInputFailure({
    required String sessionId,
    required String message,
  });
}

/// 不抢焦点的翻译浮层与实时翻译盖层。
abstract interface class OverlayHost {
  /// sessionId 绑定会话，x/y 为屏幕锚点，width/height 为逻辑尺寸；显示并定位浮层，返回完成的 Future。
  Future<void> showOverlay({
    required String sessionId,
    required double x,
    required double y,
    double width,
    double height,
  });

  /// sessionId 为待隐藏会话；只隐藏该会话的浮层，返回完成的 Future。
  Future<void> hideOverlay({required String sessionId});

  /// sessionId 为即将展开的会话；保留浮层直至显式关闭，返回完成的 Future。
  Future<void> retainOverlay({required String sessionId});

  /// sessionId 为目标会话，width/height 为逻辑尺寸；调整浮层大小，返回完成的 Future。
  Future<void> setOverlaySize({
    required String sessionId,
    required double width,
    required double height,
  });

  /// sessionId 为目标会话；把当前按下事件交给系统拖动浮层，返回完成的 Future。
  Future<void> dragOverlay({required String sessionId});

  /// state 为实时翻译快照；交给原生盖层绘制，返回接收完成的 Future。
  Future<void> publishLiveRegion(Map<String, Object?> state);
}

/// 系统离线朗读。
abstract interface class SpeechPort {
  /// text 为卡片一栏全文，language 为语言码；同一段正在朗读时停止，否则改读该段，返回调用后是否在朗读。
  Future<bool> toggleSpeech({required String text, required String language});

  /// 无参数；停止当前朗读，返回完成的 Future。
  Future<void> stopSpeech();
}

/// 本机文本服务：设备语言识别与离线词典。
abstract interface class TextServices {
  /// text 为原文；返回设备识别的语言码，无法判断时为 null，不联网。
  Future<String?> detectLanguage(String text);

  /// text 为单词或短语；返回系统词典释义全文，查不到时为 null，不联网。
  Future<String?> lookupDefinition(String text);
}

/// 原生性能日志。
abstract interface class PerformanceMarks {
  /// stage 为固定阶段名，watch 为该阶段计时器；把毫秒耗时写入原生性能日志，返回发送完成的 Future。
  Future<void> perfMark(String stage, Stopwatch watch);
}

/// 应用宿主：启动握手、偏好与目录、跨窗口请求入口、截图身份核对与历史变更广播。
abstract interface class AppHost {
  /// 无参数；返回原生保存的偏好与系统首选语言。
  Future<Map<Object?, Object?>> loadSettings();

  /// 无参数；返回应用支持目录路径。
  Future<String> applicationSupportPath();

  /// 无参数；通知原生主界面可用，返回窗口调度后完成的 Future。
  Future<void> appReady();

  /// message 为初始化失败原因；原生提示后退出，返回提示调度完成的 Future。
  Future<void> appStartFailed(String message);

  /// handler 处理附属窗口经原生转发的业务请求，返回值即回复；无返回值。
  void handleApplicationRequests(Future<Object?> Function(MethodCall) handler);

  /// captureId 为截图身份；返回原生截图是否仍存在且未被替换。
  Future<bool> isCurrentScreenshot(String captureId);

  /// 无参数；通知已打开的历史窗口重新读取，返回转发完成的 Future。
  Future<void> notifyHistoryChanged();
}
