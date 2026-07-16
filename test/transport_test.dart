import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vmodal_sdk_flutter/src/http.dart';
import 'package:vmodal_sdk_flutter/src/transport.dart' show readBounded;
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

import 'fakes.dart';

void main() {
  test(
    'bounded reader accepts exact limit and rejects limit plus one',
    () async {
      final exact = VmodalResponse(
        statusCode: 200,
        contentLength: 4,
        body: Stream<List<int>>.value(<int>[1, 2, 3, 4]),
      );
      expect(
        await readBounded(exact, 4),
        Uint8List.fromList(<int>[1, 2, 3, 4]),
      );
      final token = CancellationToken();
      final overflow = VmodalResponse(
        statusCode: 200,
        contentLength: -1,
        body: Stream<List<int>>.fromIterable(<List<int>>[
          <int>[1, 2],
          <int>[3, 4, 5],
          <int>[6, 7],
        ]),
      );
      await expectLater(
        readBounded(overflow, 4, cancellation: token),
        throwsA(isA<ResponseTooLarge>()),
      );
      expect(token.isCanceled, isTrue);
    },
  );

  test('declared overflow fails before stream consumption', () async {
    var listened = false;
    final response = VmodalResponse(
      statusCode: 200,
      contentLength: 10,
      body: Stream<List<int>>.multi((MultiStreamController<List<int>> out) {
        listened = true;
        out.add(<int>[1]);
        unawaited(out.close());
      }),
    );
    await expectLater(
      readBounded(response, 4),
      throwsA(isA<ResponseTooLarge>()),
    );
    expect(listened, isFalse);
  });

  test('strict JSON rejects malformed and wrong top-level shapes', () async {
    final malformed = FakeTransport()..addResponse(jsonResponse('{"broken":'));
    final http = VmodalHttp(
      SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
      malformed,
    );
    await expectLater(
      http.request('GET', '/api/external/v1/health'),
      throwsA(isA<MalformedResponse>()),
    );
    final list = FakeTransport()..addResponse(jsonResponse('[]'));
    final listHttp = VmodalHttp(
      SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
      list,
    );
    await expectLater(
      listHttp.request('GET', '/api/external/v1/health'),
      throwsA(isA<MalformedResponse>()),
    );
  });

  test('canceling one response does not affect a concurrent request', () async {
    final firstReady = Completer<void>();
    final releaseSecond = Completer<void>();
    var calls = 0;
    final fake = HandlerTransport((VmodalRequest request) async {
      calls++;
      if (calls == 1) {
        firstReady.complete();
        return VmodalResponse(
          statusCode: 200,
          contentLength: -1,
          body: Stream<List<int>>.periodic(
            const Duration(milliseconds: 1),
            (_) => <int>[123],
          ),
        );
      }
      await releaseSecond.future;
      return jsonResponse('{"status":"ok"}');
    });
    final http = VmodalHttp(
      SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
      fake,
    );
    final token = CancellationToken();
    final one = http.request(
      'GET',
      '/api/external/v1/one',
      cancellation: token,
    );
    await firstReady.future;
    final two = http.request('GET', '/api/external/v1/two');
    token.cancel();
    releaseSecond.complete();
    await expectLater(one, throwsA(isA<OperationCanceled>()));
    expect((await two)['status'], 'ok');
  });
}
