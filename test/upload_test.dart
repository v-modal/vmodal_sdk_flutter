import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

import 'fakes.dart';

void main() {
  test('upload source is reopenable and range exact', () async {
    var opens = 0;
    final source = UploadSource(
      fileName: 'a.mp4',
      contentLength: 6,
      sourceId: 'stable-a',
      opener: () {
        opens++;
        return Stream<List<int>>.fromIterable(<List<int>>[
          <int>[0, 1, 2],
          <int>[3, 4, 5],
        ]);
      },
    );
    Future<List<int>> read(int offset, int length) => source
        .open(offset: offset, length: length)
        .expand((List<int> x) => x)
        .toList();
    expect(await read(2, 3), <int>[2, 3, 4]);
    expect(await read(0, 6), <int>[0, 1, 2, 3, 4, 5]);
    expect(opens, 2);
  });

  test('premature source EOF is an error', () async {
    final source = UploadSource(
      fileName: 'a.mp4',
      contentLength: 4,
      sourceId: 'short-a',
      opener: () => Stream<List<int>>.value(<int>[1, 2]),
    );
    await expectLater(
      source.open().drain<void>(),
      throwsA(isA<TransportException>()),
    );
  });

  test(
    'signed single upload streams, isolates headers, then finalizes',
    () async {
      final api = FakeTransport()
        ..addResponse(
          jsonResponse(
            '{"url":"https://objects.test/u","method":"PUT","key":"k"}',
          ),
        )
        ..addResponse(jsonResponse('{"dest_path":"done/a.mp4"}'));
      final signed = FakeSignedUploadTransport()
        ..queued.add(const SignedUploadResult(statusCode: 200, etag: 'etag-a'));
      final client = VmodalClient(
        config: SdkConfig(baseUrl: 'https://gateway.test', token: 'secret-key'),
        transport: api,
        signedUploadTransport: signed,
      );
      final source = UploadSource(
        fileName: 'a.mp4',
        contentLength: 4,
        sourceId: 'source-a',
        opener: () => Stream<List<int>>.fromIterable(<List<int>>[
          <int>[1, 2],
          <int>[3, 4],
        ]),
      );
      final task = client.collections.videoUpload(
        source,
        collectionName: 'g',
        subCollectionName: 's',
      );
      final progress = <int>[];
      final sub = task.progress.listen(
        (UploadProgress value) => progress.add(value.uploadedBytes),
      );
      final result = await task.result;
      await sub.cancel();
      expect(result.uploaded, isTrue);
      expect(result.uploadStrategy, 'single');
      expect(result.destPath, 'done/a.mp4');
      expect(progress, <int>[2, 4]);
      expect(signed.calls.single.headers, isEmpty);
      expect(signed.calls.single.url.host, 'objects.test');
      expect(api.requests, hasLength(2));
      expect(api.requests.last.method, 'POST');
    },
  );

  test(
    'cancel before upload produces exactly one canceled terminal state',
    () async {
      final wait = Completer<void>();
      final api = HandlerTransport((VmodalRequest request) async {
        await wait.future;
        request.cancellation.throwIfCanceled();
        return jsonResponse('{}');
      });
      final client = VmodalClient(
        config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
        transport: api,
        signedUploadTransport: FakeSignedUploadTransport(),
      );
      final task = client.collections.videoUpload(
        UploadSource(
          fileName: 'a.mp4',
          contentLength: 1,
          sourceId: 'source-a',
          opener: () => Stream<List<int>>.value(<int>[1]),
        ),
        collectionName: 'g',
        subCollectionName: 's',
      );
      task.cancel();
      wait.complete();
      await expectLater(task.result, throwsA(isA<OperationCanceled>()));
      expect(task.state, UploadTaskState.canceled);
    },
  );

  test('bulk results retain input order under bounded work', () async {
    final api = FakeTransport();
    for (var i = 0; i < 3; i++) {
      api
        ..addResponse(
          jsonResponse(
            '{"url":"https://objects.test/$i","method":"PUT","key":"k$i"}',
          ),
        )
        ..addResponse(jsonResponse('{"dest_path":"done/$i"}'));
    }
    final signed = FakeSignedUploadTransport();
    final client = VmodalClient(
      config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
      transport: api,
      signedUploadTransport: signed,
    );
    final sources = List<UploadSource>.generate(
      3,
      (int index) => UploadSource(
        fileName: '$index.mp4',
        contentLength: 1,
        sourceId: 'source-$index',
        opener: () => Stream<List<int>>.value(<int>[index]),
      ),
    );
    final result = await client.collections
        .videoUploadBulk(
          sources,
          collectionName: 'g',
          subCollectionName: 's',
          options: const VideoUploadOptions(maxConcurrency: 1),
        )
        .result;
    expect(result.data.map((VideoUploadResponse row) => row.fileName), <String>[
      '0.mp4',
      '1.mp4',
      '2.mp4',
    ]);
    expect(signed.maxActive, 1);
  });
}
