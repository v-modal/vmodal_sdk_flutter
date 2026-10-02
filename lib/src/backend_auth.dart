import 'dart:async';
import 'dart:convert';

import 'api_key_provider.dart';
import 'config.dart';
import 'errors.dart';
import 'http.dart';
import 'transport.dart';
import 'upload.dart';
import 'user_session.dart';

/// Observable VModal connection lifecycle; host login remains host-owned.
enum BackendConnectionState {
  ready,
  refreshing,
  unavailable,
  expired,
  invalidated,
  closed,
}

/// Immutable exact resource grant returned by the VModal issuer.
final class ScopedGrant {
  ScopedGrant._(
    this.grantId,
    this.collectionId,
    this.streamName,
    this.mode,
    Set<UserAction> actions,
    this.collectionWide,
  ) : actions = Set<UserAction>.unmodifiable(actions);

  factory ScopedGrant.fromJson(Map<String, Object?> json) {
    _fields(json, const {
      'grant_id',
      'collection_id',
      'stream_name',
      'mode',
      'actions',
      'collection_wide',
    });
    final values = json['actions'];
    if (values is! List || values.isEmpty) _invalid();
    final actions = <UserAction>{};
    for (final value in values) {
      if (value is! String) _invalid();
      final matches = UserAction.values.where((a) => a.name == value);
      if (matches.isEmpty || !actions.add(matches.single)) _invalid();
    }
    if (json['collection_wide'] is! bool) _invalid();
    return ScopedGrant._(
      _identifier(json, 'grant_id', 128),
      _selector(json, 'collection_id'),
      _selector(json, 'stream_name'),
      _selector(json, 'mode'),
      actions,
      json['collection_wide']! as bool,
    );
  }

  final String grantId, collectionId, streamName, mode;
  final Set<UserAction> actions;
  final bool collectionWide;
  ContentMapping get mapping => ContentMapping.opaque(
    collectionId: collectionId,
    streamName: streamName,
    mode: mode,
    actions: actions,
    collectionWide: collectionWide,
  );

  Map<String, Object?> toJson() => {
    'grant_id': grantId,
    'collection_id': collectionId,
    'stream_name': streamName,
    'mode': mode,
    'actions': actions.map((a) => a.name).toList()..sort(),
    'collection_wide': collectionWide,
  };

  @override
  String toString() => 'ScopedGrant(actions=${actions.length})';
}

/// Strict version-1 server envelope. The bearer stays in memory.
final class ScopedTokenEnvelope {
  ScopedTokenEnvelope._({
    required this.accessToken,
    required this.expiresIn,
    required this.issuedAt,
    required this.expiresAt,
    required this.principalId,
    required this.tenantId,
    required this.projectId,
    required this.appUserId,
    required this.policyRevision,
    required this.delegationRevision,
    required List<ScopedGrant> grants,
  }) : grants = List<ScopedGrant>.unmodifiable(grants);

  factory ScopedTokenEnvelope.fromJson(Map<String, Object?> json) {
    _fields(json, const {
      'version',
      'auth_mode',
      'access_token',
      'token_type',
      'expires_in',
      'issued_at',
      'expires_at',
      'principal_id',
      'tenant_id',
      'project_id',
      'app_user_id',
      'policy_revision',
      'delegation_revision',
      'grants',
    });
    if (json['version'] is! int ||
        json['version'] != 1 ||
        json['auth_mode'] != 'developer_backend' ||
        json['token_type'] != 'Bearer') {
      _invalid();
    }
    final lifetime = json['expires_in'];
    final revision = json['delegation_revision'];
    if (lifetime is! int ||
        lifetime < 60 ||
        lifetime > 900 ||
        revision is! int ||
        revision < 1) {
      _invalid();
    }
    final issued = _time(json, 'issued_at');
    final expires = _time(json, 'expires_at');
    if (expires.difference(issued) != Duration(seconds: lifetime)) _invalid();
    final token = json['access_token'];
    if (token is! String || token.trim() != token) _invalid();
    strApiKey(token);
    if (!RegExp(
      r'^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$',
    ).hasMatch(token)) {
      _invalid();
    }
    return ScopedTokenEnvelope._(
      accessToken: token,
      expiresIn: lifetime,
      issuedAt: issued,
      expiresAt: expires,
      principalId: _identifier(json, 'principal_id', 256),
      tenantId: _identifier(json, 'tenant_id', 256),
      projectId: _identifier(json, 'project_id', 256),
      appUserId: _identifier(json, 'app_user_id', 256),
      policyRevision: _identifier(json, 'policy_revision', 128),
      delegationRevision: revision,
      grants: _grants(json['grants']),
    );
  }

