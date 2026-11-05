# lib/src/platform目录索引

Dart 与原生层（macOS Swift、Windows C++）之间的平台端口、通道适配器与事件协议。

1. [channel_platform_bridge.dart](channel_platform_bridge.dart)：两平台共用的通道适配器，实现全部平台端口。
2. [index.md](index.md)：索引本目录直接子文件和子目录的用途。
3. [platform_event.dart](platform_event.dart)：解析原生发送的选区和生命周期事件。
4. [platform_ports.dart](platform_ports.dart)：按能力定义主引擎依赖的平台端口。
5. [settings_platform.dart](settings_platform.dart)：定义设置模块使用的系统事务与凭据存储接口。
