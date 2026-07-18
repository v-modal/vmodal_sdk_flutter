import 'package:flutter_test/flutter_test.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

import 'fakes.dart';

void main() {
  test('fromEnvironment transfers bootstrap transport ownership', () async {
    final api = FakeTransport()
      ..addResponse(
        jsonResponse(
          '{"user_id":"user-1","tenant_id":"tenant-1",'
          '"email":"user@example.test"}',
        ),
      );
    final signed = FakeSignedUploadTransport();

    final client = await VmodalClient.fromEnvironment(
      const <String, String>{'VMODAL_API_KEY': 'key'},
      transport: api,
      signedUploadTransport: signed,
    );

    expect(identical(client.transport, api), isTrue);
    expect(identical(client.signedUploadTransport, signed), isTrue);
    expect(client.config.normalizedUserId, 'user-1');
    expect(api.closeCalls, 0);
    expect(signed.closeCalls, 0);

    await client.close();
    await client.close();
    expect(api.closeCalls, 1);
    expect(signed.closeCalls, 1);
  });

  test('fromEnvironment closes transports when user ID is missing', () async {
    final api = FakeTransport()
      ..addResponse(jsonResponse('{"email":"user@example.test"}'));
    final signed = FakeSignedUploadTransport();

    await expectLater(
      VmodalClient.fromEnvironment(
        const <String, String>{'VMODAL_API_KEY': 'key'},
        transport: api,
        signedUploadTransport: signed,
      ),
      throwsA(isA<AuthException>()),
    );

    expect(api.closeCalls, 1);
    expect(signed.closeCalls, 1);
  });

  test('fromEnvironment closes transports when auth throws', () async {
    final api = FakeTransport()..addError(const TransportException());
    final signed = FakeSignedUploadTransport();

    await expectLater(
      VmodalClient.fromEnvironment(
        const <String, String>{
          'VMODAL_API_KEY': 'key',
          'VMODAL_MAX_RETRIES': '0',
        },
        transport: api,
        signedUploadTransport: signed,
      ),
      throwsA(isA<TransportException>()),
    );

    expect(api.closeCalls, 1);
    expect(signed.closeCalls, 1);
  });
}
