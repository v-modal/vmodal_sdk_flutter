import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'api_key_provider.dart';
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
  final Expando<TenantCredentialSnapshot> _credentialSnapshots =
      Expando<TenantCredentialSnapshot>();
  final Expando<int> _scopedRevisions = Expando<int>();

  Future<T> _withReady<T>(
    Future<T> Function(Map<String, String>) work, {
    bool usersApi = false,
  }) {
    final provider = config.apiKeyProvider;
    Map<String, String> capture() =>
        headers(forceToken: usersApi, requireUserId: !usersApi);
    if (provider is AsyncCredentialProvider) {
      return provider.ensureReady().then((_) => work(capture()));
    }
    return work(capture());
  }

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
    TenantCredentialSnapshot? snapshot;
    if (forceToken || config.normalizedMode != 'direct') {
      final provider = config.apiKeyProvider;
      if (provider is TenantSessionApiKeyProvider) {
        snapshot = provider.snapshot();
      }
      final key = snapshot?.apiKey ?? config.currentApiKey();
      if (key.isEmpty) throw const AuthException('API key is required');
      out['Authorization'] = 'Bearer $key';
    }
    _assertGatewayHeaders(out);
    final frozen = Map<String, String>.unmodifiable(out);
    if (snapshot != null) _credentialSnapshots[frozen] = snapshot;
    final provider = config.apiKeyProvider;
    if (provider is AsyncCredentialProvider) {
      _scopedRevisions[frozen] = provider.revision;
    }
    return frozen;
  }

  Future<Map<String, Object?>> request(
    String method,
    String path, {
    Object? json,
    Map<String, Object?> data = const <String, Object?>{},
    List<VmodalFilePart> files = const <VmodalFilePart>[],
    Map<String, Object?> params = const <String, Object?>{},
    CancellationToken? cancellation,
  }) => _withReady(
    (captured) => _requestJson(
      method,
      path,
      headers: captured,
      json: json,
      data: data,
      files: files,
      params: params,
      cancellation: cancellation,
    ),
  );

  Future<Map<String, Object?>> requestUsers(
    String method,
    String path, {
    Object? json,
    Map<String, Object?> params = const <String, Object?>{},
    CancellationToken? cancellation,
  }) => _withReady(
    (captured) => _requestJson(
      method,
      path,
      headers: captured,
      json: json,
      params: params,
      usersApi: true,
      cancellation: cancellation,
    ),
    usersApi: true,
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
    return _withReady(
      (captured) => _executeRead<Uint8List>(
        method,
        path,
        headers: captured,
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
    await _withReady(
      (captured) => _executeRead<void>(
        method,
        path,
        headers: captured,
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
    final provider = config.apiKeyProvider;
    final tenantProvider = provider is TenantSessionApiKeyProvider
        ? provider
        : null;
    final scopedProvider = provider is AsyncCredentialProvider
        ? provider
        : null;
    var requestHeaders = headers;
    var snapshot = _credentialSnapshots[requestHeaders];
    var scopedRevision = _scopedRevisions[requestHeaders];
    var recovered = false;
    var retries = 0;
    final retryBudget =
        config.normalizedMaxRetries +
        (canRetry && (tenantProvider != null || scopedProvider != null)
            ? 1
            : 0);
    for (var attempt = 0; attempt <= retryBudget; attempt++) {
      cancellation.throwIfCanceled();
      final attemptCancellation = CancellationToken();
      final removeCancel = cancellation.onCancel(attemptCancellation.cancel);
      try {
        if (scopedProvider != null &&
            scopedRevision != null &&
            !scopedProvider.isRevisionUsable(scopedRevision)) {
          if (recovered || (!canRetry && attempt > 0)) {
            throw const AuthException('scoped credential expired');
          }
          recovered = true;
          await scopedProvider.recover(scopedRevision);
          cancellation.throwIfCanceled();
          requestHeaders = this.headers(
            forceToken: usersApi,
            requireUserId: !usersApi,
          );
          scopedRevision = _scopedRevisions[requestHeaders];
        }
        final request = VmodalRequest(
          method: normalized,
          uri: uri,
          headers: requestHeaders,
          jsonBody: json,
          formFields: data,
          files: files,
          responseMode: responseMode,
          cancellation: attemptCancellation,
        );
        // Retain this request's headers, but never dispatch after authoritative
        // revocation or after its session lease has expired.
        tenantProvider?.snapshot();
        final response = await transport.send(request);
        if (scopedProvider != null && response.statusCode == 401) {
          await _discard(response, attemptCancellation);
          cancellation.throwIfCanceled();
          scopedProvider.reject(scopedRevision!);
          if (!canRetry || recovered || attempt >= retryBudget) {
            throw const AuthException('scoped request authentication failed');
          }
          recovered = true;
          await scopedProvider.recover(scopedRevision);
          cancellation.throwIfCanceled();
          requestHeaders = this.headers(
            forceToken: usersApi,
            requireUserId: !usersApi,
          );
          scopedRevision = _scopedRevisions[requestHeaders];
          continue;
        }
        if (tenantProvider != null && response.statusCode == 401) {
          await _discard(response, attemptCancellation);
          cancellation.throwIfCanceled();
          if (!canRetry ||
              recovered ||
              attempt >= retryBudget ||
              snapshot == null) {
            throw const TenantAuthException();
          }
          recovered = true;
          await tenantProvider.recover(snapshot.revision);
          cancellation.throwIfCanceled();
          requestHeaders = this.headers(
            forceToken: usersApi,
            requireUserId: !usersApi,
          );
          snapshot = _credentialSnapshots[requestHeaders];
          continue;
        }
        if (tenantProvider != null && response.statusCode == 403) {
          await _discard(response, attemptCancellation);
          throw const ApiException('tenant request denied', statusCode: 403);
        }
        if (canRetry &&
            const <int>{500, 502, 503, 504}.contains(response.statusCode) &&
            retries < config.normalizedMaxRetries &&
            attempt < retryBudget) {
          retries++;
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
      } on OperationCanceled catch (error) {
        if (cancellation.isCanceled || error is SessionInvalidated) rethrow;
        if (!canRetry ||
            retries >= config.normalizedMaxRetries ||
            attempt >= retryBudget) {
          throw const TransportException();
        }
        retries++;
        await _delay(Duration(milliseconds: 50 * (attempt + 1)));
      } on TransportException {
        if (cancellation.isCanceled) throw const OperationCanceled();
        if (!canRetry ||
            retries >= config.normalizedMaxRetries ||
            attempt >= retryBudget) {
          rethrow;
        }
        retries++;
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
