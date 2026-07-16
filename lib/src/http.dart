import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'config.dart';
import 'errors.dart';
import 'transport.dart';
import 'utils.dart';

typedef DelayStrategy = Future<void> Function(Duration duration);

class VmodalHttp {
  VmodalHttp(this.config, this.transport, {DelayStrategy? delay})
    : _delay = delay ?? Future<void>.delayed;

  final SdkConfig config;
  final VmodalTransport transport;
  final DelayStrategy _delay;

  Map<String, String> headers({
    bool forceToken = false,
    bool requireUserId = true,
  }) {
    final out = <String, String>{};
    if (config.normalizedMode == 'direct') {
      final userId = config.normalizedUserId;
      if (requireUserId && userId.isEmpty) {
        throw const AuthException('user_id is required');
      }
      if (userId.isNotEmpty) {
        out['X-User-Id'] = strHeaderValue('user_id', userId);
      }
      if (config.normalizedTenantId.isNotEmpty) {
        out['X-Tenant-Id'] = strHeaderValue(
          'tenant_id',
          config.normalizedTenantId,
        );
      }
      if (config.normalizedEmail.isNotEmpty) {
        out['X-User-Email'] = strHeaderValue('email', config.normalizedEmail);
      }
    }
    if (forceToken || config.normalizedMode != 'direct') {
      final key = config.currentApiKey();
      if (key.isEmpty) throw const AuthException('API key is required');
      out['Authorization'] = 'Bearer $key';
    }
    _assertGatewayHeaders(out);
    return Map<String, String>.unmodifiable(out);
  }

  Future<Map<String, Object?>> request(
    String method,
    String path, {
    Object? json,
    Map<String, Object?> data = const <String, Object?>{},
    List<VmodalFilePart> files = const <VmodalFilePart>[],
    Map<String, Object?> params = const <String, Object?>{},
    CancellationToken? cancellation,
  }) => _requestJson(
    method,
    path,
    headers: headers(),
    json: json,
    data: data,
    files: files,
    params: params,
    cancellation: cancellation,
  );

  Future<Map<String, Object?>> requestUsers(
    String method,
    String path, {
    Object? json,
    Map<String, Object?> params = const <String, Object?>{},
    CancellationToken? cancellation,
  }) => _requestJson(
    method,
    path,
    headers: headers(forceToken: true, requireUserId: false),
    json: json,
    params: params,
    usersApi: true,
    cancellation: cancellation,
  );

  Future<Uint8List> requestBytes(
    String method,
    String path, {
    Object? json,
    Map<String, Object?> params = const <String, Object?>{},
    CancellationToken? cancellation,
  }) async {
    final token = cancellation ?? CancellationToken();
    final response = await _execute(
      method,
      path,
      headers: headers(),
      json: json,
      params: params,
      responseMode: VmodalResponseMode.bytes,
      cancellation: token,
    );
    return readBounded(response, binaryResponseLimitBytes, cancellation: token);
  }

  Future<Map<String, Object?>> _requestJson(
    String method,
    String path, {
    required Map<String, String> headers,
    Object? json,
    Map<String, Object?> data = const <String, Object?>{},
    List<VmodalFilePart> files = const <VmodalFilePart>[],
    Map<String, Object?> params = const <String, Object?>{},
    bool usersApi = false,
    CancellationToken? cancellation,
  }) async {
    final token = cancellation ?? CancellationToken();
    final response = await _execute(
      method,
      path,
      headers: headers,
      json: json,
      data: data,
      files: files,
      params: params,
      usersApi: usersApi,
      cancellation: token,
    );
    final bytes = await readBounded(
      response,
      jsonResponseLimitBytes,
      cancellation: token,
    );
    if (bytes.isEmpty) return <String, Object?>{};
    final value = jsonDecodeStrict(bytes);
    if (value is! Map) {
      throw const MalformedResponse('JSON object response required');
    }
    return objectMap(value);
  }