  int get version => 1;
  String get authMode => 'developer_backend';
  String get tokenType => 'Bearer';
  final String accessToken,
      principalId,
      tenantId,
      projectId,
      appUserId,
      policyRevision;
  final int expiresIn, delegationRevision;
  final DateTime issuedAt, expiresAt;
  final List<ScopedGrant> grants;

  String get _binding =>
      jsonEncode([principalId, tenantId, projectId, appUserId]);
  String get _policy =>
      jsonEncode([policyRevision, delegationRevision, _grantPolicy(grants)]);
  @override
  String toString() =>
      'ScopedTokenEnvelope(version=1, grants=${grants.length}, [REDACTED])';
}

/// Thin owner of a guarded user session and its scoped credential lifecycle.
final class BackendConnection {
  BackendConnection._(this._source, this._manager);
  final _ScopedCredentialSource _source;
  final UserSessionManager _manager;
  Future<void>? _closing;

  UserSession get session {
    _source._check();
    final value = _manager.current;
    if (value == null) throw const SessionInvalidated();
    return value;
  }

  BackendConnectionState get state {
    if (_source.state == BackendConnectionState.ready &&
        _source._envelope != null &&
        !_source.clock().isBefore(_source._envelope!.expiresAt)) {
      _source._emit(BackendConnectionState.expired);
    }
    return _source.state;
  }

  Stream<BackendConnectionState> get states => _source.states.stream;
  UserScope scope(String grantId) {
    final active = session;
    final grants = _source.envelope.grants.where((g) => g.grantId == grantId);
    if (grants.isEmpty) throw const ValidationException('Unknown grant ID');
    return active.scope(grants.single.mapping);
  }

  Future<void> refresh() => _source.refresh();
  Future<void> close() {
    if (_closing != null) return _closing!;
    final done = Completer<void>();
    _closing = done.future;
    // Retire guards before publishing closed to reentrant stream listeners.
    final cleanup = _manager.close();
    _source.close();
    unawaited(cleanup.then(done.complete, onError: done.completeError));
    return done.future;
  }

  /// @nodoc
  static Future<BackendConnection> connect({
    required String expectedAppUserId,
    required String expectedProjectId,
    required Future<ScopedTokenEnvelope> Function() loadToken,
    Uri? baseUri,
    Duration timeout = const Duration(seconds: 30),
    int maxRetries = 1,
    Duration refreshLeeway = const Duration(seconds: 60),
    ScopedTokenEnvelope? initialToken,
    DateTime Function()? clock,
    DelayStrategy? delay,
    VmodalTransport Function(SdkConfig)? transportFactory,
    SignedUploadTransport Function(SdkConfig)? signedUploadTransportFactory,
  }) async {
    if (expectedAppUserId.isEmpty ||
        expectedProjectId.isEmpty ||
        refreshLeeway.isNegative) {
      _invalid();
    }
    final config = SdkConfig(
      baseUrl: baseUri?.toString(),
      timeout: timeout,
      maxRetries: maxRetries,
    );
    final source = _ScopedCredentialSource(
      config,
      expectedAppUserId,
      expectedProjectId,
      loadToken,
      refreshLeeway,
      clock ?? DateTime.now,
      delay ?? Future<void>.delayed,
      transportFactory ?? HttpVmodalTransport.new,
    );
    UserSessionManager? manager;
    try {
      await source.refresh(initialToken: initialToken);
      manager = UserSessionManager(
        config: config,
        credentialSource: source,
        transportFactory: transportFactory,
        signedUploadTransportFactory: signedUploadTransportFactory,
      );
      source.onInvalidated = () {
        unawaited(manager!.logout());
      };
      final envelope = source.envelope;
      await manager.openUserSession(
        tenantId: envelope.tenantId,
        appUserId: envelope.appUserId,
        allowedContentMapping: envelope.grants.map((g) => g.mapping),
        policyRevision: envelope.policyRevision,
      );
      return BackendConnection._(source, manager);
    } on Object {
      source.close();
      await manager?.close();
      rethrow;
    }
  }
}

