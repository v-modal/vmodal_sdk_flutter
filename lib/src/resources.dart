import 'dart:typed_data';

import 'errors.dart';
import 'http.dart';
import 'models.dart';
import 'routes.dart';
import 'transport.dart';
import 'upload.dart';
import 'utils.dart';

class AuthResource {
  AuthResource(this.http);

  final VmodalHttp http;

  Future<HealthResponse> health({CancellationToken? cancellation}) async =>
      HealthResponse(
        await http.request(
          'GET',
          Routes.full(Routes.health),
          cancellation: cancellation,
        ),
      );

  Future<bool> authCheck({CancellationToken? cancellation}) async {
    await health(cancellation: cancellation);
    return true;
  }

  Future<UserProfile> me({CancellationToken? cancellation}) async =>
      UserProfile(
        await http.requestUsers(
          'GET',
          Routes.usersFull(Routes.authMe),
          cancellation: cancellation,
        ),
      );
}

class SearchesResource {
  SearchesResource(this.http);

  final VmodalHttp http;

  Future<SearchResponse> searchVideo(
    SearchRequest request, {
    CancellationToken? cancellation,
  }) async {
    request.validate();
    return SearchResponse(
      await http.request(
        'POST',
        Routes.full(Routes.searchClient),
        json: request.toJson(),
        cancellation: cancellation,
      ),
    );
  }
}

class CollectionsResource {
  CollectionsResource(this.http, this.signedUploads);

  final VmodalHttp http;
  final SignedUploadTransport signedUploads;

  Future<GroupsResponse> listGroups({
    String? mode,
    CancellationToken? cancellation,
  }) async => GroupsResponse(
    await http.request(
      'GET',
      Routes.full(Routes.groups),
      params: <String, Object?>{if (mode != null) 'mode': mode},
      cancellation: cancellation,
    ),
  );

  Future<UploadResponse> uploadFile(
    VmodalFilePart part, {
    String groupName = '',
    String mode = 'vid_file',
    String streamName = 'astream',
    String description = '',
    List<String> tag = const <String>[],
    CancellationToken? cancellation,
  }) async => UploadResponse(
    await http.request(
      'POST',
      Routes.full(Routes.upload),
      data: <String, Object?>{
        'mode': mode,
        'group_name': groupName,
        'stream_name': streamName,
        'description': description,
        if (tag.isNotEmpty) 'tag': tag,
      },
      files: <VmodalFilePart>[part],
      cancellation: cancellation,
    ),
  );

  Never uploadFolder() => throw const FeatureDisabled(
    'folder upload is disabled on server (cannot scan remote PC/laptop)',
  );

  Future<MetadataParquetUploadResponse> uploadMetadataJsonl(
    VmodalFilePart part, {
    String mode = 'img_file',
    String groupName = '',
    String streamName = '',
    String writeMode = 'append',
    bool allowOverlap = false,
    CancellationToken? cancellation,
  }) async {
    final form = <String, Object?>{
      'mode': mode,
      'group_name': groupName,
      'stream_name': streamName,
      'write_mode': writeMode,
      'allow_overlap': '$allowOverlap',
      if (http.config.normalizedMode == 'direct')
        'user_id': http.config.normalizedUserId,
    };
    Map<String, Object?> raw;
    try {
      raw = await http.request(
        'POST',
        Routes.full(Routes.uploadMetadataJsonl),
        data: form,
        files: <VmodalFilePart>[part],
        cancellation: cancellation,
      );
    } on ApiException catch (error) {
      if (error.statusCode != 404) rethrow;
      raw = await http.request(
        'POST',
        Routes.uploadMetadataItemParquetInternal,
        data: form,
        files: <VmodalFilePart>[part],
        cancellation: cancellation,
      );
    }
    return MetadataParquetUploadResponse(raw);
  }

  Future<CollectionAddAssetsResponse> addAssets({
    required String collectionId,
    required List<String> assetIds,
    required String mode,
    required String groupName,
    String streamName = 'astream',
    CancellationToken? cancellation,
  }) async {
    final request = CollectionAddAssetsRequest(
      collectionId: collectionId,
      assetIds: assetIds,
      mode: mode,
      groupName: groupName,
      streamName: streamName,
    );
    request.validate();
    final path = Routes.collectionAddAssets.replaceAll(
      '{collection_id}',
      Uri.encodeComponent(collectionId),
    );
    return CollectionAddAssetsResponse(
      await http.request(
        'POST',
        Routes.full(path),
        json: request.toJson(),
        cancellation: cancellation,
      ),
    );
  }

