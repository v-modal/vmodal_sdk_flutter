import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:framebase/data/archive_controller.dart';
import 'package:framebase/data/search_gateway.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

class UploadGateway extends SearchGateway {
  UploadGateway()
    : super(MutableApiKeyProvider('fixture-upload'), 'scope_upload');

  @override
  Future<UploadTask<VideoUploadResponse>> upload(File file) async =>
      UploadTask<VideoUploadResponse>.start((cancellation, emit) async {
        emit(UploadProgress(file.lengthSync(), file.lengthSync()));
        return VideoUploadResponse(const <String, Object?>{
          'uploaded': true,
          'asset_id': 'asset-uploaded',
        });
      });

  @override
  Future<IndexationSubmitResponse> createIndex(
    CancellationToken cancellation,
  ) async => IndexationSubmitResponse(const <String, Object?>{
    'job_id': 'job-ready',
    'status': 'queued',
  });

  @override
  Future<IndexationStatusResponse> indexStatus(
    String job,
    CancellationToken cancellation,
  ) async => IndexationStatusResponse(const <String, Object?>{
    'job_id': 'job-ready',
    'status': 'success',
  });

  @override
  Future<void> refreshVersion() async => version = 1;
}

class DeleteGateway extends SearchGateway {
  DeleteGateway({this.deleteError})
    : super(MutableApiKeyProvider('fixture-delete'), 'scope_delete');
  final Object? deleteError;
  int previews = 0;
  int deletes = 0;

  @override
  Future<DeleteCollectionResponse> previewLibraryDeletion(
    CancellationToken cancellation,
  ) async {
    cancellation.throwIfCanceled();
    previews++;
    return DeleteCollectionResponse(const <String, Object?>{
      'status': 'dry_run',
      'group_name': 'scope_delete',
      'mode': 'vid_file',
      'scope': 'all',
      'removed_bytes': 12,
      'sql_rows_deleted': 3,
      'execution_time_ms': 4,
    });
  }

  @override
  Future<DeleteCollectionResponse> deleteLibrary(
    CancellationToken cancellation,
  ) async {
    cancellation.throwIfCanceled();
    deletes++;
    if (deleteError case final Object error) throw error;
    return DeleteCollectionResponse(const <String, Object?>{
      'status': 'ok',
      'group_name': 'scope_delete',
      'mode': 'vid_file',
      'scope': 'all',
    });
  }
}

class DelayedDeleteGateway extends DeleteGateway {
  final Completer<DeleteCollectionResponse> completion =
      Completer<DeleteCollectionResponse>();

  @override
  Future<DeleteCollectionResponse> deleteLibrary(
    CancellationToken cancellation,
  ) {
    deletes++;
    return completion.future;
  }
}

class BlockingGateway extends SearchGateway {
  BlockingGateway()
    : super(MutableApiKeyProvider('fixture-blocking'), 'scope_blocking') {
    version = 1;
  }

  final uploadStarted = Completer<void>();
  final indexStarted = Completer<void>();
  final searchStarted = Completer<void>();
  UploadTask<VideoUploadResponse>? activeUpload;

  @override
  Future<UploadTask<VideoUploadResponse>> upload(File file) async {
    final task = UploadTask<VideoUploadResponse>.start((token, emit) async {
      uploadStarted.complete();
      await token.whenCanceled;
      token.throwIfCanceled();
      throw StateError('Canceled upload continued');
    });
    activeUpload = task;
    return task;
  }

  @override
  Future<IndexationSubmitResponse> createIndex(
    CancellationToken cancellation,
  ) async => IndexationSubmitResponse(const <String, Object?>{
    'job_id': 'job-continues-remotely',
    'status': 'queued',
  });

  @override
  Future<IndexationStatusResponse> indexStatus(
    String job,
    CancellationToken cancellation,
  ) async {
    indexStarted.complete();
    await cancellation.whenCanceled;
    cancellation.throwIfCanceled();
    throw StateError('Canceled index polling continued');
  }

  @override
  Future<SearchBatch> search(
    String query, {
    CancellationToken? cancellation,
    String? imageQuery,
    double maxDistance = 1.5,
  }) async {
    searchStarted.complete();
    await cancellation!.whenCanceled;
    cancellation.throwIfCanceled();
    throw StateError('Canceled search continued');
  }
}