class _ScopedCredentialSource implements SessionCredentialSource {
  _ScopedCredentialSource(
    this.config,
    this.expectedAppUserId,
    this.expectedProjectId,
    this.loadToken,
    this.leeway,
    this.clock,
    this.delay,
    this.transportFactory,
  );
  final SdkConfig config;
  final String expectedAppUserId, expectedProjectId;
  final Future<ScopedTokenEnvelope> Function() loadToken;
  final Duration leeway;
  final DateTime Function() clock;
  final DelayStrategy delay;
  final VmodalTransport Function(SdkConfig) transportFactory;
  final states = StreamController<BackendConnectionState>.broadcast();
  BackendConnectionState state = BackendConnectionState.refreshing;
  ScopedTokenEnvelope? _envelope;
  ScopedTokenEnvelope get envelope {
    _check();
    return _envelope!;
  }

  int revision = 0, _generation = 0;
  int? _rejectedRevision;
  final Map<int, DateTime> _expiries = {};
  final Set<int> _rejections = {};
  Future<void>? _pending;
  final CancellationToken _lifetime = CancellationToken();
  void Function()? onInvalidated;
  final Set<_ScopedProvider> _providers = {};
  @override
  String get serviceNamespace => SessionContext.serviceNamespaceFor(config);
  @override
  String get tenantId => envelope.tenantId;
  @override
  String get expectedPrincipal => envelope.principalId;
  @override
  String? get projectId => expectedProjectId;
  bool get usable =>
      _envelope != null &&
      clock().isBefore(_envelope!.expiresAt) &&
      _rejectedRevision != revision;

  void _check() {
    if (state == BackendConnectionState.closed ||
        state == BackendConnectionState.invalidated) {
      throw const SessionInvalidated();
    }
  }

  void _emit(BackendConnectionState next) {
    if (state == next) return;
    state = next;
    states.add(next);
  }

  void _invalidate() {
    ++_generation;
    _lifetime.cancel();
    state = BackendConnectionState.invalidated;
    onInvalidated?.call();
    if (state == BackendConnectionState.invalidated && !states.isClosed) {
      states.add(BackendConnectionState.invalidated);
    }
  }

  @override
  MutableApiKeyProvider createProvider({required bool Function() isActive}) {
    _check();
    final provider = _ScopedProvider(this, isActive);
    _providers.add(provider);
    return provider;
  }

  Future<void> ensureReady() async {
    _check();
    if (!usable) {
      if (_envelope != null && !clock().isBefore(_envelope!.expiresAt)) {
        _emit(BackendConnectionState.expired);
      }
      await refresh();
      _check();
      if (!usable) {
        throw const BackendAuthException(BackendAuthFailure.unavailable);
      }
      return;
    }
    final effective = Duration(
      microseconds: leeway.inMicroseconds < envelope.expiresIn * 500000
          ? leeway.inMicroseconds
          : envelope.expiresIn * 500000,
    );
    if (!clock().add(effective).isBefore(envelope.expiresAt)) {
      unawaited(refresh().catchError((Object _) {}));
    }
  }

  void reject(int failedRevision) {
    _check();
    _rejections.add(failedRevision);
    if (failedRevision == revision) _rejectedRevision = revision;
  }

  Future<void> recover(int failedRevision) async {
    _check();
    if (failedRevision < revision && usable) return;
    reject(failedRevision);
    await refresh();
  }

