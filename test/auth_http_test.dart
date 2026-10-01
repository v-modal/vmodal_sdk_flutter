import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

import 'fakes.dart';

TenantCredential _credential(String key) => TenantCredential(
  serviceNamespace: 'https://gateway.test/api/v1/proxy/search_api',
  tenantId: 'T',
  principal: 'tenant-principal',
  apiKey: key,
);

TenantCredentialSource _source({Future<TenantCredential> Function()? renew}) =>
    TenantCredentialSource(
      serviceNamespace: 'https://gateway.test/api/v1/proxy/search_api',
      tenantId: 'T',
      expectedPrincipal: 'tenant-principal',
      initialKey: 'old-key',
      renew: renew,
    );

VmodalClient _tenantClient(
  TenantCredentialSource keys,
  VmodalTransport transport, {
  int retries = 0,
  TenantSessionApiKeyProvider? provider,
}) => VmodalClient(
  config: SdkConfig(
    baseUrl: 'https://gateway.test',
    apiKeyProvider: provider ?? keys.createProvider(isActive: () => true),
    maxRetries: retries,
  ),
  transport: transport,
  signedUploadTransport: FakeSignedUploadTransport(),
  delay: (_) async {},
);

void main() {
  test(
    'gateway request reads provider once and sends no identity headers',
    () async {
      final keys = CountingKeyProvider('old-key');
      final fake = FakeTransport()
        ..addResponse(jsonResponse('{"status":"ok"}'));
      final client = VmodalClient(
        config: SdkConfig(
          baseUrl: 'https://gateway.test',
          userId: 'spoof-user',
          tenantId: 'spoof-tenant',
          email: 'spoof@example.test',
          apiKeyProvider: keys,
        ),
        transport: fake,
        signedUploadTransport: FakeSignedUploadTransport(),
      );
      await client.health();
      expect(keys.reads, 1);
      final headers = fake.requests.single.headers;
      expect(headers['Authorization'], 'Bearer old-key');
      expect(
        headers.keys.map((String value) => value.toLowerCase()),
        isNot(contains('x-user-id')),
      );
      expect(
        headers.keys.map((String value) => value.toLowerCase()),
        isNot(contains('x-tenant-id')),
      );
    },
  );

  test('rotation validates before swap and clear fails closed', () {
    final keys = MutableApiKeyProvider('good-key');
    expect(() => keys.rotate('bad\nkey'), throwsA(isA<ValidationException>()));
    expect(keys.current(), 'good-key');
    keys.rotate('new-key');
    expect(keys.current(), 'new-key');
    keys.clear();
    expect(() => keys.current(), throwsA(isA<AuthException>()));
    keys.close();
    expect(() => keys.current(), throwsA(isA<AuthException>()));
  });

  test('GET retries retryable statuses but POST is sent once', () async {
    final getFake = FakeTransport()
      ..addResponse(jsonResponse('{"error":true}', status: 503))
      ..addResponse(jsonResponse('{"status":"ok"}'));
    final client = VmodalClient(
      config: SdkConfig(
        baseUrl: 'https://gateway.test',
        token: 'key',
        maxRetries: 1,
      ),
      transport: getFake,
      signedUploadTransport: FakeSignedUploadTransport(),
      delay: (_) async {},
    );
    await client.health();
    expect(getFake.requests, hasLength(2));

    final postFake = FakeTransport()
      ..addResponse(jsonResponse('{"error":true}', status: 503));
    final postClient = VmodalClient(
      config: SdkConfig(
        baseUrl: 'https://gateway.test',
        token: 'key',
        maxRetries: 5,
      ),
      transport: postFake,
      signedUploadTransport: FakeSignedUploadTransport(),
      delay: (_) async {},
    );
    await expectLater(
      postClient.searches.searchVideo(const SearchRequest(queryText: 'one')),
      throwsA(isA<ApiException>()),
    );
    expect(postFake.requests, hasLength(1));
  });

  test('401 and 422 map to typed redacted errors', () async {
    final fake = FakeTransport()
      ..addResponse(jsonResponse('{"secret":"body-sentinel"}', status: 401))
      ..addResponse(jsonResponse('{"detail":"bad"}', status: 422));
    final client = VmodalClient(
      config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
      transport: fake,
      signedUploadTransport: FakeSignedUploadTransport(),
    );
    Object? auth;
    try {
      await client.health();
    } on Object catch (error) {
      auth = error;
    }
    expect(auth, isA<AuthException>());
    expect('$auth', isNot(contains('body-sentinel')));
    await expectLater(
      client.searches.searchVideo(const SearchRequest(queryText: 'one')),
      throwsA(isA<ValidationException>()),
    );
  });

  test('unsafe direct requires identity and keeps branches separate', () {
    final fake = FakeTransport();
    final client = VmodalClient.unsafeDirect(
      baseUrl: 'http://localhost:4099',
      userId: 'trusted-user',
      transport: fake,
      signedUploadTransport: FakeSignedUploadTransport(),
    );
    expect(client.http.headers()['X-User-Id'], 'trusted-user');
    expect(client.http.headers(), isNot(contains('Authorization')));
    final missing = VmodalClient.unsafeDirect(
      baseUrl: 'http://localhost:4099',
      userId: '',
      transport: fake,
      signedUploadTransport: FakeSignedUploadTransport(),
    );
    expect(() => missing.http.headers(), throwsA(isA<AuthException>()));
  });

  test(
    'stale-key 401 reconstructs one read with the committed fresh headers',
    () async {
      final denied = Completer<VmodalResponse>();
      final keys = _source();
      final fake = HandlerTransport((VmodalRequest request) async {
        return request.headers['Authorization'] == 'Bearer old-key'
            ? denied.future
            : jsonResponse('{"status":"ok"}');
      });
      final client = _tenantClient(keys, fake);
      final read = client.health();
      keys.install(_credential('new-key'));
      denied.complete(jsonResponse('{"secret":"tenant-body"}', status: 401));
      await read;
      expect(fake.requests, hasLength(2));
      expect(fake.requests.first.headers['Authorization'], 'Bearer old-key');
      expect(fake.requests.last.headers['Authorization'], 'Bearer new-key');
      expect(keys.isAvailable, isTrue);
    },
  );

  test(
    'eligible read denied after renewal terminates with a safe tenant error',
    () async {
      var renewals = 0;
      final keys = _source(
        renew: () async {
          renewals++;
          return _credential('new-key');
        },
      );
      final fake = FakeTransport()
        ..addResponse(jsonResponse('{"secret":"raw-denial"}', status: 401))
        ..addResponse(jsonResponse('{"secret":"raw-denial"}', status: 401));
      final client = _tenantClient(keys, fake, retries: 10);
      await expectLater(
        client.health(),
        throwsA(
          isA<TenantAuthException>()
              .having((TenantAuthException e) => e.body, 'body', isNull)
              .having((TenantAuthException e) => e.details, 'details', isNull),
        ),
      );
      expect(renewals, 1);
      expect(fake.requests, hasLength(2));
      expect(keys.currentSnapshot.apiKey, 'new-key');
    },
  );

  test(
    'ordinary retries and one auth recovery have a shared finite budget',
    () async {
      final keys = _source(renew: () async => _credential('new-key'));
      final fake = FakeTransport()
        ..addResponse(jsonResponse('{}', status: 503))
        ..addResponse(jsonResponse('{}', status: 401))
        ..addResponse(jsonResponse('{}', status: 503));
      final client = _tenantClient(keys, fake, retries: 1);
      await expectLater(client.health(), throwsA(isA<ApiException>()));
      expect(fake.requests, hasLength(3));
      expect(fake.requests.first.headers['Authorization'], 'Bearer old-key');
      expect(fake.requests[1].headers['Authorization'], 'Bearer old-key');
      expect(fake.requests.last.headers['Authorization'], 'Bearer new-key');
    },
  );

  test(
    'mutations and 403 never obtain a broader credential or replay',
    () async {
      var renewals = 0;
      final keys = _source(
        renew: () async {
          renewals++;
          return _credential('new-key');
        },
      );
      final fake = FakeTransport()
        ..addResponse(jsonResponse('{}', status: 401))
        ..addResponse(jsonResponse('{"private":"denied"}', status: 403));
      final client = _tenantClient(keys, fake, retries: 5);
      await expectLater(
        client.searches.searchVideo(const SearchRequest(queryText: 'query')),
        throwsA(isA<TenantAuthException>()),
      );
      await expectLater(
        client.health(),
        throwsA(
          isA<ApiException>()
              .having((ApiException e) => e.statusCode, 'status', 403)
              .having((ApiException e) => e.body, 'body', isNull),
        ),
      );
      expect(fake.requests, hasLength(2));
      expect(renewals, 0);
    },
  );

  test(
    'closed session awaiting shared renewal dispatches no recovered read',
    () async {
      final pending = Completer<TenantCredential>();
      final started = Completer<void>();
      final keys = _source(
        renew: () {
          started.complete();
          return pending.future;
        },
      );
      var active = true;
      final provider = keys.createProvider(isActive: () => active);
      final fake = FakeTransport()
        ..addResponse(jsonResponse('{}', status: 401));
      final client = _tenantClient(keys, fake, provider: provider);
      final read = client.health();
      final failure = expectLater(read, throwsA(isA<OperationCanceled>()));
      await started.future;
      active = false;
      provider.close();
      final b = keys.createProvider(isActive: () => true);
      pending.complete(_credential('new-key'));
      await failure;
      expect(fake.requests, hasLength(1));
      expect(b.current(), 'new-key');
      expect(provider.isClosed, isTrue);
    },
  );

  test('concurrent read failures join one tenant renewal', () async {
    final pending = Completer<TenantCredential>();
    var renewals = 0;
    final keys = _source(
      renew: () {
        renewals++;
        return pending.future;
      },
    );
    final fake = FakeTransport()
      ..addResponse(jsonResponse('{}', status: 401))
      ..addResponse(jsonResponse('{}', status: 401))
      ..addResponse(jsonResponse('{"status":"ok"}'))
      ..addResponse(jsonResponse('{"status":"ok"}'));
    final client = _tenantClient(keys, fake);
    final first = client.health();
    final second = client.health();
    await Future<void>.delayed(Duration.zero);
    expect(renewals, 1);
    pending.complete(_credential('new-key'));
    await Future.wait(<Future<HealthResponse>>[first, second]);
    expect(fake.requests, hasLength(4));
    expect(
      fake.requests
          .skip(2)
          .map((VmodalRequest r) => r.headers['Authorization']),
      everyElement('Bearer new-key'),
    );
  });

  test('rotation preserves a successful in-flight mutation snapshot', () async {
    final response = Completer<VmodalResponse>();
    final keys = _source();
    var calls = 0;
    final fake = HandlerTransport(
      (_) => calls++ == 0
          ? response.future
          : Future<VmodalResponse>.value(jsonResponse('{}')),
    );
    final client = _tenantClient(keys, fake);
    final mutation = client.searches.searchVideo(
      const SearchRequest(queryText: 'query'),
    );
    keys.install(_credential('new-key'));
    response.complete(jsonResponse('{}'));
    await mutation;
    await client.health();
    expect(fake.requests.first.headers['Authorization'], 'Bearer old-key');
    expect(fake.requests.last.headers['Authorization'], 'Bearer new-key');
    expect(fake.requests, hasLength(2));
  });

  test(
    'authoritative revocation during retry delay blocks the next send',
    () async {
      final keys = _source();
      final fake = FakeTransport()
        ..addResponse(jsonResponse('{}', status: 503));
      final client = VmodalClient(
        config: SdkConfig(
          baseUrl: 'https://gateway.test',
          apiKeyProvider: keys.createProvider(isActive: () => true),
          maxRetries: 5,
        ),
        transport: fake,
        signedUploadTransport: FakeSignedUploadTransport(),
        delay: (_) async {
          keys.revoke();
        },
      );
      await expectLater(client.health(), throwsA(isA<TenantAuthException>()));
      expect(fake.requests, hasLength(1));
    },
  );

  test(
    'renewal failure blocks tenant calls without closing the app session',
    () async {
      final keys = _source(
        renew: () async => throw StateError('private-issuer-error'),
      );
      final provider = keys.createProvider(isActive: () => true);
      final fake = FakeTransport()
        ..addResponse(jsonResponse('{}', status: 401))
        ..addResponse(jsonResponse('{}'));
      final client = _tenantClient(keys, fake, provider: provider);
      await expectLater(client.health(), throwsA(isA<TenantAuthException>()));
      await expectLater(client.health(), throwsA(isA<TenantAuthException>()));
      expect(provider.isClosed, isFalse);
      expect(fake.requests, hasLength(1));
      keys.install(_credential('recovered-key'));
      await client.health();
      expect(
        fake.requests.last.headers['Authorization'],
        'Bearer recovered-key',
      );
    },
  );
}
