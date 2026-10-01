import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

import 'fakes.dart';

ContentMapping mapping(String collection, {Set<UserAction>? actions}) =>
    ContentMapping.opaque(
      collectionId: collection,
      streamName: 'camera',
      actions: actions ?? const <UserAction>{UserAction.search},
    );

UserSessionPolicy policy(String user, ContentMapping content) =>
    UserSessionPolicy(
      tenantId: 'same-tenant',
      appUserId: user,
      allowedContentMapping: <ContentMapping>[content],
    );

({
  UserSessionManager manager,
  TenantCredentialSource credentials,
  List<FakeTransport> apis,
  List<FakeSignedUploadTransport> signed,
})
setup() {
  final config = SdkConfig(baseUrl: 'https://gateway.test');
  final credentials = TenantCredentialSource(
    serviceNamespace: SessionContext.serviceNamespaceFor(config),
    tenantId: 'same-tenant',
    expectedPrincipal: 'tenant-principal',
    initialKey: 'same-key',
  );
  final apis = <FakeTransport>[];
  final signed = <FakeSignedUploadTransport>[];
  final manager = UserSessionManager(
    config: config,
    credentialSource: credentials,
    transportFactory: (_) {
      final api = FakeTransport();
      apis.add(api);
      return api;
    },
    signedUploadTransportFactory: (_) {
      final transport = FakeSignedUploadTransport();
      signed.add(transport);
      return transport;
    },
  );
  return (
    manager: manager,
    credentials: credentials,
    apis: apis,
    signed: signed,
  );
}

