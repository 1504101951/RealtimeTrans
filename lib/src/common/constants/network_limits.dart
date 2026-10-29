/// 网络请求的共用时限。
abstract final class NetworkLimits {
  /// 建立 HTTP 连接的时限；翻译服务使用（#124）。
  static const connectionTimeout = Duration(seconds: 10);

  /// Anthropic 开启思考时的 budget_tokens；须小于服务的最大输出 tokens。
  static const anthropicThinkingBudget = 2048;
}
