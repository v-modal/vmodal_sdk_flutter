import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

import 'fakes.dart';

int searchIndex(VmodalRequest request) {
  final body = request.jsonBody! as Map<String, Object?>;
  return int.parse((body['query_text']! as String).split('-').last);
}

VmodalResponse searchResponse(int index) =>
    jsonResponse('{"data":[],"cnt_actual":$index,"cnt_total":$index}');

void main() {
  test(
    'search serialization preserves exact defaults and snake case',
    () async {
      final fake = FakeTransport()
        ..addResponse(jsonResponse('{"data":[],"cnt_actual":0,"cnt_total":0}'));
      final client = VmodalClient(
        config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
        transport: fake,
        signedUploadTransport: FakeSignedUploadTransport(),
      );
      await client.searches.searchVideo(const SearchRequest(queryText: 'bike'));
      final request = fake.requests.single;
      expect(request.method, 'POST');
      expect(request.uri.path, endsWith('/api/external/v1/search'));
      final body = request.jsonBody! as Map<String, Object?>;
      expect(body['query_text'], 'bike');
      expect(body['group_name'], 'agroup');
      expect(body['stream_name'], 'astream');
      expect(body['search_sources'], <String>['ocr', 'asr', 'image']);
      expect(body, isNot(contains('user_id')));
    },
  );

  test('batch search preserves input order after mixed completion', () async {
    final started = Completer<void>();
    final gates = List<Completer<void>>.generate(3, (_) => Completer<void>());
    var calls = 0;
    final fake = HandlerTransport((VmodalRequest _) async {
      final index = calls;
      calls++;
      if (calls == 3) started.complete();
      await gates[index].future;
      return searchResponse(index);
    });
    final client = VmodalClient(
      config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
      transport: fake,
      signedUploadTransport: FakeSignedUploadTransport(),
    );
    final future = client.searches.searchBatch(
      List<SearchRequest>.generate(
        3,
        (_) => const SearchRequest(queryText: 'duplicate'),
      ),
      batchSize: 1,
      nWorker: 3,
    );
    await started.future;
    gates[2].complete();
    gates[0].complete();
    gates[1].complete();
    final results = await future;
    expect(results.map((SearchResponse value) => value.cntActual), <int>[
      0,
      1,
      2,
    ]);
  });

  test('batch search keeps worker concurrency at or below nWorker', () async {
    final started = List<Completer<void>>.generate(
      11,
      (_) => Completer<void>(),
    );
    final gates = List<Completer<void>>.generate(11, (_) => Completer<void>());
    var active = 0;
    var maxActive = 0;
    final fake = HandlerTransport((VmodalRequest request) async {
      final index = searchIndex(request);
      active++;
      if (active > maxActive) maxActive = active;
      started[index].complete();
      try {
        await gates[index].future;
        return searchResponse(index);
      } finally {
        active--;
      }
    });
    final client = VmodalClient(
      config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
      transport: fake,
      signedUploadTransport: FakeSignedUploadTransport(),
    );
    final future = client.searches.searchBatch(
      List<SearchRequest>.generate(
        11,
        (int index) => SearchRequest(queryText: 'query-$index'),
      ),
      batchSize: 2,
      nWorker: 3,
    );

    await Future.wait(<Future<void>>[
      started[0].future,
      started[2].future,
      started[4].future,
    ]);
    gates[0].complete();
    gates[2].complete();
    gates[4].complete();
    await Future.wait(<Future<void>>[
      started[1].future,
      started[3].future,
      started[5].future,
    ]);
    gates[1].complete();
    gates[3].complete();
    gates[5].complete();
    await Future.wait(<Future<void>>[
      started[6].future,
      started[8].future,
      started[10].future,
    ]);
    gates[6].complete();
    gates[8].complete();
    gates[10].complete();
    await Future.wait(<Future<void>>[started[7].future, started[9].future]);
    gates[7].complete();
    gates[9].complete();
    expect(await future, hasLength(11));
    expect(maxActive, 3);
  });

  test('batch search executes each worker mini-batch serially', () async {
    final started = List<Completer<void>>.generate(4, (_) => Completer<void>());
    final gates = List<Completer<void>>.generate(4, (_) => Completer<void>());
    final fake = HandlerTransport((VmodalRequest request) async {
      final index = searchIndex(request);
      started[index].complete();
      await gates[index].future;
      return searchResponse(index);
    });
    final client = VmodalClient(
      config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
      transport: fake,
      signedUploadTransport: FakeSignedUploadTransport(),
    );
    final future = client.searches.searchBatch(
      List<SearchRequest>.generate(
        4,
        (int index) => SearchRequest(queryText: 'query-$index'),
      ),
      batchSize: 2,
      nWorker: 2,
    );
    await Future.wait(<Future<void>>[started[0].future, started[2].future]);
    expect(started[1].isCompleted, isFalse);
    expect(started[3].isCompleted, isFalse);
    gates[0].complete();
    await started[1].future;
    expect(started[3].isCompleted, isFalse);
    gates[1].complete();
    gates[2].complete();
    await started[3].future;
    gates[3].complete();
    expect(await future, hasLength(4));
  });

  test('batch search empty and invalid inputs stay local', () async {
    final fake = FakeTransport();
    final client = VmodalClient(
      config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
      transport: fake,
      signedUploadTransport: FakeSignedUploadTransport(),
    );
    expect(await client.searches.searchBatch(<SearchRequest>[]), isEmpty);
    await expectLater(
      client.searches.searchBatch(<SearchRequest>[], batchSize: 0),
      throwsA(isA<ValidationException>()),
    );
    await expectLater(
      client.searches.searchBatch(<SearchRequest>[], nWorker: 0),
      throwsA(isA<ValidationException>()),
    );
    await expectLater(
      client.searches.searchBatch(const <SearchRequest>[
        SearchRequest(queryText: 'valid'),
        SearchRequest(),
      ]),
      throwsA(isA<ValidationException>()),
    );
    expect(fake.requests, isEmpty);
  });

  test('batch failure stops scheduling and reports lowest input', () async {
    final started = List<Completer<void>>.generate(8, (_) => Completer<void>());
    final gates = List<Completer<void>>.generate(8, (_) => Completer<void>());
    final token = CancellationToken();
    final fake = HandlerTransport((VmodalRequest request) async {
      final index = searchIndex(request);
      started[index].complete();
      await gates[index].future;
      if (index == 2 || index == 4) {
        throw ApiException('failure-$index', statusCode: 500);
      }
      return searchResponse(index);
    });
    final client = VmodalClient(
      config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
      transport: fake,
      signedUploadTransport: FakeSignedUploadTransport(),
    );
    final future = client.searches.searchBatch(
      List<SearchRequest>.generate(
        8,
        (int index) => SearchRequest(queryText: 'query-$index'),
      ),
      batchSize: 2,
      nWorker: 3,
      cancellation: token,
    );
    final expected = expectLater(
      future,
      throwsA(
        isA<ApiException>().having(
          (ApiException value) => value.message,
          'message',
          'failure-2',
        ),
      ),
    );
    await Future.wait(<Future<void>>[
      started[0].future,
      started[2].future,
      started[4].future,
    ]);
    gates[4].complete();
    gates[2].complete();
    gates[0].complete();
    await expected;
    expect(fake.requests, hasLength(3));
    expect(token.isCanceled, isFalse);
  });

  test(
    'batch cancellation reaches active requests and stops scheduling',
    () async {
      final started = <Completer<void>>[Completer<void>(), Completer<void>()];
      final fake = HandlerTransport((VmodalRequest request) async {
        final index = searchIndex(request);
        started[index == 0 ? 0 : 1].complete();
        await request.cancellation.whenCanceled;
        request.cancellation.throwIfCanceled();
        return searchResponse(index);
      });
      final token = CancellationToken();
      final client = VmodalClient(
        config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
        transport: fake,
        signedUploadTransport: FakeSignedUploadTransport(),
      );
      final future = client.searches.searchBatch(
        List<SearchRequest>.generate(
          6,
          (int index) => SearchRequest(queryText: 'query-$index'),
        ),
        batchSize: 2,
        nWorker: 2,
        cancellation: token,
      );
      final expected = expectLater(future, throwsA(isA<OperationCanceled>()));
      await Future.wait(<Future<void>>[started[0].future, started[1].future]);
      token.cancel();
      await expected;
      expect(fake.requests, hasLength(2));
      expect(
        fake.requests.every(
          (VmodalRequest request) => request.cancellation.isCanceled,
        ),
        isTrue,
      );
    },
  );

  test('batch search reuses the normal route and request JSON', () async {
    final fake = FakeTransport()
      ..addResponse(jsonResponse('{"data":[],"cnt_actual":0,"cnt_total":0}'));
    final client = VmodalClient(
      config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
      transport: fake,
      signedUploadTransport: FakeSignedUploadTransport(),
    );
    const input = SearchRequest(
      queryText: 'batch contract',
      groupName: 'travel',
      streamName: 'camera',
      limit: 7,
    );
    expect(
      await client.searches.searchBatch(<SearchRequest>[input]),
      hasLength(1),
    );
    final request = fake.requests.single;
    expect(request.method, 'POST');
    expect(request.uri.path, endsWith('/api/external/v1/search'));
    expect(request.jsonBody, input.toJson());
  });

  test('model validation and numeric coercion match mobile contract', () {
    expect(
      () => const SearchRequest().validate(),
      throwsA(isA<ValidationException>()),
    );
    final response = SearchResponse(<String, Object?>{
      'data': <Object?>[],
      'cnt_actual': '2',
      'cnt_total': 3.0,
      'execution_time_ms': '1.5',
    });
    expect(response.cntActual, 2);
    expect(response.cntTotal, 3);
    expect(response.executionTimeMs, 1.5);

    final groups = GroupsResponse(<String, Object?>{
      'total': 1,
      'data': <Object?>[
        <String, Object?>{
          'user_id': 'u',
          'mode': 'vid_file',
          'group_name': 'travel',
          'video_group': 'vid_file-travel',
          'modality_types': <String>['vid_img_emb'],
          'lancedb_versions': <String>['invalid', 'v2', 'V10', 'v3'],
        },
      ],
    });
    expect(groups.data.single.groupName, 'travel');
    expect(groups.data.single.latestLancedbVersion, 10);
    expect(
      groups.findGroup(' travel ', mode: 'vid_file'),
      same(groups.data.single),
    );
    expect(groups.findGroup('travel', mode: 'img_file'), isNull);
  });

  test('canonical video hits expose typed fields and preserve raw data', () {
    final raw = <String, Object?>{
      'asset_id': 'asset-7',
      'file_name': 'camera.mp4',
      'playback_offset_ms': '35000',
      'distance': '0.42',
      'preview_image_url': '/api/external/v1/image/get_image?sig=test',
      'extension_field': <String>['kept'],
    };
    final hit = VideoSearchHit(raw);
    expect(hit.assetId, 'asset-7');
    expect(hit.fileName, 'camera.mp4');
    expect(hit.playbackOffsetMs, 35000);
    expect(hit.distance, .42);
    expect(hit.previewImageUrl, '/api/external/v1/image/get_image?sig=test');
    expect(hit.raw, same(raw));
    expect(hit.raw['extension_field'], <String>['kept']);
    expect(
      VideoSearchHit(const <String, Object?>{
        'playback_offset_ms': 1200,
      }).playbackOffsetMs,
      1200,
    );
  });

  test(
    'search response adds ordered map-only video hits without changing data',
    () {
      final rows = <Object?>[
        <String, Object?>{'asset_id': 'first'},
        'unchanged scalar',
        <Object?, Object?>{'asset_id': 'second'},
      ];
      final response = SearchResponse(<String, Object?>{'data': rows});
      expect(response.data, rows);
      expect(response.data[1], 'unchanged scalar');
      expect(response.videoHits.map((hit) => hit.assetId), ['first', 'second']);
    },
  );

  test(
    'legacy video hit aliases normalize filename time distance and preview',
    () {
      final hit = VideoSearchHit(const <String, Object?>{
        'source_path': r'C:\archive\camera.mp4',
        'timestamp_seconds': '35.1256',
        'score': .73,
        'image_url': 'https://images.test/frame.jpg',
      });
      expect(hit.fileName, 'camera.mp4');
      expect(hit.playbackOffsetMs, 35126);
      expect(hit.distance, .73);
      expect(hit.previewImageUrl, 'https://images.test/frame.jpg');
      expect(
        VideoSearchHit(const <String, Object?>{'score': .92}).distance,
        .92,
      );
      expect(
        VideoSearchHit(const <String, Object?>{'score_ui': .98}).distance,
        isNull,
      );
    },
  );

  test(
    'malformed video hit fields stay null and identity is never invented',
    () {
      for (final raw in <Map<String, Object?>>[
        <String, Object?>{'ts_unix': '1788510000000'},
        <String, Object?>{'playback_offset_ms': -1},
        <String, Object?>{'playback_offset_ms': 1.5},
        <String, Object?>{'playback_offset_ms': 'bad'},
        <String, Object?>{'playback_offset_ms': double.infinity},
      ]) {
        expect(VideoSearchHit(raw).playbackOffsetMs, isNull);
      }
      for (final value in <Object?>[-1, 'bad', double.nan, double.infinity]) {
        expect(
          VideoSearchHit(<String, Object?>{'distance': value}).distance,
          isNull,
        );
      }
      final blank = VideoSearchHit(const <String, Object?>{
        'asset_id': '  ',
        'path': 'folder/',
        'preview_image_url': '',
        'item_id': 'frame-123',
      });
      expect(blank.assetId, isNull);
      expect(blank.fileName, isNull);
      expect(blank.previewImageUrl, isNull);
      expect(
        VideoSearchHit(const <String, Object?>{
          'item_id': 'frame-123',
          'filename': 'camera.mp4',
        }).assetId,
        isNull,
      );
    },
  );

  test('video upload asset identity is canonical-only', () {
    expect(
      VideoUploadResponse(const <String, Object?>{
        'asset_id': 'asset-uploaded',
      }).assetId,
      'asset-uploaded',
    );
    expect(
      VideoUploadResponse(const <String, Object?>{
        'filename': 'camera.mp4',
        'video_filename': 'camera.mp4',
        'key': 'uploads/camera.mp4',
        'dest_path': 'bucket/camera.mp4',
      }).assetId,
      isNull,
    );
  });

  test('gateway bulk image payload removes nested identity fields', () async {
    final fake = FakeTransport()..addResponse(jsonResponse('{"records":[]}'));
    final client = VmodalClient(
      config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
      transport: fake,
      signedUploadTransport: FakeSignedUploadTransport(),
    );
    await client.images.getUrlBulk(<Map<String, Object?>>[
      <String, Object?>{
        'mode': 'img_file',
        'userid': 'malicious-a',
        'user_id': 'malicious-b',
      },
    ], userid: 'malicious-outer');
    final body = fake.requests.single.jsonBody! as Map<String, Object?>;
    expect(body, isNot(contains('userid')));
    final row = (body['records']! as List).single as Map<String, Object?>;
    expect(row, isNot(contains('userid')));
    expect(row, isNot(contains('user_id')));
  });

  test('image bytes honor a smaller per-call limit before buffering', () async {
    final fake = FakeTransport()
      ..addResponse(
        VmodalResponse(
          statusCode: 200,
          contentLength: 4,
          body: Stream<List<int>>.value(<int>[1, 2, 3, 4]),
        ),
      );
    final client = VmodalClient(
      config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
      transport: fake,
      signedUploadTransport: FakeSignedUploadTransport(),
    );
    await expectLater(
      client.images.getImageFromUrl('https://objects.test/a', maxBytes: 3),
      throwsA(isA<ResponseTooLarge>()),
    );
  });

  test('image sink streams bytes and remains caller owned', () async {
    final dir = await Directory.systemTemp.createTemp('vmodal-image-');
    addTearDown(() => dir.delete(recursive: true));
    final fake = FakeTransport()
      ..addResponse(
        VmodalResponse(
          statusCode: 200,
          contentLength: -1,
          body: Stream<List<int>>.fromIterable(<List<int>>[
            <int>[1, 2],
            <int>[3, 4],
          ]),
        ),
      );
    final client = VmodalClient(
      config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
      transport: fake,
      signedUploadTransport: FakeSignedUploadTransport(),
    );
    final file = File('${dir.path}/a.jpg');
    final sink = file.openWrite();
    await client.images.writeImageFromUrl(
      'https://objects.test/a',
      sink,
      maxBytes: 4,
    );
    sink.add(<int>[5]);
    await sink.close();
    expect(await file.readAsBytes(), <int>[1, 2, 3, 4, 5]);
  });

  test(
    'atomic image file download preserves destination on overflow',
    () async {
      final dir = await Directory.systemTemp.createTemp('vmodal-image-');
      addTearDown(() => dir.delete(recursive: true));
      final destination = File('${dir.path}/a.jpg');
      await destination.writeAsBytes(<int>[9], flush: true);
      final fake = FakeTransport()
        ..addResponse(
          VmodalResponse(
            statusCode: 200,
            contentLength: -1,
            body: Stream<List<int>>.fromIterable(<List<int>>[
              <int>[1, 2],
              <int>[3, 4, 5],
            ]),
          ),
        );
      final client = VmodalClient(
        config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
        transport: fake,
        signedUploadTransport: FakeSignedUploadTransport(),
      );
      await expectLater(
        client.images.saveImageFromUrl(
          'https://objects.test/a',
          destination,
          maxBytes: 4,
        ),
        throwsA(isA<ResponseTooLarge>()),
      );
      expect(await destination.readAsBytes(), <int>[9]);
      expect(await dir.list().length, 1);
    },
  );

  test('atomic image file download replaces destination on success', () async {
    final dir = await Directory.systemTemp.createTemp('vmodal-image-');
    addTearDown(() => dir.delete(recursive: true));
    final destination = File('${dir.path}/a.jpg');
    await destination.writeAsBytes(<int>[9], flush: true);
    final fake = FakeTransport()
      ..addResponse(
        VmodalResponse(
          statusCode: 200,
          contentLength: 3,
          body: Stream<List<int>>.value(<int>[1, 2, 3]),
        ),
      );
    final client = VmodalClient(
      config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
      transport: fake,
      signedUploadTransport: FakeSignedUploadTransport(),
    );
    expect(
      await client.images.saveImageFromUrl(
        'https://objects.test/a',
        destination,
      ),
      destination,
    );
    expect(await destination.readAsBytes(), <int>[1, 2, 3]);
    expect(await dir.list().length, 1);
  });

  test('image per-call cap cannot raise the SDK binary ceiling', () async {
    final fake = FakeTransport();
    final client = VmodalClient(
      config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
      transport: fake,
      signedUploadTransport: FakeSignedUploadTransport(),
    );
    await expectLater(
      client.images.getImageFromUrl(
        'https://objects.test/a',
        maxBytes: 65 * 1024 * 1024,
      ),
      throwsA(isA<ValidationException>()),
    );
    expect(fake.requests, isEmpty);
  });

  test('resource paths and users API base are exact', () async {
    final fake = FakeTransport()
      ..addResponse(jsonResponse('{"user_id":"u"}'))
      ..addResponse(jsonResponse('{"data":[],"total":0}'))
      ..addResponse(jsonResponse('{"job_id":"j","status":"queued"}'));
    final client = VmodalClient(
      config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
      transport: fake,
      signedUploadTransport: FakeSignedUploadTransport(),
    );
    expect((await client.auth.me()).userId, 'u');
    await client.indexes.jobsList(groupName: 'g');
    await client.indexes.createIndex(
      const IndexationSubmitRequest(mode: 'vid_file', groupName: 'g'),
    );
    expect(
      fake.requests[0].uri.toString(),
      'https://gateway.test/api/v1/auth/me',
    );
    expect(
      fake.requests[1].uri.path,
      endsWith('/api/external/v1/indexation/jobs'),
    );
    expect(fake.requests[1].uri.queryParameters['group_name'], 'g');
    expect(fake.requests[2].method, 'POST');
  });

  test('all disabled methods fail before transport', () {
    final fake = FakeTransport();
    final client = VmodalClient(
      config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
      transport: fake,
      signedUploadTransport: FakeSignedUploadTransport(),
    );
    expect(client.collections.create, throwsA(isA<FeatureDisabled>()));
    expect(client.collections.edit, throwsA(isA<FeatureDisabled>()));
    expect(client.collections.uploadFolder, throwsA(isA<FeatureDisabled>()));
    expect(client.indexes.embeddingModels, throwsA(isA<FeatureDisabled>()));
    expect(client.gdrive.privateAuthUrl, throwsA(isA<FeatureDisabled>()));
    expect(client.sql.query, throwsA(isA<FeatureDisabled>()));
    expect(fake.requests, isEmpty);
  });

  test('request JSON remains serializable for every primary model', () {
    final values = <Map<String, Object?>>[
      const SearchRequest(queryText: 'a').toJson(),
      const DeleteCollectionRequest(groupName: 'g', mode: 'vid_file').toJson(),
      const CollectionAddAssetsRequest(
        collectionId: 'c',
        assetIds: <String>['a'],
        mode: 'vid_file',
        groupName: 'g',
      ).toJson(),
      const IndexationSubmitRequest(mode: 'vid_file', groupName: 'g').toJson(),
      const IndexationDeleteRequest(
        mode: 'vid_file',
        groupName: 'g',
        version: 'v1',
      ).toJson(),
      const ImageUrlRecord(mode: 'img_file').toJson(),
    ];
    for (final value in values) {
      expect(() => jsonEncode(value), returnsNormally);
    }
  });
}