  Future<void> refresh({ScopedTokenEnvelope? initialToken}) {
    _check();
    if (_pending != null) return _pending!;
    final generation = _generation;
    _emit(BackendConnectionState.refreshing);
    final done = Completer<void>();
    final future = done.future;
    _pending = future;
    final probeCancellation = CancellationToken();
    final removeCancel = _lifetime.onCancel(probeCancellation.cancel);
    unawaited(
      _acquire(generation, initialToken, probeCancellation)
          .timeout(
            config.timeout,
            onTimeout: () {
              probeCancellation.cancel();
              throw const BackendAuthException(BackendAuthFailure.unavailable);
            },
          )
          .then((candidate) {
            _check();
            if (generation != _generation) throw const SessionInvalidated();
            if (!clock().isBefore(candidate.expiresAt)) {
              throw const BackendAuthException(
                BackendAuthFailure.invalidResponse,
              );
            }
            _envelope = candidate;
            revision++;
            _expiries[revision] = candidate.expiresAt;
            _expiries.removeWhere((_, expiry) => !clock().isBefore(expiry));
            _rejections.removeWhere(
              (revision) => !_expiries.containsKey(revision),
            );
            _rejectedRevision = null;
            _emit(BackendConnectionState.ready);
          })
          .then(
            (_) => done.complete(),
            onError: (Object error, StackTrace stack) {
              if (state == BackendConnectionState.closed ||
                  state == BackendConnectionState.invalidated) {
                done.completeError(const SessionInvalidated(), stack);
              } else if (error is OperationCanceled ||
                  error is BackendAuthException &&
                      error.failure != BackendAuthFailure.unavailable ||
                  error is ValidationException) {
                _invalidate();
                done.completeError(error, stack);
              } else {
                _emit(BackendConnectionState.unavailable);
                done.completeError(
                  const BackendAuthException(BackendAuthFailure.unavailable),
                  stack,
                );
              }
            },
          )
          .whenComplete(() {
            removeCancel();
            if (identical(_pending, future)) _pending = null;
          }),
    );
    return future;
  }

  Future<T> _live<T>(Future<T> work, CancellationToken cancellation) async {
    cancellation.throwIfCanceled();
    final result = await Future.any<T>([
      work,
      cancellation.whenCanceled.then<T>((_) => throw const OperationCanceled()),
    ]);
    cancellation.throwIfCanceled();
    _check();
    return result;
  }

  Future<ScopedTokenEnvelope> _acquire(
    int generation,
    ScopedTokenEnvelope? seed,
    CancellationToken cancellation,
  ) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final candidate =
            seed ??
            await _live<ScopedTokenEnvelope>(
              Future<ScopedTokenEnvelope>.sync(loadToken),
              cancellation,
            );
        _check();
        cancellation.throwIfCanceled();
        if (generation != _generation) throw const SessionInvalidated();
        if (candidate.appUserId != expectedAppUserId ||
            candidate.projectId != expectedProjectId ||
            !clock().isBefore(candidate.expiresAt) ||
            candidate.issuedAt.isAfter(
              clock().add(const Duration(seconds: 30)),
            )) {
          throw const BackendAuthException(BackendAuthFailure.invalidResponse);
        }
        if (_envelope != null &&
            (candidate._binding != envelope._binding ||
                candidate._policy != envelope._policy)) {
          throw const BackendAuthException(BackendAuthFailure.invalidResponse);
        }
        await _live(_verify(candidate, cancellation), cancellation);
        if (!clock().isBefore(candidate.expiresAt)) {
          throw const BackendAuthException(BackendAuthFailure.invalidResponse);
        }
        return candidate;
      } on Object catch (error) {
        cancellation.throwIfCanceled();
        _check();
        if (error is OperationCanceled) rethrow;
        if (error is ValidationException ||
            error is BackendAuthException &&
                error.failure != BackendAuthFailure.unavailable) {
          rethrow;
        }
        if ((error is AuthException && error is! BackendAuthException) ||
            error is ApiException && error.statusCode == 403) {
          throw const BackendAuthException(BackendAuthFailure.invalidResponse);
        }
        if (attempt == 2 || seed != null) rethrow;
        var wait = Duration(milliseconds: attempt == 0 ? 250 : 1000);
        if (error is BackendAuthException && error.retryAfter != null) {
          final retry = error.retryAfter!;
          if (retry > wait) {
            wait = retry > config.timeout ? config.timeout : retry;
          }
        }
        await _live(delay(wait), cancellation);
      }
    }
    throw const BackendAuthException(BackendAuthFailure.unavailable);
  }

  Future<void> _verify(
    ScopedTokenEnvelope candidate,
    CancellationToken cancellation,
  ) async {
    final probeConfig = config.copyWith(
      token: candidate.accessToken,
      maxRetries: 0,
    );
    final transport = transportFactory(probeConfig);
    Future<void>? closing;
    Future<void> closeProbe() => closing ??= Future<void>.sync(transport.close);
    final removeCancel = cancellation.onCancel(() {
      unawaited(closeProbe().catchError((Object _) {}));
    });
    try {
      final json = await VmodalHttp(
        probeConfig,
        transport,
      ).requestUsers('GET', '/api/v1/auth/me', cancellation: cancellation);
      if (json['auth_mode'] != 'developer_backend' ||
          json['type'] != 'scoped_user' ||
          _time(json, 'expires_at') != candidate.expiresAt ||
          json['user_id'] != candidate.principalId ||
          json['principal_id'] != candidate.principalId ||
          json['tenant_id'] != candidate.tenantId ||
          json['project_id'] != candidate.projectId ||
          json['app_user_id'] != candidate.appUserId ||
          json['policy_revision'] != candidate.policyRevision ||
          json['delegation_revision'] is! int ||
          json['delegation_revision'] != candidate.delegationRevision ||
          _grantPolicy(_grants(json['grants'])) !=
              _grantPolicy(candidate.grants)) {
        throw const BackendAuthException(BackendAuthFailure.invalidResponse);
      }
    } finally {
      removeCancel();
      await closeProbe();
    }
  }

  void close() {
    if (state == BackendConnectionState.closed) return;
    ++_generation;
    _lifetime.cancel();
    _emit(BackendConnectionState.closed);
    for (final provider in _providers.toList()) {
      provider.close();
    }
    _envelope = null;
    unawaited(states.close());
  }
}

