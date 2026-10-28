import 'package:flutter/material.dart';

import '../common/constants/drawing_metrics.dart';
import '../common/constants/screenshot_enums.dart';
import '../common/widgets/native_glass.dart';
import 'drawing_style.dart';

/// 解析用户输入的6位不透明sRGB值；text允许#前缀，非法输入返回null。
Color? parseDrawingColor(String text) {
  final hex = text.trim().replaceFirst(RegExp(r'^#'), '');
  if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(hex)) return null;
  return Color(0xFF000000 | int.parse(hex, radix: 16));
}

/// 通用调色盘：纯色或双色渐变，所有带颜色的工具与美化背景共用（#103）。
/// initial 为当前颜色与渐变，onApply 返回确认的值，onCancel 关闭不改变；footer 为附加在操作按钮之上的内容
/// （美化背景放「阴影」与「无背景」）。不接触画布或历史。
class ColorPicker extends StatefulWidget {
  const ColorPicker({
    super.key,
    required this.initial,
    required this.onApply,
    required this.onCancel,
    this.footer,
  });
  final ColorFill initial;
  final ValueChanged<ColorFill> onApply;
  final VoidCallback onCancel;
  final Widget? footer;
  @override
  State<ColorPicker> createState() => _ColorPickerState();
}

/// 持有页签、起止两色、正在编辑的颜色与方向；色域、色相与 HEX 编辑当前选中的颜色。
class _ColorPickerState extends State<ColorPicker> {
  late bool _gradient = widget.initial.gradient != null;
  late HSVColor _start = HSVColor.fromColor(widget.initial.color);
  late HSVColor _end = HSVColor.fromColor(
    widget.initial.gradient?.end ?? DrawingMetrics.gradients.first.to,
  );
  late GradientDirection _direction =
      widget.initial.gradient?.direction ?? GradientDirection.downRight;

  /// 渐变页签中是否正在编辑结束色；纯色页签始终编辑起始色。
  bool _editingEnd = false;
  late final TextEditingController _hex = TextEditingController(
    text: _hexString(widget.initial.color),
  );
  bool _invalid = false;

  /// 无参数；返回色域、色相与 HEX 正在编辑的颜色。
  HSVColor get _hsv => _gradient && _editingEnd ? _end : _start;

  /// color为sRGB；返回6位大写HEX，不包含alpha。
  String _hexString(Color color) => (color.toARGB32() & 0xFFFFFF)
      .toRadixString(16)
      .padLeft(6, '0')
      .toUpperCase();

  /// value 为调色结果；写入正在编辑的颜色并同步 HEX 输入，返回空。
  void _setColor(HSVColor value) => setState(() {
    if (_gradient && _editingEnd) {
      _end = value;
    } else {
      _start = value;
    }
    _invalid = false;
    _hex.text = _hexString(value.toColor());
  });

  /// end 为是否改为编辑结束色；切换渐变页签中正在编辑的颜色并同步 HEX，返回空。
  void _selectWell(bool end) => setState(() {
    _editingEnd = end;
    _invalid = false;
    _hex.text = _hexString(_hsv.toColor());
  });

  /// point为色域内坐标；夹紧边缘并映射饱和度/亮度，返回空。
  void _pickField(Offset point) => _setColor(
    _hsv
        .withSaturation((point.dx / DrawingMetrics.fieldWidth).clamp(0, 1))
        .withValue((1 - point.dy / DrawingMetrics.fieldHeight).clamp(0, 1)),
  );

