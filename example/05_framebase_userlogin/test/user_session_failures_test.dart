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
import 'user_session_controller_test.dart'
    show credential, QueueCredentials, settle;

class ExpiredAuth extends MockFirebaseAuth {
  @override
  Future<String?> idToken(AppUser user) async =>
      throw FirebaseIdentityExpired();
}

void main() {
  test(
    'initial failures preserve denial identity and contract distinctions without retries',
    () async {
      final now = DateTime.utc(2030);
      for (final entry in [
        (
          const CredentialDenied(),
          SessionFailureKind.credentialDenied,
          SessionState.denied,
        ),
        (
          const CredentialContractError(),
          SessionFailureKind.contract,
          SessionState.error,
        ),
        (
          FirebaseIdentityExpired(),
          SessionFailureKind.firebaseIdentityExpired,
          SessionState.error,
        ),
      ]) {
        final auth = MockFirebaseAuth();
        final archive = ArchiveController(
          persist: false,
          supportDirectory: Directory.systemTemp,
        );
        final source = QueueCredentials([entry.$1]);
        final waits = <Duration>[];
        var transports = 0;
        final controller = UserSessionController(
          auth: auth,
          credentials: source,
          archive: archive,
          clock: () => now,
          delay: (wait) async => waits.add(wait),
          transportFactory: (_) {
            transports++;
            return QueueTransport();
          },
        );
        await settle();
        auth.setUser(const AppUser('alice'));
        await settle();
        expect(controller.failureKind, entry.$2);
        expect(controller.state, entry.$3);
        expect(waits, isEmpty);
        expect(transports, 0);
        expect(archive.connected, isFalse);
        controller.dispose();
        archive.dispose();
      }
    },
  );

  test(
    'missing read grant and malformed scope fail before creating cloud session',
    () async {
      final now = DateTime.utc(2030);
      for (final c in [
        credential(
          'alice',
          now.add(const Duration(hours: 1)),
          grants: {'library:write'},
        ),
        credential(
          'alice',
          now.add(const Duration(hours: 1)),
          scope: '../scope',
        ),
      ]) {
        final auth = MockFirebaseAuth();
        final archive = ArchiveController(
          persist: false,
          supportDirectory: Directory.systemTemp,
        );
        var transports = 0;
        final controller = UserSessionController(
          auth: auth,
          credentials: QueueCredentials([c]),
          archive: archive,
          clock: () => now,
          transportFactory: (_) {
            transports++;
            return QueueTransport();
          },
        );
        await settle();
        auth.setUser(const AppUser('alice'));
        await settle();
        expect(transports, 0);
        expect(controller.gateway, isNull);
        expect(
          controller.failureKind,
          c.permissions.contains('library:read')
              ? SessionFailureKind.contract
              : SessionFailureKind.credentialDenied,
        );
        controller.dispose();
        archive.dispose();
      }
    },
  );

  test(
    'transient acquisition uses two bounded backoffs and manual retry restores this user',
    () async {
      final now = DateTime.utc(2030);
      final auth = MockFirebaseAuth();
      final archive = ArchiveController(
        persist: false,
        supportDirectory: Directory.systemTemp,
      );
      final source = QueueCredentials([
        const CredentialTransient(),
        const CredentialTransient(),
        const CredentialTransient(),
        credential('alice', now.add(const Duration(hours: 1))),
      ]);
      final waits = <Duration>[];
      final controller = UserSessionController(
        auth: auth,
        credentials: source,
        archive: archive,
        clock: () => now,
        delay: (wait) async => waits.add(wait),
        transportFactory: (_) => QueueTransport(),
      );
      await settle();
      auth.setUser(const AppUser('alice'));
      await settle();
      expect(source.calls, 3);
      expect(waits, [
        const Duration(milliseconds: 250),
        const Duration(milliseconds: 500),
      ]);
      expect(controller.state, SessionState.recoverable);
      expect(controller.canRead, isFalse);
      await controller.retry();
      expect(controller.state, SessionState.ready);
      expect(source.calls, 4);
      controller.dispose();
      archive.dispose();
    },
  );

  test(
    'renewal transient exhaustion blocks calls and retry preserves existing lease',
    () async {
      var now = DateTime.utc(2030);
      final auth = MockFirebaseAuth();
      final archive = ArchiveController(
        persist: false,
        supportDirectory: Directory.systemTemp,
      );
      final source = QueueCredentials([
        credential('alice', now.add(const Duration(minutes: 2))),
        const CredentialTransient(),
        const CredentialTransient(),
        const CredentialTransient(),
      ]);
      final waits = <Duration>[];
      final controller = UserSessionController(
        auth: auth,
        credentials: source,
        archive: archive,
        clock: () => now,
        delay: (wait) async => waits.add(wait),
        transportFactory: (_) => QueueTransport(),
      );
      await settle();
      auth.setUser(const AppUser('alice'));
      await settle();
      final gateway = controller.gateway!;
      now = now.add(const Duration(seconds: 70));
      await expectLater(
        controller.ensureFresh(),
        throwsA(isA<TenantAuthException>()),
      );
      expect(controller.state, SessionState.recoverable);
      expect(controller.failureKind, SessionFailureKind.transient);
      expect(waits, hasLength(2));
      expect(controller.gateway, same(gateway));
      expect(gateway.session.isActive, isTrue);
      source.items.add(
        credential(
          'alice',
          now.add(const Duration(minutes: 3)),
          token: 'retry-key',
        ),
      );
      await controller.retry();
      expect(controller.state, SessionState.ready);
      expect(controller.gateway, same(gateway));
      controller.dispose();
      archive.dispose();
    },
  );

  test(
    'switch during renewal backoff never dispatches another A issuer request',
    () async {
      var now = DateTime.utc(2030);
      final wait = Completer<void>();
      final source = QueueCredentials([
        credential('alice', now.add(const Duration(minutes: 2))),
        const CredentialTransient(),
        credential('bob', now.add(const Duration(hours: 1))),
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
        delay: (_) => wait.future,
        transportFactory: (_) => QueueTransport(),
      );
      await settle();
      auth.setUser(const AppUser('alice'));
      await settle();
      final a = controller.gateway!;
      now = now.add(const Duration(seconds: 70));
      final renewal = expectLater(
        controller.ensureFresh(),
        throwsA(isA<CredentialDenied>()),
      );
      await settle();
      auth.setUser(const AppUser('bob'));
      await settle();
      final b = controller.gateway!;
      wait.complete();
      await renewal;
      expect(source.calls, 3);
      expect(controller.gateway, same(b));
      expect(a.session.isActive, isFalse);
      expect(controller.state, SessionState.ready);
      expect(controller.user!.uid, 'bob');
      controller.dispose();
      archive.dispose();
    },
  );

  test(
    'Firebase token expiry fails once before calling credential issuer',
    () async {
      final auth = ExpiredAuth();
      final archive = ArchiveController(
        persist: false,
        supportDirectory: Directory.systemTemp,
      );
      final source = QueueCredentials([]);
      final controller = UserSessionController(
        auth: auth,
        credentials: source,
        archive: archive,
      );
      await settle();
      auth.setUser(const AppUser('alice'));
      await settle();
      expect(source.calls, 0);
      expect(
        controller.failureKind,
        SessionFailureKind.firebaseIdentityExpired,
      );
      expect(controller.gateway, isNull);
      expect(controller.canRetry, isFalse);
      controller.dispose();
      archive.dispose();
    },
  );
}
