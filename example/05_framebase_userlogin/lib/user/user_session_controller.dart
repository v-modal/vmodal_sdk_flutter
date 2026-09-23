import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

import '../data/archive_controller.dart';
import '../data/search_gateway.dart';
import 'auth_adapter.dart';
import 'vmodal_credential.dart';

enum SessionState { loading, signedOut, resolving, ready, denied, error }

typedef GatewayFactory =
    SearchGateway Function(
      MutableApiKeyProvider provider,
      String collectionUserId,
      Future<void> Function() ensureFresh,
    );

class UserSessionController extends ChangeNotifier {
  UserSessionController({
    required this.auth,
    required this.credentials,
    required this.archive,
    GatewayFactory? gatewayFactory,
    DateTime Function()? clock,
  }) : gatewayFactory =
           gatewayFactory ??
           ((provider, id, fresh) =>
               SearchGateway(provider, id, ensureFresh: fresh)),
       clock = clock ?? DateTime.now {
    _subscription = auth.users.listen(_onUser);
  }

  final FirebaseAuthAdapter auth;
  final VmodalCredentialSource credentials;
  final ArchiveController archive;
  final GatewayFactory gatewayFactory;
  final DateTime Function() clock;
  late final StreamSubscription<AppUser?> _subscription;
  SessionState state = SessionState.loading;
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
    message = '';
    state = next == null ? SessionState.signedOut : SessionState.resolving;
    _notify();
    if (next != null) unawaited(_resolve(next, _generation));
  }

  bool _current(AppUser account, int generation) =>
      !_disposed && generation == _generation && user?.uid == account.uid;

  Future<void> _resolve(AppUser account, int generation) async {
    SearchGateway? next;
    try {
      final firebaseToken = await auth.idToken(account);
      if (!_current(account, generation)) return;
      final credential = await credentials.acquire(account, firebaseToken);
      if (!_current(account, generation)) return;
      credential.validate(account, clock());
      final provider = MutableApiKeyProvider(credential.apiToken!);
      _provider = provider;
      _credential = credential;
      next = gatewayFactory(
        provider,
        credential.collectionUserId!,
        ensureFresh,
      );
      next.onAccessFailure = (status) {
        if (_current(account, generation)) {
          _fail(status == 403 ? SessionState.denied : SessionState.error);
        }
      };
      await next.connect(credential.vmodalUserId!);
      if (!_current(account, generation)) {
        await next.close();
        return;
      }
      gateway = next;
      await archive.activate(
        credential.collectionUserId!,
        next,
        canRead: credential.permissions.contains('library:read'),
        canWrite: credential.permissions.contains('library:write'),
      );
      if (!_current(account, generation)) return;
      state = SessionState.ready;
      _schedule();
      _notify();
    } on CredentialDenied {
      if (_current(account, generation)) _fail(SessionState.denied);
      if (next != null && next != gateway) await next.close();
    } on Object {
      if (_current(account, generation)) _fail(SessionState.error);
      if (next != null && next != gateway) await next.close();
    }
  }

  void _fail(SessionState next) {
    _teardown();
    state = next;
    message = next == SessionState.denied
        ? 'Access to this library is unavailable.'
        : 'Could not connect your library. Please retry.';
    _notify();
  }

  void _schedule() {
    _timer?.cancel();
    final expiry = _credential?.expiresAt;
    if (expiry == null) return;
    final delay =
        expiry.difference(clock().toUtc()) - const Duration(seconds: 60);
    _timer = Timer(delay.isNegative ? Duration.zero : delay, () {
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
      final firebaseToken = await auth.idToken(account);
      if (!_current(account, generation)) throw const CredentialDenied();
      final renewed = await credentials.acquire(account, firebaseToken);
      if (!_current(account, generation)) throw const CredentialDenied();
      renewed.validate(account, clock(), previous: _credential);
      _provider!.rotate(renewed.apiToken!);
      _credential = renewed;
      _schedule();
      _notify();
    } on Object {
      if (_current(account, generation)) _fail(SessionState.error);
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
    if (account == null) return;
    _teardown();
    state = SessionState.resolving;
    message = '';
    _notify();
    await _resolve(account, _generation);
  }

  Future<void> signOut() async {
    _teardown();
    user = null;
    state = SessionState.signedOut;
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
