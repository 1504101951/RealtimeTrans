import '../common/constants/text_mode.dart';
import '../platform/settings_platform.dart';
import '../settings/app_settings.dart';
import '../settings/service_config.dart';
import 'providers/api_translation_provider.dart';
import 'providers/apple_translation_provider.dart';
import 'providers/unofficial_google_provider.dart';
import 'translation_types.dart';

/// settings为启动请求时的配置，platform提供凭据读取；返回默认服务，凭据在请求前读取。
/// 返回值同时支持单篇翻译和实时翻译使用的批量翻译。
BatchTranslationProvider providerForSettings(
  AppSettings settings,
  SettingsPlatform platform,
) => providerForService(settings, platform, settings.defaultServiceId);

/// settings 为发起时的配置，platform 提供凭据读取，serviceId 为谷歌翻译或已配置服务的 id；
/// 返回该服务的翻译 Provider，凭据在请求前读取（#100 卡片服务菜单与默认服务共用）。
BatchTranslationProvider providerForService(
  AppSettings settings,
  SettingsPlatform platform,
  String serviceId,
) {
  if (serviceId == ServiceConfig.builtinId) return UnofficialGoogleProvider();
  final config = settings.services.singleWhere(
    (service) => service.id == serviceId,
  );
  // 系统翻译在本机完成，不读取凭据。
  if (config.isSystem) return AppleTranslationProvider(config: config);
  // 术语表只交给配置型服务；其中只有模型服务把命中的术语写入请求。
  return ApiTranslationProvider(
    config: config,
    credentials: () => platform.readCredentials(serviceId),
    prompt: settings.prompts[TextMode.translate]!,
    thinking: settings.thinking[TextMode.translate]!,
    glossary: settings.glossary,
  );
}

/// settings 为发起时的配置，platform 提供凭据读取，mode 为润色、纠错或解释。
/// 返回使用默认服务与处理提示词的模型 Provider；默认服务不是模型服务时返回 null，由调用方提示。
TranslationProvider? assistProviderForSettings(
  AppSettings settings,
  SettingsPlatform platform,
  TextMode mode,
) => assistProviderForService(
  settings,
  platform,
  mode,
  settings.defaultServiceId,
);

/// settings/platform 同上，mode 为润色、纠错或解释，serviceId 为服务 id；
/// 返回使用该服务与该模式提示词、思考开关的模型 Provider；服务不是模型服务时返回 null（#100）。
TranslationProvider? assistProviderForService(
  AppSettings settings,
  SettingsPlatform platform,
  TextMode mode,
  String serviceId,
) {
  if (serviceId == ServiceConfig.builtinId) return null;
  final config = settings.services.singleWhere(
    (service) => service.id == serviceId,
  );
  if (!config.isModel) return null;
  return ApiTranslationProvider(
    config: config,
    credentials: () => platform.readCredentials(config.id),
    mode: mode,
    prompt: settings.prompts[mode]!,
    thinking: settings.thinking[mode]!,
  );
}

/// settings 为当前配置；返回谷歌翻译与全部已配置服务的菜单项，顺序与设置页一致。
List<ServiceChoice> serviceChoices(AppSettings settings) => [
  (
    id: ServiceConfig.builtinId,
    name: ServiceConfig.builtinName,
    isModel: false,
    isDefault: settings.defaultServiceId == ServiceConfig.builtinId,
  ),
  for (final service in settings.services)
    (
      id: service.id,
      name: service.displayName,
      isModel: service.isModel,
      isDefault: settings.defaultServiceId == service.id,
    ),
];

/// provider为请求实际使用的服务；返回可记录的模型名，非模型服务返回null。
String? translationHistoryModel(TranslationProvider provider) {
  if (provider is! ApiTranslationProvider || provider.config.model.isEmpty) {
    return null;
  }
  return provider.config.model;
}
