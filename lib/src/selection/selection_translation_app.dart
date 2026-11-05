import 'dart:async';

import 'package:flutter/material.dart';

import '../common/constants/selection_gesture_types.dart';
import '../common/constants/text_mode.dart';
import '../common/widgets/native_glass.dart';
import '../history/translation_history.dart';
import '../history/vocabulary.dart';
import '../overlay/translation_overlay.dart';
import '../platform/platform_event.dart';
import '../platform/platform_ports.dart';
import '../translation/language_direction.dart';
import '../translation/provider_selection.dart';
import '../translation/translation_types.dart';
import 'selection_session.dart';

/// 选区翻译界面与会话协调者；处理原生事件、取消和完整成功后的历史记录。
class TranslateApp extends StatefulWidget {
  /// selection 为选区读取与输入注入，overlay 为浮层窗口，speech 为朗读，perf 为性能日志；
  /// session 为唯一翻译会话，history 为主引擎历史存储，vocabulary 为生词本；构造不启动请求。
  const TranslateApp({
    super.key,
    required this.selection,
    required this.overlay,
    required this.speech,
    required this.perf,
    required this.session,
    required this.history,
    required this.vocabulary,
  });

  final SelectionPort selection;
  final OverlayHost overlay;
  final SpeechPort speech;
  final PerformanceMarks perf;
  final SelectionSession session;
  final TranslationHistoryStore history;
  final VocabularyStore vocabulary;

  /// 无参数；返回管理事件订阅与浮层同步的界面状态。
  @override
  State<TranslateApp> createState() => _TranslateAppState();
}

/// 绑定选区会话与浮层生命周期，不创建独立配置或历史存储。
class _TranslateAppState extends State<TranslateApp> {
  static const _triggerSize = TranslationOverlay.triggerWindowSize;
  static const _resultSize = Size(720, 420);
  late final StreamSubscription<PlatformEvent> _bridgeSubscription;

  /// 来源在接受选区时冻结，不读取翻译完成后的前台应用。
  String? _sourceAppName;

  /// 由输入翻译快捷键发起的会话 ID；完整成功后用译文替换来源输入框，其他会话为 null。
  String? _replaceSessionId;

  /// 无参数；订阅原生事件与会话状态，无返回值。
  @override
  void initState() {
    super.initState();
    // 订阅跟随界面生命周期，避免重建后由旧界面继续处理选区。
    _bridgeSubscription = widget.selection.events.listen(_onBridgeEvent);
    widget.session.addListener(_syncOverlaySize);
  }

  /// 无参数；解除界面监听，避免旧界面处理新事件，无返回值。
  @override
  void dispose() {
    _bridgeSubscription.cancel();
    widget.session.removeListener(_syncOverlaySize);
    super.dispose();
  }

  /// event 为携带 sessionId 的选区或失效事件；同步界面与原生窗口，无返回值。
  void _onBridgeEvent(PlatformEvent event) {
    switch (event) {
      case SelectionCaptured(
        :final sessionId,
        :final text,
        :final gesture,
        :final sourceAppName,
        :final x,
        :final y,
      ):
        // 全局翻译与输入翻译快捷键都是明确请求，读取完成即直接翻译。
        final explicit =
            gesture == SelectionGestureTypes.hotkey ||
            gesture == SelectionGestureTypes.inputHotkey;
        // 被动捕获只更新小按钮，不能替换用户正在阅读的结果。
        if (widget.session.isExpanded && !explicit) {
          return;
        }
        _sourceAppName = sourceAppName;
        // 新选区替换卡片内容，停止朗读旧内容。
        unawaited(widget.speech.stopSpeech());
        // 输入翻译会话在完整成功后用译文替换来源输入框中的原文。
        _replaceSessionId = gesture == SelectionGestureTypes.inputHotkey
            ? sessionId
            : null;
        // 键盘选择先显示候选按钮；明确热键的空读取也必须进入可见失败状态。
        widget.session.begin(
          sessionId: sessionId,
          text: text,
          input: gesture == SelectionGestureTypes.inputHotkey,
          awaitSelection:
              gesture == SelectionGestureTypes.selectAll ||
              gesture == SelectionGestureTypes.keyboard ||
              explicit,
        );
        // 没有可用触发态时先退出，后续只处理需要展示的选区。
        if (widget.session.snapshot.phase != TranslationPhase.trigger) {
          widget.overlay.hideOverlay(sessionId: sessionId);
          return;
        }
        final size = explicit ? _resultSize : _triggerSize;
        if (explicit) {
          unawaited(_activate(readSelection: false));
        }
        // 输入翻译全过程不显示按钮或卡片，结果只体现在来源输入框或失败气泡（#99）。
        if (_replaceSessionId == sessionId) return;
        widget.overlay.showOverlay(
          sessionId: sessionId,
          x: x,
          y: y,
          width: size.width,
          height: size.height,
        );
      case SelectionInvalidated(:final sessionId):
        if (widget.session.isExpanded ||
            widget.session.sessionId != sessionId) {
          return;
        }
        _dismiss();
      case EscapePressed(:final sessionId):
        if (widget.session.sessionId != sessionId) return;
        _dismiss();
      case UnknownBridgeEvent():
        break;
    }
  }

