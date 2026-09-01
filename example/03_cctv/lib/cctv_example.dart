import 'dart:async';
import 'dart:io';

import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

/// One CCTV video and its caller-owned timestamp and metadata.
final class CctvUploadInput {
  CctvUploadInput({
    required this.file,
    required this.videoFilename,
    required this.startDatetimeUser,
    required this.metadataText,
    required List<String> metadataTags,
    this.reProcess = false,
  }) : metadataTags = List<String>.unmodifiable(metadataTags);

  final File file;
  final String videoFilename;
  final String startDatetimeUser;
  final String metadataText;
  final List<String> metadataTags;
  final bool reProcess;

  VideoUploadOptions toUploadOptions() => VideoUploadOptions(
    videoFilename: videoFilename,
    startDatetimeUser: startDatetimeUser,
    metadataText: metadataText,
    metadataTags: metadataTags,
    reProcess: reProcess,
  );
}

/// Absolute-time search input for indexed CCTV frames.
final class CctvSearchInput {
  const CctvSearchInput({
    required this.visualQuery,
    required this.metadataQuery,
    required this.startDate,
    required this.endDate,
    this.versionLancedb,
  });

  final String visualQuery;
  final String metadataQuery;
  final String startDate;
  final String endDate;
  final int? versionLancedb;

  ScopedSearchOptions toSearchOptions() => ScopedSearchOptions(
    queryMetadataText: metadataQuery,
    searchSources: const <String>['image'],
    startDate: startDate,
    endDate: endDate,
    versionLancedb: versionLancedb,
  );
}

/// Progressive CCTV example: auth, discovery, upload, index, then search.
final class CctvExample {
  CctvExample({
    required ApiKeyProvider apiKeyProvider,
    this.projectId = 'cctv_app',
    this.collectionName = 'entrance_cameras',
    this.streamName = 'camera_01',
  }) : client = VmodalClient(
         config: SdkConfig(apiKeyProvider: apiKeyProvider),
       ) {
    project = VModal.fromClient(projectId: projectId, client: client);
    camera = project.scope(
      collectionName: collectionName,
      streamName: streamName,
    );
  }

  final String projectId;
  final String collectionName;
  final String streamName;
  final VmodalClient client;
  late final VModalProject project;
  late final VModalScope camera;

  Future<UserProfile> authenticate() => client.auth.me();

  Future<List<String>> listCollections() =>
      project.listCollections(mode: 'vid_file');

  Future<IndexationJobsListResponse> listIndexJobs() => camera.listIndexJobs();

  UploadTask<VideoUploadResponse> upload(CctvUploadInput input) =>
      camera.upload(
        UploadSource.fromFile(input.file),
        options: ScopedUploadOptions(uploadOptions: input.toUploadOptions()),
      );

  Future<IndexationSubmitResponse> createIndex() => camera.createIndex(
    options: const ScopedCreateIndexOptions(
      indexType: 'vid_img_emb',
      modality: 'vid_img_emb',
    ),
  );

  Future<IndexationStatusResponse> waitForIndex(
    String jobId, {
    Duration timeout = const Duration(minutes: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final status = await camera.indexStatus(jobId);
      if (const <String>{
        'completed',
        'success',
        'done',
      }.contains(status.status)) {
        return status;
      }
      if (const <String>{'failed', 'error'}.contains(status.status)) {
        throw StateError('CCTV index job failed: ${status.status}');
      }
      await Future<void>.delayed(const Duration(seconds: 5));
    }
    throw TimeoutException('CCTV index job did not finish', timeout);
  }

  Future<SearchResponse> search(CctvSearchInput input) =>
      camera.search(input.visualQuery, options: input.toSearchOptions());

  Future<void> close() => project.close();
}
