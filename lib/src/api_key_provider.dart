import 'dart:async';
import 'dart:convert';

import 'errors.dart';

/// Supplies the API key used immediately before each SDK request.
///
/// Implementations should return only an in-memory credential and throw
/// [AuthException] when it is unavailable.
abstract interface class ApiKeyProvider {
  /// Returns the current validated credential.
  String current();
}

/// In-memory credential provider supporting rotation and explicit clearing.
///
/// [close] permanently disables the provider. Values are redacted from
/// [toString] and are never persisted by this class.
class MutableApiKeyProvider implements ApiKeyProvider {
  /// Creates a provider after validating [initialKey].
  MutableApiKeyProvider(String initialKey) : _key = strApiKey(initialKey);

  String? _key;
  bool _closed = false;

  /// Whether this provider has been permanently disabled.
  bool get isClosed => _closed;

  /// Replaces the active key, or throws [AuthException] after [close].
  void rotate(String newKey) {
    final valid = strApiKey(newKey);
    if (_closed) throw const AuthException('API key is unavailable');
    _key = valid;
  }

  /// Removes the current key without permanently closing the provider.
  void clear() {
    _key = null;
  }

  /// Clears the key and permanently disables [current] and [rotate].
  void close() {
    _closed = true;
    clear();
  }

  @override
  String current() {
    final value = _key;
    if (_closed || value == null) {
      throw const AuthException('API key is unavailable');
    }
    return value;
  }

  @override
  String toString() => 'MutableApiKeyProvider([REDACTED])';
}

/// A credential returned by the host's trusted tenant issuer/resolver.
/// The resolver must verify these binding fields; they are not app-user claims.
class TenantCredential {
  TenantCredential({
    required this.serviceNamespace,
    required this.tenantId,
    required this.principal,
    required String apiKey,
    this.issuerVersion,
  }) : apiKey = strApiKey(apiKey);

  final String serviceNamespace;
  final String tenantId;
  final String principal;
  final String apiKey;
  final int? issuerVersion;

  @override
  String toString() => 'TenantCredential([REDACTED])';
}

/// Immutable accepted tenant credential, captured before request construction.
class TenantCredentialSnapshot {
  TenantCredentialSnapshot._(this.credential, this.binding, this.revision);

  final TenantCredential credential;
  final String binding;
  final int revision;
  String get apiKey => credential.apiKey;

  @override
  String toString() => 'TenantCredentialSnapshot(revision=$revision)';
}

/// Shared tenant renewal coordinator, independent of app-user lifetimes.
///
/// One normal renewal is shared by all providers. A superseding renewal or
/// external install fences older results using both ticket and base revision.
/// No key is persisted, and failures block calls unless the host explicitly
/// permits retaining the previous credential under its validity policy.
class TenantCredentialSource {
  TenantCredentialSource({
    required this.serviceNamespace,
    required this.tenantId,
    required this.expectedPrincipal,
    required String initialKey,
    this.renew,
    int? initialIssuerVersion,
    this.retainOnRenewalFailure = false,
  }) {
    if (<String>[
      serviceNamespace,
      tenantId,
      expectedPrincipal,
    ].any((String value) => value.trim().isEmpty)) {
      throw const ValidationException('tenant credential binding is required');
    }
    _snapshot = TenantCredentialSnapshot._(
      TenantCredential(
        serviceNamespace: serviceNamespace,
        tenantId: tenantId,
        principal: expectedPrincipal,
        apiKey: initialKey,
        issuerVersion: initialIssuerVersion,
      ),
      binding,
      0,
    );
  }

  final String serviceNamespace;
  final String tenantId;
  final String expectedPrincipal;
  final Future<TenantCredential> Function()? renew;
  final bool retainOnRenewalFailure;
  late TenantCredentialSnapshot _snapshot;
  final Set<TenantSessionApiKeyProvider> _providers =
      <TenantSessionApiKeyProvider>{};
  Future<TenantCredentialSnapshot>? _pending;
  int _ticket = 0;
  bool _valid = true;
  bool _closed = false;

  String get binding =>
      jsonEncode(<String>[serviceNamespace, tenantId, expectedPrincipal]);
  int get revision => _snapshot.revision;
  bool get isAvailable => !_closed && _valid;

  TenantCredentialSnapshot get currentSnapshot {
    if (!isAvailable) throw const TenantAuthException();
    return _snapshot;
  }

  /// Attaches and reads the latest committed revision without an await gap.
  TenantSessionApiKeyProvider createProvider({
    required bool Function() isActive,
  }) {
    if (!isActive()) throw const OperationCanceled();
    final provider = TenantSessionApiKeyProvider._(
      this,
      currentSnapshot,
      isActive,
    );
    _providers.add(provider);
    provider.current();
    return provider;
  }

