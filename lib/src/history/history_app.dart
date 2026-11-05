import '../common/constants/glass_metrics.dart';
import '../common/constants/method_names.dart';
import '../common/constants/channel_names.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/utils/date_text.dart';
import '../common/widgets/native_glass.dart';

import 'translation_history.dart';
import 'screenshot_history_page.dart';
import 'vocabulary_page.dart';

/// 历史窗口的分段；翻译历史、生词本（#102）与截图历史（#29）共用同一窗口。
enum _HistorySection { history, vocabulary, screenshots }

/// 独立历史窗口；只展示主引擎持久化结果，不持有第二份数据库。
class HistoryApp extends StatefulWidget {
  /// channel 为历史查询和记录开关通道；创建独立窗口内容。
  const HistoryApp({
    super.key,
    this.channel = const MethodChannel(ChannelNames.settings),
  });

  /// SQLite 统一由主引擎管理，避免多个窗口重复写入。
  final MethodChannel channel;

  /// 无参数；返回维护分页和记录开关的窗口状态。
  @override
  State<HistoryApp> createState() => _HistoryAppState();
}

/// 维护当前浏览列表；游标分页使新增记录不影响已加载的卡片。
class _HistoryAppState extends State<HistoryApp> {
  /// 保持数据库倒序，长文不截断。
  final _items = <TranslationRecord>[];

  /// 读取成功前禁用开关，避免猜测偏好覆盖真实设置。
  bool? _recording;
  bool _savingRecording = false;
  bool _loading = false;
  int _requestVersion = 0;
  bool _done = false;
  String? _pageError;
  String? _recordingError;
  bool _failedReset = false;
  final _search = TextEditingController();
  final _pageKey = GlobalKey();
  String _source = '';
  List<String> _sources = [];
  DateTime? _from;
  DateTime? _to;
  int? _retentionDays;
  bool _retentionConfirmed = true;
  bool _managing = false;
  String? _managementError;

  /// 当前分段；生词本分段不显示历史刷新与记录开关。
  _HistorySection _section = _HistorySection.history;

  /// 主引擎通知历史、生词本或截图历史变化的次数；递增后对应分段重新读取。
  int _changeVersion = 0;

  /// 无参数；读取首批记录及开关，无返回值。
  @override
  void initState() {
    super.initState();
    widget.channel.setMethodCallHandler((call) async {
      if (call.method != MethodNames.historyChanged) return;
      // 同一变更通知覆盖翻译历史、生词本与截图历史，都按最新数据重载。
      setState(() => _changeVersion += 1);
      await _refresh();
    });
    // 首屏与开关独立读取，开关失败不阻止历史浏览。
    _loadMore();
    _loadRecording();
    _loadManagement(prompt: true);
  }

