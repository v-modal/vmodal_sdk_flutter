import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

import 'fakes.dart';

UploadSource _source(String name) => UploadSource(
  fileName: name,
  contentLength: 2,
  sourceId: name,
  opener: () => Stream<List<int>>.value(<int>[1, 2]),
);

void main() {
  test('CCTV options are immutable in flight and survive adaptive copies', () {
    final tags = <String>['tag1', 'tag2'];
    final options = VideoUploadOptions(
      multipart: true,
      adaptiveConditions: const UploadConditions(),
      videoFilename: 'public.MP4',
      metadataText: '',
      metadataTags: tags,
      startDatetimeUser: '2026-07-30T09:15:00+09:00',
      reProcess: true,
    );
    final resolved = options.resolvedFor(10 * 1024 * 1024);
    tags.add('mutated');
    expect(resolved.videoFilename, 'public.MP4');
    expect(resolved.metadataText, '');
    expect(resolved.metadataTags, <String>['tag1', 'tag2']);
    expect(() => resolved.metadataTags!.add('blocked'), throwsUnsupportedError);
    expect(resolved.startDatetimeUser, '2026-07-30T09:15:00+09:00');
    expect(resolved.reProcess, isTrue);
  });

  test('CCTV upload validation fails before transport', () {
    final api = FakeTransport();
    final client = VmodalClient(
      config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
      transport: api,
      signedUploadTransport: FakeSignedUploadTransport(),
    );
    final cases = <VideoUploadOptions>[
      const VideoUploadOptions(videoFilename: ' '),
      const VideoUploadOptions(videoFilename: 'folder/camera.mp4'),
      const VideoUploadOptions(videoFilename: r'folder\camera.mp4'),
      const VideoUploadOptions(videoFilename: 'camera.webm'),
      const VideoUploadOptions(startDatetimeUser: '2026-07-30T09:15:00'),
      const VideoUploadOptions(startDatetimeUser: ' '),
    ];
    for (final options in cases) {
      expect(
        () => client.collections.videoUpload(
          _source('camera.mp4'),
          collectionName: 'group',
          subCollectionName: 'stream',
          options: options,
        ),
        throwsA(isA<ValidationException>()),
      );
    }
    expect(
      () => client.collections.videoUpload(
        _source('camera.mp4'),
        collectionName: 'group',
        subCollectionName: 'stream',
        mode: 'img_file',
        options: const VideoUploadOptions(videoFilename: 'camera.mp4'),
      ),
      throwsA(isA<ValidationException>()),
    );
    expect(api.requests, isEmpty);
  });

  test('bulk upload rejects a shared public filename before transport', () {
    final api = FakeTransport();
    final client = VmodalClient(
      config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
      transport: api,
      signedUploadTransport: FakeSignedUploadTransport(),
    );
    expect(
      () => client.collections.videoUploadBulk(
        <UploadSource>[_source('a.mp4'), _source('b.mp4')],
        collectionName: 'group',
        subCollectionName: 'stream',
        options: const VideoUploadOptions(videoFilename: 'shared.mp4'),
      ),
      throwsA(isA<ValidationException>()),
    );
    expect(api.requests, isEmpty);
  });

  test(
    'signed finalize preserves every CCTV value and canonical response',
    () async {
      final tags = <String>['tag1', 'tag2', 'tag3'];
      final api = FakeTransport()
        ..addJson(<String, Object?>{
          'url': 'https://objects.test/upload',
          'method': 'PUT',
          'key': 'key-camera',
        })
        ..addJson(<String, Object?>{
          'dest_path': 'done/public.mp4',
          'video_filename': 'public.mp4',
          'start_datetime_user': '2026-07-30T09:15:00+09:00',
          'start_ts_unix_user_ms': 1785370500000,
          'timestamp_source': 'user',
        });
      final client = VmodalClient(
        config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
        transport: api,
        signedUploadTransport: FakeSignedUploadTransport(),
      );
      final task = client.collections.videoUpload(
        _source('camera.mp4'),
        collectionName: 'group',
        subCollectionName: 'stream',
        options: VideoUploadOptions(
          videoFilename: 'public.mp4',
          metadataText: '',
          metadataTags: tags,
          startDatetimeUser: '2026-07-30T09:15:00+09:00',
          reProcess: true,
        ),
      );
      tags.add('late-mutation');
      final result = await task.result;
      final done = api.requests.last.uri.queryParametersAll;
      expect(done['key'], <String>['key-camera']);
      expect(done['mode'], <String>['vid_file']);
      expect(done['group_name'], <String>['group']);
      expect(done['stream_name'], <String>['stream']);
      expect(done['modality'], <String>['vid_raw']);
      expect(done['filename'], <String>['camera.mp4']);
      expect(done['video_filename'], <String>['public.mp4']);
      expect(done['metadata_text'], <String>['']);
      expect(done['metadata_tags'], <String>['tag1', 'tag2', 'tag3']);
      expect(done['start_datetime_user'], <String>[
        '2026-07-30T09:15:00+09:00',
      ]);
      expect(done['re_process'], <String>['true']);
      expect(result.videoFilename, 'public.mp4');
      expect(result.startDatetimeUser, '2026-07-30T09:15:00+09:00');
      expect(result.startTsUnixUserMs, 1785370500000);
      expect(result.timestampSource, 'user');
      expect(result.raw['upload_done'], isA<Map<String, Object?>>());
    },
  );

  test('non-CCTV signed finalize omits optional fields', () async {
    final api = FakeTransport()
      ..addJson(<String, Object?>{
        'url': 'https://objects.test/upload',
        'key': 'key-plain',
      })
      ..addJson(<String, Object?>{'dest_path': 'done/plain.mp4'});
    final client = VmodalClient(
      config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
      transport: api,
      signedUploadTransport: FakeSignedUploadTransport(),
    );
    await client.collections
        .videoUpload(
          _source('plain.mp4'),
          collectionName: 'group',
          subCollectionName: 'stream',
        )
        .result;
    final done = api.requests.last.uri.queryParametersAll;
    expect(done, isNot(contains('video_filename')));
    expect(done, isNot(contains('metadata_text')));
    expect(done, isNot(contains('metadata_tags')));
    expect(done, isNot(contains('start_datetime_user')));
    expect(done['re_process'], <String>['false']);
  });

  test('direct multipart upload carries additive CCTV form fields', () async {
    final api = FakeTransport()
      ..addJson(<String, Object?>{
        'status': 'ok',
        'video_filename': 'public.mp4',
        'start_ts_unix_user_ms': 1785370500000,
      });
    final client = VmodalClient(
      config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
      transport: api,
    );
    final result = await client.collections.uploadFile(
      VmodalFilePart.bytes(
        fieldName: 'file',
        fileName: 'source.mp4',
        bytes: <int>[1, 2],
        contentType: 'video/mp4',
      ),
      groupName: 'group',
      streamName: 'stream',
      description: 'legacy',
      tag: <String>['old1', 'old2'],
      videoFilename: 'public.mp4',
      metadataText: '',
      metadataTags: <String>['tag1', 'tag2', 'tag3'],
      startDatetimeUser: '2026-07-30T09:15:00+09:00',
      reProcess: true,
    );
    final form = api.requests.single.formFields;
    expect(form['description'], 'legacy');
    expect(form['tag'], <String>['old1', 'old2']);
    expect(form['video_filename'], 'public.mp4');
    expect(form['metadata_text'], '');
    expect(form['metadata_tags'], <String>['tag1', 'tag2', 'tag3']);
    expect(form['start_datetime_user'], '2026-07-30T09:15:00+09:00');
    expect(form['re_process'], isTrue);
    expect(result.raw['start_ts_unix_user_ms'], 1785370500000);
  });

  test(
    'direct timestamp upload derives the original public filename',
    () async {
      final api = FakeTransport()..addJson(<String, Object?>{'status': 'ok'});
      final client = VmodalClient(
        config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
        transport: api,
      );
      await client.collections.uploadFile(
        VmodalFilePart.bytes(
          fieldName: 'file',
          fileName: 'camera-source.mp4',
          bytes: <int>[1, 2],
          contentType: 'video/mp4',
        ),
        groupName: 'group',
        startDatetimeUser: '2026-07-30T09:15:00+09:00',
      );
      expect(
        api.requests.single.formFields['video_filename'],
        'camera-source.mp4',
      );
    },
  );

  test(
    'CCTV search preserves metadata text and absolute timezone ranges',
    () async {
      final api = FakeTransport()
        ..addJson(<String, Object?>{
          'data': <Object?>[
            <String, Object?>{
              'ts_unix': '1785370500000',
              'item_id': 'astream-some_video-1785370500000',
              'description': 'some text',
              'text_agg_tok': 'tag1 tag2 tag3',
              'metadata_join_matched': false,
            },
          ],
          'cnt_actual': 1,
          'cnt_total': 1,
        });
      final client = VmodalClient(
        config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
        transport: api,
      );
      final response = await client.searches.searchVideo(
        const SearchRequest(
          queryMetadataText: 'tag2',
          groupName: 'group',
          streamName: 'astream',
          startDate: '2026-07-30T09:15:00.000+09:00',
          endDate: '2026-07-30T09:15:00.001+09:00',
        ),
      );
      final body = api.requests.single.jsonBody! as Map<String, Object?>;
      expect(body['query_metadata'], 'tag2');
      expect(body['start_date'], '2026-07-30T09:15:00.000+09:00');
      expect(body['end_date'], '2026-07-30T09:15:00.001+09:00');
      expect(body['query_metadata'], isNot(isA<Map<Object?, Object?>>()));
      final item = SearchResultItem(
        response.data.single! as Map<String, Object?>,
      );
      expect(item.raw['ts_unix'], '1785370500000');
      expect(item.raw['item_id'], contains('some_video'));
      expect(item.raw['description'], 'some text');
      expect(item.raw['text_agg_tok'], contains('tag3'));
      expect(item.raw['metadata_join_matched'], isFalse);
    },
  );

  test('CCTV search rejects conflicting metadata and unsafe date bounds', () {
    final bad = <SearchRequest>[
      const SearchRequest(
        queryMetadata: <String, Object?>{'tag': 'tag1'},
        queryMetadataText: 'tag1',
      ),
      const SearchRequest(queryMetadataText: 'tag1', startDate: '2026-07-30'),
      const SearchRequest(
        queryMetadataText: 'tag1',
        startDate: '2026-07-30T09:15:00',
        endDate: '2026-07-30T09:16:00',
      ),
      const SearchRequest(queryMetadataText: ' '),
    ];
    for (final request in bad) {
      expect(request.validate, throwsA(isA<ValidationException>()));
    }
    expect(
      const SearchRequest(
        queryMetadataText: 'tag1',
        startDate: '2026-07-30T00:15:00.000Z',
        endDate: '2026-07-30T00:15:00.001Z',
      ).validate,
      returnsNormally,
    );
    expect(
      const SearchRequest(
        queryMetadataText: 'tag1',
        startDate: '2026-07-30',
        endDate: '2026-07-31',
      ).validate,
      returnsNormally,
    );
  });

  test(
    'scoped metadata-only search retains collection and stream mapping',
    () async {
      final api = FakeTransport()
        ..addJson(<String, Object?>{
          'data': <Object?>[],
          'cnt_actual': 0,
          'cnt_total': 0,
        });
      final client = VmodalClient(
        config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
        transport: api,
      );
      final project = VModal.fromClient(projectId: 'cctv_app', client: client);
      await project
          .scope(collectionName: 'cameras', streamName: 'entrance')
          .search(
            '',
            options: const ScopedSearchOptions(queryMetadataText: 'tag1'),
          );
      final body = api.requests.single.jsonBody! as Map<String, Object?>;
      expect(body['query_metadata'], 'tag1');
      expect(body['group_name'], 'cctv_app__cameras');
      expect(body['stream_name'], 'entrance');
    },
  );

  test(
    'bulk timestamp upload derives one public filename per source',
    () async {
      final publicNames = <String>[];
      final api = HandlerTransport((VmodalRequest request) async {
        if (request.uri.path.endsWith(Routes.externalUploadGetSignedUrl)) {
          final name = request.uri.queryParameters['filename'];
          return jsonResponse(
            '{"url":"https://objects.test/$name","key":"key-$name"}',
          );
        }
        if (request.uri.path.endsWith(Routes.externalUploadDone)) {
          final name = request.uri.queryParameters['video_filename']!;
          publicNames.add(name);
          return jsonResponse('{"video_filename":"$name"}');
        }
        throw StateError('unexpected route: ${request.uri.path}');
      });
      final client = VmodalClient(
        config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
        transport: api,
        signedUploadTransport: FakeSignedUploadTransport(),
      );
      final result = await client.collections
          .videoUploadBulk(
            <UploadSource>[_source('camera-a.mp4'), _source('camera-b.mp4')],
            collectionName: 'group',
            subCollectionName: 'stream',
            options: const VideoUploadOptions(
              startDatetimeUser: '2026-07-30T09:15:00+09:00',
            ),
          )
          .result;
      expect(publicNames.toSet(), <String>{'camera-a.mp4', 'camera-b.mp4'});
      expect(
        result.data
            .map((VideoUploadResponse item) => item.videoFilename)
            .toSet(),
        <String>{'camera-a.mp4', 'camera-b.mp4'},
      );
    },
  );
}