void main() {
  test(
    'archive manifests and imported files stay with their account',
    () async {
      final root = await Directory.systemTemp.createTemp('framebase_test_');
      addTearDown(() => root.delete(recursive: true));
      const scopeA = 'scope_7K3A';
      const scopeB = 'scope_B9Q2';
      final a = SearchGateway(MutableApiKeyProvider('fixture-a'), scopeA);
      final b = SearchGateway(MutableApiKeyProvider('fixture-b'), scopeB);
      final c = ArchiveController(supportDirectory: root);
      await c.activate(scopeA, a, canRead: true, canWrite: true);
      c.clips.first.uploaded = true;
      c.pendingJob = 'alice-job';
      c.record('Alice upload', 'done');
      final src = File('${root.path}/sample.mp4');
      await src.writeAsBytes([1, 2, 3]);
      await c.importFile(src.path, 3);
      await c.save();
      expect(c.clips.last.path, startsWith('${root.path}/accounts/$scopeA/'));
      c.deactivate();
      expect(c.events, isEmpty);
      expect(c.pendingJob, isEmpty);
      await c.activate(scopeB, b, canRead: true, canWrite: true);
      expect(c.clips, hasLength(3));
      expect(c.clips.first.uploaded, isFalse);
      expect(c.pendingJob, isEmpty);
      expect(c.events, isEmpty);
      await c.importFile(src.path, 4);
      expect(c.clips.last.path, startsWith('${root.path}/accounts/$scopeB/'));
      await c.activate(scopeA, a, canRead: true, canWrite: true);
      expect(c.clips, hasLength(4));
      expect(c.clips.first.uploaded, isTrue);
      expect(c.pendingJob, 'alice-job');
      expect(c.events.any((e) => e.title == 'Alice upload'), isTrue);
      final manifest = File('${root.path}/accounts/$scopeA/archive.json');
      final saved = await manifest.readAsString();
      for (final forbidden in [
        'fixture-a',
        'api_token',
        'session_id',
        'issued_at',
        'expires_at',
      ]) {
        expect(saved, isNot(contains(forbidden)));
      }
      expect(await Directory('${root.path}/accounts/$scopeB').exists(), isTrue);
      await a.close();
      await b.close();
      c.dispose();
    },
  );

  test(
    'active upload, index polling, and search unwind on cancellation',
    () async {
      final root = await Directory.systemTemp.createTemp('framebase_cancel_');
      addTearDown(() => root.delete(recursive: true));
      final source = File('${root.path}/camera.mp4')
        ..writeAsBytesSync([1, 2, 3]);
      final gateway = BlockingGateway();
      final c = ArchiveController(supportDirectory: root);
      await c.activate(
        'scope_blocking',
        gateway,
        canRead: true,
        canWrite: true,
      );
      c.clips = [
        ArchiveClip(
          id: 'camera',
          title: 'Camera',
          location: 'Test',
          duration: 1,
          asset: '',
          poster: '',
          path: source.path,
          bundled: false,
        ),
      ];

      final upload = c.uploadAndIndex();
      await gateway.uploadStarted.future;
      c.stopWork();
      await upload;
      expect(gateway.activeUpload!.isCanceled, isTrue);
      expect(c.busy, isFalse);
      expect(c.clips.single.uploaded, isFalse);

      c.clips.single.uploaded = true;
      final index = c.uploadAndIndex();
      await gateway.indexStarted.future;
      c.stopWork();
      await index;
      expect(c.busy, isFalse);
      expect(c.pendingJob, 'job-continues-remotely');
      expect(c.notice, contains('Indexing continues on the server'));

      final search = c.search('cyclist');
      await gateway.searchStarted.future;
      c.invalidateSearch();
      await search;
      expect(c.searching, isFalse);
      expect(c.batch, isNull);

      await c.save();
      c.dispose();
      await gateway.close();
    },
  );

  test('upload asset identity persists and controls archive lookup', () async {
    final root = await Directory.systemTemp.createTemp('framebase_asset_');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}/camera.mp4');
    await source.writeAsBytes([1, 2, 3]);
    final gateway = UploadGateway();
    final controller = ArchiveController(supportDirectory: root);
    await controller.activate('alice', gateway, canRead: true, canWrite: true);
    controller.clips = <ArchiveClip>[
      ArchiveClip(
        id: 'camera',
        title: 'Camera',
        location: 'Test',
        duration: 3,
        asset: '',
        poster: '',
        path: source.path,
        bundled: false,
      ),
    ];

    await controller.uploadAndIndex();
    expect(controller.clips.single.remoteAssetId, 'asset-uploaded');
    controller.deactivate();
    await controller.activate('alice', gateway, canRead: true, canWrite: true);
    final clip = controller.clips.single;
    expect(clip.remoteAssetId, 'asset-uploaded');
    expect(
      controller.clipFor(
        VideoSearchHit(const <String, Object?>{
          'asset_id': 'asset-uploaded',
          'file_name': 'renamed.mp4',
        }),
      ),
      same(clip),
    );
    expect(
      controller.clipFor(
        VideoSearchHit(const <String, Object?>{
          'asset_id': 'asset-other',
          'file_name': 'camera.mp4',
        }),
      ),
      isNull,
    );
    expect(
      controller.clipFor(
        VideoSearchHit(const <String, Object?>{'file_name': 'camera.mp4'}),
      ),
      same(clip),
    );
    expect(
      ArchiveClip.fromJson(const <String, dynamic>{
        'id': 'old',
        'title': 'Old',
        'location': 'Test',
        'duration': 1,
        'asset': '',
        'poster': '',
      }).remoteAssetId,
      isNull,
    );
    await controller.save();
    controller.dispose();
    await gateway.close();
  });

  test('missing paths normalize and uploaded remote rows survive', () async {
    final root = await Directory.systemTemp.createTemp('framebase_remote_');
    addTearDown(() => root.delete(recursive: true));
    final gateway = SearchGateway(
      MutableApiKeyProvider('fixture-remote'),
      'scope_remote',
    );
    final c = ArchiveController(supportDirectory: root);
    await c.activate('scope_remote', gateway, canRead: true, canWrite: true);
    c.clips = [
      ArchiveClip(
        id: 'remote',
        title: 'Remote',
        location: 'Test',
        duration: 2,
        asset: '',
        poster: '',
        path: '${root.path}/missing.mp4',
        remoteAssetId: 'asset-remote',
        uploaded: true,
        bundled: false,
      ),
      ArchiveClip(
        id: 'gone',
        title: 'Gone',
        location: 'Test',
        duration: 2,
        asset: '',
        poster: '',
        path: '${root.path}/also-missing.mp4',
        bundled: false,
      ),
    ];
    await c.save();
    c.deactivate();
    await c.activate('scope_remote', gateway, canRead: true, canWrite: true);
    expect(c.clips, hasLength(1));
    expect(c.clips.single.path, isNull);
    expect(c.clips.single.remoteOnly, isTrue);
    expect(
      c.clipFor(VideoSearchHit(const {'asset_id': 'asset-remote'})),
      same(c.clips.single),
    );
    c.dispose();
    await gateway.close();
  });

  test('local removal stays contained and keeps cloud identity', () async {
    final root = await Directory.systemTemp.createTemp('framebase_remove_');
    addTearDown(() => root.delete(recursive: true));
    final gateway = SearchGateway(
      MutableApiKeyProvider('fixture-remove'),
      'scope_remove',
    );
    final c = ArchiveController(supportDirectory: root);
    await c.activate('scope_remove', gateway, canRead: true, canWrite: true);
    final account = Directory('${root.path}/accounts/scope_remove');
    await account.create(recursive: true);
    final local = File('${account.path}/local.mp4')..writeAsBytesSync([1]);
    final remote = File('${account.path}/remote.mp4')..writeAsBytesSync([2]);
    final outside = File('${root.path}/outside.mp4')..writeAsBytesSync([3]);
    ArchiveClip clip(String id, String path, {bool uploaded = false}) =>
        ArchiveClip(
          id: id,
          title: id,
          location: 'Test',
          duration: 1,
          asset: '',
          poster: '',
          path: path,
          remoteAssetId: uploaded ? 'asset-$id' : null,
          uploaded: uploaded,
          bundled: false,
        );

    final localClip = clip('local', local.path);
    final remoteClip = clip('remote', remote.path, uploaded: true);
    final staleClip = clip('stale', outside.path);
    c.clips = [localClip, remoteClip, staleClip];
    expect(await c.removeLocalCopy(staleClip), LocalRemovalResult.unavailable);
    expect(await outside.exists(), isTrue);
    expect(await c.removeLocalCopy(localClip), LocalRemovalResult.removed);
    expect(await local.exists(), isFalse);
    expect(c.clips, isNot(contains(localClip)));
    expect(await c.removeLocalCopy(remoteClip), LocalRemovalResult.removed);
    expect(await remote.exists(), isFalse);
    expect(remoteClip.path, isNull);
    expect(remoteClip.uploaded, isTrue);
    expect(remoteClip.remoteAssetId, 'asset-remote');
    c.dispose();
    await gateway.close();
  });

  test('preview is non-mutating and commit keeps device videos', () async {
    final root = await Directory.systemTemp.createTemp('framebase_delete_');
    addTearDown(() => root.delete(recursive: true));
    final gateway = DeleteGateway()..version = 7;
    final c = ArchiveController(supportDirectory: root);
    await c.activate('scope_delete', gateway, canRead: true, canWrite: true);
    final account = Directory('${root.path}/accounts/scope_delete');
    await account.create(recursive: true);
    final file = File('${account.path}/kept.mp4')..writeAsBytesSync([1, 2]);
    ArchiveClip uploaded(String id, {String? path}) => ArchiveClip(
      id: id,
      title: id,
      location: 'Test',
      duration: 1,
      asset: '',
      poster: '',
      path: path,
      remoteAssetId: 'asset-$id',
      uploaded: true,
      bundled: false,
    );

    c.clips = [uploaded('kept', path: file.path), uploaded('remote')];
    c.indexVersion = 7;
    final preview = await c.previewCloudLibraryDeletion();
    expect(preview?.removedBytes, 12);
    expect(c.clips, hasLength(2));
    expect(c.clips.every((item) => item.uploaded), isTrue);
    expect(await c.deleteCloudLibrary(), CloudDeletionResult.deleted);
    expect(gateway.previews, 1);
    expect(gateway.deletes, 1);
    expect(await file.exists(), isTrue);
    expect(c.clips, hasLength(1));
    expect(c.clips.single.id, 'kept');
    expect(c.clips.single.uploaded, isFalse);
    expect(c.clips.single.remoteAssetId, isNull);
    expect(c.indexVersion, isNull);
    c.dispose();
    await gateway.close();
  });

  test('known late success reconciles only its captured scope', () async {
    final root = await Directory.systemTemp.createTemp('framebase_late_');
    addTearDown(() => root.delete(recursive: true));
    final a = DelayedDeleteGateway();
    final b = SearchGateway(MutableApiKeyProvider('fixture-b'), 'scope_b');
    final c = ArchiveController(supportDirectory: root);
    await c.activate('scope_delete', a, canRead: true, canWrite: true);
    final account = Directory('${root.path}/accounts/scope_delete');
    await account.create(recursive: true);
    final file = File('${account.path}/kept.mp4')..writeAsBytesSync([1]);
    c.clips = [
      ArchiveClip(
        id: 'kept',
        title: 'Kept',
        location: 'Test',
        duration: 1,
        asset: '',
        poster: '',
        path: file.path,
        remoteAssetId: 'asset-kept',
        uploaded: true,
        bundled: false,
      ),
    ];
    await c.save();
    final deletion = c.deleteCloudLibrary();
    await Future<void>.delayed(Duration.zero);
    await c.activate('scope_b', b, canRead: true, canWrite: true);
    expect(c.clips, hasLength(3));
    a.completion.complete(
      DeleteCollectionResponse(const {
        'status': 'ok',
        'group_name': 'scope_delete',
        'mode': 'vid_file',
        'scope': 'all',
      }),
    );
    expect(await deletion, CloudDeletionResult.deleted);
    expect(c.clips, hasLength(3));
    expect(c.clips.any((item) => item.id == 'kept'), isFalse);

    await c.activate('scope_delete', a, canRead: true, canWrite: true);
    expect(c.clips.single.id, 'kept');
    expect(c.clips.single.uploaded, isFalse);
    expect(c.clips.single.remoteAssetId, isNull);
    expect(await file.exists(), isTrue);
    c.dispose();
    await a.close();
    await b.close();
  });

  test('failed cloud commit keeps conservative remote state', () async {
    final root = await Directory.systemTemp.createTemp('framebase_fail_');
    addTearDown(() => root.delete(recursive: true));
    final gateway = DeleteGateway(
      deleteError: const ApiException('active', statusCode: 409),
    );
    final c = ArchiveController(supportDirectory: root);
    await c.activate('scope_delete', gateway, canRead: true, canWrite: true);
    c.clips = [
      ArchiveClip(
        id: 'remote',
        title: 'Remote',
        location: 'Test',
        duration: 1,
        asset: '',
        poster: '',
        remoteAssetId: 'asset-remote',
        uploaded: true,
        bundled: false,
      ),
    ];
    expect(await c.deleteCloudLibrary(), CloudDeletionResult.failed);
    expect(c.clips.single.uploaded, isTrue);
    expect(c.clips.single.remoteAssetId, 'asset-remote');
    expect(c.notice, contains('still running'));
    c.dispose();
    await gateway.close();
  });
}