  Future<VmodalResponse> _execute(
    String method,
    String path, {
    required Map<String, String> headers,
    Object? json,
    Map<String, Object?> data = const <String, Object?>{},
    List<VmodalFilePart> files = const <VmodalFilePart>[],
    Map<String, Object?> params = const <String, Object?>{},
    bool usersApi = false,
    VmodalResponseMode responseMode = VmodalResponseMode.json,
    required CancellationToken cancellation,
  }) async {
    final normalized = method.toUpperCase();
    final canRetry = normalized == 'GET' || normalized == 'HEAD';
    final uri = _uri(path, params, usersApi: usersApi);
    final request = VmodalRequest(
      method: normalized,
      uri: uri,
      headers: headers,
      jsonBody: json,
      formFields: data,
      files: files,
      responseMode: responseMode,
      cancellation: cancellation,
    );
    for (var attempt = 0; attempt <= config.normalizedMaxRetries; attempt++) {
      cancellation.throwIfCanceled();
      try {
        final response = await transport.send(request);
        if (canRetry &&
            const <int>{500, 502, 503, 504}.contains(response.statusCode) &&
            attempt < config.normalizedMaxRetries) {
          await _discard(response, cancellation);
          await _delay(Duration(milliseconds: 50 * (attempt + 1)));
          continue;
        }
        if (response.statusCode < 200 || response.statusCode > 299) {
          await _raiseForStatus(response, cancellation);
        }
        return response;
      } on TransportException {
        if (!canRetry || attempt >= config.normalizedMaxRetries) rethrow;
        await _delay(Duration(milliseconds: 50 * (attempt + 1)));
      }
    }
    throw const TransportException();
  }

  Future<void> _raiseForStatus(
    VmodalResponse response,
    CancellationToken token,
  ) async {
    final bytes = await readBounded(
      response,
      errorResponseLimitBytes,
      cancellation: token,
    );
    Object? body;
    if (bytes.isNotEmpty) {
      final contentType = response.headers.entries
          .where(
            (MapEntry<String, String> item) =>
                item.key.toLowerCase() == 'content-type',
          )
          .map((MapEntry<String, String> item) => item.value)
          .join(';')
          .toLowerCase();
      final text = utf8.decode(bytes);
      if (contentType.contains('json') ||
          text.trimLeft().startsWith('{') ||
          text.trimLeft().startsWith('[')) {
        try {
          body = jsonDecode(text);
        } on Object {
          body = null;
        }
      } else {
        body = text;
      }
    }
    if (response.statusCode == 401) {
      throw AuthException(
        'authentication failed',
        statusCode: response.statusCode,
        body: body,
      );
    }
    if (response.statusCode == 422) {
      throw ValidationException(
        'validation failed',
        statusCode: response.statusCode,
        body: body,
        details: body is Map ? body['detail'] : body,
      );
    }
    throw ApiException(
      'api request failed',
      statusCode: response.statusCode,
      body: body,
    );
  }

  Future<void> _discard(
    VmodalResponse response,
    CancellationToken token,
  ) async {
    await readBounded(response, errorResponseLimitBytes, cancellation: token);
  }

  Uri _uri(String path, Map<String, Object?> params, {required bool usersApi}) {
    final base = usersApi
        ? strUsersBaseUrl(config.normalizedBaseUrl)
        : config.normalizedBaseUrl;
    final target = Uri.tryParse(path);
    final uri = target != null && target.hasScheme
        ? target
        : Uri.parse('$base${path.startsWith('/') ? path : '/$path'}');
    _requireSameOrigin(uri, Uri.parse(base));
    final query = <String, List<String>>{};
    uri.queryParametersAll.forEach((String key, List<String> values) {
      query[key] = List<String>.from(values);
    });
    params.forEach((String key, Object? value) {
      if (value == null) return;
      query[key] = value is Iterable
          ? value
                .where((Object? item) => item != null)
                .map((Object? item) => '$item')
                .toList()
          : <String>['$value'];
    });
    final pairs = <String>[];
    query.forEach((String key, List<String> values) {
      for (final value in values) {
        pairs.add(
          '${Uri.encodeQueryComponent(key)}=${Uri.encodeQueryComponent(value)}',
        );
      }
    });
    return uri.replace(query: pairs.isEmpty ? null : pairs.join('&'));
  }

  void _requireSameOrigin(Uri target, Uri base) {
    int port(Uri uri) => uri.hasPort
        ? uri.port
        : switch (uri.scheme) {
            'https' => 443,
            'http' => 80,
            _ => -1,
          };
    if (target.scheme != base.scheme ||
        target.host.toLowerCase() != base.host.toLowerCase() ||
        port(target) != port(base)) {
      throw const ValidationException(
        'absolute API URL must match the configured origin',
      );
    }
  }

  void _assertGatewayHeaders(Map<String, String> values) {
    if (config.normalizedMode != 'gateway') return;
    const forbidden = <String>{
      'x-user-id',
      'x-tenant-id',
      'x-user-email',
      'x-userid',
    };
    if (values.keys.any(
      (String key) => forbidden.contains(key.toLowerCase()),
    )) {
      throw const ValidationException(
        'gateway request contains forbidden identity headers',
      );
    }
  }
}
