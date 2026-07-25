import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

import 'fakes.dart';

({VModalProject project, FakeTransport api, FakeSignedUploadTransport signed})
facade({String projectId = 'food_app'}) {
  final api = FakeTransport();
  final signed = FakeSignedUploadTransport();
  final client = VmodalClient(
    config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
    transport: api,
    signedUploadTransport: signed,
  );
  return (
    project: VModal.fromClient(projectId: projectId, client: client),
    api: api,
    signed: signed,
  );
}

Map<String, Object?> requestValues(VmodalRequest request) {
  final json = request.jsonBody is Map<String, Object?>
      ? request.jsonBody! as Map<String, Object?>
      : const <String, Object?>{};
  return <String, Object?>{
    ...json,
    ...request.formFields,
    ...request.uri.queryParameters,
  };
}

Map<String, Object?> group(String name) => <String, Object?>{
  'group_name': name,
  'mode': 'vid_file',
};

UploadSource source() => UploadSource(
  fileName: 'video.mp4',
  contentLength: 2,
  sourceId: 'facade-video',
  opener: () => Stream<List<int>>.value(<int>[1, 2]),
);

VmodalFilePart metadataPart() => VmodalFilePart.bytes(
  fieldName: 'file',
  fileName: 'metadata.jsonl',
  bytes: <int>[123, 125],
);

String repeated(String value, int count) =>
    List<String>.filled(count, value).join();

