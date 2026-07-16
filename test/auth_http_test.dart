import 'package:flutter_test/flutter_test.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

import 'fakes.dart';

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
}
