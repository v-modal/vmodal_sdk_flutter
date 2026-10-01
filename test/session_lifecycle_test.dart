import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

import 'fakes.dart';
import 'user_session_test.dart' as sessions;

class LifecycleTransport extends FakeTransport {
  LifecycleTransport(this.onClose);
  final Future<void> Function() onClose;

  @override
  Future<void> close() {
    closeCalls++;
    closed = true;
    return onClose();
  }
}

void main() {
  test(
    'transport ownership cannot be shared between session managers',
    () async {
      stdout.writeln(
        '[lifecycle] weak ownership tracking covers all session managers',
      );
      final config = SdkConfig(baseUrl: 'https://gateway.test');
      final source = TenantCredentialSource(
        serviceNamespace: SessionContext.serviceNamespaceFor(config),
        tenantId: 'same-tenant',
        expectedPrincipal: 'tenant-principal',
        initialKey: 'same-key',
      );
      final shared = FakeTransport()..addJson({'data': <Object?>[]});
      UserSessionManager manager() => UserSessionManager(
        config: config,
        credentialSource: source,
        transportFactory: (_) => shared,
        signedUploadTransportFactory: (_) => FakeSignedUploadTransport(),
      );
      final first = manager();
      final second = manager();
      final map = sessions.mapping('same');
      final a = await first.openResolvedSession(
        () async => sessions.policy('A', map),
      );
      await expectLater(
        second.openResolvedSession(() async => sessions.policy('B', map)),
        throwsA(isA<ValidationException>()),
      );
      expect(shared.closed, isFalse);
      await a.scope(map).search('A still owns this transport');
      await second.close();
      expect(shared.closed, isFalse);
      await first.close();
      expect(shared.closeCalls, 1);
    },
  );

  test(
    'factory reentry retires its candidate before creating another resource',
    () async {
      stdout.writeln(
        '[lifecycle] activation tickets fence synchronous factory reentry',
      );
      final config = SdkConfig(baseUrl: 'https://gateway.test');
      final source = TenantCredentialSource(
        serviceNamespace: SessionContext.serviceNamespaceFor(config),
        tenantId: 'same-tenant',
        expectedPrincipal: 'tenant-principal',
        initialKey: 'same-key',
      );
      late UserSessionManager manager;
      Future<UserSession>? newest;
      final gateways = <FakeTransport>[];
      final providers = <MutableApiKeyProvider>[];
      var signedCount = 0;
      manager = UserSessionManager(
        config: config,
        credentialSource: source,
        transportFactory: (bound) {
          final result = FakeTransport();
          gateways.add(result);
          providers.add(bound.apiKeyProvider! as MutableApiKeyProvider);
          if (gateways.length == 1) {
            newest = manager.openResolvedSession(
              () async => sessions.policy('C', sessions.mapping('C')),
            );
          }
          return result;
        },
        signedUploadTransportFactory: (_) {
          signedCount++;
          return FakeSignedUploadTransport();
        },
      );
      await expectLater(
        manager.openResolvedSession(
          () async => sessions.policy('A', sessions.mapping('A')),
        ),
        throwsA(isA<OperationCanceled>()),
      );
      final c = await newest!;
      expect(manager.current, same(c));
      expect(providers.first.isClosed, isTrue);
      expect(gateways.first.closed, isTrue);
      expect(gateways.last.closed, isFalse);
      expect(signedCount, 1);
      await manager.close();
    },
  );

  test(
    'provider is permanently closed before cancellation and host reentry',
    () async {
      stdout.writeln(
        '[lifecycle] internal retirement precedes every external callback',
      );
      final config = SdkConfig(baseUrl: 'https://gateway.test');
      final source = TenantCredentialSource(
        serviceNamespace: SessionContext.serviceNamespaceFor(config),
        tenantId: 'same-tenant',
        expectedPrincipal: 'tenant-principal',
        initialKey: 'same-key',
      );
      final pending = Completer<VmodalResponse>();
      late MutableApiKeyProvider provider;
      final dispatched = Completer<void>();
      var callbacks = 0;
      late UserSessionManager manager;
      Future<void>? reentered;
      manager = UserSessionManager(
        config: config,
        credentialSource: source,
        transportFactory: (bound) {
          provider = bound.apiKeyProvider! as MutableApiKeyProvider;
          return HandlerTransport((request) {
            request.cancellation.onCancel(() {
              expect(provider.isClosed, isTrue);
              expect(
                () => provider.current(),
                throwsA(isA<OperationCanceled>()),
              );
              callbacks++;
            });
            dispatched.complete();
            return pending.future;
          });
        },
        signedUploadTransportFactory: (_) => FakeSignedUploadTransport(),
        onInvalidated: (session) {
          expect(provider.isClosed, isTrue);
          expect(session.isActive, isFalse);
          reentered = manager.close();
        },
      );
      final map = sessions.mapping('A');
      final a = await manager.openResolvedSession(
        () async => sessions.policy('A', map),
      );
      final result = a.scope(map).search('private A');
      final canceled = expectLater(result, throwsA(isA<OperationCanceled>()));
      await dispatched.future;
      final closing = manager.close();
      expect(manager.close(), same(closing));
      expect(reentered, same(closing));
      expect(callbacks, 1);
      await canceled;
      await closing;
      pending.completeError(
        const ApiException('private A', body: 'private body'),
      );
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'both closes start before host notification and slow gateway completion',
    () async {
      stdout.writeln(
        '[lifecycle] slow outgoing gateway cannot delay signed transport close',
      );
      final config = SdkConfig(baseUrl: 'https://gateway.test');
      final source = TenantCredentialSource(
        serviceNamespace: SessionContext.serviceNamespaceFor(config),
        tenantId: 'same-tenant',
        expectedPrincipal: 'tenant-principal',
        initialKey: 'same-key',
      );
      final pending = Completer<void>();
      final gateway = LifecycleTransport(() => pending.future);
      final signed = FakeSignedUploadTransport();
      final manager = UserSessionManager(
        config: config,
        credentialSource: source,
        transportFactory: (_) => gateway,
        signedUploadTransportFactory: (_) => signed,
        onInvalidated: (_) {
          expect(gateway.closeCalls, 1);
          expect(signed.closeCalls, 1);
        },
      );
      final a = await manager.openResolvedSession(
        () async => sessions.policy('A', sessions.mapping('A')),
      );
      final closing = a.close();
      expect(a.close(), same(closing));
      expect(a.isActive, isFalse);
      expect(signed.closed, isTrue);
      pending.complete();
      await closing;
      await manager.close();
    },
  );

  test(
    'late failed teardown reports payload-free failure and leaves B usable',
    () async {
      stdout.writeln(
        '[lifecycle] raw teardown errors never cross into the next user',
      );
      final config = SdkConfig(baseUrl: 'https://gateway.test');
      final source = TenantCredentialSource(
        serviceNamespace: SessionContext.serviceNamespaceFor(config),
        tenantId: 'same-tenant',
        expectedPrincipal: 'tenant-principal',
        initialKey: 'same-key',
      );
      final failed = Completer<void>();
      final aGateway = LifecycleTransport(() => failed.future);
      final bGateway = FakeTransport()..addJson({'data': <Object?>[]});
      var count = 0;
      final signed = <FakeSignedUploadTransport>[];
      final manager = UserSessionManager(
        config: config,
        credentialSource: source,
        transportFactory: (_) => count++ == 0 ? aGateway : bGateway,
        signedUploadTransportFactory: (_) {
          final result = FakeSignedUploadTransport();
          signed.add(result);
          return result;
        },
        onInvalidated: (session) {
          if (session.context.appUserId == 'A') {
            throw const ApiException(
              'same-key',
              body: 'A private body',
              details: 'A cause',
            );
          }
        },
      );
      final map = sessions.mapping('shared');
      final a = await manager.openResolvedSession(
        () async => sessions.policy('A', map),
      );
      final b = await manager.openResolvedSession(
        () async => sessions.policy('B', map),
      );
      expect(signed.first.closed, isTrue);
      failed.completeError(
        const ApiException('same-key', body: 'A body', details: 'A cause'),
      );
      await Future<void>.delayed(Duration.zero);
      await expectLater(a.close(), throwsA(isA<TransportException>()));
      expect(manager.current, same(b));
      await b.scope(map).search('B');
      for (final error in [...a.cleanupErrors, ...manager.cleanupErrors]) {
        expect(error, isA<SdkException>());
        final safe = error as SdkException;
        expect(safe.body, isNull);
        expect(safe.details, isNull);
        expect(safe.toString(), isNot(contains('same-key')));
        expect(safe.toString(), isNot(contains('A body')));
      }
      expect(() => manager.cleanupErrors.clear(), throwsUnsupportedError);
      await manager.close();
    },
  );

  test(
    'synchronous gateway close failure still closes signed transport',
    () async {
      final config = SdkConfig(baseUrl: 'https://gateway.test');
      final source = TenantCredentialSource(
        serviceNamespace: SessionContext.serviceNamespaceFor(config),
        tenantId: 'same-tenant',
        expectedPrincipal: 'tenant-principal',
        initialKey: 'same-key',
      );
      final gateway = LifecycleTransport(
        () => throw StateError('same-key private A'),
      );
      final signed = FakeSignedUploadTransport();
      final manager = UserSessionManager(
        config: config,
        credentialSource: source,
        transportFactory: (_) => gateway,
        signedUploadTransportFactory: (_) => signed,
      );
      final a = await manager.openResolvedSession(
        () async => sessions.policy('A', sessions.mapping('A')),
      );
      final closing = a.close();
      expect(a.close(), same(closing));
      await expectLater(
        closing,
        throwsA(
          isA<TransportException>().having((e) => e.details, 'details', isNull),
        ),
      );
      expect(signed.closeCalls, 1);
      expect(a.isActive, isFalse);
      await manager.close();
    },
  );

  test(
    'caller cannot replace the captured tenant principal during verification',
    () async {
      final cfg = sessions.setup();
      final a = await cfg.manager.openResolvedSession(
        () async => sessions.policy('A', sessions.mapping('A')),
      );
      await expectLater(
        a.verifyPrincipal('other-principal'),
        throwsA(isA<ValidationException>()),
      );
      expect(cfg.apis.single.requests, isEmpty);
      cfg.apis.single.addJson({'user_id': 'other-principal'});
      await expectLater(
        a.verifyPrincipal('tenant-principal'),
        throwsA(isA<ValidationException>()),
      );
      expect(a.isActive, isTrue);
      await cfg.manager.close();
    },
  );

  test(
    'service namespace normalizes default ports and rejects URL adornments',
    () {
      expect(
        SessionContext.serviceNamespaceFor(
          SdkConfig(baseUrl: 'https://GATEWAY.test:443'),
        ),
        SessionContext.serviceNamespaceFor(
          SdkConfig(baseUrl: 'https://gateway.test'),
        ),
      );
      for (final suffix in ['?tenant=another', '#another']) {
        expect(
          () => SessionContext.serviceNamespaceFor(
            SdkConfig(baseUrl: 'https://gateway.test$suffix'),
          ),
          throwsA(isA<ValidationException>()),
        );
      }
    },
  );

  test(
    'session-owned storage barrier fences A to B to A publication',
    () async {
      final cfg = sessions.setup();
      final map = sessions.mapping('same');
      final oldA = await cfg.manager.openResolvedSession(
        () async => sessions.policy('A', map),
      );
      final writer = oldA.scope(map).storageLease;
      final pending = Completer<void>();
      final started = Completer<void>();
      final oldWrite = writer.run(() {
        started.complete();
        return pending.future;
      });
      final canceled = expectLater(oldWrite, throwsA(isA<OperationCanceled>()));
      await started.future;
      final b = await cfg.manager.openResolvedSession(
        () async => sessions.policy('B', map),
      );
      // The public storage operation settles without releasing the physical
      // commit barrier protecting a future generation of the same owner.
      await canceled.timeout(const Duration(seconds: 1));
      var bWrites = 0;
      await b.scope(map).storageLease.run(() async => bWrites++);
      final newA = await cfg.manager.openResolvedSession(
        () async => sessions.policy('A', map),
      );
      var newWrites = 0;
      final newWrite = newA
          .scope(map)
          .storageLease
          .run(() async => newWrites++);
      await Future<void>.delayed(Duration.zero);
      expect(bWrites, 1);
      expect(newWrites, 0);
      pending.complete();
      await newWrite;
      expect(newWrites, 1);
      expect(() => writer.check(), throwsA(isA<OperationCanceled>()));
      await cfg.manager.close();
    },
  );

  test(
    'video media derives exact wire modality and captured relative frame time',
    () async {
      stdout.writeln(
        '[media] proven file-video offset becomes a vid_img selector',
      );
      final cfg = sessions.setup();
      final map = sessions.mapping(
        'same',
        actions: {UserAction.search, UserAction.media},
      );
      final a = await cfg.manager.openResolvedSession(
        () async => sessions.policy('A', map),
      );
      cfg.apis.single.addJson({
        'data': [
          {
            'asset_id': 'a',
            'filename': 'a.mp4',
            'playback_offset_ms': 2300,
            'preview_image_url': 'https://another-user.test/private',
          },
          {
            'asset_id': 'invalid',
            'filename': 'a.mp4',
            'modality': 'img_raw',
            'ts_unix_13digits': 1000,
          },
          {'asset_id': 'no-time', 'filename': 'a.mp4'},
        ],
      });
      final hits = (await a.scope(map).search('a')).assets;
      cfg.apis.single.addJson({
        'found': true,
        'url_pre_signed': 'https://objects.test/scoped',
      });
      cfg.apis.single.addResponse(
        VmodalResponse(statusCode: 200, body: Stream.value([1])),
      );
      expect(await a.scope(map).imageBytes(hits.first), [1]);
      final body = cfg.apis.single.requests[1].jsonBody! as Map;
      expect(body['modality'], 'vid_img');
      expect(body['ts_unix_13digits'], '0000000002300');
      expect(
        (cfg.apis.single.requests.last.jsonBody! as Map)['url_pre_signed'],
        'https://objects.test/scoped',
      );
      expect(
        () => a.scope(map).imageBytes(hits[1]),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => a.scope(map).imageBytes(hits[2]),
        throwsA(isA<FeatureDisabled>()),
      );
      expect(cfg.apis.single.requests, hasLength(3));
      await cfg.manager.close();
    },
  );
}
