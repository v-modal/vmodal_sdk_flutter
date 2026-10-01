import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:framebase/data/archive_controller.dart';
import 'package:framebase/user/auth_adapter.dart';
import 'package:framebase/user/mock_firebase_auth.dart';
import 'package:framebase/user/user_session_controller.dart';
import 'package:framebase/user/vmodal_credential.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';
import 'session_fixture.dart';

class QueueCredentials implements VmodalCredentialSource {
  QueueCredentials(this.items);
  final List<Object> items;
  int calls = 0;
  @override
  Future<VmodalCredential> acquire(AppUser user, String? token) async {
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
  String token = 'same-key',
  String? scope,
  Set<String> grants = const {'library:read', 'library:write'},
  String? tenantId = 'same-tenant',
  bool collectionWide = false,
}) => VmodalCredential(
  contractVersion: 1,
  sessionId: 'issuer-$uid',
  issuedAt: expiry.subtract(const Duration(minutes: 5)),
  apiToken: token,
  expiresAt: expiry,
  firebaseUid: uid,
  vmodalUserId: 'shared-principal',
  tenantId: tenantId,
  scopeId: scope ?? 'scope_$uid',
  allowed: true,
  permissions: grants,
  collectionWide: collectionWide,
);

Future<void> settle() =>
    Future<void>.delayed(const Duration(milliseconds: 100));

