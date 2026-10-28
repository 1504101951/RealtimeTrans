import '../common/constants/drawing_metrics.dart';

/// 「我的贴纸」中的一张：id 即文件名，width/height 为默认大小（pt），按原图比例（#103）。
class StickerEntry {
  /// id、width、height 含义见类说明。
  const StickerEntry({
    required this.id,
    required this.width,
    required this.height,
  });
  final String id;
  final double width;
  final double height;

  /// map 为偏好中的贴纸字典；返回贴纸，字段缺失由类型转换抛错。
  factory StickerEntry.fromMap(Map<Object?, Object?> map) => StickerEntry(
    id: map['id'] as String,
    width: (map['width'] as num).toDouble(),
    height: (map['height'] as num).toDouble(),
  );

  /// 无参数；返回可写入偏好的字典。
  Map<String, Object> toMap() => {'id': id, 'width': width, 'height': height};

  /// 无参数；校验 id 非空、宽高为正且长边不超过上限，非法时抛 FormatException。
  void validate() {
    if (id.isEmpty ||
        width <= 0 ||
        height <= 0 ||
        (width > height ? width : height) > StickerMetrics.maxDefaultSize) {
      throw const FormatException('贴纸默认大小无效。');
    }
  }
}

/// width/height 为原图像素尺寸；返回初始默认大小（pt）：长边取原图长边与上限的较小值，保持原比例。
(double, double) initialStickerSize(int width, int height) {
  final long = (width > height ? width : height).toDouble();
  final scale = long > StickerMetrics.maxDefaultSize
      ? StickerMetrics.maxDefaultSize / long
      : 1.0;
  return (width * scale, height * scale);
}
