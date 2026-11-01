import 'package:flutter_test/flutter_test.dart';
import 'package:translate_app/src/common/utils/date_text.dart';

/// 无参数；验证历史与生词本共用的日期文本。
void main() {
  test('月、日、时、分不足两位时补零', () {
    // 作用：列表时间与导出文件名依赖固定宽度。边界：各字段取一位数最大值 9 与两位数 12。
    expect(dateText(DateTime(2026, 9, 9)), '2026-09-09');
    expect(dateTimeText(DateTime(2026, 12, 9, 9, 5)), '2026-12-09 09:05');
  });
}