void main() {
  test(
    'read-only issuer grant connects and searches without index write privileges',
    () async {
      final now = DateTime.utc(2030);
      final auth = MockFirebaseAuth();
      final archive = ArchiveController(
        persist: false,
        supportDirectory: Directory.systemTemp,
      );
      final transport = QueueTransport();
      final controller = UserSessionController(
        auth: auth,
        credentials: QueueCredentials([
          credential(
            'alice',
            now.add(const Duration(hours: 1)),
            grants: {'library:read'},
          ),
        ]),
        archive: archive,
        clock: () => now,
        transportFactory: (_) => transport,
      );
      await settle();
      auth.setUser(const AppUser('alice'));
      await settle();
      expect(controller.state, SessionState.ready);
      expect(controller.canRead, isTrue);
      expect(controller.canWrite, isFalse);
      expect(transport.requests, hasLength(2));
      final batch = await controller.gateway!.search('bus');
      expect(batch.matches, isEmpty);
      controller.dispose();
      archive.dispose();
    },
  );
  test(
    'archive teardown listener can activate B without old logout clearing B',
    () async {
      final now = DateTime.utc(2030);
      final auth = MockFirebaseAuth();
      final archive = ArchiveController(
        persist: false,
        supportDirectory: Directory.systemTemp,
      );
      final controller = UserSessionController(
        auth: auth,
        credentials: QueueCredentials([
          credential('alice', now.add(const Duration(hours: 1))),
          credential('bob', now.add(const Duration(hours: 1))),
        ]),
        archive: archive,
        clock: () => now,
        transportFactory: (_) => QueueTransport(),
      );
      await settle();
      auth.setUser(const AppUser('alice'));
      await settle();
      final a = controller.gateway!;
      var entered = false;
      archive.addListener(() {
        if (!entered && !archive.connected) {
          entered = true;
          expect(a.session.isActive, isFalse);
          auth.setUser(const AppUser('bob'));
        }
      });
      await controller.signOut();
      await settle();
      expect(controller.state, SessionState.ready);
      expect(controller.user!.uid, 'bob');
      expect(controller.gateway!.session.isActive, isTrue);
      controller.dispose();
      archive.dispose();
    },
  );
  test(
    'version 1 legacy principal is tenant binding and never app identity',
    () {
      final now = DateTime.utc(2030);
      final c = credential(
        'alice',
        now.add(const Duration(hours: 1)),
        tenantId: null,
      );
      c.validate(const AppUser('alice'), now);
      expect(c.tenantBinding, 'shared-principal');
      expect(
        () => c.validate(const AppUser('bob'), now),
        throwsA(isA<CredentialContractError>()),
      );
      final changed = credential(
        'alice',
        now.add(const Duration(hours: 1)),
        scope: 'scope_narrow',
        tenantId: null,
      );
      expect(
        () => changed.validate(const AppUser('alice'), now, previous: c),
        returnsNormally,
      );
      expect(c.samePolicy(changed), isFalse);
      expect(c.collectionWide, isFalse);
    },
  );

  test(
    'same key and auth principal isolate A B A sessions and archives',
    () async {
      final now = DateTime.utc(2030);
      final root = await Directory.systemTemp.createTemp('host_same_key_');
      addTearDown(() => root.delete(recursive: true));
      final archive = ArchiveController(persist: false, supportDirectory: root);
      final auth = MockFirebaseAuth();
      final source = QueueCredentials([
        credential('alice', now.add(const Duration(hours: 1))),
        credential('bob', now.add(const Duration(hours: 1))),
        credential('alice', now.add(const Duration(hours: 1))),
      ]);
      final transports = <QueueTransport>[];
      final controller = UserSessionController(
        auth: auth,
        credentials: source,
        archive: archive,
        clock: () => now,
        transportFactory: (_) {
          final transport = QueueTransport();
          transports.add(transport);
          return transport;
        },
      );
      await settle();
      auth.setUser(const AppUser('alice'));
      await settle();
      expect(controller.state, SessionState.ready);
      final a = controller.gateway!;
      final ownerA = a.context.ownerKey;
      final pathA = archive.archiveDirectory;
      auth.setUser(const AppUser('bob'));
      await settle();
      final b = controller.gateway!;
      expect(a.session.isActive, isFalse);
      expect(b.accountId, 'bob');
      expect(b.context.tenantId, 'same-tenant');
      expect(b.context.ownerKey, isNot(ownerA));
      expect(archive.archiveDirectory, isNot(pathA));
      await expectLater(a.search('private'), throwsA(isA<OperationCanceled>()));
      a.reportFailure(const AuthException('old error'));
      expect(controller.gateway, same(b));
      expect(controller.state, SessionState.ready);
      auth.setUser(const AppUser('alice'));
      await settle();
      expect(controller.gateway!.context.ownerKey, ownerA);
      expect(controller.gateway!.session.sessionId, isNot(a.session.sessionId));
      expect(transports, hasLength(3));
      for (final t in transports) {
        expect(t.requests.first.headers['Authorization'], 'Bearer same-key');
      }
      controller.dispose();
      archive.dispose();
    },
  );

  test('late issuer result cannot replace B or display A archive', () async {
    final now = DateTime.utc(2030);
    final pending = Completer<VmodalCredential>();
    final auth = MockFirebaseAuth();
    final archive = ArchiveController(
      persist: false,
      supportDirectory: Directory.systemTemp,
    );
    final controller = UserSessionController(
      auth: auth,
      credentials: QueueCredentials([
        pending.future,
        credential('bob', now.add(const Duration(hours: 1))),
      ]),
      archive: archive,
      clock: () => now,
      transportFactory: (_) => QueueTransport(),
    );
    await settle();
    auth.setUser(const AppUser('alice'));
    await settle();
    expect(archive.connected, isFalse);
    auth.setUser(const AppUser('bob'));
    await settle();
    final b = controller.gateway;
    pending.complete(credential('alice', now.add(const Duration(hours: 1))));
    await settle();
    expect(controller.gateway, same(b));
    expect(controller.user!.uid, 'bob');
    controller.dispose();
    archive.dispose();
  });

  test(
    'credential-only renewal coalesces and preserves runtime ownership',
    () async {
      var now = DateTime.utc(2030);
      final pending = Completer<VmodalCredential>();
      final source = QueueCredentials([
        credential('alice', now.add(const Duration(minutes: 2))),
        pending.future,
      ]);
      final auth = MockFirebaseAuth();
      final archive = ArchiveController(
        persist: false,
        supportDirectory: Directory.systemTemp,
      );
      final transport = QueueTransport();
      final controller = UserSessionController(
        auth: auth,
        credentials: source,
        archive: archive,
        clock: () => now,
        transportFactory: (_) => transport,
      );
      await settle();
      auth.setUser(const AppUser('alice'));
      await settle();
      final gateway = controller.gateway!;
      final id = gateway.session.sessionId;
      final owner = gateway.context.ownerKey;
      now = now.add(const Duration(seconds: 70));
      final first = controller.ensureFresh();
      final second = controller.ensureFresh();
      await settle();
      expect(source.calls, 2);
      pending.complete(
        credential(
          'alice',
          now.add(const Duration(minutes: 2)),
          token: 'rotated',
        ),
      );
      await Future.wait([first, second]);
      expect(controller.gateway, same(gateway));
      expect(gateway.session.sessionId, id);
      expect(gateway.context.ownerKey, owner);
      await gateway.listJobs();
      expect(
        transport.requests.last.headers['Authorization'],
        'Bearer rotated',
      );
      controller.dispose();
      archive.dispose();
    },
  );

  test(
    'grant narrowing rebuilds session before exposing the new policy',
    () async {
      var now = DateTime.utc(2030);
      final renewed = credential(
        'alice',
        now.add(const Duration(minutes: 4)),
        grants: {'library:read'},
      );
      final source = QueueCredentials([
        credential('alice', now.add(const Duration(minutes: 2))),
        renewed,
        renewed,
      ]);
      final auth = MockFirebaseAuth();
      final archive = ArchiveController(
        persist: false,
        supportDirectory: Directory.systemTemp,
      );
      final controller = UserSessionController(
        auth: auth,
        credentials: source,
        archive: archive,
        clock: () => now,
        transportFactory: (_) => QueueTransport(),
      );
      await settle();
      auth.setUser(const AppUser('alice'));
      await settle();
      final old = controller.gateway!;
      now = now.add(const Duration(seconds: 70));
      await expectLater(
        controller.ensureFresh(),
        throwsA(isA<TenantAuthException>()),
      );
      await settle();
      expect(old.session.isActive, isFalse);
      expect(controller.state, SessionState.ready);
      expect(controller.canWrite, isFalse);
      expect(controller.canRead, isTrue);
      expect(
        controller.gateway!.session.sessionId,
        isNot(old.session.sessionId),
      );
      controller.dispose();
      archive.dispose();
    },
  );

  test(
    'tenant 401 recovers without signing Firebase user out; old failures are ignored',
    () async {
      final now = DateTime.utc(2030);
      final auth = MockFirebaseAuth();
      final archive = ArchiveController(
        persist: false,
        supportDirectory: Directory.systemTemp,
      );
      final controller = UserSessionController(
        auth: auth,
        credentials: QueueCredentials([
          credential('alice', now.add(const Duration(hours: 1))),
          credential(
            'alice',
            now.add(const Duration(hours: 1)),
            token: 'recovered',
          ),
        ]),
        archive: archive,
        clock: () => now,
        transportFactory: (_) => QueueTransport(),
      );
      await settle();
      auth.setUser(const AppUser('alice'));
      await settle();
      final gateway = controller.gateway!;
      gateway.reportFailure(const AuthException('expired'));
      expect(controller.state, SessionState.recoverable);
      expect(controller.user!.uid, 'alice');
      expect(controller.gateway, same(gateway));
      expect(controller.canRetry, isTrue);
      await controller.retry();
      expect(controller.state, SessionState.ready);
      expect(controller.gateway, same(gateway));
      await controller.signOut();
      gateway.reportFailure(const AuthException('late'));
      expect(controller.state, SessionState.signedOut);
      controller.dispose();
      archive.dispose();
    },
  );
}