class _ScopedProvider extends MutableApiKeyProvider
    implements AsyncCredentialProvider {
  _ScopedProvider(this.source, this.isActive)
    : super(source.envelope.accessToken);
  final _ScopedCredentialSource source;
  final bool Function() isActive;
  void _check() {
    if (isClosed || !isActive()) throw const SessionInvalidated();
    source._check();
  }

  @override
  int get revision {
    _check();
    return source.revision;
  }

  @override
  String current() {
    _check();
    if (!source.usable) {
      throw const BackendAuthException(BackendAuthFailure.unavailable);
    }
    return source.envelope.accessToken;
  }

  @override
  Future<void> ensureReady() async {
    _check();
    await source.ensureReady();
    _check();
  }

  @override
  bool isRevisionUsable(int revision) {
    _check();
    final expiry = source._expiries[revision];
    return expiry != null &&
        source.clock().isBefore(expiry) &&
        !source._rejections.contains(revision);
  }

  @override
  void reject(int revision) {
    _check();
    source.reject(revision);
  }

  @override
  Future<void> recover(int failedRevision) async {
    _check();
    await source.recover(failedRevision);
    _check();
  }

  @override
  void rotate(String newKey) =>
      throw const AuthException('Scoped credentials require backend renewal');
  @override
  void close() {
    source._providers.remove(this);
    super.close();
  }
}

Never _invalid() =>
    throw const ValidationException('Invalid scoped token contract');
void _fields(Map<String, Object?> json, Set<String> fields) {
  if (json.length != fields.length || !json.keys.every(fields.contains)) {
    _invalid();
  }
}

String _identifier(Map<String, Object?> json, String key, int limit) {
  final value = json[key];
  if (value is! String ||
      value.trim().isEmpty ||
      utf8.encode(value).length > limit ||
      value.runes.any((n) => n < 32 || (n >= 127 && n <= 159))) {
    _invalid();
  }
  return value;
}

String _selector(Map<String, Object?> json, String key) {
  final value = _identifier(json, key, 80);
  if (!RegExp(r'^[a-zA-Z0-9_]{1,80}$').hasMatch(value)) _invalid();
  return value;
}

DateTime _time(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String ||
      !RegExp(
        r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$',
      ).hasMatch(value)) {
    _invalid();
  }
  final time = DateTime.tryParse(value);
  if (time == null ||
      time.toIso8601String().substring(0, 19) != value.substring(0, 19)) {
    _invalid();
  }
  return time;
}

List<ScopedGrant> _grants(Object? raw) {
  if (raw is! List || raw.isEmpty || raw.length > 16) _invalid();
  final ids = <String>{}, selectors = <String>{};
  return raw.map((value) {
    if (value is! Map<String, Object?>) _invalid();
    final grant = ScopedGrant.fromJson(value);
    if (!ids.add(grant.grantId) ||
        !selectors.add(
          jsonEncode([grant.collectionId, grant.streamName, grant.mode]),
        )) {
      _invalid();
    }
    return grant;
  }).toList();
}

String _grantPolicy(List<ScopedGrant> grants) {
  final values = grants.map((g) => jsonEncode(g.toJson())).toList()..sort();
  return jsonEncode(values);
}