  /// 无参数；按当前会话阶段更新原生窗口尺寸，无返回值。
  void _syncOverlaySize() {
    final id = widget.session.sessionId;
    // 输入翻译会话没有浮层，结束时由 _finishInput 释放会话（#99）。
    if (id == null || id == _replaceSessionId) return;
    final phase = widget.session.snapshot.phase;
    if (phase == TranslationPhase.idle) {
      widget.overlay.hideOverlay(sessionId: id);
      return;
    }
    if (phase == TranslationPhase.trigger) {
      widget.overlay.setOverlaySize(
        sessionId: id,
        width: _triggerSize.width,
        height: _triggerSize.height,
      );
      return;
    }
    widget.overlay.setOverlaySize(
      sessionId: id,
      width: _resultSize.width,
      height: _resultSize.height,
    );
  }

  /// readSelection 表示点击后补读格式；快捷键已完成读取；返回翻译结束或取消的 Future。
  Future<void> _activate({bool readSelection = true}) async {
    final id = widget.session.sessionId;
    final retry = widget.session.canRetry;
    if (id == null ||
        (!retry && widget.session.snapshot.phase != TranslationPhase.trigger)) {
      return;
    }
    // 先保留窗口，再开始异步补读；期间切 App 不会关闭加载或失败卡片。
    await widget.overlay.retainOverlay(sessionId: id);
    // 连续点击等待同一个原生响应时，只允许一次激活及一次成功记录。
    if (widget.session.sessionId != id ||
        (retry
            ? !widget.session.canRetry
            : widget.session.snapshot.phase != TranslationPhase.trigger)) {
      return;
    }
    // 输入翻译使用不含段落对照的服务（与语言方向的选择方式一致）。
    final activeProvider = retry
        ? widget.session.activeProvider
        : _replaceSessionId == id
        ? widget.session.inputProvider
        : widget.session.provider;
    // 历史记录的目标语言按本次实际使用的一组语言解析：输入翻译用输入翻译语言（#99）。
    final activeLanguage = retry
        ? widget.session.activeLanguage
        : _replaceSessionId == id
        ? widget.session.inputLanguage
        : widget.session.language;
    final sourceLabel = _sourceAppName;
    // 输入翻译从发起翻译起分段计时；只记录阶段名与毫秒，不含文本。
    final watch = _replaceSessionId == id ? (Stopwatch()..start()) : null;
    // 首个非空译文到达时记录一次 input-first-token，随后移除监听。
    void markFirstToken() {
      if (widget.session.snapshot.translatedText.isEmpty) return;
      widget.session.removeListener(markFirstToken);
      unawaited(widget.perf.perfMark('input-first-token', watch!));
    }

    if (watch != null) widget.session.addListener(markFirstToken);
    // 读取与翻译共用会话取消边界，迟到的原文不能覆盖用户的新选区。
    if (retry) {
      // 原文、方向和服务都属于失败会话；重试不重新读取前台选区。
      await widget.session.retry();
    } else {
      await widget.session.activate(
        readSelection: readSelection
            ? () => widget.selection.readSelectionForTranslation(sessionId: id)
            : null,
      );
    }
    if (watch != null) {
      widget.session.removeListener(markFirstToken);
      // 完整成功才记录 input-complete；失败或取消不产生该阶段。
      if (widget.session.sessionId == id &&
          widget.session.snapshot.phase == TranslationPhase.completed) {
        unawaited(widget.perf.perfMark('input-complete', watch));
      }
    }
    // _record 只在翻译模式完整成功时记录历史。
    _record(id, activeProvider, activeLanguage, sourceLabel);
    // _finishInput 完成输入翻译的替换或失败提示并结束会话（#99）。
    if (_replaceSessionId == id) await _finishInput(id);
  }

  /// id 为输入翻译会话；完整成功时粘贴替换原文，翻译失败或未替换时请求原生在选中区域附近显示原因，
  /// 随后结束会话；会话已被替换或取消时不做任何事，返回结束的 Future（#99）。
  Future<void> _finishInput(String id) async {
    if (widget.session.sessionId != id) return;
    final snapshot = widget.session.snapshot;
    // replaceSelection 返回 null 表示已替换，否则为未替换原因；翻译未完成时直接使用失败说明。
    final String? failure;
    if (snapshot.phase == TranslationPhase.completed) {
      // input-replace 只计 replaceSelection 的耗时。
      final replace = Stopwatch()..start();
      failure = await widget.selection.replaceSelection(
        sessionId: id,
        text: snapshot.translatedText,
      );
      unawaited(widget.perf.perfMark('input-replace', replace));
    } else {
      failure = snapshot.message ?? '翻译失败';
    }
    if (widget.session.sessionId != id) return;
    // showInputFailure 需要原生会话仍在，必须先于 _dismiss 释放会话。
    if (failure != null) {
      await widget.selection.showInputFailure(sessionId: id, message: failure);
    }
    _dismiss();
  }

