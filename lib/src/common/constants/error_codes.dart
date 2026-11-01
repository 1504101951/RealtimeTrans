/// Dart 按码分支的跨端错误码协议值；是 Swift AppConstants 错误码的子集，字面量一致，改名须两端同步。
abstract final class ErrorCodes {
  static const invalidSettings = 'invalid_settings';

  static const ocrEmpty = 'ocr_empty';

  static const settingsConflict = 'settings_conflict';

  static const staleCapture = 'stale_capture';

  static const testFailed = 'test_failed';

  static const translateFailed = 'translate_failed';

  /// Apple 系统翻译的语言对未下载语言包；变更须同步两端。
  static const translationNotInstalled = 'translation_not_installed';

  /// Apple 系统翻译不支持该语言对；变更须同步两端。
  static const translationUnsupported = 'translation_unsupported';
}
