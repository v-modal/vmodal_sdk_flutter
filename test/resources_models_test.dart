import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

import 'fakes.dart';

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
