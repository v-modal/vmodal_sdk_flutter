import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

import '../data/archive_controller.dart';
import '../data/search_gateway.dart';
import 'auth_adapter.dart';
import 'vmodal_credential.dart';

enum SessionState {
  loading,
  signedOut,
  resolving,
  ready,
  recoverable,
  denied,
  error,
}

enum SessionFailureKind {
  transient,
  firebaseIdentityExpired,
  credentialDenied,
  vmodalUnauthorized,
  vmodalForbidden,
  contract,
}

typedef GatewayFactory =
    SearchGateway Function(
      MutableApiKeyProvider provider,
      String scopeId,
      Future<void> Function() ensureFresh,
    );

class UserSessionController extends ChangeNotifier {
  UserSessionController({
    required this.auth,
    required this.credentials,
    required this.archive,
    GatewayFactory? gatewayFactory,
    DateTime Function()? clock,
    Future<void> Function(Duration)? delay,
  }) : gatewayFactory =
           gatewayFactory ??
           ((provider, id, fresh) =>
               SearchGateway(provider, id, ensureFresh: fresh)),
       clock = clock ?? DateTime.now,
       delay = delay ?? Future<void>.delayed {
    _subscription = auth.users.listen(_onUser);
  }

  static const _transientMessage =
      'Connection interrupted. Retry to reconnect your library.';
  static const _identityMessage = 'Your sign-in expired. Sign in again.';
  static const _deniedMessage = 'Access to this library is unavailable.';
  static const _unauthorizedMessage =
      'Your library session expired. Sign in again.';
  static const _contractMessage =
      'The library connection is not configured correctly.';
  static const _backoff = [
    Duration(milliseconds: 250),
    Duration(milliseconds: 500),
  ];

  final FirebaseAuthAdapter auth;
  final VmodalCredentialSource credentials;
  final ArchiveController archive;
  final GatewayFactory gatewayFactory;
  final DateTime Function() clock;
  final Future<void> Function(Duration) delay;
  late final StreamSubscription<AppUser?> _subscription;
  SessionState state = SessionState.loading;
  SessionFailureKind? failureKind;
  AppUser? user;
  VmodalCredential? _credential;
  MutableApiKeyProvider? _provider;
  SearchGateway? gateway;
  Timer? _timer;
  Future<void>? _refreshing;
  String message = '';
  bool signingIn = false;
  int _generation = 0;
  bool _disposed = false;