  /// 无参数；返回当前页签对应的调色盘值，纯色时不带渐变。
  ColorFill get _value => (
    color: _start.toColor(),
    gradient: _gradient
        ? FillGradient(end: _end.toColor(), direction: _direction)
        : null,
  );

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  /// color 为色块颜色，selected 为是否选中，key/label 为测试键与可访问名，onTap 为点击动作，
  /// gradient 为渐变色块的结束色；返回 24×24（或指定尺寸）的圆角色块。
  Widget _swatch({
    required Key key,
    required String label,
    required Color color,
    required bool selected,
    required VoidCallback onTap,
    Color? gradientEnd,
    double width = DrawingMetrics.swatch,
    double height = DrawingMetrics.swatch,
    double border = 1,
  }) => Semantics(
    button: true,
    selected: selected,
    label: label,
    child: InkWell(
      key: key,
      onTap: onTap,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: gradientEnd == null ? color : null,
          gradient: gradientEnd == null
              ? null
              : LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [color, gradientEnd],
                ),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Colors.grey,
            width: border,
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final (begin, end) = switch (_direction) {
      GradientDirection.right => (Alignment.centerLeft, Alignment.centerRight),
      GradientDirection.down => (Alignment.topCenter, Alignment.bottomCenter),
      GradientDirection.downRight => (Alignment.topLeft, Alignment.bottomRight),
      GradientDirection.upRight => (Alignment.bottomLeft, Alignment.topRight),
    };
    return SizedBox(
      width: DrawingMetrics.paletteWidth,
      child: Padding(
        padding: const EdgeInsets.all(DrawingMetrics.padding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '颜色',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                // 页签切换只改变编辑方式；纯色页签应用时不带渐变。
                NativeGlassSegments<bool>(
                  value: _gradient,
                  options: const {false: '纯色', true: '渐变'},
                  onChanged: (value) => setState(() {
                    _gradient = value;
                    _editingEnd = false;
                    _invalid = false;
                    _hex.text = _hexString(_start.toColor());
                  }),
                ),
              ],
            ),
            const SizedBox(height: DrawingMetrics.gap),
            if (_gradient) ...[
              Wrap(
                spacing: DrawingMetrics.gap,
                children: [
                  for (final (index, preset)
                      in DrawingMetrics.gradients.indexed)
                    _swatch(
                      key: Key('gradient-preset-$index'),
                      label: '渐变 ${preset.name}',
                      color: preset.from,
                      gradientEnd: preset.to,
                      selected:
                          _start.toColor() == preset.from &&
                          _end.toColor() == preset.to,
                      onTap: () => setState(() {
                        _start = HSVColor.fromColor(preset.from);
                        _end = HSVColor.fromColor(preset.to);
                        _direction = GradientDirection.downRight;
                        _hex.text = _hexString(_hsv.toColor());
                      }),
                    ),
                ],
              ),
              const SizedBox(height: DrawingMetrics.gap),
              Row(
                children: [
                  _swatch(
                    key: const Key('gradient-start'),
                    label: '起始色',
                    color: _start.toColor(),
                    selected: !_editingEnd,
                    onTap: () => _selectWell(false),
                    width: DrawingMetrics.wellWidth,
                    height: DrawingMetrics.wellHeight,
                    border: _editingEnd ? 1 : DrawingMetrics.wellSelectedBorder,
                  ),
                  const SizedBox(width: DrawingMetrics.gap),
                  _swatch(
                    key: const Key('gradient-end'),
                    label: '结束色',
                    color: _end.toColor(),
                    selected: _editingEnd,
                    onTap: () => _selectWell(true),
                    width: DrawingMetrics.wellWidth,
                    height: DrawingMetrics.wellHeight,
                    border: _editingEnd ? DrawingMetrics.wellSelectedBorder : 1,
                  ),
                ],
              ),
              const SizedBox(height: DrawingMetrics.gap),
            ],
            Semantics(
              label: '饱和度与亮度',
              child: GestureDetector(
                key: const Key('color-field'),
                onTapDown: (e) => _pickField(e.localPosition),
                onPanStart: (e) => _pickField(e.localPosition),
                onPanUpdate: (e) => _pickField(e.localPosition),
                child: SizedBox(
                  height: DrawingMetrics.fieldHeight,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                Colors.white,
                                HSVColor.fromAHSV(1, _hsv.hue, 1, 1).toColor(),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Colors.transparent, Colors.black],
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: (_hsv.saturation * DrawingMetrics.fieldWidth - 4)
                            .clamp(0, DrawingMetrics.fieldWidth - 8),
                        top: ((1 - _hsv.value) * DrawingMetrics.fieldHeight - 4)
                            .clamp(0, DrawingMetrics.fieldHeight - 8),
                        child: Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 1),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: DrawingMetrics.gap),
            SizedBox(
              height: DrawingMetrics.hueHeight,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2,
                  overlayShape: SliderComponentShape.noOverlay,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                ),
                child: Slider(
                  key: const Key('color-hue'),
                  min: 0,
                  max: 360,
                  value: _hsv.hue,
                  semanticFormatterCallback: (v) => '色相 ${v.round()}度',
                  onChanged: (v) => _setColor(_hsv.withHue(v)),
                ),
              ),
            ),
            const SizedBox(height: DrawingMetrics.gap),
            if (!_gradient)
              Wrap(
                spacing: DrawingMetrics.gap,
                children: [
                  for (final color in DrawingMetrics.colors)
                    _swatch(
                      key: Key('palette-${_hexString(color)}'),
                      label: '颜色 ${_hexString(color)}',
                      color: color,
                      selected: color == _start.toColor(),
                      onTap: () => _setColor(HSVColor.fromColor(color)),
                    ),
                ],
              )
            else ...[
              // 方向按钮：→ ↓ ↘ ↗，选中为系统蓝底白图标。
              Row(
                children: [
                  for (final (direction, icon, label) in const [
                    (GradientDirection.right, Icons.arrow_forward, '向右'),
                    (GradientDirection.down, Icons.arrow_downward, '向下'),
                    (GradientDirection.downRight, Icons.south_east, '向右下'),
                    (GradientDirection.upRight, Icons.north_east, '向右上'),
                  ]) ...[
                    SizedBox.square(
                      dimension: DrawingMetrics.directionButton,
                      child: IconButton(
                        key: Key('gradient-direction-${direction.name}'),
                        tooltip: '渐变$label',
                        padding: EdgeInsets.zero,
                        iconSize: 16,
                        onPressed: () => setState(() => _direction = direction),
                        icon: Icon(icon),
                        style: IconButton.styleFrom(
                          backgroundColor: _direction == direction
                              ? NativeGlassTheme.selectionBlue
                              : Colors.transparent,
                          foregroundColor: _direction == direction
                              ? Colors.white
                              : null,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                ],
              ),
              const SizedBox(height: DrawingMetrics.gap),
              Container(
                key: const Key('gradient-preview'),
                height: DrawingMetrics.previewHeight,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  gradient: LinearGradient(
                    begin: begin,
                    end: end,
                    colors: [_start.toColor(), _end.toColor()],
                  ),
                ),
              ),
            ],
            const SizedBox(height: DrawingMetrics.gap),
            SizedBox(
              height: 32,
              child: TextField(
                key: const Key('color-hex'),
                controller: _hex,
                decoration: const InputDecoration(
                  prefixText: '#',
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                ),
                onChanged: (text) {
                  final color = parseDrawingColor(text);
                  setState(() {
                    _invalid = color == null;
                    if (color == null) return;
                    if (_gradient && _editingEnd) {
                      _end = HSVColor.fromColor(color);
                    } else {
                      _start = HSVColor.fromColor(color);
                    }
                  });
                },
              ),
            ),
            if (_invalid)
              const Text('请输入6位十六进制颜色', style: TextStyle(color: Colors.red)),
            ?widget.footer,
            const SizedBox(height: DrawingMetrics.gap),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: widget.onCancel, child: const Text('取消')),
                const SizedBox(width: DrawingMetrics.gap),
                TextButton(
                  key: const Key('apply-color'),
                  onPressed: _invalid ? null : () => widget.onApply(_value),
                  child: const Text('应用'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 独立线宽选择器；initial是逻辑pt，onApply返回已确认值，取消不改变外部状态。
class StrokeWidthPicker extends StatefulWidget {
  const StrokeWidthPicker({
    super.key,
    required this.initial,
    required this.onApply,
    required this.onCancel,
  });
  final double initial;
  final ValueChanged<double> onApply;
  final VoidCallback onCancel;
  @override
  State<StrokeWidthPicker> createState() => _StrokeWidthPickerState();
}

class _StrokeWidthPickerState extends State<StrokeWidthPicker> {
  late double _value = widget.initial.roundToDouble().clamp(
    DrawingMetrics.minWidth,
    DrawingMetrics.maxWidth,
  );
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(DrawingMetrics.padding),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 200,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2,
                  overlayShape: SliderComponentShape.noOverlay,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                ),
                child: Slider(
                  key: const Key('stroke-width-slider'),
                  min: DrawingMetrics.minWidth,
                  max: DrawingMetrics.maxWidth,
                  divisions: 19,
                  value: _value,
                  semanticFormatterCallback: (v) => '${v.round()}pt',
                  onChanged: (v) => setState(() => _value = v),
                ),
              ),
            ),
            SizedBox(width: 40, child: Text('${_value.round()}pt')),
          ],
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(onPressed: widget.onCancel, child: const Text('取消')),
            const SizedBox(width: DrawingMetrics.gap),
            TextButton(
              key: const Key('apply-stroke-width'),
              onPressed: () => widget.onApply(_value),
              child: const Text('应用'),
            ),
          ],
        ),
      ],
    ),
  );
}
