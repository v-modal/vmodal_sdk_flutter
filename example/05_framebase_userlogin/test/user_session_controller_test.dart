import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:framebase/data/archive_controller.dart';
import 'package:framebase/data/search_gateway.dart';
import 'package:framebase/user/auth_adapter.dart';
import 'package:framebase/user/mock_firebase_auth.dart';
import 'package:framebase/user/user_session_controller.dart';
import 'package:framebase/user/vmodal_credential.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

class SessionGateway extends SearchGateway {
  SessionGateway(super.keys, super.scopeId, this.owner, [this.connectError]);
  final String owner;
  final Object? connectError;
  int destructiveCalls = 0;
  @override
  Future<void> connect(String expectedUserId) async {
    if (connectError case final Object error) throw error;
    if (expectedUserId != owner) throw const AuthException('Wrong owner');
    accountId = owner;
  }

  @override
  Future<DeleteCollectionResponse> previewLibraryDeletion(
    CancellationToken cancellation,
  ) async {
    destructiveCalls++;
    return DeleteCollectionResponse(const {'status': 'dry_run'});
  }

  @override
  Future<DeleteCollectionResponse> deleteLibrary(
    CancellationToken cancellation,
  ) async {
    destructiveCalls++;
    return DeleteCollectionResponse(const {'status': 'ok'});
  }
}

class TrackingArchive extends ArchiveController {
  TrackingArchive({required Directory supportDirectory})
    : super(persist: false, supportDirectory: supportDirectory);
  String activatedScope = '';
  int activations = 0;

  @override
  Future<void> activate(
    String scopeId,
    SearchGateway gateway, {
    required bool canRead,
    required bool canWrite,
  }) async {
    activatedScope = scopeId;
    activations++;
    await super.activate(
      scopeId,
      gateway,
      canRead: canRead,
      canWrite: canWrite,
    );
  }
}

class TokenAuth extends MockFirebaseAuth {
  TokenAuth(this.tokens);
  final List<Object> tokens;

  @override
  Future<String?> idToken(AppUser user) async {
    final item = tokens.removeAt(0);
    if (item is String) return item;
    if (item is Future<String?>) return item;
    throw item;
  }
}

class QueueCredentials implements VmodalCredentialSource {
  QueueCredentials(this.items);
  final List<Object> items;
  int calls = 0;
  @override
  Future<VmodalCredential> acquire(
    AppUser user,
    String? firebaseIdToken,
  ) async {
    calls++;
    final item = items.removeAt(0);
    if (item is VmodalCredential) return item;
    if (item is Future<VmodalCredential>) return item;
    throw item;
  }
}