  bool get canRetry => failureKind == SessionFailureKind.transient;
  bool get canRead =>
      state == SessionState.ready &&
      (_credential?.permissions.contains('library:read') ?? false);
  bool get canWrite =>
      state == SessionState.ready &&
      (_credential?.permissions.contains('library:write') ?? false);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _teardown() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    archive.deactivate();
    _provider?.clear();
    _refreshing = null;
    final old = gateway;
    gateway = null;
    _provider = null;
    _credential = null;
    if (old != null) unawaited(old.close());
  }

  void _onUser(AppUser? next) {
    if (_disposed) return;
    if (next?.uid == user?.uid && state != SessionState.loading) return;
    _teardown();
    user = next;
    failureKind = null;
    message = '';
    state = next == null ? SessionState.signedOut : SessionState.resolving;
    _notify();
    if (next != null) unawaited(_resolve(next, _generation));
  }

  bool _current(AppUser account, int generation) =>
      !_disposed && generation == _generation && user?.uid == account.uid;

  Future<VmodalCredential> _acquire(
    AppUser account,
    int generation, {
    VmodalCredential? previous,
  }) async {
    Object? failure;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (!_current(account, generation)) {
        throw failure ?? const CredentialDenied();
      }
      try {
        final firebaseToken = await auth.idToken(account);
        if (!_current(account, generation)) {
          throw const CredentialDenied();
        }
        final credential = await credentials.acquire(account, firebaseToken);
        if (!_current(account, generation)) {
          throw const CredentialDenied();
        }
        credential.validate(account, clock(), previous: previous);
        return credential;
      } on FirebaseIdentityTransient catch (error) {
        failure = error;
      } on CredentialTransient catch (error) {
        failure = error;
      }
      if (attempt == 2) throw failure;
      if (!_current(account, generation)) throw failure;
      await delay(_backoff[attempt]);
      if (!_current(account, generation)) throw failure;
    }
    throw failure!;
  }

  Future<void> _resolve(AppUser account, int generation) async {
    SearchGateway? next;
    try {
      final credential = await _acquire(account, generation);
      if (!_current(account, generation)) return;
      final provider = MutableApiKeyProvider(credential.apiToken!);
      _provider = provider;
      _credential = credential;
      next = gatewayFactory(provider, credential.scopeId!, ensureFresh);
      next.onAccessFailure = (status) {
        if (_current(account, generation)) {
          if (status == 403) {
            _fail(
              SessionState.denied,
              SessionFailureKind.vmodalForbidden,
              _deniedMessage,
            );
          } else {
            _fail(
              SessionState.error,
              SessionFailureKind.vmodalUnauthorized,
              _unauthorizedMessage,
            );
          }
        }
      };
      await next.connect(credential.vmodalUserId!);
      if (!_current(account, generation)) {
        await next.close();
        return;
      }
      gateway = next;
      await archive.activate(
        credential.scopeId!,
        next,
        canRead: credential.permissions.contains('library:read'),
        canWrite: credential.permissions.contains('library:write'),
      );
      if (!_current(account, generation)) return;
      state = SessionState.ready;
      failureKind = null;
      message = '';
      _schedule();
      _notify();
    } on FirebaseIdentityTransient {
      if (_current(account, generation)) _recover();
      if (next != null && next != gateway) await next.close();
    } on CredentialTransient {
      if (_current(account, generation)) _recover();
      if (next != null && next != gateway) await next.close();
    } on Object catch (error) {
      if (_current(account, generation)) _failFor(error);
      if (next != null && next != gateway) await next.close();
    }
  }

  void _recover() {
    state = SessionState.recoverable;
    failureKind = SessionFailureKind.transient;
    message = _transientMessage;
    _notify();
  }

  void _failFor(Object error) {
    if (error is FirebaseIdentityExpired) {
      _fail(
        SessionState.error,
        SessionFailureKind.firebaseIdentityExpired,
        _identityMessage,
      );
    } else if (error is CredentialDenied) {
      _fail(
        SessionState.denied,
        SessionFailureKind.credentialDenied,
        _deniedMessage,
      );
    } else if (error is AuthException ||
        error is ApiException && error.statusCode == 401) {
      _fail(
        SessionState.error,
        SessionFailureKind.vmodalUnauthorized,
        _unauthorizedMessage,
      );
    } else if (error is ApiException && error.statusCode == 403) {
      _fail(
        SessionState.denied,
        SessionFailureKind.vmodalForbidden,
        _deniedMessage,
      );
    } else {
      _fail(SessionState.error, SessionFailureKind.contract, _contractMessage);
    }
  }

  void _fail(SessionState next, SessionFailureKind kind, String safeMessage) {
    _teardown();
    state = next;
    failureKind = kind;
    message = safeMessage;
    _notify();
  }

  void _schedule() {
    _timer?.cancel();
    final expiry = _credential?.expiresAt;
    if (expiry == null) return;
    final wait =
        expiry.difference(clock().toUtc()) - const Duration(seconds: 60);
    _timer = Timer(wait.isNegative ? Duration.zero : wait, () {
      unawaited(ensureFresh().catchError((Object _) {}));
    });
  }

  Future<void> ensureFresh() {
    final account = user;
    final credential = _credential;
    if (account == null || credential == null || _provider == null) {
      return Future.error(const CredentialDenied());
    }
    if (credential.expiresAt!.isAfter(
      clock().toUtc().add(const Duration(seconds: 60)),
    )) {
      return Future.value();
    }
    return _startRefresh(account);
  }

  Future<void> _startRefresh(AppUser account) {
    final current = _refreshing;
    if (current != null) return current;
    final task = _refresh(account, _generation);
    _refreshing = task;
    task.then(
      (_) {
        if (identical(_refreshing, task)) _refreshing = null;
      },
      onError: (Object _) {
        if (identical(_refreshing, task)) _refreshing = null;
      },
    );
    return task;
  }

  Future<void> _refresh(AppUser account, int generation) async {
    try {
      final renewed = await _acquire(
        account,
        generation,
        previous: _credential,
      );
      if (!_current(account, generation)) throw const CredentialDenied();
      _provider!.rotate(renewed.apiToken!);
      _credential = renewed;
      state = SessionState.ready;
      failureKind = null;
      message = '';
      _schedule();
      _notify();
    } on FirebaseIdentityTransient {
      if (_current(account, generation)) _recover();
      rethrow;
    } on CredentialTransient {
      if (_current(account, generation)) _recover();
      rethrow;
    } on Object catch (error) {
      if (_current(account, generation)) _failFor(error);
      rethrow;
    }
  }

  Future<void> signIn(String email, String password) async {
    signingIn = true;
    message = '';
    _notify();
    try {
      await auth.signIn(email, password);
    } on Object {
      message = 'Sign-in failed. Check your details and retry.';
      _notify();
    } finally {
      signingIn = false;
      _notify();
    }
  }

  Future<void> retry() async {
    final account = user;
    if (account == null || failureKind != SessionFailureKind.transient) return;
    final established = _credential != null && _provider != null;
    state = SessionState.resolving;
    failureKind = null;
    message = '';
    _notify();
    if (!established) {
      await _resolve(account, _generation);
      return;
    }
    try {
      await _startRefresh(account);
    } on Object {
      // The typed failure has already updated the recoverable or terminal UI.
    }
  }

  Future<void> signOut() async {
    _teardown();
    user = null;
    state = SessionState.signedOut;
    failureKind = null;
    message = '';
    _notify();
    await auth.signOut();
  }

  @override
  void dispose() {
    _disposed = true;
    _teardown();
    unawaited(_subscription.cancel());
    unawaited(auth.close());
    super.dispose();
  }
}
