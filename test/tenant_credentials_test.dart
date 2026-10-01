import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

TenantCredential credential(String key, {int? version, String tenant = 'T'}) =>
    TenantCredential(
      serviceNamespace: 'https://gateway.test/api/v1/proxy/search_api',
      tenantId: tenant,
      principal: 'tenant-principal',
      apiKey: key,
      issuerVersion: version,
    );

TenantCredentialSource source({
  Future<TenantCredential> Function()? renew,
  int? version,
  bool retain = false,
}) => TenantCredentialSource(
  serviceNamespace: 'https://gateway.test/api/v1/proxy/search_api',
  tenantId: 'T',
  expectedPrincipal: 'tenant-principal',
  initialKey: 'same-key',
  initialIssuerVersion: version,
  renew: renew,
  retainOnRenewalFailure: retain,
);

void main() {
  test('same tenant and key produce distinct permanently closed providers', () {
    final keys = source();
    var activeA = true;
    final a = keys.createProvider(isActive: () => activeA);
    expect(a.current(), 'same-key');
    activeA = false;
    a.close();
    final b = keys.createProvider(isActive: () => true);
    keys.install(credential('rotated-key'));
    expect(b.current(), 'rotated-key');
    expect(b.installedRevision, 1);
    expect(() => a.current(), throwsA(isA<OperationCanceled>()));
    expect(a.isClosed, isTrue);
    expect(() => a.rotate('reopened'), throwsA(isA<AuthException>()));
  });

  test(
    'normal renewals coalesce even when originating session closes',
    () async {
      final pending = Completer<TenantCredential>();
      var calls = 0;
      final keys = source(
        renew: () {
          calls++;
          return pending.future;
        },
      );
      final a = keys.createProvider(isActive: () => true);
      final first = keys.renewCredential();
      final second = keys.renewCredential();
      expect(identical(first, second), isTrue);
      a.close();
      final b = keys.createProvider(isActive: () => true);
      pending.complete(credential('next-key'));
      await Future.wait(<Future<TenantCredentialSnapshot>>[first, second]);
      expect(calls, 1);
      expect(b.current(), 'next-key');
      expect(a.isClosed, isTrue);
    },
  );

  test(
    'external install fences a pending renewal for the same app user',
    () async {
      final pending = Completer<TenantCredential>();
      final keys = source(renew: () => pending.future);
      final a = keys.createProvider(isActive: () => true);
      final renewal = keys.renewCredential();
      keys.install(credential('external-new-key'));
      pending.complete(credential('stale-key'));
      expect((await renewal).apiKey, 'external-new-key');
      expect(keys.revision, 1);
      expect(a.current(), 'external-new-key');
    },
  );

  test(
    'superseded renewal cannot overwrite a newer out-of-order result',
    () async {
      final old = Completer<TenantCredential>();
      final newer = Completer<TenantCredential>();
      var calls = 0;
      final keys = source(
        renew: () => calls++ == 0 ? old.future : newer.future,
      );
      final first = keys.renewCredential();
      final second = keys.renewCredential(supersede: true);
      newer.complete(credential('newer-key'));
      await second;
      old.complete(credential('older-key'));
      await first;
      expect(keys.currentSnapshot.apiKey, 'newer-key');
      expect(keys.revision, 1);
    },
  );

  test('rotation during setup is installed before a new provider reads', () {
    final keys = source();
    final candidate = keys.createProvider(isActive: () => true);
    keys.install(credential('latest-key'));
    final next = keys.createProvider(isActive: () => true);
    expect(candidate.current(), 'latest-key');
    expect(next.current(), 'latest-key');
    expect(next.installedRevision, keys.revision);
  });

  test('binding and issuer version changes fail without replacing the key', () {
    final keys = source(version: 2);
    expect(
      () => keys.install(credential('wrong-key', tenant: 'other', version: 3)),
      throwsA(isA<TenantAuthException>()),
    );
    expect(
      () => keys.install(credential('older-key', version: 1)),
      throwsA(isA<TenantAuthException>()),
    );
    expect(
      () => keys.install(credential('different-key', version: 2)),
      throwsA(isA<TenantAuthException>()),
    );
    expect(
      () => keys.install(credential('missing-version')),
      throwsA(isA<TenantAuthException>()),
    );
    expect(keys.currentSnapshot.apiKey, 'same-key');
    expect(keys.revision, 0);
    keys.install(credential('new-key', version: 3));
    expect(keys.currentSnapshot.apiKey, 'new-key');
  });

  test(
    'synchronous renewal failure is classified and blocks without rollback',
    () async {
      final keys = source(
        renew: () => throw StateError('secret-issuer-message'),
      );
      final a = keys.createProvider(isActive: () => true);
      await expectLater(
        keys.renewCredential(),
        throwsA(
          isA<TenantAuthException>()
              .having(
                (TenantAuthException e) => e.details,
                'safe details',
                isNull,
              )
              .having((TenantAuthException e) => e.body, 'safe body', isNull),
        ),
      );
      expect(keys.revision, 0);
      expect(a.isClosed, isFalse);
      expect(() => a.current(), throwsA(isA<TenantAuthException>()));
      keys.install(credential('recovered'));
      expect(a.current(), 'recovered');
    },
  );

  test(
    'retaining an old key requires an explicit authoritative validity policy',
    () async {
      final keys = source(
        renew: () async => throw StateError('issuer failure'),
        retain: true,
      );
      await expectLater(
        keys.renewCredential(),
        throwsA(isA<TenantAuthException>()),
      );
      expect(keys.currentSnapshot.apiKey, 'same-key');
      expect(keys.revision, 0);
    },
  );

  test('revocation and retirement fence in-flight renewal results', () async {
    final pending = Completer<TenantCredential>();
    final keys = source(renew: () => pending.future);
    final provider = keys.createProvider(isActive: () => true);
    final renewal = keys.renewCredential();
    final assertion = expectLater(renewal, throwsA(isA<TenantAuthException>()));
    keys.revoke();
    pending.complete(credential('late-key'));
    await assertion;
    expect(() => provider.current(), throwsA(isA<TenantAuthException>()));
    keys.close();
    expect(provider.isClosed, isTrue);
    expect(
      () => keys.install(credential('reopened')),
      throwsA(isA<TenantAuthException>()),
    );
  });

  test(
    'no resolver and stale 401 leave a committed newer revision intact',
    () async {
      final keys = source();
      await expectLater(keys.recover(0), throwsA(isA<TenantAuthException>()));
      expect(keys.isAvailable, isTrue);
      keys.install(credential('current-key'));
      expect((await keys.recover(0)).apiKey, 'current-key');
      expect(keys.isAvailable, isTrue);
      expect(
        '$keys ${keys.currentSnapshot} ${credential('hidden')}',
        isNot(contains('current-key')),
      );
    },
  );
}
