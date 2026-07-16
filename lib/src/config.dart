import 'dart:convert';

import 'api_key_provider.dart';
import 'errors.dart';

const String publicGatewayUrlHash =
    'aHR0cHM6Ly9zZWFyY2hhcGktdGVzdC52LW1vZGFsLmNvbQ==';
final String publicGatewayUrl = utf8.decode(base64Decode(publicGatewayUrlHash));
const String devGatewayUrl = 'http://127.0.0.1:3099';

class SdkConfig {
  SdkConfig({
    String? baseUrl,
    this.userId = '',
    this.tenantId = '',
    this.email = '',
    this.token = '',
    this.timeout = const Duration(seconds: 30),
    this.mode = 'gateway',
    this.maxRetries = 1,
    this.apiKeyProvider,
  }) : baseUrl = baseUrl ?? publicGatewayUrl {
    if (timeout <= Duration.zero) {
      throw const ValidationException('timeout must be positive');
    }
    if (maxRetries < 0) {
      throw const ValidationException('max_retries must not be negative');
    }
    if (!const <String>{'gateway', 'direct'}.contains(normalizedMode)) {
      throw const ValidationException('mode must be gateway or direct');
    }
    _validateBase(normalizedBaseUrl);
  }

  final String baseUrl;
  final String userId;
  final String tenantId;
  final String email;
  final String token;
  final Duration timeout;
  final String mode;
  final int maxRetries;
  final ApiKeyProvider? apiKeyProvider;

  String get normalizedMode {
    final value = mode.trim().toLowerCase();
    return value.isEmpty ? 'gateway' : value;
  }

  String get normalizedBaseUrl => strGatewayBaseUrl(baseUrl, normalizedMode);
  String get normalizedUserId => userId.trim();
  String get normalizedTenantId => tenantId.trim();
  String get normalizedEmail => email.trim();
  int get normalizedMaxRetries => maxRetries;

  String currentApiKey() {
    final value = apiKeyProvider?.current() ?? token;
    return value.trim().isEmpty ? '' : strApiKey(value);
  }

  SdkConfig copyWith({
    String? baseUrl,
    String? userId,
    String? tenantId,
    String? email,
    String? token,
    Duration? timeout,
    String? mode,
    int? maxRetries,
    ApiKeyProvider? apiKeyProvider,
  }) => SdkConfig(
    baseUrl: baseUrl ?? this.baseUrl,
    userId: userId ?? this.userId,
    tenantId: tenantId ?? this.tenantId,
    email: email ?? this.email,
    token: token ?? this.token,
    timeout: timeout ?? this.timeout,
    mode: mode ?? this.mode,
    maxRetries: maxRetries ?? this.maxRetries,
    apiKeyProvider: apiKeyProvider ?? this.apiKeyProvider,
  );

  factory SdkConfig.fromEnvironment(
    Map<String, String> env, {
    String? baseUrl,
    String? userId,
    String? tenantId,
    String? email,
    String? token,
    Duration? timeout,
    String? mode,
    int? maxRetries,
    ApiKeyProvider? apiKeyProvider,
  }) {
    final envName = (env['VMODAL_ENV'] ?? 'prd').trim().toLowerCase();
    if (!const <String>{'dev', 'prd'}.contains(envName)) {
      throw const ValidationException('VMODAL_ENV must be dev or prd');
    }
    final fallback = envName == 'dev' ? devGatewayUrl : publicGatewayUrl;
    final rawBase =
        baseUrl ??
        _first(<String?>[
          env['VMODAL_BASE_URL'],
          env['TEST_CLIENT_SERVER_API_URL'],
          fallback,
        ]);
    final rawToken =
        token ??
        _first(<String?>[
          env['VMODAL_API_KEY'],
          env['VMODAL_API_TOKEN'],
          env['TEST_CLIENT_CLERK_USER_API_TOKEN'],
          env['TEST_CLIENT_USER_TOKEN'],
        ]);
    if (rawToken.isEmpty && apiKeyProvider == null) {
      throw const ValidationException('VMODAL_API_KEY is required');
    }
    final seconds = double.tryParse(env['VMODAL_TIMEOUT'] ?? '');
    return SdkConfig(
      baseUrl: rawBase,
      userId: userId ?? env['VMODAL_USER_ID'] ?? '',
      tenantId: tenantId ?? env['VMODAL_TENANT_ID'] ?? '',
      email: email ?? env['VMODAL_USER_EMAIL'] ?? '',
      token: rawToken,
      timeout:
          timeout ??
          (seconds == null
              ? const Duration(seconds: 30)
              : Duration(milliseconds: (seconds * 1000).round())),
      mode: mode ?? 'gateway',
      maxRetries:
          maxRetries ?? int.tryParse(env['VMODAL_MAX_RETRIES'] ?? '') ?? 1,
      apiKeyProvider: apiKeyProvider,
    );
  }

  @override
  String toString() =>
      'SdkConfig('
      'baseUrlConfigured=${baseUrl.isNotEmpty}, '
      'userIdConfigured=${userId.isNotEmpty}, '
      'tenantIdConfigured=${tenantId.isNotEmpty}, '
      'emailConfigured=${email.isNotEmpty}, '
      'tokenConfigured=${token.isNotEmpty}, '
      'timeoutMs=${timeout.inMilliseconds}, '
      'mode=$normalizedMode, '
      'maxRetries=$maxRetries, '
      'apiKeyProviderConfigured=${apiKeyProvider != null})';
}

String strGatewayBaseUrl(String baseUrl, [String mode = '']) {
  final base = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
  if (base.isEmpty || mode.trim().toLowerCase() != 'gateway') return base;
  const suffix = '/api/v1/proxy/search_api';
  return base.endsWith(suffix) ? base : '$base$suffix';
}

String strUsersBaseUrl(String baseUrl) {
  final base = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
  const suffix = '/api/v1/proxy/search_api';
  return base.endsWith(suffix)
      ? base.substring(0, base.length - suffix.length)
      : base;
}

String _first(List<String?> values) {
  for (final value in values) {
    if (value != null && value.trim().isNotEmpty) return value;
  }
  return '';
}

void _validateBase(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    throw const ValidationException('invalid HTTP URL');
  }
  if (uri.scheme != 'http' && uri.scheme != 'https') {
    throw const ValidationException('HTTP or HTTPS URL is required');
  }
  if (uri.userInfo.isNotEmpty) {
    throw const ValidationException('URL user information is not allowed');
  }
  if (uri.scheme == 'http' && !_loopback(uri.host)) {
    throw const ValidationException('HTTPS is required for non-local URLs');
  }
}

bool _loopback(String host) => const <String>{
  'localhost',
  '127.0.0.1',
  '::1',
  '0:0:0:0:0:0:0:1',
}.contains(host.toLowerCase());
