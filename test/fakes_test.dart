import 'package:flutter_test/flutter_test.dart';
import 'package:vmodal_sdk_flutter/src/transport.dart' show readBounded;
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

import 'fakes.dart';

void main() {
  test('queued fake records requests and preserves order', () async {
    final fake = FakeTransport()
      ..addResponse(jsonResponse('{"value":1}'))
      ..addError(const TransportException());
    final request = VmodalRequest(
      method: 'GET',
      uri: Uri.parse('https://example.test/a'),
    );
    expect((await fake.send(request)).statusCode, 200);
    await expectLater(fake.send(request), throwsA(isA<TransportException>()));
    expect(fake.requests, hasLength(2));
  });

  test('chunk fake preserves all bytes', () async {
    final response = jsonResponse('{"ok":true}', chunks: <int>[1, 2, 3]);
    final bytes = await readBounded(response, 100);
    expect(String.fromCharCodes(bytes), '{"ok":true}');
  });

  test('fake signed transport streams and records progress', () async {
    final fake = FakeSignedUploadTransport();
    final source = UploadSource(
      fileName: 'a.mp4',
      contentLength: 4,
      sourceId: 'source-a',
      opener: () => Stream<List<int>>.fromIterable(<List<int>>[
        <int>[1, 2],
        <int>[3, 4],
      ]),
    );
    final values = <int>[];
    await fake.upload(
      source: source,
      url: Uri.parse('https://objects.test/a'),
      cancellation: CancellationToken(),
      onProgress: (UploadProgress value) => values.add(value.uploadedBytes),
    );
    expect(values, <int>[2, 4]);
    expect(fake.calls, hasLength(1));
  });
}