  /// 无参数；读取持久化开关，返回读取结束的 Future。
  Future<void> _loadRecording() async {
    try {
      final value = await widget.channel.invokeMethod<bool>(
        MethodNames.historyRecording,
      );
      if (!mounted) return;
      setState(() {
        _recording = value!;
        _recordingError = null;
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() => _recordingError = error.message ?? '无法读取记录设置');
    }
  }

  /// enabled 为用户选择；持久化成功后才更新显示，返回保存结束的 Future。
  Future<void> _setRecording(bool enabled) async {
    setState(() => _savingRecording = true);
    try {
      await widget.channel.invokeMethod<void>(MethodNames.setHistoryRecording, {
        'enabled': enabled,
      });
      if (!mounted) return;
      setState(() {
        _recording = enabled;
        _recordingError = null;
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() => _recordingError = error.message ?? '无法保存记录设置');
    } finally {
      if (mounted) setState(() => _savingRecording = false);
    }
  }

  /// reset 决定替换首批或按原游标追加；失败保留记录与重试语义，返回读取结束的 Future。
  Future<void> _loadMore({bool reset = false}) async {
    if (!reset && (_loading || _done)) return;
    final version = reset ? ++_requestVersion : _requestVersion;
    setState(() {
      _loading = true;
      _pageError = null;
    });
    try {
      final last = reset ? null : _items.lastOrNull;
      final page = await widget.channel.invokeListMethod<Map<Object?, Object?>>(
        MethodNames.historyPage,
        {
          'limit': 10,
          'query': _search.text.trim(),
          'source': _source,
          if (_from != null) 'from': _from!.millisecondsSinceEpoch,
          if (_to != null)
            'to': DateTime(
              _to!.year,
              _to!.month,
              _to!.day + 1,
            ).millisecondsSinceEpoch,
          if (last != null)
            'before': {'completedAt': last.completedAt, 'id': last.id},
        },
      );
      if (!mounted || version != _requestVersion) return;
      // 完整解析后再追加，避免失败的一页留下部分记录。
      final records = page!.map(TranslationRecord.fromMap).toList();
      setState(() {
        if (reset) _items.clear();
        _items.addAll(records);
        _done = records.length < 10;
      });
    } on PlatformException catch (error) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _failedReset = reset;
        _pageError = error.message ?? '无法读取翻译历史';
      });
    } finally {
      if (mounted && version == _requestVersion) {
        setState(() => _loading = false);
      }
    }
  }

  /// 无参数；回到最新记录并重新加载首批，返回刷新完成的 Future。
  Future<void> _refresh() async {
    // 列表与管理元数据分别显示失败，互不阻塞。
    await Future.wait([_loadMore(reset: true), _loadManagement()]);
  }

  /// prompt 为首次读取标记；读取来源与期限，必要时提示默认期限确认，返回读取结束的 Future。
  Future<void> _loadManagement({bool prompt = false}) async {
    try {
      // 来源与期限互不依赖，并发读取；任一失败按原异常进入下方的 PlatformException 处理。
      final results = await Future.wait<Object?>([
        widget.channel.invokeListMethod<String>(MethodNames.historySources),
        widget.channel.invokeMapMethod<String, Object?>(
          MethodNames.historyRetention,
        ),
      ]);
      final sources = results[0] as List<String>?;
      final retention = results[1] as Map<String, Object?>?;
      if (!mounted) return;
      setState(() {
        _sources = sources!;
        _retentionDays = retention!['days'] as int;
        _retentionConfirmed = retention['confirmed'] as bool;
        _managementError = null;
      });
      if (prompt && !_retentionConfirmed) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final context = _pageKey.currentContext;
          if (context != null && mounted) {
            _changeRetention(context, _retentionDays!);
          }
        });
      }
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() => _managementError = error.message ?? '无法读取历史管理设置');
      }
    }
  }

  /// context 为窗口内上下文，title/message 为确认说明；返回是否明确确认。
  Future<bool> _confirm(
    BuildContext context,
    String title,
    String message,
  ) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => NativeGlassDialog(
          maxWidth: 520,
          title: Text(title),
          content: SingleChildScrollView(child: Text(message)),
          actions: [
            NativeGlassSurface(
              material: true,
              child: TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
            ),
            NativeGlassSurface(
              material: true,
              child: TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('确认'),
              ),
            ),
          ],
        ),
      ) ??
      false;

  /// context 为弹窗上下文，days 为待选期限；预览清理数量并确认后提交，返回操作结束的 Future。
  Future<void> _changeRetention(BuildContext context, int days) async {
    setState(() => _managing = true);
    try {
      // 预览不修改设置或记录，取消后保持数据库原状。
      final preview = await widget.channel.invokeMapMethod<String, Object?>(
        MethodNames.historyRetention,
        {'days': days},
      );
      if (!context.mounted) return;
      final count = preview!['expiredCount'] as int;
      if (days != 0 &&
          !await _confirm(
            context,
            '设置历史保留期限',
            '保留最近 $days 天的翻译历史，将清理 $count 条记录。确认后持续自动清理。',
          )) {
        return;
      }
      await widget.channel.invokeMethod<void>(MethodNames.setHistoryRetention, {
        'days': days,
      });
      if (mounted) await _refresh();
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() => _managementError = error.message ?? '无法保存历史保留期限');
      }
    } finally {
      if (mounted) setState(() => _managing = false);
    }
  }

  /// context 为弹窗上下文；id 非空时删除单条，为空时清空全部翻译历史，返回操作结束的 Future。
  Future<void> _deleteHistory(BuildContext context, {int? id}) async {
    final confirmed = await _confirm(
      context,
      id == null ? '清空全部翻译历史' : '删除翻译记录',
      id == null ? '清空全部翻译历史，不受当前筛选范围限制。此操作无法撤销。' : '删除这条翻译记录？此操作无法撤销。',
    );
    if (!confirmed || !mounted) return;
    setState(() => _managing = true);
    try {
      await widget.channel.invokeMethod<void>(
        id == null ? MethodNames.clearHistory : MethodNames.deleteHistory,
        id == null ? null : {'id': id},
      );
      if (mounted) await _refresh();
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() => _managementError = error.message ?? '无法删除翻译历史');
      }
    } finally {
      if (mounted) setState(() => _managing = false);
    }
  }

  /// context 为日期控件上下文，start 指定起始或结束日期；选择后回到首批，返回选择结束的 Future。
  Future<void> _pickDate(BuildContext context, {required bool start}) async {
    final first = start ? DateTime(1970) : _from ?? DateTime(1970);
    final last = start ? _to ?? DateTime(2100) : DateTime(2100);
    final chosen = start ? _from : _to;
    final today = DateTime.now();
    final initial =
        chosen ??
        (today.isBefore(first)
            ? first
            : today.isAfter(last)
            ? last
            : today);
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
    );
    if (date == null || !mounted) return;
    setState(() {
      if (start) {
        _from = date;
      } else {
        _to = date;
      }
    });
    // 本地日期按日历的下一天生成排他上界，避免夏令时日长变化。
    await _loadMore(reset: true);
  }

  /// context 为窗口内上下文；返回按窗口宽度换行的筛选与管理控件。
  Widget _buildManagement(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      GlassMetrics.pagePadding,
      8,
      GlassMetrics.pagePadding,
      0,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 240,
              height: GlassMetrics.hitSize,
              child: NativeGlassSurface(
                material: true,
                child: TextField(
                  key: const ValueKey('history-search'),
                  controller: _search,
                  decoration: const InputDecoration(
                    hintText: '搜索原文或译文',
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 7,
                    ),
                  ),
                  onChanged: (_) => _loadMore(reset: true),
                ),
              ),
            ),
            SizedBox(
              width: 160,
              child: NativeGlassMenuButton<String>(
                value: _source,
                items: {
                  '': '全部来源',
                  for (final source in {
                    ..._sources,
                    if (_source.isNotEmpty) _source,
                  })
                    source: source,
                },
                onChanged: (source) {
                  setState(() => _source = source);
                  _loadMore(reset: true);
                },
              ),
            ),
            NativeGlassSurface(
              material: true,
              child: TextButton(
                onPressed: () => _pickDate(context, start: true),
                child: Text(
                  _from == null
                      ? '起始日期'
                      : '起始 ${dateText(_from!)}',
                ),
              ),
            ),
            NativeGlassSurface(
              material: true,
              child: TextButton(
                onPressed: () => _pickDate(context, start: false),
                child: Text(
                  _to == null
                      ? '结束日期'
                      : '结束 ${dateText(_to!)}',
                ),
              ),
            ),
            NativeGlassSurface(
              material: true,
              child: TextButton(
                onPressed: () {
                  setState(() {
                    _search.clear();
                    _source = '';
                    _from = null;
                    _to = null;
                  });
                  _loadMore(reset: true);
                },
                child: const Text('清除筛选'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('保留期限'),
            SizedBox(
              width: 140,
              child: NativeGlassMenuButton<int>(
                value: _retentionDays ?? 30,
                items: TranslationHistoryStore.retentionOptions,
                onChanged: _retentionDays == null || _managing
                    ? null
                    : (days) => _changeRetention(context, days),
              ),
            ),
            NativeGlassSurface(
              material: true,
              child: TextButton(
                onPressed: _managing ? null : () => _deleteHistory(context),
                child: const Text('清空全部'),
              ),
            ),
            if (!_retentionConfirmed)
              NativeGlassSurface(
                material: true,
                child: TextButton(
                  onPressed: _managing
                      ? null
                      : () => _changeRetention(context, _retentionDays!),
                  child: const Text('确认保留期限'),
                ),
              ),
          ],
        ),
        if (!_retentionConfirmed) const Text('保留期限尚未确认，现有记录不会自动清理。'),
        if (_managementError != null)
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(_managementError!),
              NativeGlassSurface(
                material: true,
                child: TextButton(
                  onPressed: _loadManagement,
                  child: const Text('重新读取管理设置'),
                ),
              ),
            ],
          ),
      ],
    ),
  );

  /// 无参数；解除通道回调并释放搜索输入，无返回值。
  @override
  void dispose() {
    widget.channel.setMethodCallHandler(null);
    _search.dispose();
    super.dispose();
  }

  /// 无参数；返回列表末尾的加载、重试、空列表或完成提示组件。
  Widget _buildFooter() {
    if (_loading) return const CircularProgressIndicator();
    if (_pageError != null) {
      return Column(
        children: [
          Text(_pageError!),
          NativeGlassSurface(
            material: true,
            child: TextButton(
              onPressed: () => _loadMore(reset: _failedReset),
              child: const Text('重试加载'),
            ),
          ),
        ],
      );
    }
    if (_items.isEmpty) return const Text('暂无翻译历史');
    if (_done) return const Text('已显示全部历史');
    // 窗口足够高而未产生滚动时，仍提供可访问的下一批入口。
    return NativeGlassSurface(
      material: true,
      child: TextButton(onPressed: _loadMore, child: const Text('加载更多')),
    );
  }

  /// context 为窗口上下文；返回来源/日期标题与译文优先的历史卡片。
  @override
  Widget build(BuildContext context) {
    return NativeGlassApp(
      home: Builder(key: _pageKey, builder: _buildPage),
    );
  }

  /// 内层context订阅当前主题，确保列表缓存的显式文本样式也随外观重建。
  Widget _buildPage(BuildContext context) {
    final theme = Theme.of(context);
    return NativeGlassWindowPage(
      child: Scaffold(
        appBar: AppBar(
          title: Text(switch (_section) {
            _HistorySection.history => '翻译历史',
            _HistorySection.vocabulary => '生词本',
            _HistorySection.screenshots => '截图历史',
          }),
          // 分段放在标题栏下方单独一行，窄窗口下不与刷新、记录开关争宽度。
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(GlassMetrics.hitSize + 8),
            child: Padding(
              padding: const EdgeInsets.only(
                left: GlassMetrics.pagePadding,
                bottom: 8,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: NativeGlassSegments<_HistorySection>(
                  value: _section,
                  options: const {
                    _HistorySection.history: '翻译历史',
                    _HistorySection.vocabulary: '生词本',
                    _HistorySection.screenshots: '截图历史',
                  },
                  navigation: true,
                  onChanged: (section) => setState(() => _section = section),
                ),
              ),
            ),
          ),
          actions: [
            if (_section == _HistorySection.history) ...[
              NativeGlassSurface(
                material: true,
                child: IconButton(
                  tooltip: '刷新历史',
                  onPressed: _loading ? null : _refresh,
                  icon: const Icon(Icons.refresh),
                ),
              ),
              const SizedBox(width: 12),
              const Text('记录历史'),
              const SizedBox(width: 8),
              NativeGlassSwitch(
                label: '记录翻译历史',
                value: _recording ?? false,
                onChanged: _recording == null || _savingRecording
                    ? null
                    : _setRecording,
              ),
              const SizedBox(width: 16),
            ],
          ],
        ),
        // 每个分段只渲染自己的内容；变更版本号共用同一计数。
        body: switch (_section) {
          _HistorySection.vocabulary => VocabularyPage(
            channel: widget.channel,
            version: _changeVersion,
          ),
          _HistorySection.screenshots => ScreenshotHistoryPage(
            channel: widget.channel,
            version: _changeVersion,
          ),
          _HistorySection.history => Column(
            children: [
              // 管理控件位于分段下方，保持正文独立滚动。
              _buildManagement(context),
              if (_recordingError != null)
                ListTile(
                  title: Text(_recordingError!),
                  trailing: NativeGlassSurface(
                    material: true,
                    child: TextButton(
                      onPressed: _loadRecording,
                      child: const Text('重新读取设置'),
                    ),
                  ),
                ),
              if (_recording == false)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('已暂停记录；已有历史仍保留。'),
                ),
              Expanded(
                child: NotificationListener<ScrollNotification>(
                  onNotification: (notification) {
                    // 只响应外层列表；错误后由用户显式重试，避免无限失败重试。
                    if (notification.depth == 0 &&
                        notification.metrics.extentAfter < 160 &&
                        _pageError == null) {
                      _loadMore();
                    }
                    return false;
                  },
                  child: ListView.builder(
                    padding: const EdgeInsets.all(GlassMetrics.pagePadding),
                    itemCount: _items.length + 1,
                    itemBuilder: (context, index) {
                      if (index == _items.length) {
                        // 列表末项承载分页反馈，不遮挡已有结果。
                        return Padding(
                          padding: const EdgeInsets.all(24),
                          child: Center(child: _buildFooter()),
                        );
                      }
                      final item = _items[index];
                      final timestamp = dateTimeText(
                        DateTime.fromMillisecondsSinceEpoch(item.completedAt),
                      );
                      return Card(
                        key: ValueKey('history-${item.id}'),
                        margin: const EdgeInsets.only(
                          bottom: GlassMetrics.groupGap,
                        ),
                        elevation: 0,
                        child: Padding(
                          padding: const EdgeInsets.all(
                            GlassMetrics.panelPadding,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Wrap(
                                alignment: WrapAlignment.spaceBetween,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                spacing: 16,
                                runSpacing: 8,
                                children: [
                                  Text(
                                    item.sourceLabel == null ||
                                            item.sourceLabel!.isEmpty
                                        ? TranslationHistoryStore.unknownSource
                                        : item.sourceLabel!,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium,
                                  ),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        timestamp,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall,
                                      ),
                                      const SizedBox(width: 8),
                                      NativeGlassSurface(
                                        material: true,
                                        child: IconButton(
                                          tooltip: '删除翻译记录',
                                          onPressed: _managing
                                              ? null
                                              : () => _deleteHistory(
                                                  context,
                                                  id: item.id,
                                                ),
                                          icon: const Icon(
                                            Icons.delete_outline,
                                            size: GlassMetrics.icon,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              const Divider(height: 28),
                              Text('译文', style: theme.textTheme.labelLarge),
                              const SizedBox(height: 8),
                              SelectableText(
                                item.translatedText,
                                style: theme.textTheme.bodyMedium,
                              ),
                              // 译文与原文独立阅读，分隔线不进入可复制正文。
                              const Divider(height: 21, thickness: 1),
                              Text('原文', style: theme.textTheme.labelLarge),
                              const SizedBox(height: 8),
                              SelectableText(
                                item.sourceText,
                                style: theme.textTheme.bodyMedium,
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        },
      ),
    );
  }
}
