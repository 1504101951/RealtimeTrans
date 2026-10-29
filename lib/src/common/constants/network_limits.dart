/// 网络请求的共用时限。
abstract final class NetworkLimits {
  /// 建立 HTTP 连接的时限；翻译服务使用（#124）。
  static const connectionTimeout = Duration(seconds: 10);

  /// 共享翻译客户端保持空闲连接的时长；60 秒为经验值，用于连续翻译复用连接。
  /// 若出现复用的连接被服务端提前关闭导致的请求失败，需重新评估该时长。
  static const idleTimeout = Duration(seconds: 60);

  /// Anthropic 开启思考时的 budget_tokens；须小于服务的最大输出 tokens。
  static const anthropicThinkingBudget = 2048;
}