void main() {
  test('configuration and scope validation are local and deterministic', () {
    stdout.writeln('[facade] validating names and composite boundaries');
    final cfg = facade(projectId: ' food_app ');
    final scope = cfg.project.scope(
      collectionName: ' user_123 ',
      streamName: ' favorites__saved ',
    );
    expect(cfg.project.projectId, 'food_app');
    expect(scope.projectId, 'food_app');
    expect(scope.collectionName, 'user_123');
    expect(scope.streamName, 'favorites__saved');
    expect('${scope.projectId}__${scope.collectionName}', 'food_app__user_123');

    final invalid = <String>['', ' ', 'a-b', 'a b', 'a/b', 'a.b', 'é'];
    for (final value in invalid) {
      expect(
        () => facade(projectId: value),
        throwsA(isA<ValidationException>()),
        reason: 'projectId=$value',
      );
      expect(
        () => cfg.project.scope(collectionName: value, streamName: 'stream'),
        throwsA(isA<ValidationException>()),
        reason: 'collectionName=$value',
      );
      expect(
        () =>
            cfg.project.scope(collectionName: 'collection', streamName: value),
        throwsA(isA<ValidationException>()),
        reason: 'streamName=$value',
      );
    }
    expect(
      () => facade(projectId: 'bad__project'),
      throwsA(isA<ValidationException>()),
    );
    expect(
      () => cfg.project.scope(
        collectionName: 'bad__collection',
        streamName: 'stream',
      ),
      throwsA(isA<ValidationException>()),
    );
    expect(
      cfg.project
          .scope(collectionName: 'a', streamName: repeated('s', 80))
          .streamName,
      hasLength(80),
    );
    expect(
      () =>
          cfg.project.scope(collectionName: 'a', streamName: repeated('s', 81)),
      throwsA(isA<ValidationException>()),
    );
    expect(
      facade(projectId: repeated('p', 80)).project.projectId,
      hasLength(80),
    );
    expect(
      () => facade(projectId: repeated('p', 81)),
      throwsA(isA<ValidationException>()),
    );
    expect(
      cfg.project
          .scope(collectionName: repeated('c', 70), streamName: 'stream')
          .collectionName,
      hasLength(70),
      reason: 'food_app + separator + 70 characters is exactly 80',
    );
    final short = facade(projectId: 'p');
    expect(
      short.project
          .scope(collectionName: repeated('c', 77), streamName: 'stream')
          .collectionName,
      hasLength(77),
      reason: 'encoded collection is exactly 80 characters',
    );
    expect(
      () => short.project.scope(
        collectionName: repeated('c', 78),
        streamName: 'stream',
      ),
      throwsA(isA<ValidationException>()),
    );
    expect(cfg.api.requests, isEmpty);
    expect(short.api.requests, isEmpty);
  });

  test('configure does not read credentials or perform network I/O', () async {
    stdout.writeln('[facade] checking configure lifecycle');
    final keys = CountingKeyProvider('key');
    final project = VModal.configure(
      projectId: ' demo_app ',
      apiKeyProvider: keys,
      baseUri: Uri.parse('https://gateway.test'),
    );
    expect(project.projectId, 'demo_app');
    expect(keys.reads, 0);
    await project.close();
    await project.close();
  });

  test('all scoped operations use one collection and stream mapping', () async {
    stdout.writeln('[facade] checking delegated request contracts');
    final cfg = facade();
    final scope = cfg.project.scope(
      collectionName: 'user_123',
      streamName: 'favorites',
    );
    final cancel = CancellationToken();
    for (var i = 0; i < 9; i++) {
      cfg.api.addJson(<String, Object?>{
        'data': <Object?>[],
        'total': 0,
        'job_id': 'job-1',
        'status': 'ok',
      });
    }

    await scope.uploadMetadata(
      metadataPart(),
      options: const ScopedMetadataOptions(
        mode: 'img_file',
        writeMode: 'replace',
        allowOverlap: true,
      ),
      cancellation: cancel,
    );
    await scope.search(
      'birthday dinner',
      options: const ScopedSearchOptions(
        queryMetadata: <String, Object?>{'kind': 'meal'},
        imageQuery: 'image-ref',
        mode: 'vid_file',
        searchSources: <String>['asr'],
        searchCombineMode: 'intersection',
        startDate: '2026-01-01',
        endDate: '2026-02-01',
        offset: 4,
        limit: 9,
        textEmbScoreMin: 0.7,
        imageEmbScoreMin: 1.2,
        versionLancedb: 3,
      ),
      cancellation: cancel,
    );
    await scope.addAssets(
      'collection-id',
      <String>['asset-1'],
      options: const ScopedAddAssetsOptions(mode: 'vid_file'),
      cancellation: cancel,
    );
    await scope.updateAsset(
      'video.mp4',
      changes: const ScopedAssetChanges(
        description: 'updated',
        tags: <String>['favorite'],
      ),
      cancellation: cancel,
    );
    await scope.createIndex(
      options: const ScopedCreateIndexOptions(
        indexType: 'vector',
        modality: 'vid_raw',
        insertMode: 'replace',
        createIndex: false,
        version: 'v3',
        startDate: '2026-01-01',
        endDate: '2026-02-01',
        embeddingModel: 'model-a',
        reProcess: true,
        dryRun: true,
      ),
      cancellation: cancel,
    );
    await scope.listIndexJobs(
      options: const ScopedIndexJobsOptions(
        status: 'queued',
        mode: 'vid_file',
        limit: 10,
      ),
      cancellation: cancel,
    );
    await scope.indexStatus('job-1', cancellation: cancel);
    await scope.deleteIndex(
      'v3',
      options: const ScopedDeleteIndexOptions(
        modality: 'vid_raw',
        dryRun: true,
        confirm: false,
      ),
      cancellation: cancel,
    );
    await scope.deleteCollection(
      options: const ScopedDeleteCollectionOptions(
        scope: 'all',
        dryRun: true,
        confirm: false,
      ),
      cancellation: cancel,
    );

    expect(cfg.api.requests, hasLength(9));
    for (final request in cfg.api.requests) {
      expect(request.cancellation, same(cancel));
    }
    final values = cfg.api.requests.map(requestValues).toList();
    for (final index in <int>[0, 1, 2, 3, 4, 5, 7, 8]) {
      expect(
        values[index]['group_name'],
        'food_app__user_123',
        reason: 'request $index',
      );
    }
    for (final index in <int>[0, 1, 2, 3, 4]) {
      expect(
        values[index]['stream_name'],
        'favorites',
        reason: 'request $index',
      );
    }
    expect(values[0]['write_mode'], 'replace');
    expect(values[0]['allow_overlap'], 'true');
    expect(values[1]['query_metadata'], <String, Object?>{'kind': 'meal'});
    expect(values[1]['image_query'], 'image-ref');
    expect(values[1]['search_sources'], <String>['asr']);
    expect(values[1]['search_combine_mode'], 'intersection');
    expect(values[1]['offset'], 4);
    expect(values[1]['limit'], 9);
    expect(values[4]['version'], 'v3');
    expect(values[4]['re_process'], isTrue);
    expect(values[5]['limit'], '10');
    expect(cfg.api.requests[6].uri.path, endsWith('/job-1'));
    expect(values[6], isNot(contains('group_name')));
    expect(values[7]['dry_run'], isTrue);
    expect(values[7]['confirm'], isFalse);
    expect(values[8]['scope'], 'all');
    expect(values[8]['dry_run'], isTrue);
  });

  test(
    'scoped upload preserves task, progress, cancellation, and mapping',
    () async {
      stdout.writeln('[facade] checking signed upload behavior');
      final cfg = facade();
      cfg.api
        ..addJson(<String, Object?>{
          'url': 'https://objects.test/video',
          'method': 'PUT',
          'key': 'uploads/video',
        })
        ..addJson(<String, Object?>{'dest_path': 'done/video.mp4'});
      final scope = cfg.project.scope(
        collectionName: 'user_123',
        streamName: 'favorites',
      );
      final task = scope.upload(
        source(),
        options: const ScopedUploadOptions(
          mode: 'vid_file',
          modality: 'vid_raw',
          ttl: 42,
        ),
      );
      final progress = <int>[];
      final sub = task.progress.listen(
        (UploadProgress value) => progress.add(value.uploadedBytes),
      );
      final result = await task.result;
      await sub.cancel();

      expect(task, isA<UploadTask<VideoUploadResponse>>());
      expect(task.state, UploadTaskState.succeeded);
      expect(result.destPath, 'done/video.mp4');
      expect(progress, <int>[2]);
      expect(cfg.signed.calls, hasLength(1));
      expect(cfg.api.requests, hasLength(2));
      for (final request in cfg.api.requests) {
        final values = requestValues(request);
        expect(values['group_name'], 'food_app__user_123');
        expect(values['stream_name'], 'favorites');
      }
      expect(requestValues(cfg.api.requests.first)['ttl'], '42');
    },
  );

  test(
    'collection listing decodes exact project names in stable order',
    () async {
      stdout.writeln('[facade] checking collection listing decode');
      final cfg = facade();
      final cancel = CancellationToken();
      cfg.api.addJson(<String, Object?>{
        'data': <Object?>[
          group('food_app__global'),
          group('food__global'),
          group('food_app__user_123'),
          group('food_apps__global'),
          group('food_app__global'),
        ],
        'total': 5,
      });
      expect(
        await cfg.project.listCollections(
          mode: 'vid_file',
          cancellation: cancel,
        ),
        <String>['global', 'user_123'],
      );
      expect(cfg.api.requests.single.cancellation, same(cancel));
      expect(cfg.api.requests.single.uri.queryParameters['mode'], 'vid_file');

      cfg.api.addJson(<String, Object?>{
        'data': <Object?>[group('food_app__bad-name')],
        'total': 1,
      });
      await expectLater(
        cfg.project.listCollections(),
        throwsA(isA<MalformedResponse>()),
      );
    },
  );

  test('overlapping scopes retain immutable request organization', () async {
    stdout.writeln('[facade] checking concurrent scope isolation');
    final waits = <String, Completer<VmodalResponse>>{
      'first': Completer<VmodalResponse>(),
      'second': Completer<VmodalResponse>(),
    };
    final api = HandlerTransport((VmodalRequest request) {
      final query = requestValues(request)['query_text']! as String;
      return waits[query]!.future;
    });
    final client = VmodalClient(
      config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
      transport: api,
      signedUploadTransport: FakeSignedUploadTransport(),
    );
    final project = VModal.fromClient(projectId: 'app', client: client);
    final first = project.scope(collectionName: 'user_1', streamName: 'camera');
    final second = project.scope(
      collectionName: 'user_2',
      streamName: 'favorites',
    );
    final firstResult = first.search('first');
    final secondResult = second.search('second');
    expect(api.requests, hasLength(2));
    expect(requestValues(api.requests[0])['group_name'], 'app__user_1');
    expect(requestValues(api.requests[0])['stream_name'], 'camera');
    expect(requestValues(api.requests[1])['group_name'], 'app__user_2');
    expect(requestValues(api.requests[1])['stream_name'], 'favorites');

    waits['second']!.complete(
      jsonResponse('{"data":[],"cnt_actual":2,"cnt_total":2}'),
    );
    waits['first']!.complete(
      jsonResponse('{"data":[],"cnt_actual":1,"cnt_total":1}'),
    );
    expect((await secondResult).cntActual, 2);
    expect((await firstResult).cntActual, 1);
  });

  test('invalid operation input fails before transport', () async {
    stdout.writeln('[facade] checking delegated local validation');
    final cfg = facade();
    final scope = cfg.project.scope(
      collectionName: 'global',
      streamName: 'uploads',
    );
    await expectLater(scope.search(' '), throwsA(isA<ValidationException>()));
    await expectLater(
      scope.addAssets('', const <String>[]),
      throwsA(isA<ValidationException>()),
    );
    expect(
      () => scope.updateAsset(' ', changes: const ScopedAssetChanges()),
      throwsA(isA<ValidationException>()),
    );
    await expectLater(
      scope.createIndex(options: const ScopedCreateIndexOptions(mode: '')),
      throwsA(isA<ValidationException>()),
    );
    await expectLater(
      scope.listIndexJobs(options: const ScopedIndexJobsOptions(limit: 0)),
      throwsA(isA<ValidationException>()),
    );
    await expectLater(
      scope.indexStatus(' '),
      throwsA(isA<ValidationException>()),
    );
    await expectLater(
      scope.deleteIndex(' '),
      throwsA(isA<ValidationException>()),
    );
    await expectLater(
      scope.deleteCollection(
        options: const ScopedDeleteCollectionOptions(mode: ''),
      ),
      throwsA(isA<ValidationException>()),
    );
    expect(cfg.api.requests, isEmpty);
  });

  test(
    'project owns client lifecycle and low-level API stays compatible',
    () async {
      stdout.writeln('[facade] checking ownership and compatibility');
      final cfg = facade();
      await cfg.project.close();
      await cfg.project.close();
      expect(cfg.api.closeCalls, 1);
      expect(cfg.signed.closeCalls, 1);

      final api = FakeTransport()
        ..addJson(<String, Object?>{
          'data': <Object?>[],
          'cnt_actual': 0,
          'cnt_total': 0,
        });
      final client = VmodalClient(
        config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
        transport: api,
        signedUploadTransport: FakeSignedUploadTransport(),
      );
      await client.searches.searchVideo(
        const SearchRequest(
          queryText: 'compatible',
          groupName: 'raw_backend_name',
          streamName: 'raw_stream',
        ),
      );
      expect(
        requestValues(api.requests.single)['group_name'],
        'raw_backend_name',
      );
    },
  );
}