  /// 无参数；把卡片的单词、译文与词典释义加入生词本，同一单词已存在时更新，无返回值。
  void _addVocabulary() {
    final session = widget.session;
    final definition = session.definition;
    if (definition == null) return;
    widget.vocabulary.add(
      VocabularyEntry(
        word: session.snapshot.sourceText.trim(),
        translation: session.snapshot.translatedText,
        definition: definition,
        addedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    // markSavedToVocabulary 置位并通知卡片把按钮改为已加入。
    session.markSavedToVocabulary();
  }

  /// source 为 true 时朗读原文栏，否则朗读结果栏；按该栏语言朗读，同一栏再次点击停止，无返回值。
  void _speak(bool source) {
    final snapshot = widget.session.snapshot;
    final primary = widget.session.activeLanguage.primaryCode;
    // 原文用识别出的语言，结果栏用本次请求的输出语言；缺失时按主要语言朗读。
    final language = source
        ? snapshot.detectedLanguage ?? primary
        : widget.session.outputLanguage ?? primary;
    unawaited(
      widget.speech.toggleSpeech(
        text: source ? snapshot.sourceText : snapshot.translatedText,
        language: language,
      ),
    );
  }

  /// mode 为卡片菜单选择的处理模式；对当前原文重新处理，翻译模式成功时记录历史，返回结束的 Future。
  Future<void> _switchMode(TextMode mode) async {
    final id = widget.session.sessionId;
    if (id == null) return;
    // 原文结果都会被替换，先停止朗读旧内容。
    unawaited(widget.speech.stopSpeech());
    final sourceLabel = _sourceAppName;
    await widget.session.switchMode(mode);
    _record(
      id,
      widget.session.activeProvider,
      widget.session.activeLanguage,
      sourceLabel,
    );
  }

  /// serviceId 为卡片服务菜单选中的服务；用它重新处理当前原文，翻译模式成功时记录历史，返回结束的 Future（#100）。
  Future<void> _switchService(String serviceId) async {
    final id = widget.session.sessionId;
    if (id == null) return;
    // 结果会被替换，先停止朗读旧内容。
    unawaited(widget.speech.stopSpeech());
    final sourceLabel = _sourceAppName;
    await widget.session.switchService(serviceId);
    _record(
      id,
      widget.session.activeProvider,
      widget.session.activeLanguage,
      sourceLabel,
    );
  }

  /// id 为发起时的会话，provider/language 为冻结的服务与方向，sourceLabel 为来源应用名。
  /// 仅在会话未被替换、处于翻译模式且完整成功时写入历史，无返回值。
  void _record(
    String id,
    TranslationProvider provider,
    LanguageDirection language,
    String? sourceLabel,
  ) {
    // 旧请求结束时新会话可能已经完成，必须核对 ID，不能重复记录新会话。
    if (widget.session.sessionId != id ||
        widget.session.mode != TextMode.translate ||
        widget.session.snapshot.phase != TranslationPhase.completed) {
      return;
    }
    widget.history.insert(
      sourceText: widget.session.snapshot.sourceText,
      translatedText: widget.session.snapshot.translatedText,
      detectedLanguage: widget.session.snapshot.detectedLanguage ?? '',
      // 按本次检测结果解析激活时的方向，不能把次要语言错误记录成主要语言。
      targetLanguage: language
          .resolve(widget.session.snapshot.detectedLanguage)
          .targetLanguage,
      providerId: provider.id,
      model: translationHistoryModel(provider),
      sourceLabel: sourceLabel,
      completedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// 无参数；关闭当前会话及其原生窗口，无返回值。
  void _dismiss() {
    final id = widget.session.sessionId;
    // 关闭卡片即停止朗读；取消业务请求后，用关闭前的会话 ID 隐藏窗口。
    unawaited(widget.speech.stopSpeech());
    widget.session.dismiss();
    if (id != null) {
      widget.overlay.hideOverlay(sessionId: id);
    }
  }

  /// context 为 Flutter 构建上下文；返回当前会话对应的浮层界面。
  @override
  Widget build(BuildContext context) {
    return NativeGlassApp(
      home: TranslationOverlay(
        session: widget.session,
        onActivate: _activate,
        onDismiss: _dismiss,
        onMode: (mode) => unawaited(_switchMode(mode)),
        onService: (serviceId) => unawaited(_switchService(serviceId)),
        onSpeak: _speak,
        onAddVocabulary: _addVocabulary,
        onDrag: () {
          final id = widget.session.sessionId;
          // 原生拖动保持来源应用焦点，并保留当前会话的位置。
          if (id != null) widget.overlay.dragOverlay(sessionId: id);
        },
      ),
    );
  }
}
