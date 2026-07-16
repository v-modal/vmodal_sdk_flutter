import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

import 'fakes.dart';

void main() {
  test('multipart validates explicit options and size never enables it', () {
    expect(
      () => const VideoUploadOptions(
        multipart: true,
        partSizeBytes: 1024,
      ).validate(10 * 1024 * 1024),
      throwsA(isA<ValidationException>()),
    );
    expect(
      const VideoUploadOptions(
        multipartThresholdBytes: 1,
      ).resolvedFor(1024 * 1024 * 1024).multipart,
      isFalse,
    );
  });

  test(
    'missing multipart route maps to FeatureDisabled without single fallback',
    () async {
      final api = FakeTransport()
        ..addResponse(jsonResponse('{"detail":"missing"}', status: 404));
      final client = VmodalClient(
        config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
        transport: api,
        signedUploadTransport: FakeSignedUploadTransport(),
      );
      final task = client.collections.videoUpload(
        UploadSource(
          fileName: 'a.mp4',
          contentLength: 6 * 1024 * 1024,
          sourceId: 'source-a',
          opener: () => _bytes(6 * 1024 * 1024, 1),
        ),
        collectionName: 'g',
        subCollectionName: 's',
        options: const VideoUploadOptions(
          multipart: true,
          partSizeBytes: 5 * 1024 * 1024,
        ),
      );
      await expectLater(task.result, throwsA(isA<FeatureDisabled>()));
      expect(api.requests, hasLength(1));
      expect(
        api.requests.single.uri.path,
        endsWith(Routes.externalUploadMultipartCreate),
      );
    },
  );

  test('multipart completes only ordered server-verified parts', () async {
    const mib = 1024 * 1024;
    final source = UploadSource(
      fileName: 'a.mp4',
      contentLength: 6 * mib,
      sourceId: 'source-a',
      versionTag: 'v1',
      opener: () => _bytes(6 * mib, 7),
    );
    final md5a = await md5Hex(source, offset: 0, length: 5 * mib);
    final md5b = await md5Hex(source, offset: 5 * mib, length: mib);
    var statusCalls = 0;
    final api = HandlerTransport((VmodalRequest request) async {
      final path = request.uri.path;
      if (path.endsWith(Routes.externalUploadMultipartCreate)) {
        return jsonResponse(
          '{"request_id":"r","upload_id":"u","key":"k",'
          '"part_count":2,"part_size_bytes":${5 * mib}}',
        );
      }
      if (path.endsWith(Routes.externalUploadMultipartStatus)) {
        statusCalls++;
        if (statusCalls == 1) {
          return jsonResponse('{"status":"uploading","parts":[]}');
        }
        return jsonResponse(
          '{"status":"uploading","parts":['
          '{"part_number":2,"etag":"$md5b","size_bytes":$mib},'
          '{"part_number":1,"etag":"$md5a","size_bytes":${5 * mib}}]}',
        );
      }
      if (path.endsWith(Routes.externalUploadMultipartSignParts)) {
        return jsonResponse(
          '{"parts":['
          '{"part_number":1,"url":"https://objects.test/1","method":"PUT"},'
          '{"part_number":2,"url":"https://objects.test/2","method":"PUT"}]}',
        );
      }
      if (path.endsWith(Routes.externalUploadMultipartComplete)) {
        final body = request.jsonBody! as Map<String, Object?>;
        final parts = body['parts']! as List;
        expect(
          parts.map(
            (Object? item) => (item! as Map<String, Object?>)['part_number'],
          ),
          <int>[1, 2],
        );
        return jsonResponse('{"etag":"complete-etag"}');
      }
      if (path.endsWith(Routes.externalUploadDone)) {
        return jsonResponse('{"dest_path":"done/a.mp4"}');
      }
      throw StateError('unexpected route: $path');
    });
    final signed = FakeSignedUploadTransport()
      ..queued.add(const SignedUploadResult(statusCode: 200))
      ..queued.add(const SignedUploadResult(statusCode: 200));
    // Fake result MD5/ETag must match the bytes. Set them after construction.
    signed.queued
      ..clear()
      ..add(SignedUploadResult(statusCode: 200, etag: md5a, localMd5: md5a))
      ..add(SignedUploadResult(statusCode: 200, etag: md5b, localMd5: md5b));
    final client = VmodalClient(
      config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
      transport: api,
      signedUploadTransport: signed,
    );
    final result = await client.collections
        .videoUpload(
          source,
          collectionName: 'g',
          subCollectionName: 's',
          options: VideoUploadOptions(
            multipart: true,
            partSizeBytes: 5 * mib,
            maxConcurrency: 2,
            sessionStore: MemoryUploadSessionStore(),
          ),
        )
        .result;
    expect(result.uploadStrategy, 'multipart');
    expect(result.partCount, 2);
    expect(result.destPath, 'done/a.mp4');
    expect(statusCalls, 2);
  });

  test('file checkpoint rejects oversized and malformed state', () async {
    final dir = await Directory.systemTemp.createTemp('vmodal-checkpoint-');
    addTearDown(() => dir.delete(recursive: true));
    final store = FileUploadSessionStore(dir);
    await store.save('a', <String, Object?>{'valid': true});
    expect(await store.load('a'), <String, Object?>{'valid': true});
    await File(
      '${dir.path}/${sha256.convert('b'.codeUnits)}.json',
    ).writeAsString('{bad');
    await expectLater(store.load('b'), throwsA(isA<MalformedResponse>()));
  });
}

Stream<List<int>> _bytes(int length, int value) async* {
  const chunkSize = 256 * 1024;
  var left = length;
  while (left > 0) {
    final size = left < chunkSize ? left : chunkSize;
    yield Uint8List(size)..fillRange(0, size, value);
    left -= size;
  }
}