VmodalCredential credential(
  String uid,
  DateTime expiry, {
  int? version = 1,
  String? sessionId,
  DateTime? issuedAt,
  String? token,
  String? owner,
  String? scope,
  bool allowed = true,
  Set<String> grants = const {'library:read', 'library:write'},
}) => VmodalCredential(
  contractVersion: version,
  sessionId: sessionId ?? 'session-$uid',
  issuedAt: issuedAt ?? expiry.subtract(const Duration(minutes: 5)),
  apiToken: token ?? 'placeholder-$uid',
  expiresAt: expiry,
  firebaseUid: uid,
  vmodalUserId: owner ?? 'vm-$uid',
  scopeId: scope ?? 'scope_$uid',
  allowed: allowed,
  permissions: grants,
);

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  test('credential parses scope and rejects invalid contracts or grants', () {
    final now = DateTime.utc(2030);
    const user = AppUser('alice');
    final valid = <String, Object?>{
      'version': 1,
      'session_id': 'issuer-session-7K3A',
      'issued_at': '2030-01-01T00:00:00+00:00',
      'api_token': 'token',
      'expires_at': '2030-01-01T01:00:00Z',
      'firebase_uid': 'alice',
      'vmodal_user_id': 'vm-alice',
      'scope_id': 'scope_7K3A',
      'allowed': true,
      'permissions': ['library:read'],
    };
    final parsed = VmodalCredential.fromJson(valid);
    expect(parsed.contractVersion, 1);
    expect(parsed.sessionId, 'issuer-session-7K3A');
    expect(parsed.issuedAt, DateTime.utc(2030));
    expect(parsed.expiresAt, DateTime.utc(2030, 1, 1, 1));
    expect(parsed.scopeId, 'scope_7K3A');
    expect(() => parsed.validate(user, now), returnsNormally);

    for (final invalid in <Map<String, Object?>>[
      Map<String, Object?>.from(valid)..remove('version'),
      {...valid, 'version': 2},
      {...valid, 'session_id': '  '},
      Map<String, Object?>.from(valid)..remove('issued_at'),
      {...valid, 'issued_at': 'not-a-date'},
      {...valid, 'issued_at': valid['expires_at']},
      {...valid, 'issued_at': '2030-01-01T02:00:00Z'},
    ]) {
      expect(
        () => VmodalCredential.fromJson(invalid).validate(user, now),
        throwsA(isA<CredentialContractError>()),
      );
    }
    expect(
      () => credential('alice', now).validate(user, now),
      throwsA(isA<CredentialContractError>()),
    );
    expect(
      () => credential(
        'bob',
        now.add(const Duration(hours: 1)),
      ).validate(user, now),
      throwsA(isA<CredentialContractError>()),
    );
    expect(
      () => credential(
        'alice',
        now.add(const Duration(hours: 1)),
        grants: {'library:write'},
      ).validate(user, now),
      throwsA(isA<CredentialDenied>()),
    );
    expect(
      () => credential(
        'alice',
        now.add(const Duration(hours: 1)),
        allowed: false,
      ).validate(user, now),
      throwsA(isA<CredentialDenied>()),
    );
    expect(
      () => credential(
        'alice',
        now.add(const Duration(hours: 1)),
        scope: 'invalid-scope',
      ).validate(user, now),
      throwsA(isA<CredentialContractError>()),
    );
    final prior = credential(
      'alice',
      now.add(const Duration(hours: 1)),
      scope: 'scope_original',
    );
    expect(
      () => credential(
        'alice',
        now.add(const Duration(hours: 1)),
        scope: 'scope_changed',
      ).validate(user, now, previous: prior),
      throwsA(isA<CredentialContractError>()),
    );
    expect(
      () => credential(
        'alice',
        now.add(const Duration(hours: 1)),
        sessionId: 'rotated-session',
        scope: 'scope_original',
      ).validate(user, now, previous: prior),
      returnsNormally,
    );
  });

  test('initial resolve passes the issuer scope unchanged', () async {
    final now = DateTime.utc(2030);
    final root = await Directory.systemTemp.createTemp('scope_session_');
    addTearDown(() => root.delete(recursive: true));
    final archive = TrackingArchive(supportDirectory: root);
    final auth = MockFirebaseAuth();
    final source = QueueCredentials([
      Future.value(
        credential(
          'alice',
          now.add(const Duration(hours: 1)),
          scope: 'scope_7K3A',
        ),
      ),
    ]);
    final session = UserSessionController(
      auth: auth,
      credentials: source,
      archive: archive,
      clock: () => now,
      gatewayFactory: (key, scope, fresh) =>
          SessionGateway(key, scope, 'vm-alice'),
    );
    await settle();
    auth.setUser(const AppUser('alice'));
    await settle();
    expect(session.state, SessionState.ready);
    expect(session.gateway?.collection, 'scope_7K3A');
    expect(archive.activatedScope, 'scope_7K3A');
    session.dispose();
    archive.dispose();
  });
  test('empty default and denied credential issue no gateway calls', () async {
    final archive = ArchiveController(
      persist: false,
      supportDirectory: Directory.systemTemp,
    );
    final auth = MockFirebaseAuth();
    final source = MockVmodalCredentialSource();
    var gateways = 0;
    final session = UserSessionController(
      auth: auth,
      credentials: source,
      archive: archive,
      gatewayFactory: (key, id, fresh) {
        gateways++;
        return SessionGateway(key, id, 'vm-alice');
      },
    );
    expect(session.state, SessionState.loading);
    await settle();
    expect(session.state, SessionState.signedOut);
    expect(source.calls, 0);
    auth.setUser(const AppUser('alice'));
    await settle();
    expect(session.state, SessionState.denied);
    expect(gateways, 0);
    expect(archive.connected, isFalse);
    session.dispose();
    archive.dispose();
  });

  test('owner mismatch and missing read grant fail closed', () async {
    final now = DateTime.utc(2030);
    for (final grants in [
      <String>{'library:write'},
      <String>{'library:read'},
    ]) {
      final archive = ArchiveController(
        persist: false,
        supportDirectory: Directory.systemTemp,
      );
      final auth = MockFirebaseAuth();
      final source = QueueCredentials([
        Future.value(
          credential(
            'alice',
            now.add(const Duration(hours: 1)),
            grants: grants,
          ),
        ),
      ]);
      final session = UserSessionController(
        auth: auth,
        credentials: source,
        archive: archive,
        clock: () => now,
        gatewayFactory: (key, id, fresh) =>
            SessionGateway(key, id, 'different'),
      );
      await settle();
      auth.setUser(const AppUser('alice'));
      await settle();
      expect(
        session.state,
        grants.contains('library:read')
            ? SessionState.error
            : SessionState.denied,
      );
      expect(archive.connected, isFalse);
      session.dispose();
      archive.dispose();
    }
  });

  test(
    'refresh is single flight, rotates key, and failure clears it',
    () async {
      var now = DateTime.utc(2030);
      final pending = Completer<VmodalCredential>();
      final failed = Completer<VmodalCredential>();
      final source = QueueCredentials([
        Future.value(credential('alice', now.add(const Duration(minutes: 2)))),
        pending.future,
        failed.future,
      ]);
      final archive = ArchiveController(
        persist: false,
        supportDirectory: Directory.systemTemp,
      );
      final auth = MockFirebaseAuth();
      final session = UserSessionController(
        auth: auth,
        credentials: source,
        archive: archive,
        clock: () => now,
        gatewayFactory: (key, id, fresh) => SessionGateway(key, id, 'vm-alice'),
      );
      await settle();
      auth.setUser(const AppUser('alice'));
      await settle();
      expect(session.state, SessionState.ready);
      final provider = session.gateway!.keys;
      now = now.add(const Duration(seconds: 70));
      final a = session.ensureFresh();
      final b = session.ensureFresh();
      await settle();
      expect(source.calls, 2);
      pending.complete(
        credential(
          'alice',
          now.add(const Duration(minutes: 2)),
          token: 'rotated',
        ),
      );
      await Future.wait([a, b]);
      expect(provider.current(), 'rotated');
      now = now.add(const Duration(seconds: 70));
      final renewal = expectLater(
        session.ensureFresh(),
        throwsA(isA<CredentialDenied>()),
      );
      failed.completeError(const CredentialDenied());
      await renewal;
      expect(session.state, SessionState.denied);
      expect(session.failureKind, SessionFailureKind.credentialDenied);
      expect(() => provider.current(), throwsA(isA<AuthException>()));
      session.dispose();
      archive.dispose();
    },
  );

  test('refresh rejects a changed scope before key rotation', () async {
    var now = DateTime.utc(2030);
    final source = QueueCredentials([
      Future.value(credential('alice', now.add(const Duration(minutes: 2)))),
      Future.value(
        credential(
          'alice',
          now.add(const Duration(minutes: 4)),
          token: 'must-not-rotate',
          scope: 'scope_other',
        ),
      ),
    ]);
    final archive = ArchiveController(
      persist: false,
      supportDirectory: Directory.systemTemp,
    );
    final auth = MockFirebaseAuth();
    final session = UserSessionController(
      auth: auth,
      credentials: source,
      archive: archive,
      clock: () => now,
      gatewayFactory: (key, scope, fresh) =>
          SessionGateway(key, scope, 'vm-alice'),
    );
    await settle();
    auth.setUser(const AppUser('alice'));
    await settle();
    final provider = session.gateway!.keys;
    expect(provider.current(), 'placeholder-alice');
    now = now.add(const Duration(seconds: 70));
    await expectLater(
      session.ensureFresh(),
      throwsA(isA<CredentialContractError>()),
    );
    expect(session.state, SessionState.error);
    expect(() => provider.current(), throwsA(isA<AuthException>()));
    session.dispose();
    archive.dispose();
  });

  test('late account A response cannot replace account B', () async {
    final now = DateTime.utc(2030);
    final delayed = Completer<VmodalCredential>();
    final source = QueueCredentials([
      delayed.future,
      Future.value(credential('bob', now.add(const Duration(hours: 1)))),
    ]);
    final archive = ArchiveController(
      persist: false,
      supportDirectory: Directory.systemTemp,
    );
    final auth = MockFirebaseAuth();
    final session = UserSessionController(
      auth: auth,
      credentials: source,
      archive: archive,
      clock: () => now,
      gatewayFactory: (key, id, fresh) =>
          SessionGateway(key, id, id == 'scope_bob' ? 'vm-bob' : 'vm-alice'),
    );
    await settle();
    auth.setUser(const AppUser('alice'));
    await settle();
    auth.setUser(const AppUser('bob'));
    await settle();
    expect(session.gateway?.collection, 'scope_bob');
    final bobGateway = session.gateway! as SessionGateway;
    delayed.complete(credential('alice', now.add(const Duration(hours: 1))));
    await settle();
    expect(session.gateway?.collection, 'scope_bob');
    await session.signOut();
    expect(session.state, SessionState.signedOut);
    expect(archive.clips.any((c) => c.uploaded), isFalse);
    expect(bobGateway.destructiveCalls, 0);
    session.dispose();
    archive.dispose();
  });

  test('late account A refresh cannot reopen after switching to B', () async {
    var now = DateTime.utc(2030);
    final delayed = Completer<VmodalCredential>();
    final source = QueueCredentials([
      Future.value(credential('alice', now.add(const Duration(minutes: 2)))),
      delayed.future,
      Future.value(credential('bob', now.add(const Duration(hours: 1)))),
    ]);
    final archive = ArchiveController(
      persist: false,
      supportDirectory: Directory.systemTemp,
    );
    final auth = MockFirebaseAuth();
    final session = UserSessionController(
      auth: auth,
      credentials: source,
      archive: archive,
      clock: () => now,
      gatewayFactory: (key, id, fresh) =>
          SessionGateway(key, id, id == 'scope_bob' ? 'vm-bob' : 'vm-alice'),
    );
    await settle();
    auth.setUser(const AppUser('alice'));
    await settle();
    now = now.add(const Duration(seconds: 70));
    final old = expectLater(
      session.ensureFresh(),
      throwsA(isA<CredentialDenied>()),
    );
    await settle();
    auth.setUser(const AppUser('bob'));
    await settle();
    expect(session.gateway?.collection, 'scope_bob');
    delayed.complete(credential('alice', now.add(const Duration(hours: 1))));
    await old;
    expect(session.gateway?.collection, 'scope_bob');
    session.dispose();
    archive.dispose();
  });

  test(
    'transient refresh retries twice, stays single flight, and rotates in place',
    () async {
      var now = DateTime.utc(2030);
      final delays = <Duration>[];
      final source = QueueCredentials([
        credential('alice', now.add(const Duration(minutes: 2))),
        const CredentialTransient(),
        const CredentialTransient(),
        credential(
          'alice',
          now.add(const Duration(minutes: 4)),
          token: 'rotated-after-retry',
        ),
      ]);
      final root = await Directory.systemTemp.createTemp('retry_success_');
      addTearDown(() => root.delete(recursive: true));
      final archive = TrackingArchive(supportDirectory: root);
      final auth = MockFirebaseAuth();
      var gateways = 0;
      final session = UserSessionController(
        auth: auth,
        credentials: source,
        archive: archive,
        clock: () => now,
        delay: (value) async => delays.add(value),
        gatewayFactory: (key, scope, fresh) {
          gateways++;
          return SessionGateway(key, scope, 'vm-alice');
        },
      );
      await settle();
      auth.setUser(const AppUser('alice'));
      await settle();
      final gateway = session.gateway!;
      final provider = gateway.keys;
      now = now.add(const Duration(seconds: 70));

      final first = session.ensureFresh();
      final second = session.ensureFresh();
      await Future.wait([first, second]);

      expect(source.calls, 4);
      expect(delays, const [
        Duration(milliseconds: 250),
        Duration(milliseconds: 500),
      ]);
      expect(session.state, SessionState.ready);
      expect(session.failureKind, isNull);
      expect(session.gateway, same(gateway));
      expect(session.gateway!.keys, same(provider));
      expect(provider.current(), 'rotated-after-retry');
      expect(archive.activations, 1);
      expect(archive.connected, isTrue);
      expect(gateways, 1);
      session.dispose();
      archive.dispose();
    },
  );

  test('transient exhaustion preserves resources and manual retry', () async {
    var now = DateTime.utc(2030);
    final delays = <Duration>[];
    final source = QueueCredentials([
      credential('alice', now.add(const Duration(minutes: 2))),
      const CredentialTransient(),
      const CredentialTransient(),
      const CredentialTransient(),
    ]);
    final root = await Directory.systemTemp.createTemp('retry_manual_');
    addTearDown(() => root.delete(recursive: true));
    final archive = TrackingArchive(supportDirectory: root);
    final auth = MockFirebaseAuth();
    var gateways = 0;
    final session = UserSessionController(
      auth: auth,
      credentials: source,
      archive: archive,
      clock: () => now,
      delay: (value) async => delays.add(value),
      gatewayFactory: (key, scope, fresh) {
        gateways++;
        return SessionGateway(key, scope, 'vm-alice');
      },
    );
    await settle();
    auth.setUser(const AppUser('alice'));
    await settle();
    final gateway = session.gateway!;
    final provider = gateway.keys;
    now = now.add(const Duration(seconds: 70));

    await expectLater(
      session.ensureFresh(),
      throwsA(isA<CredentialTransient>()),
    );

    expect(session.state, SessionState.recoverable);
    expect(session.failureKind, SessionFailureKind.transient);
    expect(session.canRetry, isTrue);
    expect(session.gateway, same(gateway));
    expect(session.gateway!.keys, same(provider));
    expect(provider.current(), 'placeholder-alice');
    expect(gateway.collection, 'scope_alice');
    expect(archive.activatedScope, 'scope_alice');
    expect(archive.connected, isTrue);
    expect(session.canRead, isFalse);
    expect(session.canWrite, isFalse);
    expect(gateways, 1);
    expect(archive.activations, 1);

    source.items.add(
      credential(
        'alice',
        now.add(const Duration(minutes: 4)),
        token: 'manual-retry-key',
      ),
    );
    await session.retry();

    expect(session.state, SessionState.ready);
    expect(session.failureKind, isNull);
    expect(session.gateway, same(gateway));
    expect(provider.current(), 'manual-retry-key');
    expect(archive.connected, isTrue);
    expect(gateways, 1);
    expect(archive.activations, 1);
    expect(delays, const [
      Duration(milliseconds: 250),
      Duration(milliseconds: 500),
    ]);
    session.dispose();
    archive.dispose();
  });

  test('initial transient exhaustion can resolve on manual retry', () async {
    final now = DateTime.utc(2030);
    final delays = <Duration>[];
    final source = QueueCredentials([
      const CredentialTransient(),
      const CredentialTransient(),
      const CredentialTransient(),
    ]);
    final archive = ArchiveController(
      persist: false,
      supportDirectory: Directory.systemTemp,
    );
    final auth = MockFirebaseAuth();
    var gateways = 0;
    final session = UserSessionController(
      auth: auth,
      credentials: source,
      archive: archive,
      clock: () => now,
      delay: (value) async => delays.add(value),
      gatewayFactory: (key, scope, fresh) {
        gateways++;
        return SessionGateway(key, scope, 'vm-alice');
      },
    );
    await settle();
    auth.setUser(const AppUser('alice'));
    await settle();

    expect(session.state, SessionState.recoverable);
    expect(session.failureKind, SessionFailureKind.transient);
    expect(session.gateway, isNull);
    expect(archive.connected, isFalse);
    expect(gateways, 0);

    source.items.add(credential('alice', now.add(const Duration(hours: 1))));
    await session.retry();

    expect(session.state, SessionState.ready);
    expect(session.failureKind, isNull);
    expect(session.gateway, isNotNull);
    expect(archive.connected, isTrue);
    expect(gateways, 1);
    expect(delays, const [
      Duration(milliseconds: 250),
      Duration(milliseconds: 500),
    ]);
    session.dispose();
    archive.dispose();
  });

  test('terminal refresh failures do not retry and fail closed', () async {
    Future<void> check(
      Object error,
      SessionState expectedState,
      SessionFailureKind expectedKind,
    ) async {
      var now = DateTime.utc(2030);
      final delays = <Duration>[];
      final source = QueueCredentials([
        credential('alice', now.add(const Duration(minutes: 2))),
        error,
      ]);
      final archive = ArchiveController(
        persist: false,
        supportDirectory: Directory.systemTemp,
      );
      final auth = MockFirebaseAuth();
      final session = UserSessionController(
        auth: auth,
        credentials: source,
        archive: archive,
        clock: () => now,
        delay: (value) async => delays.add(value),
        gatewayFactory: (key, scope, fresh) =>
            SessionGateway(key, scope, 'vm-alice'),
      );
      await settle();
      auth.setUser(const AppUser('alice'));
      await settle();
      final provider = session.gateway!.keys;
      now = now.add(const Duration(seconds: 70));

      await expectLater(session.ensureFresh(), throwsA(same(error)));

      expect(delays, isEmpty);
      expect(session.state, expectedState);
      expect(session.failureKind, expectedKind);
      expect(session.canRetry, isFalse);
      expect(session.gateway, isNull);
      expect(archive.connected, isFalse);
      expect(() => provider.current(), throwsA(isA<AuthException>()));
      session.dispose();
      archive.dispose();
    }

    await check(
      const FirebaseIdentityExpired(),
      SessionState.error,
      SessionFailureKind.firebaseIdentityExpired,
    );
    await check(
      const CredentialDenied(),
      SessionState.denied,
      SessionFailureKind.credentialDenied,
    );
    await check(
      const CredentialContractError(),
      SessionState.error,
      SessionFailureKind.contract,
    );
  });

  test('VMODAL 401 and 403 stay distinct at connect and after ready', () async {
    Future<void> checkConnect(
      Object error,
      SessionState expectedState,
      SessionFailureKind expectedKind,
    ) async {
      final now = DateTime.utc(2030);
      final delays = <Duration>[];
      final source = QueueCredentials([
        credential('alice', now.add(const Duration(hours: 1))),
      ]);
      final archive = ArchiveController(
        persist: false,
        supportDirectory: Directory.systemTemp,
      );
      final auth = MockFirebaseAuth();
      MutableApiKeyProvider? provider;
      final session = UserSessionController(
        auth: auth,
        credentials: source,
        archive: archive,
        clock: () => now,
        delay: (value) async => delays.add(value),
        gatewayFactory: (key, scope, fresh) {
          provider = key;
          return SessionGateway(key, scope, 'vm-alice', error);
        },
      );
      await settle();
      auth.setUser(const AppUser('alice'));
      await settle();
      expect(delays, isEmpty);
      expect(session.state, expectedState);
      expect(session.failureKind, expectedKind);
      expect(session.gateway, isNull);
      expect(archive.connected, isFalse);
      expect(() => provider!.current(), throwsA(isA<AuthException>()));
      session.dispose();
      archive.dispose();
    }

    await checkConnect(
      const AuthException('expired'),
      SessionState.error,
      SessionFailureKind.vmodalUnauthorized,
    );
    await checkConnect(
      const ApiException('forbidden', statusCode: 403),
      SessionState.denied,
      SessionFailureKind.vmodalForbidden,
    );

    Future<void> checkCallback(
      SdkException error,
      SessionState expectedState,
      SessionFailureKind expectedKind,
    ) async {
      final now = DateTime.utc(2030);
      final source = QueueCredentials([
        credential('alice', now.add(const Duration(hours: 1))),
      ]);
      final archive = ArchiveController(
        persist: false,
        supportDirectory: Directory.systemTemp,
      );
      final auth = MockFirebaseAuth();
      final session = UserSessionController(
        auth: auth,
        credentials: source,
        archive: archive,
        clock: () => now,
        gatewayFactory: (key, scope, fresh) =>
            SessionGateway(key, scope, 'vm-alice'),
      );
      await settle();
      auth.setUser(const AppUser('alice'));
      await settle();
      final gateway = session.gateway!;
      final provider = gateway.keys;
      gateway.reportFailure(error);
      expect(session.state, expectedState);
      expect(session.failureKind, expectedKind);
      expect(session.gateway, isNull);
      expect(archive.connected, isFalse);
      expect(() => provider.current(), throwsA(isA<AuthException>()));
      session.dispose();
      archive.dispose();
    }

    await checkCallback(
      const AuthException('expired'),
      SessionState.error,
      SessionFailureKind.vmodalUnauthorized,
    );
    await checkCallback(
      const ApiException('forbidden', statusCode: 403),
      SessionState.denied,
      SessionFailureKind.vmodalForbidden,
    );
  });

  test('Firebase identity expiry from the adapter does not back off', () async {
    var now = DateTime.utc(2030);
    final expired = FirebaseIdentityExpired();
    final auth = TokenAuth(['initial', expired]);
    final source = QueueCredentials([
      credential('alice', now.add(const Duration(minutes: 2))),
    ]);
    final archive = ArchiveController(
      persist: false,
      supportDirectory: Directory.systemTemp,
    );
    final delays = <Duration>[];
    final session = UserSessionController(
      auth: auth,
      credentials: source,
      archive: archive,
      clock: () => now,
      delay: (value) async => delays.add(value),
      gatewayFactory: (key, scope, fresh) =>
          SessionGateway(key, scope, 'vm-alice'),
    );
    await settle();
    auth.setUser(const AppUser('alice'));
    await settle();
    final provider = session.gateway!.keys;
    now = now.add(const Duration(seconds: 70));
    await expectLater(session.ensureFresh(), throwsA(same(expired)));
    expect(delays, isEmpty);
    expect(session.state, SessionState.error);
    expect(session.failureKind, SessionFailureKind.firebaseIdentityExpired);
    expect(() => provider.current(), throwsA(isA<AuthException>()));
    expect(archive.connected, isFalse);
    session.dispose();
    archive.dispose();
  });

  test('account switch during retry backoff cannot mutate old state', () async {
    var now = DateTime.utc(2030);
    final waiting = Completer<void>();
    final delays = <Duration>[];
    final source = QueueCredentials([
      credential('alice', now.add(const Duration(minutes: 2))),
      const CredentialTransient(),
      credential('bob', now.add(const Duration(hours: 1))),
    ]);
    final root = await Directory.systemTemp.createTemp('retry_switch_');
    addTearDown(() => root.delete(recursive: true));
    final archive = TrackingArchive(supportDirectory: root);
    final auth = MockFirebaseAuth();
    final session = UserSessionController(
      auth: auth,
      credentials: source,
      archive: archive,
      clock: () => now,
      delay: (value) {
        delays.add(value);
        return waiting.future;
      },
      gatewayFactory: (key, scope, fresh) => SessionGateway(
        key,
        scope,
        scope == 'scope_bob' ? 'vm-bob' : 'vm-alice',
      ),
    );
    await settle();
    auth.setUser(const AppUser('alice'));
    await settle();
    final oldGateway = session.gateway!;
    final oldProvider = oldGateway.keys;
    now = now.add(const Duration(seconds: 70));
    final oldRefresh = expectLater(
      session.ensureFresh(),
      throwsA(isA<CredentialTransient>()),
    );
    await settle();
    expect(delays, const [Duration(milliseconds: 250)]);

    auth.setUser(const AppUser('bob'));
    await settle();
    expect(session.state, SessionState.ready);
    expect(session.gateway?.collection, 'scope_bob');
    expect(archive.activatedScope, 'scope_bob');
    waiting.complete();
    await oldRefresh;

    expect(session.state, SessionState.ready);
    expect(session.failureKind, isNull);
    expect(session.gateway?.collection, 'scope_bob');
    expect(archive.activatedScope, 'scope_bob');
    expect(session.gateway, isNot(same(oldGateway)));
    expect(() => oldProvider.current(), throwsA(isA<AuthException>()));
    session.dispose();
    archive.dispose();
  });
}
