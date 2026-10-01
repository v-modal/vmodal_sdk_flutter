import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

import 'user_session_test.dart' as sessions;

class UnboundTranscoder implements VideoTranscoder {
  @override
  bool get isPassthrough => false;
  @override
  Future<TranscodeResult> reduce(File input) =>
      throw StateError('must not run');
}

ContentMapping content({String stream = 'camera', bool wide = false}) =>
    ContentMapping.opaque(
      collectionId: 'shared',
      streamName: stream,
      collectionWide: wide,
      actions: UserAction.values.toSet(),
    );

Map<String, Object?> row(String id, {String stream = 'camera'}) =>
    <String, Object?>{
      'job_id': id,
      'group_name': 'shared',
      'stream_name': stream,
      'mode': 'vid_file',
      'status': 'completed',
      'secret': 'tenant-private',
      'assets': <Object?>[
        {'asset_id': 'other'},
      ],
    };

void main() {
  test(
    'public upload progress buffered while paused is dropped after switch',
    () async {
      stdout.writeln(
        '[provenance] listener delivery fence applies to the public upload task',
      );
      final cfg = sessions.setup();
      final map = content();
      final a = await cfg.manager.openResolvedSession(
        () async => sessions.policy('A', map),
      );
      final sent = Completer<void>();
      final release = Completer<void>();
      Stream<List<int>> bytes() async* {
        yield [1];
        sent.complete();
        await release.future;
        yield [2];
      }

      cfg.apis.single.addJson({
        'url': 'https://objects.test/a',
        'key': 'private',
        'method': 'PUT',
      });
      final source = UploadSource(
        fileName: 'a.mp4',
        contentLength: 2,
        opener: bytes,
      );
      final task = a.scope(map).upload(source);
      final values = <UploadProgress>[];
      final subscription = task.progress.listen(
        values.add,
        onError: (Object _) {},
      )..pause();
      final rejected = expectLater(
        task.result,
        throwsA(isA<OperationCanceled>()),
      );
      await sent.future;
      await cfg.manager.openResolvedSession(
        () async => sessions.policy('B', map),
      );
      await rejected;
      subscription.resume();
      await Future<void>.delayed(Duration.zero);
      expect(values, isEmpty);
      release.complete();
      await subscription.cancel();
      await cfg.manager.close();
    },
  );

  test('metadata batches validate every live resource before dispatch', () async {
    stdout.writeln(
      '[provenance] metadata preparation validates rows and freezes the payload',
    );
    final cfg = sessions.setup();
    final map = content();
    final a = await cfg.manager.openResolvedSession(
      () async => sessions.policy('A', map),
    );
    cfg.apis.single.addJson({
      'data': [
        {'asset_id': 'a', 'filename': 'a.mp4'},
      ],
    });
    await a.scope(map).search('a');
    VmodalFilePart part(String data) => VmodalFilePart.bytes(
      fieldName: 'file',
      fileName: 'metadata.jsonl',
      bytes: utf8.encode(data),
    );
    await expectLater(
      a
          .scope(map)
          .uploadMetadata(
            part('{"filename":"B.mp4","description":"B"}'),
            options: const ScopedMetadataOptions(mode: 'vid_file'),
          ),
      throwsA(isA<ValidationException>()),
    );
    await expectLater(
      a
          .scope(map)
          .uploadMetadata(
            part('{"filename":"a.mp4","user_id":"B"}'),
            options: const ScopedMetadataOptions(mode: 'vid_file'),
          ),
      throwsA(isA<ValidationException>()),
    );
    expect(cfg.apis.single.requests, hasLength(1));
    cfg.apis.single.addJson({
      'status': 'ok',
      'raw': {'secret': 'B'},
    });
    final result = await a
        .scope(map)
        .uploadMetadata(
          part('{"filename":"a.mp4","asset_id":"a","description":"new"}'),
          options: const ScopedMetadataOptions(mode: 'vid_file'),
        );
    expect(result.raw, {'status': 'ok'});
    expect(cfg.apis.single.requests.last.formFields['group_name'], 'shared');
    await cfg.manager.close();
  });

  test('switch during metadata file preparation prevents dispatch', () async {
    stdout.writeln(
      '[provenance] pending file stream settles on invalidation without dispatch',
    );
    final cfg = sessions.setup();
    final map = content();
    final a = await cfg.manager.openResolvedSession(
      () async => sessions.policy('A', map),
    );
    final input = StreamController<List<int>>();
    final opened = Completer<void>();
    final file = VmodalFilePart(
      fieldName: 'file',
      fileName: 'metadata.jsonl',
      contentLength: 0,
      opener: () {
        opened.complete();
        return input.stream;
      },
    );
    final result = a
        .scope(map)
        .uploadMetadata(
          file,
          options: const ScopedMetadataOptions(mode: 'vid_file'),
        );
    final rejected = expectLater(result, throwsA(isA<OperationCanceled>()));
    await opened.future;
    final b = await cfg.manager.openResolvedSession(
      () async => sessions.policy('B', map),
    );
    await rejected.timeout(const Duration(seconds: 1));
    expect(cfg.apis.first.requests, isEmpty);
    expect(b.isActive, isTrue);
    await input.close();
    await cfg.manager.close();
  });

  test(
    'upload strips signed grants, object keys and paths; custom hooks reject locally',
    () async {
      stdout.writeln(
        '[provenance] signed upload emits only the scoped safe completion summary',
      );
      final cfg = sessions.setup();
      final map = content();
      final a = await cfg.manager.openResolvedSession(
        () async => sessions.policy('A', map),
      );
      final source = UploadSource(
        fileName: 'a.mp4',
        contentLength: 1,
        opener: () => Stream.value([1]),
      );
      expect(
        () => a
            .scope(map)
            .upload(
              source,
              options: ScopedUploadOptions(
                uploadOptions: VideoUploadOptions(
                  transcoder: UnboundTranscoder(),
                ),
              ),
            ),
        throwsA(isA<ValidationException>()),
      );
      expect(cfg.apis.single.requests, isEmpty);
      cfg.apis.single.addJson({
        'url': 'https://objects.test/private?signature=secret',
        'method': 'PUT',
        'key': 'tenant-key',
        'user_id': 'tenant',
      });
      cfg.apis.single.addJson({
        'asset_id': 'a',
        'dest_path': 'tenant/private',
        'filepath_local': '/private/file',
        'source_filepath_local': '/private/source',
      });
      final result = await a.scope(map).upload(source).result;
      expect(result.asset?.assetId, 'a');
      expect(result.url, isEmpty);
      expect(result.key, isEmpty);
      expect(result.destPath, isEmpty);
      expect(result.filePath, isEmpty);
      expect(result.uploadId, isEmpty);
      expect(result.raw.keys, isNot(contains('user_id')));
      await cfg.manager.close();
    },
  );

  test(
    'discovery omits broader counts, nested data and unproven jobs',
    () async {
      stdout.writeln('[provenance] exact collection + stream + mode required');
      final cfg = sessions.setup();
      final map = content();
      final session = await cfg.manager.openResolvedSession(
        () async => sessions.policy('A', map),
      );
      cfg.apis.single.addJson({
        'data': <Object?>[
          row('allowed'),
          row('other-stream', stream: 'elsewhere'),
          {'job_id': 'unknown', 'group_name': 'shared', 'mode': 'vid_file'},
          {...row('other-mode'), 'mode': 'img_file'},
        ],
        'total': 999,
        'tenant_secret': 'private',
      });
      final jobs = await session.scope(map).listIndexJobs();
      expect(jobs.map((j) => j.jobId), ['allowed']);
      expect(jobs.single.raw, {'job_id': 'allowed', 'status': 'completed'});
      await cfg.manager.close();
    },
  );

  test(
    'search rebuilds raw/data/counts and handles only safe scoped hits',
    () async {
      stdout.writeln(
        '[provenance] sanitized scoped results mint live asset handles',
      );
      final cfg = sessions.setup();
      final map = content();
      final session = await cfg.manager.openResolvedSession(
        () async => sessions.policy('A', map),
      );
      cfg.apis.single.addJson({
        'data': <Object?>[
          {
            'asset_id': 'a',
            'filename': 'a.mp4',
            'score': 0.3,
            'preview_image_url': 'https://objects.test/private',
            'assets': [
              {'asset_id': 'B'},
            ],
            'raw': {'private': 'B'},
            'userdata': 'tenant-secret',
          },
          {'asset_id': 'b', 'stream_name': 'other'},
          {'asset_id': 'c', 'mode': 'img_file'},
        ],
        'cnt_actual': 100,
        'cnt_total': 999,
        'extra': 'private',
      });
      final result = await session.scope(map).search('query');
      expect(result.cntActual, 1);
      expect(result.cntTotal, 1);
      expect(result.assets.single.assetId, 'a');
      expect(result.raw.keys.toSet(), {'data', 'cnt_actual', 'cnt_total'});
      expect(result.videoHits.single.raw, {
        'asset_id': 'a',
        'filename': 'a.mp4',
        'score': 0.3,
      });
      expect(result.videoHits.single.previewImageUrl, isNull);
      cfg.apis.single.addJson({
        'status': 'ok',
        'assets': [
          {'asset_id': 'B'},
        ],
      });
      await session
          .scope(map)
          .updateAsset(
            result.assets.single,
            changes: const ScopedAssetChanges(description: 'new'),
          );
      expect(
        cfg.apis.single.requests.last.formFields['filename_sanitized'],
        'a.mp4',
      );
      await cfg.manager.close();
    },
  );

  test(
    'every association member must match live session and exact scope',
    () async {
      stdout.writeln('[provenance] mixed scope batch denied before dispatch');
      final cfg = sessions.setup();
      final map = content();
      final other = content(stream: 'other');
      final session = await cfg.manager.openUserSession(
        tenantId: 'same-tenant',
        appUserId: 'A',
        allowedContentMapping: [map, other],
      );
      cfg.apis.single.addJson({
        'data': [
          {'asset_id': 'a', 'filename': 'a.mp4'},
        ],
      });
      final a = (await session.scope(map).search('a')).assets.single;
      cfg.apis.single.addJson({
        'data': [
          {'asset_id': 'b', 'filename': 'b.mp4'},
        ],
      });
      final b = (await session.scope(other).search('b')).assets.single;
      expect(
        () => session.scope(map).addAssets([a, b]),
        throwsA(isA<ValidationException>()),
      );
      expect(cfg.apis.single.requests, hasLength(2));
      cfg.apis.single.addJson({'status': 'ok', 'data': 'tenant-private'});
      final added = await session.scope(map).addAssets([a]);
      expect(added.raw, {'status': 'ok'});
      expect((cfg.apis.single.requests.last.jsonBody! as Map)['asset_ids'], [
        'a',
      ]);
      final next = await cfg.manager.openResolvedSession(
        () async => sessions.policy('B', map),
      );
      expect(
        () => next.scope(map).addAssets([a]),
        throwsA(isA<ValidationException>()),
      );
      expect(cfg.apis.last.requests, isEmpty);
      await cfg.manager.close();
    },
  );

  test(
    'job status requires live provenance and strips response bodies',
    () async {
      stdout.writeln(
        '[provenance] index create binds trusted job; late owner reuse denied',
      );
      final cfg = sessions.setup();
      final map = content();
      final a = await cfg.manager.openResolvedSession(
        () async => sessions.policy('A', map),
      );
      cfg.apis.single.addJson({
        'job_id': 'job-a',
        'status': 'queued',
        'signed_url': 'secret',
      });
      final job = await a.scope(map).createIndex();
      expect(job.raw, {'job_id': 'job-a', 'status': 'queued'});
      cfg.apis.single.addJson({
        'job_id': 'job-a',
        'status': 'done',
        'data': [
          {'secret': 'B'},
        ],
      });
      expect((await a.scope(map).indexStatus(job)).raw, {
        'job_id': 'job-a',
        'status': 'done',
      });
      final b = await cfg.manager.openResolvedSession(
        () async => sessions.policy('B', map),
      );
      expect(
        () => b.scope(map).indexStatus(job),
        throwsA(isA<ValidationException>()),
      );
      expect(
        () => b.scope(map).rebindJob(job.toDurableReference()),
        throwsA(isA<ValidationException>()),
      );
      expect(cfg.apis.last.requests, isEmpty);
      await cfg.manager.close();
    },
  );

  test(
    'durable job rebind needs exact owner policy and scoped discovery proof',
    () async {
      stdout.writeln(
        '[provenance] restart references do not authorize tenant-wide status lookup',
      );
      final cfg = sessions.setup();
      final map = content();
      final a = await cfg.manager.openResolvedSession(
        () async => sessions.policy('A', map),
      );
      cfg.apis.single.addJson({'job_id': 'job-a', 'status': 'queued'});
      final durable = (await a.scope(map).createIndex()).toDurableReference();
      final again = await cfg.manager.openResolvedSession(
        () async => sessions.policy('A', map),
      );
      cfg.apis.last.addJson({
        'data': [
          {'job_id': 'job-a'},
        ],
      });
      await expectLater(
        again.scope(map).rebindJob(durable),
        throwsA(isA<FeatureDisabled>()),
      );
      cfg.apis.last.addJson({
        'data': [row('job-a')],
      });
      final rebound = await again.scope(map).rebindJob(durable);
      expect(rebound.jobId, 'job-a');
      expect(
        cfg.apis.last.requests.every(
          (r) => r.uri.path.endsWith(Routes.indexationJobs),
        ),
        isTrue,
      );
      await cfg.manager.close();
    },
  );

  test(
    'collection discovery filters mappings; aggregate metadata needs wide grant',
    () async {
      stdout.writeln(
        '[provenance] hidden collection metadata and counts are not exposed',
      );
      final cfg = sessions.setup();
      final map = content();
      final a = await cfg.manager.openResolvedSession(
        () async => sessions.policy('A', map),
      );
      final data = {
        'data': [
          {
            'group_name': 'shared',
            'mode': 'vid_file',
            'lancedb_versions': ['v1', 'v99'],
            'secret': 'private',
          },
          {'group_name': 'B-private', 'mode': 'vid_file', 'secret': 'B'},
        ],
        'total': 999,
      };
      cfg.apis.single.addJson(data);
      expect(await a.listCollections(), [map]);
      cfg.apis.single.addJson(data);
      expect(await a.scope(map).collectionInfo(), isNull);
      expect(
        () => a.scope(map).deleteIndex('v1'),
        throwsA(isA<ValidationException>()),
      );
      final wide = content(wide: true);
      final current = await cfg.manager.openResolvedSession(
        () async => sessions.policy('A', wide),
      );
      cfg.apis.last.addJson(data);
      expect(await current.scope(wide).latestVersion(), 99);
      await cfg.manager.close();
    },
  );

  test(
    'media exposes guarded bytes using only a proven scoped selector',
    () async {
      stdout.writeln(
        '[provenance] caller never receives storage URL or arbitrary sink',
      );
      final cfg = sessions.setup();
      final map = content();
      final a = await cfg.manager.openResolvedSession(
        () async => sessions.policy('A', map),
      );
      cfg.apis.single.addJson({
        'data': [
          {'asset_id': 'a', 'filename': 'a.mp4', 'ts_unix_13digits': 123},
        ],
      });
      final hit = (await a.scope(map).search('a')).assets.single;
      cfg.apis.single.addJson({
        'found': true,
        'url_pre_signed': 'https://objects.test/private',
      });
      cfg.apis.single.addResponse(
        VmodalResponse(statusCode: 200, body: Stream.value([1, 2, 3])),
      );
      final bytes = await a.scope(map).imageBytes(hit);
      expect(bytes, Uint8List.fromList([1, 2, 3]));
      expect(
        (cfg.apis.single.requests[1].jsonBody! as Map)['group_name'],
        'shared',
      );
      final b = await cfg.manager.openResolvedSession(
        () async => sessions.policy('B', map),
      );
      expect(
        () => b.scope(map).imageBytes(hit),
        throwsA(isA<ValidationException>()),
      );
      expect(cfg.apis.last.requests, isEmpty);
      await cfg.manager.close();
    },
  );

  test(
    'scoped API errors omit server body, details and server message',
    () async {
      stdout.writeln(
        '[provenance] tenant error bodies never escape restricted interface',
      );
      final cfg = sessions.setup();
      final map = content();
      final a = await cfg.manager.openResolvedSession(
        () async => sessions.policy('A', map),
      );
      cfg.apis.single.addJson({'detail': 'B private signed URL'}, status: 403);
      await expectLater(
        a.scope(map).search('a'),
        throwsA(
          isA<SdkException>()
              .having((e) => e.body, 'body', isNull)
              .having((e) => e.details, 'details', isNull)
              .having(
                (e) => e.message.contains('B private'),
                'message',
                isFalse,
              ),
        ),
      );
      await cfg.manager.close();
    },
  );
}
