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
        expect(request.uri.queryParametersAll['metadata_tags'], <String>[
          'tag1',
          'tag2',
        ]);
        expect(request.uri.queryParameters['video_filename'], 'public.mp4');
        return jsonResponse(
          '{"dest_path":"done/public.mp4",'
          '"video_filename":"public.mp4",'
          '"start_datetime_user":"2026-07-30T09:15:00+09:00",'
          '"start_ts_unix_user_ms":1785370500000,'
          '"timestamp_source":"user"}',
        );
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
      config: SdkConfig(
        baseUrl: 'https://gateway.test',
        token: 'key',
        maxRetries: 0,
      ),
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
            videoFilename: 'public.mp4',
            metadataText: '',
            metadataTags: const <String>['tag1', 'tag2'],
            startDatetimeUser: '2026-07-30T09:15:00+09:00',
          ),
        )
        .result;
    expect(result.uploadStrategy, 'multipart');
    expect(result.partCount, 2);
    expect(result.destPath, 'done/public.mp4');
    expect(result.videoFilename, 'public.mp4');
    expect(result.startTsUnixUserMs, 1785370500000);
    expect(statusCalls, 2);
  });

  test(
    'completed multipart resume finalizes with the same CCTV fields',
    () async {
      const mib = 1024 * 1024;
      final source = UploadSource(
        fileName: 'camera.mp4',
        contentLength: 6 * mib,
        sourceId: 'resume-cctv',
        versionTag: 'v1',
        opener: () => _bytes(6 * mib, 8),
      );
      final store = MemoryUploadSessionStore();
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
            return jsonResponse('{"detail":"temporary"}', status: 500);
          }
          return jsonResponse(
            '{"status":"completed","etag":"done-etag",'
            '"size_bytes":${6 * mib}}',
          );
        }
        if (path.endsWith(Routes.externalUploadDone)) {
          expect(request.uri.queryParameters['video_filename'], 'camera.mp4');
          expect(request.uri.queryParametersAll['metadata_tags'], <String>[
            'tag1',
            'tag2',
            'tag3',
          ]);
          return jsonResponse(
            '{"video_filename":"camera.mp4",'
            '"start_datetime_user":"2026-07-30T09:15:00+09:00",'
            '"start_ts_unix_user_ms":1785370500000,'
            '"timestamp_source":"user"}',
          );
        }
        throw StateError('unexpected route: $path');
      });
      final client = VmodalClient(
        config: SdkConfig(
          baseUrl: 'https://gateway.test',
          token: 'key',
          maxRetries: 0,
        ),
        transport: api,
        signedUploadTransport: FakeSignedUploadTransport(),
      );
      final options = VideoUploadOptions(
        multipart: true,
        partSizeBytes: 5 * mib,
        sessionStore: store,
        metadataTags: const <String>['tag1', 'tag2', 'tag3'],
        startDatetimeUser: '2026-07-30T09:15:00+09:00',
      );
      await expectLater(
        client.collections
            .videoUpload(
              source,
              collectionName: 'group',
              subCollectionName: 'stream',
              options: options,
            )
            .result,
        throwsA(isA<ApiException>()),
      );
      final result = await client.collections
          .videoUpload(
            source,
            collectionName: 'group',
            subCollectionName: 'stream',
            options: options,
          )
          .result;
      expect(result.resumed, isTrue);
      expect(result.videoFilename, 'camera.mp4');
      expect(result.startTsUnixUserMs, 1785370500000);
      expect(statusCalls, 2);
    },
  );

  test(
    'adaptive bulk multipart shares its conservative signed budget',
    () async {
      const mib = 1024 * 1024;
      final sources = List<UploadSource>.generate(
        2,
        (int index) => UploadSource(
          fileName: '$index.mp4',
          contentLength: 6 * mib,
          sourceId: 'source-$index',
          versionTag: 'v1',
          opener: () => _bytes(6 * mib, index + 1),
        ),
      );
      final digests = <String, List<String>>{};
      for (final source in sources) {
        digests[source.fileName] = <String>[
          await md5Hex(source, offset: 0, length: 5 * mib),
          await md5Hex(source, offset: 5 * mib, length: mib),
        ];
      }
      final statusCalls = <String, int>{};
      final api = HandlerTransport((VmodalRequest request) async {
        final path = request.uri.path;
        if (path.endsWith(Routes.externalUploadMultipartCreate)) {
          final body = request.jsonBody! as Map<String, Object?>;
          final name = '${body['filename']}';
          return jsonResponse(
            '{"request_id":"r-$name","upload_id":"$name","key":"k-$name",'
            '"part_count":2,"part_size_bytes":${5 * mib}}',
          );
        }
        if (path.endsWith(Routes.externalUploadMultipartStatus)) {
          final name = request.uri.queryParameters['upload_id']!;
          final count = (statusCalls[name] ?? 0) + 1;
          statusCalls[name] = count;
          if (count == 1) {
            return jsonResponse('{"status":"uploading","parts":[]}');
          }
          final md5s = digests[name]!;
          return jsonResponse(
            '{"status":"uploading","parts":['
            '{"part_number":1,"etag":"${md5s[0]}","size_bytes":${5 * mib}},'
            '{"part_number":2,"etag":"${md5s[1]}","size_bytes":$mib}]}',
          );
        }
        if (path.endsWith(Routes.externalUploadMultipartSignParts)) {
          final body = request.jsonBody! as Map<String, Object?>;
          final name = '${body['upload_id']}';
          final numbers = body['part_numbers']! as List<Object?>;
          final parts = numbers
              .map(
                (Object? number) =>
                    '{"part_number":$number,'
                    '"url":"https://objects.test/$name/$number",'
                    '"method":"PUT"}',
              )
              .join(',');
          return jsonResponse('{"parts":[$parts]}');
        }
        if (path.endsWith(Routes.externalUploadMultipartComplete)) {
          return jsonResponse('{"etag":"complete-etag"}');
        }
        if (path.endsWith(Routes.externalUploadDone)) {
          return jsonResponse('{"dest_path":"done"}');
        }
        throw StateError('unexpected route: $path');
      });
      final signed = FakeSignedUploadTransport()
        ..delay = const Duration(milliseconds: 10)
        ..sourceMd5 = true;
      final client = VmodalClient(
        config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
        transport: api,
        signedUploadTransport: signed,
      );
      final result = await client.collections
          .videoUploadBulk(
            sources,
            collectionName: 'g',
            subCollectionName: 's',
            options: VideoUploadOptions(
              multipart: true,
              maxConcurrency: 4,
              adaptiveConditions: const UploadConditions(
                deviceMemory: UploadDeviceMemory.low,
              ),
              sessionStore: MemoryUploadSessionStore(),
            ),
          )
          .result;
      expect(
        result.data.map((VideoUploadResponse item) => item.fileName),
        <String>['0.mp4', '1.mp4'],
      );
      expect(signed.maxActive, 1);
    },
  );

  test('bulk multipart rejects duplicate checkpoint contracts', () {
    const mib = 1024 * 1024;
    final source = UploadSource(
      fileName: 'a.mp4',
      contentLength: 6 * mib,
      sourceId: 'same-source',
      versionTag: 'v1',
      opener: () => _bytes(6 * mib, 1),
    );
    final client = VmodalClient(
      config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
      transport: FakeTransport(),
      signedUploadTransport: FakeSignedUploadTransport(),
    );
    expect(
      () => client.collections.videoUploadBulk(
        <UploadSource>[source, source],
        collectionName: 'g',
        subCollectionName: 's',
        options: const VideoUploadOptions(
          multipart: true,
          partSizeBytes: 5 * mib,
        ),
      ),
      throwsA(isA<ValidationException>()),
    );
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
