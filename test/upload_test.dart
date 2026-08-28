import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
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
    'file source opens exact full, offset, final, and empty ranges',
    () async {
      final dir = await Directory.systemTemp.createTemp('vmodal-source-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/a.mp4');
      await file.writeAsBytes(<int>[0, 1, 2, 3, 4, 5, 6], flush: true);
      final source = UploadSource.fromFile(file);

      Future<List<int>> read(int offset, int length) => source
          .open(offset: offset, length: length)
          .expand((List<int> value) => value)
          .toList();

      expect(await read(0, 7), <int>[0, 1, 2, 3, 4, 5, 6]);
      expect(await read(2, 3), <int>[2, 3, 4]);
      expect(await read(5, 2), <int>[5, 6]);
      expect(await read(7, 0), isEmpty);
    },
  );

  test('custom source keeps a defensive snapshot of mutable chunks', () async {
    final bytes = Uint8List.fromList(<int>[1, 2, 3, 4]);
    final source = UploadSource(
      fileName: 'a.mp4',
      contentLength: bytes.length,
      opener: () => Stream<List<int>>.value(bytes),
    );
    final chunk = await source.open().single;
    bytes.fillRange(0, bytes.length, 9);
    expect(chunk, <int>[1, 2, 3, 4]);
  });

  test('file source rejects truncation after source creation', () async {
    final dir = await Directory.systemTemp.createTemp('vmodal-source-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/a.mp4');
    await file.writeAsBytes(<int>[0, 1, 2, 3], flush: true);
    final source = UploadSource.fromFile(file);
    await file.writeAsBytes(<int>[0, 1], flush: true);
    await expectLater(
      source.open().drain<void>(),
      throwsA(isA<TransportException>()),
    );
  });

  test('progress gate emits first, byte, time, and terminal events', () {
    var elapsed = 0;
    final gate = UploadProgressGate(monotonicMilliseconds: () => elapsed);
    final emitted = <int>[];

    void add(int value) {
      final progress = gate.next(UploadProgress(value, 1000));
      if (progress != null) emitted.add(progress.uploadedBytes);
    }

    add(1);
    add(5);
    elapsed = 250;
    add(6);
    add(16);
    add(15);
    add(1000);
    add(1000);
    expect(emitted, <int>[1, 6, 16, 1000]);
  });

  test(
    'IO signed transport streams exact bytes with integrity progress',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final received = Completer<List<int>>();
      server.listen((HttpRequest request) async {
        final bytes = await request.fold<List<int>>(
          <int>[],
          (List<int> out, List<int> chunk) => out..addAll(chunk),
        );
        received.complete(bytes);
        request.response.headers.set('etag', md5.convert(bytes).toString());
        await request.response.close();
      });
      final source = UploadSource(
        fileName: 'a.mp4',
        contentLength: 5,
        opener: () => Stream<List<int>>.fromIterable(<List<int>>[
          <int>[1, 2],
          <int>[3, 4, 5],
        ]),
      );
      final transport = IoSignedUploadTransport(const Duration(seconds: 2));
      addTearDown(transport.close);
      final progress = <int>[];
      final result = await transport.upload(
        source: source,
        url: Uri.parse('http://127.0.0.1:${server.port}/upload'),
        cancellation: CancellationToken(),
        onProgress: (UploadProgress value) {
          progress.add(value.uploadedBytes);
        },
      );
      expect(await received.future, <int>[1, 2, 3, 4, 5]);
      expect(result.localMd5, md5.convert(<int>[1, 2, 3, 4, 5]).toString());
      expect(result.etag, result.localMd5);
      expect(progress, <int>[2, 5]);
    },
  );

  test(
    'IO signed transport aborts an awaited body stream on cancellation',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((HttpRequest request) async {
        await request.drain<void>();
        await request.response.close();
      });
      final source = UploadSource(
        fileName: 'a.mp4',
        contentLength: 4,
        opener: () async* {
          yield <int>[1, 2];
          await Future<void>.delayed(const Duration(milliseconds: 50));
          yield <int>[3, 4];
        },
      );
      final token = CancellationToken();
      final transport = IoSignedUploadTransport(const Duration(seconds: 2));
      addTearDown(transport.close);
      await expectLater(
        transport.upload(
          source: source,
          url: Uri.parse('http://127.0.0.1:${server.port}/upload'),
          cancellation: token,
          onProgress: (_) => token.cancel(),
        ),
        throwsA(isA<OperationCanceled>()),
      );
    },
  );

  test('IO signed timeout keeps full sent-byte and digest metadata', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((HttpRequest request) async {
      await request.drain<void>();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await request.response.close();
    });
    final source = UploadSource(
      fileName: 'a.mp4',
      contentLength: 4,
      opener: () => Stream<List<int>>.value(<int>[1, 2, 3, 4]),
    );
    final transport = IoSignedUploadTransport(const Duration(milliseconds: 20));
    addTearDown(transport.close);
    await expectLater(
      transport.upload(
        source: source,
        url: Uri.parse('http://127.0.0.1:${server.port}/upload'),
        cancellation: CancellationToken(),
      ),
      throwsA(
        isA<SignedUploadFailure>()
            .having((SignedUploadFailure error) => error.sentBytes, 'sent', 4)
            .having(
              (SignedUploadFailure error) => error.localMd5,
              'md5',
              md5.convert(<int>[1, 2, 3, 4]).toString(),
            ),
      ),
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

  test('single-upload bulk shares one signed network budget', () async {
    final api = HandlerTransport((VmodalRequest request) async {
      if (request.uri.path.endsWith(Routes.externalUploadGetSignedUrl)) {
        final name = request.uri.queryParameters['filename'];
        return jsonResponse(
          '{"url":"https://objects.test/$name","method":"PUT","key":"$name"}',
        );
      }
      if (request.uri.path.endsWith(Routes.externalUploadDone)) {
        return jsonResponse('{"dest_path":"done"}');
      }
      throw StateError('unexpected route: ${request.uri.path}');
    });
    final signed = FakeSignedUploadTransport()
      ..delay = const Duration(milliseconds: 10);
    final client = VmodalClient(
      config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
      transport: api,
      signedUploadTransport: signed,
    );
    final sources = List<UploadSource>.generate(
      5,
      (int index) => UploadSource(
        fileName: '$index.mp4',
        contentLength: 1,
        sourceId: 'source-$index',
        opener: () => Stream<List<int>>.value(<int>[index]),
      ),
    );
    await client.collections
        .videoUploadBulk(
          sources,
          collectionName: 'g',
          subCollectionName: 's',
          options: const VideoUploadOptions(maxConcurrency: 2),
        )
        .result;
    expect(signed.maxActive, 2);
  });
}