  /// Installs a trusted replacement. Binding changes require a new source.
  void install(TenantCredential candidate) {
    if (_closed) throw const TenantAuthException();
    _validate(candidate);
    ++_ticket;
    _pending = null;
    _commit(candidate);
  }

  /// Coalesces normal renewals; [supersede] deliberately fences earlier ones.
  Future<TenantCredentialSnapshot> renewCredential({bool supersede = false}) {
    if (_closed) {
      return Future<TenantCredentialSnapshot>.error(
        const TenantAuthException(),
      );
    }
    if (!supersede && _pending != null) return _pending!;
    final resolver = renew;
    if (resolver == null) {
      return Future<TenantCredentialSnapshot>.error(
        const TenantAuthException(),
      );
    }
    final ticket = ++_ticket;
    final base = revision;
    final completer = Completer<TenantCredentialSnapshot>();
    final future = completer.future;
    _pending = future;
    unawaited(
      Future<TenantCredential>.sync(resolver)
          .then((TenantCredential candidate) {
            if (ticket == _ticket && base == revision && !_closed) {
              _validate(candidate);
              _commit(candidate);
            }
            return currentSnapshot;
          })
          .then(
            completer.complete,
            onError: (Object error, StackTrace stack) {
              if (ticket == _ticket && base == revision && !_closed) {
                if (!retainOnRenewalFailure) _valid = false;
                completer.completeError(const TenantAuthException(), stack);
              } else if (isAvailable) {
                completer.complete(currentSnapshot);
              } else {
                completer.completeError(const TenantAuthException(), stack);
              }
            },
          )
          .whenComplete(() {
            if (identical(_pending, future)) _pending = null;
          }),
    );
    return future;
  }

  /// A stale request cannot revoke a newer accepted credential.
  Future<TenantCredentialSnapshot> recover(int failedRevision) {
    if (isAvailable && failedRevision < revision) {
      return Future<TenantCredentialSnapshot>.value(currentSnapshot);
    }
    return renewCredential();
  }

  /// Authoritative revocation, unlike an unverified request's 401 response.
  void revoke() {
    ++_ticket;
    _pending = null;
    _valid = false;
    for (final provider in _providers) {
      provider.clear();
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    revoke();
    for (final provider in _providers.toList()) {
      provider.close();
    }
  }

  void _validate(TenantCredential candidate) {
    if (candidate.serviceNamespace != serviceNamespace ||
        candidate.tenantId != tenantId ||
        candidate.principal != expectedPrincipal) {
      throw const TenantAuthException('tenant credential binding changed');
    }
    final currentVersion = _snapshot.credential.issuerVersion;
    final nextVersion = candidate.issuerVersion;
    if (currentVersion != null &&
        (nextVersion == null ||
            nextVersion < currentVersion ||
            (nextVersion == currentVersion &&
                candidate.apiKey != _snapshot.apiKey))) {
      throw const TenantAuthException('tenant credential version is stale');
    }
  }

  void _commit(TenantCredential candidate) {
    _snapshot = TenantCredentialSnapshot._(candidate, binding, revision + 1);
    _valid = true;
    for (final provider in _providers.toList()) {
      provider._install(_snapshot);
    }
  }

  @override
  String toString() => 'TenantCredentialSource(revision=$revision)';
}

/// A private session provider subscribed to one shared tenant binding.
class TenantSessionApiKeyProvider extends MutableApiKeyProvider {
  TenantSessionApiKeyProvider._(
    this._source,
    TenantCredentialSnapshot snapshot,
    this._isActive,
  ) : _revision = snapshot.revision,
      super(snapshot.apiKey);

  final TenantCredentialSource _source;
  final bool Function() _isActive;
  int _revision;
  int get installedRevision => _revision;
  String get binding => _source.binding;

  TenantCredentialSnapshot snapshot() {
    if (isClosed || !_isActive()) throw const SessionInvalidated();
    final value = _source.currentSnapshot;
    _install(value);
    return value;
  }

  @override
  String current() => snapshot().apiKey;

  Future<void> recover(int failedRevision) async {
    snapshot();
    await _source.recover(failedRevision);
    snapshot();
  }

  void _install(TenantCredentialSnapshot value) {
    if (isClosed ||
        !_isActive() ||
        value.binding != binding ||
        value.revision <= _revision) {
      return;
    }
    super.rotate(value.apiKey);
    _revision = value.revision;
  }

  @override
  void rotate(String newKey) => throw const TenantAuthException(
    'install tenant credentials through the credential source',
  );

  @override
  void close() {
    _source._providers.remove(this);
    super.close();
  }
}

/// @nodoc
String strApiKey(String value) {
  final key = value.trim();
  if (key.isEmpty) throw const ValidationException('API key must not be blank');
  if (key.length > 8192) {
    throw const ValidationException('API key is too long');
  }
  if (key.runes.any((int value) => value < 32 || value == 127)) {
    throw const ValidationException('API key contains invalid characters');
  }
  return key;
}
