import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'config.dart';
import 'errors.dart';
import 'transport.dart';
import 'utils.dart';

typedef DelayStrategy = Future<void> Function(Duration duration);
typedef ResponseReader<T> =
    Future<T> Function(VmodalResponse response, CancellationToken cancellation);

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
    int? maxBytes,
    CancellationToken? cancellation,
  }) async {
    final limit = _binaryLimit(maxBytes);
    final token = cancellation ?? CancellationToken();
    return _executeRead<Uint8List>(
      method,
      path,
      headers: headers(),
      json: json,
      params: params,
      responseMode: VmodalResponseMode.bytes,
      cancellation: token,
      reader: (VmodalResponse response, CancellationToken attempt) =>
          readBounded(
            response,
            limit,
            cancellation: attempt,
            idleTimeout: config.idleTimeout,
          ),
    );
  }

  Future<void> requestBytesToSink(
    String method,
    String path, {
    required IOSink sink,
    Object? json,
    Map<String, Object?> params = const <String, Object?>{},
    int? maxBytes,
    CancellationToken? cancellation,
  }) async {
    final limit = _binaryLimit(maxBytes);
    final token = cancellation ?? CancellationToken();
    await _executeRead<void>(
      method,
      path,
      headers: headers(),
      json: json,
      params: params,
      responseMode: VmodalResponseMode.bytes,
      cancellation: token,
      reader: (VmodalResponse response, CancellationToken attempt) =>
          writeBounded(
            response,
            sink,
            limit,
            cancellation: attempt,
            idleTimeout: config.idleTimeout,
          ),
    );
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
    return _executeRead<Map<String, Object?>>(
      method,
      path,
      headers: headers,
      json: json,
      data: data,
      files: files,
      params: params,
      usersApi: usersApi,
      cancellation: token,
      reader: (VmodalResponse response, CancellationToken attempt) =>
          readJsonObjectBounded(
            response,
            jsonResponseLimitBytes,
            cancellation: attempt,
            idleTimeout: config.idleTimeout,
          ),
    );
  }

  Future<T> _executeRead<T>(
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
    required ResponseReader<T> reader,
  }) async {
    final normalized = method.toUpperCase();
    final canRetry = normalized == 'GET' || normalized == 'HEAD';
    final uri = _uri(path, params, usersApi: usersApi);
    for (var attempt = 0; attempt <= config.normalizedMaxRetries; attempt++) {
      cancellation.throwIfCanceled();
      final attemptCancellation = CancellationToken();
      final removeCancel = cancellation.onCancel(attemptCancellation.cancel);
      try {
        final request = VmodalRequest(
          method: normalized,
          uri: uri,
          headers: headers,
          jsonBody: json,
          formFields: data,
          files: files,
          responseMode: responseMode,
          cancellation: attemptCancellation,
        );
        final response = await transport.send(request);
        if (canRetry &&
            const <int>{500, 502, 503, 504}.contains(response.statusCode) &&
            attempt < config.normalizedMaxRetries) {
          await _discard(response, attemptCancellation);
          await _delay(Duration(milliseconds: 50 * (attempt + 1)));
          continue;
        }
        if (response.statusCode < 200 || response.statusCode > 299) {
          await _raiseForStatus(response, attemptCancellation);
        }
        final value = await reader(response, attemptCancellation);
        cancellation.throwIfCanceled();
        return value;
      } on OperationCanceled {
        if (cancellation.isCanceled) rethrow;
        if (!canRetry || attempt >= config.normalizedMaxRetries) {
          throw const TransportException();
        }
        await _delay(Duration(milliseconds: 50 * (attempt + 1)));
      } on TransportException {
        if (cancellation.isCanceled) throw const OperationCanceled();
        if (!canRetry || attempt >= config.normalizedMaxRetries) rethrow;
        await _delay(Duration(milliseconds: 50 * (attempt + 1)));
      } finally {
        removeCancel();
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
      idleTimeout: config.idleTimeout,
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
          body = objRedactServerDetails(jsonDecode(text));
        } on Object {
          body = null;
        }
      } else {
        body = strRedactServerPaths(text);
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
    await readBounded(
      response,
      errorResponseLimitBytes,
      cancellation: token,
      idleTimeout: config.idleTimeout,
    );
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

  int _binaryLimit(int? maxBytes) {
    if (maxBytes == null) return binaryResponseLimitBytes;
    if (maxBytes <= 0 || maxBytes > binaryResponseLimitBytes) {
      throw const ValidationException(
        'max_bytes must be positive and no larger than the SDK binary limit',
      );
    }
    return maxBytes;
  }
}