void main() {
  test(
    'owner identity preserves exact authenticated user characters',
    () async {
      final env = setup();
      addTearDown(env.manager.close);
      final content = mapping('shared-scope');
      final a = await env.manager.openResolvedSession(
        () async => policy('A', content),
      );
      final spaced = await env.manager.openResolvedSession(
        () async => policy(' A ', content),
      );
      expect(spaced.context.appUserId, ' A ');
      expect(spaced.context.ownerKey, isNot(a.context.ownerKey));
      expect(
        spaced.context.scopeKey(content),
        isNot(a.context.scopeKey(content)),
      );
    },
  );

  test(
    'reentrant invalidation callback can activate only its latest ticket',
    () async {
      stdout.writeln(
        '[user-session] callback reentry after synchronous invalidation',
      );
      final config = SdkConfig(baseUrl: 'https://gateway.test');
      final credentials = TenantCredentialSource(
        serviceNamespace: SessionContext.serviceNamespaceFor(config),
        tenantId: 'same-tenant',
        expectedPrincipal: 'tenant-principal',
        initialKey: 'same-key',
      );
      late UserSessionManager manager;
      Future<UserSession>? reentered;
      manager = UserSessionManager(
        config: config,
        credentialSource: credentials,
        transportFactory: (_) => FakeTransport(),
        signedUploadTransportFactory: (_) => FakeSignedUploadTransport(),
        onInvalidated: (session) {
          expect(session.isActive, isFalse);
          if (session.context.appUserId == 'A') {
            reentered = manager.openResolvedSession(
              () async => policy('C', mapping('C')),
            );
          }
        },
      );
      await manager.openResolvedSession(() async => policy('A', mapping('A')));
      await expectLater(
        manager.openResolvedSession(() async => policy('B', mapping('B'))),
        throwsA(isA<OperationCanceled>()),
      );
      final c = await reentered!;
      expect(manager.current, same(c));
      expect(c.context.appUserId, 'C');
      await manager.close();
    },
  );

  test(
    'same tenant key A/B switch invalidates A and rejects B selectors',
    () async {
      stdout.writeln(
        '[user-session] same tenant, same credential; distinct runtime ownership',
      );
      final cfg = setup();
      final aMap = mapping('A');
      final bMap = mapping('B');
      final a = await cfg.manager.openResolvedSession(
        () async => policy('A', aMap),
      );
      final scope = a.scope(aMap);
      expect(() => a.scope(bMap), throwsA(isA<ValidationException>()));
      final openingB = cfg.manager.openResolvedSession(
        () async => policy('B', bMap),
      );
      expect(a.isActive, isFalse);
      expect(() => scope.search('old'), throwsA(isA<OperationCanceled>()));
      final b = await openingB;
      expect(b.sessionId, isNot(a.sessionId));
      expect(b.context.ownerKey, isNot(a.context.ownerKey));
      cfg.apis.last.addJson(<String, Object?>{'data': <Object?>[]});
      await b.scope(bMap).search('new');
      expect(
        cfg.apis.last.requests.single.headers['Authorization'],
        'Bearer same-key',
      );
      expect(
        cfg.apis.last.requests.single.headers,
        isNot(contains('X-User-Id')),
      );
      expect(cfg.apis.first.requests, isEmpty);
      await cfg.manager.close();
    },
  );

  test('late activation cannot publish over the newer ticket', () async {
    stdout.writeln('[user-session] out-of-order host identity resolution');
    final cfg = setup();
    final pending = Completer<UserSessionPolicy>();
    final openingA = cfg.manager.openResolvedSession(() => pending.future);
    final rejection = expectLater(openingA, throwsA(isA<OperationCanceled>()));
    final b = await cfg.manager.openResolvedSession(
      () async => policy('B', mapping('B')),
    );
    pending.complete(policy('A', mapping('A')));
    await rejection;
    expect(cfg.manager.current, same(b));
    expect(cfg.apis, hasLength(1));
    await cfg.manager.close();
  });

  test(
    'late I/O is discarded promptly when custom transport ignores cancellation',
    () async {
      stdout.writeln(
        '[user-session] pending A response is never delivered after switch',
      );
      final response = Completer<VmodalResponse>();
      final config = SdkConfig(baseUrl: 'https://gateway.test');
      final credentials = TenantCredentialSource(
        serviceNamespace: SessionContext.serviceNamespaceFor(config),
        tenantId: 'same-tenant',
        expectedPrincipal: 'tenant-principal',
        initialKey: 'same-key',
      );
      var first = true;
      final manager = UserSessionManager(
        config: config,
        credentialSource: credentials,
        transportFactory: (_) {
          if (first) {
            first = false;
            return HandlerTransport((_) => response.future);
          }
          return FakeTransport();
        },
        signedUploadTransportFactory: (_) => FakeSignedUploadTransport(),
      );
      final map = mapping('same-selector');
      final a = await manager.openResolvedSession(() async => policy('A', map));
      final result = a.scope(map).search('private A');
      final rejected = expectLater(result, throwsA(isA<OperationCanceled>()));
      final b = await manager.openResolvedSession(() async => policy('B', map));
      await rejected.timeout(const Duration(seconds: 2));
      response.complete(jsonResponse('{"data":[{"private":"A"}]}'));
      await Future<void>.delayed(Duration.zero);
      expect(manager.current, same(b));
      expect(b.isActive, isTrue);
      await manager.close();
    },
  );

  test(
    'A to B to A keeps old generation retired and stable owner namespaces',
    () async {
      stdout.writeln(
        '[user-session] stable owner keys with fresh A generations',
      );
      final cfg = setup();
      final map = mapping('shared');
      final oldA = await cfg.manager.openResolvedSession(
        () async => policy('A', map),
      );
      final b = await cfg.manager.openResolvedSession(
        () async => policy('B', map),
      );
      final newA = await cfg.manager.openResolvedSession(
        () async => policy('A', map),
      );
      expect(oldA.isActive, isFalse);
      expect(b.isActive, isFalse);
      expect(newA.context.ownerKey, oldA.context.ownerKey);
      expect(newA.context.scopeKey(map), oldA.context.scopeKey(map));
      expect(newA.sessionId, isNot(oldA.sessionId));
      final closing = oldA.close();
      expect(oldA.close(), same(closing));
      await closing;
      expect(cfg.manager.current, same(newA));
      expect(cfg.apis.last.closed, isFalse);
      await cfg.manager.close();
    },
  );

  test(
    'caller policy and nested options are snapshotted before request dispatch',
    () async {
      stdout.writeln(
        '[user-session] immutable mappings and nested request options',
      );
      final cfg = setup();
      final actions = <UserAction>{UserAction.search};
      final map = mapping('opaque__unchanged', actions: actions);
      final mappings = <ContentMapping>[map];
      final opening = cfg.manager.openUserSession(
        tenantId: 'same-tenant',
        appUserId: 'A',
        allowedContentMapping: mappings,
      );
      mappings.clear();
      actions.clear();
      final session = await opening;
      final nested = <String, Object?>{
        'nested': <Object?>['before'],
      };
      final sources = <String>['asr'];
      cfg.apis.single.addJson(<String, Object?>{'data': <Object?>[]});
      final result = session
          .scope(map)
          .search(
            'query',
            options: ScopedSearchOptions(
              queryMetadata: nested,
              searchSources: sources,
            ),
          );
      (nested['nested']! as List<Object?>)[0] = 'after';
      sources.clear();
      await result;
      final request = cfg.apis.single.requests.single.jsonBody! as Map;
      expect(request['group_name'], 'opaque__unchanged');
      expect(request['query_metadata'], <String, Object?>{
        'nested': <Object?>['before'],
      });
      expect(request['search_sources'], <String>['asr']);
      await cfg.manager.close();
    },
  );

  test(
    'same tenant key rotation preserves session and uses new key for future requests',
    () async {
      stdout.writeln(
        '[user-session] tenant credential rotation keeps owner and scope stable',
      );
      final cfg = setup();
      final map = mapping('A');
      final session = await cfg.manager.openResolvedSession(
        () async => policy('A', map),
      );
      final owner = session.context.ownerKey;
      final generation = session.sessionId;
      cfg.credentials.install(
        TenantCredential(
          serviceNamespace: session.context.serviceNamespace,
          tenantId: 'same-tenant',
          principal: 'tenant-principal',
          apiKey: 'new-key',
        ),
      );
      cfg.apis.single.addJson(<String, Object?>{'data': <Object?>[]});
      await session.scope(map).search('after rotation');
      expect(session.context.ownerKey, owner);
      expect(session.sessionId, generation);
      expect(
        cfg.apis.single.requests.single.headers['Authorization'],
        'Bearer new-key',
      );
      await cfg.manager.close();
    },
  );

  test(
    'mode override and stream-only deletion reject before dispatch',
    () async {
      stdout.writeln(
        '[user-session] exact mode and collection-wide permission checks',
      );
      final cfg = setup();
      final map = mapping(
        'A',
        actions: <UserAction>{UserAction.search, UserAction.delete},
      );
      final session = await cfg.manager.openResolvedSession(
        () async => policy('A', map),
      );
      expect(
        () => session
            .scope(map)
            .search(
              'query',
              options: const ScopedSearchOptions(mode: 'img_file'),
            ),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => session.scope(map).deleteCollection(),
        throwsA(isA<ValidationException>()),
      );
      expect(cfg.apis.single.requests, isEmpty);
      await cfg.manager.close();
    },
  );

  test(
    'logout fences pending resolution and failed activation leaves manager empty',
    () async {
      stdout.writeln('[user-session] logout during host resolution');
      final cfg = setup();
      final pending = Completer<UserSessionPolicy>();
      final opening = cfg.manager.openResolvedSession(() => pending.future);
      final rejected = expectLater(opening, throwsA(isA<OperationCanceled>()));
      await cfg.manager.logout();
      pending.complete(policy('A', mapping('A')));
      await rejected;
      expect(cfg.manager.current, isNull);
      await expectLater(
        cfg.manager.openUserSession(
          tenantId: 'different',
          appUserId: 'A',
          allowedContentMapping: <ContentMapping>[mapping('A')],
        ),
        throwsA(isA<ValidationException>()),
      );
      expect(cfg.manager.current, isNull);
      await cfg.manager.close();
    },
  );
}