  Future<CollectionDescriptionUpdateResponse> updateDescription({
    required String groupName,
    required String mode,
    required String streamName,
    required String filenameSanitized,
    String? description,
    List<String>? tag,
    CancellationToken? cancellation,
  }) async => CollectionDescriptionUpdateResponse(
    await http.request(
      'POST',
      Routes.full(Routes.collectionDescriptionUpdate),
      data: <String, Object?>{
        'group_name': groupName,
        'mode': mode,
        'stream_name': streamName,
        'filename_sanitized': filenameSanitized,
        if (description != null) 'description': description,
        if (tag != null) 'tag': tag,
      },
      cancellation: cancellation,
    ),
  );

  Future<DeleteCollectionResponse> delete({
    required String groupName,
    required String mode,
    String scope = 'all',
    bool dryRun = false,
    bool confirm = false,
    CancellationToken? cancellation,
  }) async {
    final request = DeleteCollectionRequest(
      groupName: groupName,
      mode: mode,
      scope: scope,
      dryRun: dryRun,
      confirm: confirm,
    );
    request.validate();
    return DeleteCollectionResponse(
      await http.request(
        'DELETE',
        Routes.full(Routes.collectionDelete),
        json: request.toJson(),
        cancellation: cancellation,
      ),
    );
  }

  Never create() => throw const FeatureDisabled(
    'no server endpoint; upload creates collection implicitly',
  );
  Never edit() => throw const FeatureDisabled(
    'no server endpoint; upload creates collection implicitly',
  );
  Never autoIndexGet() => throw const FeatureDisabled(
    'collection auto_index is disabled on server',
  );
  Never autoIndexSet() => throw const FeatureDisabled(
    'collection auto_index is disabled on server',
  );
}

class IndexesResource {
  IndexesResource(this.http);

  final VmodalHttp http;

  Future<IndexationJobsListResponse> jobsList({
    String? status,
    String? mode,
    String? groupName,
    int limit = 200,
    CancellationToken? cancellation,
  }) async {
    if (limit < 1 || limit > 1000) {
      throw const ValidationException('limit must be between 1 and 1000');
    }
    return IndexationJobsListResponse(
      await http.request(
        'GET',
        Routes.full(Routes.indexationJobs),
        params: <String, Object?>{
          'limit': limit,
          if (status != null) 'status': status,
          if (mode != null) 'mode': mode,
          if (groupName != null) 'group_name': groupName,
        },
        cancellation: cancellation,
      ),
    );
  }

  Future<IndexationSubmitResponse> createIndex(
    IndexationSubmitRequest request, {
    CancellationToken? cancellation,
  }) async {
    request.validate();
    return IndexationSubmitResponse(
      await http.request(
        'POST',
        Routes.full(Routes.indexationSubmit),
        json: request.toJson(),
        cancellation: cancellation,
      ),
    );
  }

  Future<IndexationStatusResponse> indexStatus(
    String jobId, {
    CancellationToken? cancellation,
  }) async {
    final clean = strRequired(jobId, 'job_id');
    final path = Routes.indexationStatus.replaceAll(
      '{job_id}',
      Uri.encodeComponent(clean),
    );
    try {
      return IndexationStatusResponse(
        await http.request(
          'GET',
          Routes.full(path),
          cancellation: cancellation,
        ),
      );
    } on ApiException catch (error) {
      if (error.statusCode != 404) rethrow;
      final jobs = await jobsList(limit: 1000, cancellation: cancellation);
      final row = objectList(jobs.raw['data'])
          .where((Map<String, Object?> value) => '${value['job_id']}' == clean)
          .firstOrNull;
      if (row == null) rethrow;
      return IndexationStatusResponse(row);
    }
  }

  Future<IndexationDeleteResponse> deleteIndex(
    IndexationDeleteRequest request, {
    CancellationToken? cancellation,
  }) async {
    request.validate();
    return IndexationDeleteResponse(
      await http.request(
        'DELETE',
        Routes.full(Routes.indexationDelete),
        json: request.toJson(),
        cancellation: cancellation,
      ),
    );
  }

  Never embeddingModels() => throw const FeatureDisabled(
    'embedding models endpoint is disabled on server',
  );
}

class AdminResource {
  AdminResource(this.http);

  final VmodalHttp http;

  Future<AdminUserStatsResponse> userStats({
    CancellationToken? cancellation,
  }) async => AdminUserStatsResponse(
    await http.request(
      'GET',
      Routes.full(Routes.adminUserStats),
      cancellation: cancellation,
    ),
  );

  Future<UsageUserDetail> usage({
    String date = '',
    CancellationToken? cancellation,
  }) async => UsageUserDetail(
    await http.requestUsers(
      'GET',
      Routes.usersFull(Routes.adminUsage),
      params: <String, Object?>{
        if (date.trim().isNotEmpty) 'date': date.trim(),
      },
      cancellation: cancellation,
    ),
  );

