import 'dart:io';

import '../common/constants/network_limits.dart';

/// 翻译请求共用的 HTTP 客户端：同一服务的连续请求复用已建立的连接，省去重复的 TCP/TLS 握手。
/// 取消只中止对应的单次请求，不关闭本客户端；应用生命周期内保持存活。
final HttpClient translationHttpClient = HttpClient()
  ..connectionTimeout = NetworkLimits.connectionTimeout
  ..idleTimeout = NetworkLimits.idleTimeout;
