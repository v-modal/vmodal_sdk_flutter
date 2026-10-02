import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

/// Host HTTP adapters pass only safe status/Retry-After data into SDK errors.
ScopedTokenEnvelope parseBackendResponse(
  int status,
  Map<String, Object?>? json, {
  Duration? retryAfter,
}) {
  if (status == 401) {
    throw const BackendAuthException(BackendAuthFailure.identityRejected);
  }
  if (status == 403) {
    throw const BackendAuthException(BackendAuthFailure.accessDenied);
  }
  if (status == 502 && json?['code'] == 'issuer_contract_rejected') {
    throw const BackendAuthException(BackendAuthFailure.invalidResponse);
  }
  if (status == 429 || status >= 500) {
    throw BackendAuthException(
      BackendAuthFailure.unavailable,
      retryAfter: retryAfter,
    );
  }
  if (status != 200 || json == null) {
    throw const BackendAuthException(BackendAuthFailure.invalidResponse);
  }
  return ScopedTokenEnvelope.fromJson(json);
}

/// One owner at the host account lifetime; feature pages retain only UserScope.
/// The host clears widgets/players/caches when initiating a transition.
final class BackendSessionOwner {
  BackendConnection? _connection;
  int _generation = 0;

  BackendConnection? get current => _connection;

  Future<BackendConnection> activate({
    required String appUserId,
    required String projectId,
    required Future<ScopedTokenEnvelope> Function() loadToken,
    Uri? baseUri,
  }) async {
    final ticket = ++_generation;
    final old = _connection;
    _connection = null;
    await old?.close();
    if (ticket != _generation) throw const SessionInvalidated();
    final next = await VModal.connectWithBackend(
      expectedAppUserId: appUserId,
      expectedProjectId: projectId,
      baseUri: baseUri,
      loadToken: () async {
        if (ticket != _generation) throw const SessionInvalidated();
        final token = await loadToken();
        if (ticket != _generation) throw const SessionInvalidated();
        return token;
      },
    );
    if (ticket != _generation) {
      await next.close();
      throw const SessionInvalidated();
    }
    _connection = next;
    return next;
  }

  Future<void> close() {
    _generation++;
    final old = _connection;
    _connection = null;
    return old?.close() ?? Future<void>.value();
  }
}