  Future<CacheStats> cacheStats({CancellationToken? cancellation}) async =>
      CacheStats(
        await http.requestUsers(
          'GET',
          Routes.usersFull(Routes.adminCacheStats),
          cancellation: cancellation,
        ),
      );
}

class R2Resource {
  R2Resource(this.http);

  final VmodalHttp http;

  Future<PresignedUploadResponse> presignUploadFile({
    required String mode,
    required String groupName,
    required String streamName,
    required String modality,
    required String filename,
    int expiresIn = 900,
    CancellationToken? cancellation,
  }) async => PresignedUploadResponse(
    await http.requestUsers(
      'GET',
      Routes.usersFull(Routes.r2UploadFile),
      params: <String, Object?>{
        'mode': mode,
        'group_name': groupName,
        'stream_name': streamName,
        'modality': modality,
        'filename': filename,
        'expires_in': expiresIn,
      },
      cancellation: cancellation,
    ),
  );

  Future<PresignedFolderResponse> presignUploadFolderVideo({
    required String mode,
    required String groupName,
    required String streamName,
    required List<String> filenames,
    int expiresIn = 900,
    CancellationToken? cancellation,
  }) async => PresignedFolderResponse(
    await http.requestUsers(
      'POST',
      Routes.usersFull(Routes.r2UploadFolderVideo),
      json: <String, Object?>{
        'mode': mode,
        'group_name': groupName,
        'stream_name': streamName,
        'filenames': filenames,
        'expires_in': expiresIn,
      },
      cancellation: cancellation,
    ),
  );
}

class ImagesResource {
  ImagesResource(this.http);

  final VmodalHttp http;

  Future<ImageUrlResponse> getUrl({
    required String mode,
    required String groupName,
    required String modality,
    required String filename,
    String streamName = 'astream',
    Object? tsUnix13digits,
    String? userid,
    CancellationToken? cancellation,
  }) async => ImageUrlResponse(
    await http.request(
      'POST',
      Routes.full(Routes.imageGetUrl),
      json: <String, Object?>{
        'mode': mode,
        'group_name': groupName,
        'modality': modality,
        'stream_name': streamName,
        'filename': filename,
        if (tsUnix13digits != null) 'ts_unix_13digits': '$tsUnix13digits',
        if (http.config.normalizedMode == 'direct' &&
            (userid?.trim().isNotEmpty ?? false))
          'userid': userid,
      },
      cancellation: cancellation,
    ),
  );

  Future<ImageUrlBulkResponse> getUrlBulk(
    List<Map<String, Object?>> records, {
    String? userid,
    CancellationToken? cancellation,
  }) async {
    final safe = http.config.normalizedMode == 'direct'
        ? records
        : records
              .map(
                (Map<String, Object?> row) => Map<String, Object?>.from(row)
                  ..remove('userid')
                  ..remove('user_id'),
              )
              .toList();
    return ImageUrlBulkResponse(
      await http.request(
        'POST',
        Routes.full(Routes.imageGetUrlBulk),
        json: <String, Object?>{
          'records': safe,
          if (http.config.normalizedMode == 'direct' &&
              (userid?.trim().isNotEmpty ?? false))
            'userid': userid,
        },
        cancellation: cancellation,
      ),
    );
  }

  Future<Uint8List> getImageFromUrl(
    String urlPreSigned, {
    String? userid,
    CancellationToken? cancellation,
  }) => http.requestBytes(
    'POST',
    Routes.full(Routes.imageGetImage),
    json: <String, Object?>{
      'url_pre_signed': urlPreSigned,
      if (http.config.normalizedMode == 'direct' &&
          (userid?.trim().isNotEmpty ?? false))
        'userid': userid,
    },
    cancellation: cancellation,
  );

  Future<ImageGetBulkResponse> getImageBulkFromUrls(
    List<String> urls, {
    String? userid,
    CancellationToken? cancellation,
  }) async => ImageGetBulkResponse(
    await http.request(
      'POST',
      Routes.full(Routes.imageGetImageBulk),
      json: <String, Object?>{
        'urls': urls,
        if (http.config.normalizedMode == 'direct' &&
            (userid?.trim().isNotEmpty ?? false))
          'userid': userid,
      },
      cancellation: cancellation,
    ),
  );
}

class GDriveResource {
  Never privateAuthUrl() => throw const FeatureDisabled(
    'private google drive auth endpoint is disabled on server',
  );
  Never privateDownload() => throw const FeatureDisabled(
    'private google drive download endpoint is disabled on server',
  );
}

class SqlResource {
  Never query() =>
      throw const FeatureDisabled('sql query endpoint is disabled on server');
}
