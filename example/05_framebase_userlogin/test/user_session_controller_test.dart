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
  SessionGateway(super.keys, super.collectionUserId, this.owner);
  final String owner;
  @override
  Future<void> connect(String expectedUserId) async {
    if (expectedUserId != owner) throw const AuthException('Wrong owner');
    accountId = owner;
  }
}

class QueueCredentials implements VmodalCredentialSource {
  QueueCredentials(this.items);
  final List<Future<VmodalCredential>> items;
  int calls = 0;
  @override
  Future<VmodalCredential> acquire(AppUser user, String? firebaseIdToken) {
    calls++;
    return items.removeAt(0);
  }
}

VmodalCredential credential(
  String uid,
  DateTime expiry, {
  String? token,
  String? owner,
  bool allowed = true,
  Set<String> grants = const {'library:read', 'library:write'},
}) => VmodalCredential(
  apiToken: token ?? 'placeholder-$uid',
  expiresAt: expiry,
  firebaseUid: uid,
  vmodalUserId: owner ?? 'vm-$uid',
  collectionUserId: uid,
  allowed: allowed,
  permissions: grants,
);

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  test('credential rejects expiry, wrong UID, and missing grants', () {
    final now = DateTime.utc(2030);
    const user = AppUser('alice');
    expect(
      () => credential('alice', now).validate(user, now),
      throwsA(isA<CredentialDenied>()),
    );
    expect(
      () => credential(
        'bob',
        now.add(const Duration(hours: 1)),
      ).validate(user, now),
      throwsA(isA<CredentialDenied>()),
    );
    expect(
      () => credential(
        'alice',
        now.add(const Duration(hours: 1)),
        grants: {'library:write'},
      ).validate(user, now),
      throwsA(isA<CredentialDenied>()),
    );
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
        return SessionGateway(key, id, 'vm-$id');
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
      expect(session.state, SessionState.error);
      expect(() => provider.current(), throwsA(isA<AuthException>()));
      session.dispose();
      archive.dispose();
    },
  );

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
      gatewayFactory: (key, id, fresh) => SessionGateway(key, id, 'vm-$id'),
    );
    await settle();
    auth.setUser(const AppUser('alice'));
    await settle();
    auth.setUser(const AppUser('bob'));
    await settle();
    expect(session.gateway?.collection, 'framebase_streets__user_bob');
    delayed.complete(credential('alice', now.add(const Duration(hours: 1))));
    await settle();
    expect(session.gateway?.collection, 'framebase_streets__user_bob');
    await session.signOut();
    expect(session.state, SessionState.signedOut);
    expect(archive.clips.any((c) => c.uploaded), isFalse);
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
      gatewayFactory: (key, id, fresh) => SessionGateway(key, id, 'vm-$id'),
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
    expect(session.gateway?.collection, 'framebase_streets__user_bob');
    delayed.complete(credential('alice', now.add(const Duration(hours: 1))));
    await old;
    expect(session.gateway?.collection, 'framebase_streets__user_bob');
    session.dispose();
    archive.dispose();
  });
}
