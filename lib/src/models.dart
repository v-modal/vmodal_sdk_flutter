import 'errors.dart';
import 'utils.dart';

class JsonBackedResponse {
  const JsonBackedResponse([this.raw = const <String, Object?>{}]);

  final Map<String, Object?> raw;
}

class SearchResultItem extends JsonBackedResponse {
  const SearchResultItem(super.raw);
}

class GroupItem extends JsonBackedResponse {
  const GroupItem(super.raw);
}

class FolderUploadItem extends JsonBackedResponse {
  const FolderUploadItem(super.raw);
}

class CollectionAsset extends JsonBackedResponse {
  const CollectionAsset(super.raw);
}

class IndexationJobItem extends JsonBackedResponse {
  const IndexationJobItem(super.raw);
}

class AdminUserStatItem extends JsonBackedResponse {
  const AdminUserStatItem(super.raw);
}

class SearchRequest {
  const SearchRequest({
    this.queryText = '',
    this.queryMetadata,
    this.imageQuery,
    this.mode = 'vid_file',
    this.groupName = 'agroup',
    this.streamName = 'astream',
    this.searchSources = const <String>['ocr', 'asr', 'image'],
    this.searchCombineMode = 'union',
    this.startDate,
    this.endDate,
    this.offset = 0,
    this.limit = 50,
    this.textEmbScoreMin = 0.90,
    this.imageEmbScoreMin = 1.5,
    this.versionLancedb,
  });

  final String queryText;
  final Map<String, Object?>? queryMetadata;
  final String? imageQuery;
  final String mode;
  final String groupName;
  final String streamName;
  final List<String> searchSources;
  final String searchCombineMode;
  final String? startDate;
  final String? endDate;
  final int offset;
  final int limit;
  final double textEmbScoreMin;
  final double imageEmbScoreMin;
  final int? versionLancedb;

  void validate() {
    if (queryText.trim().isEmpty && (imageQuery?.trim().isEmpty ?? true)) {
      throw const ValidationException('query_text or image_query is required');
    }
  }

  Map<String, Object?> toJson() => _withoutNull(<String, Object?>{
    'query_text': queryText,
    'query_metadata': queryMetadata,
    'image_query': imageQuery,
    'mode': mode,
    'group_name': groupName,
    'stream_name': streamName,
    'search_sources': searchSources,
    'search_combine_mode': searchCombineMode,
    'start_date': startDate,
    'end_date': endDate,
    'offset': offset,
    'limit': limit,
    'text_emb_score_min': textEmbScoreMin,
    'image_emb_score_min': imageEmbScoreMin,
    'version_lancedb': versionLancedb,
  });
}

class DeleteCollectionRequest {
  const DeleteCollectionRequest({
    required this.groupName,
    required this.mode,
    this.scope = 'all',
    this.dryRun = false,
    this.confirm = false,
  });

  final String groupName;
  final String mode;
  final String scope;
  final bool dryRun;
  final bool confirm;

  void validate() {
    strRequired(groupName, 'group_name');
    strRequired(mode, 'mode');
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'group_name': groupName,
    'mode': mode,
    'scope': scope,
    'dry_run': dryRun,
    'confirm': confirm,
  };
}

class CollectionAddAssetsRequest {
  const CollectionAddAssetsRequest({
    required this.collectionId,
    required this.assetIds,
    required this.mode,
    required this.groupName,
    this.streamName = 'astream',
  });

  final String collectionId;
  final List<String> assetIds;
  final String mode;
  final String groupName;
  final String streamName;

  void validate() {
    strRequired(collectionId, 'collection_id');
    if (assetIds.isEmpty) {
      throw const ValidationException('asset_ids is required');
    }
    strRequired(mode, 'mode');
    strRequired(groupName, 'group_name');
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'collection_id': collectionId,
    'asset_ids': assetIds,
    'mode': mode,
    'group_name': groupName,
    'stream_name': streamName,
  };
}

class IndexationSubmitRequest {
  const IndexationSubmitRequest({
    required this.mode,
    required this.groupName,
    this.streamName,
    this.indexType,
    this.modality,
    this.insertMode = 'append',
    this.createIndex = true,
    this.version = 'new_version',
    this.startDate,
    this.endDate,
    this.embeddingModel,
    this.reProcess = false,
    this.dryRun = false,
  });

  final String mode;
  final String groupName;
  final String? streamName;
  final String? indexType;
  final String? modality;
  final String insertMode;
  final bool createIndex;
  final String version;
  final String? startDate;
  final String? endDate;
  final String? embeddingModel;
  final bool reProcess;
  final bool dryRun;

  void validate() {
    strRequired(mode, 'mode');
    strRequired(groupName, 'group_name');
  }

  Map<String, Object?> toJson() => _withoutNull(<String, Object?>{
    'mode': mode,
    'group_name': groupName,
    'stream_name': streamName,
    'index_type': indexType,
    'modality': modality,
    'insert_mode': insertMode,
    'create_index': createIndex,
    'version': version,
    'start_date': startDate,
    'end_date': endDate,
    'embedding_model': embeddingModel,
    're_process': reProcess,
    'dry_run': dryRun,
  });
}

class IndexationDeleteRequest {
  const IndexationDeleteRequest({
    required this.mode,
    required this.groupName,
    required this.version,
    this.modality,
    this.dryRun = false,
    this.confirm = false,
  });

  final String mode;
  final String groupName;
  final String version;
  final String? modality;
  final bool dryRun;
  final bool confirm;

  void validate() {
    strRequired(mode, 'mode');
    strRequired(groupName, 'group_name');
    strRequired(version, 'version');
  }

  Map<String, Object?> toJson() => _withoutNull(<String, Object?>{
    'mode': mode,
    'group_name': groupName,
    'modality': modality,
    'version': version,
    'dry_run': dryRun,
    'confirm': confirm,
  });
}

class ImageRecord {
  const ImageRecord({
    this.mode = '',
    this.groupName = '',
    this.streamName = 'astream',
    this.filename = '',
    this.frameId = '',
    this.userid,
  });

  final String mode;
  final String groupName;
  final String streamName;
  final String filename;
  final String frameId;
  final String? userid;

  Map<String, Object?> toJson({bool includeIdentity = true}) =>
      _withoutNull(<String, Object?>{
        'mode': mode,
        'group_name': groupName,
        'stream_name': streamName,
        'filename': filename,
        'frame_id': frameId,
        if (includeIdentity) 'userid': userid,
      });
}

class ImageUrlRecord {
  const ImageUrlRecord({
    this.mode = '',
    this.groupName = '',
    this.modality = '',
    this.streamName = 'astream',
    this.filename = '',
    this.tsUnix13digits,
  });

  final String mode;
  final String groupName;
  final String modality;
  final String streamName;
  final String filename;
  final String? tsUnix13digits;

  Map<String, Object?> toJson() => _withoutNull(<String, Object?>{
    'mode': mode,
    'group_name': groupName,
    'modality': modality,
    'stream_name': streamName,
    'filename': filename,
    'ts_unix_13digits': tsUnix13digits,
  });
}

class HealthResponse extends JsonBackedResponse {
  HealthResponse(super.raw)
    : status = '${raw['status'] ?? ''}',
      timestamp = raw['timestamp']?.toString(),
      version = raw['version']?.toString(),
      pythonVersion = raw['python_version']?.toString(),
      dependencies = raw['dependencies'];

  final String status;
  final String? timestamp;
  final String? version;
  final String? pythonVersion;
  final Object? dependencies;
}

class SearchResponse extends JsonBackedResponse {
  SearchResponse(super.raw)
    : data = raw['data'] is List
          ? List<Object?>.from(raw['data']! as List)
          : <Object?>[],
      cntActual = intValue(raw['cnt_actual']),
      cntTotal = intValue(raw['cnt_total']),
      executionTimeMs = doubleValue(raw['execution_time_ms']);

  final List<Object?> data;
  final int cntActual;
  final int cntTotal;
  final double executionTimeMs;
}

class GroupsResponse extends JsonBackedResponse {
  GroupsResponse(super.raw)
    : data = raw['data'] is List
          ? List<Object?>.from(raw['data']! as List)
          : <Object?>[],
      total = intValue(raw['total']),
      executionTimeMs = doubleValue(raw['execution_time_ms']);

  final List<Object?> data;
  final int total;
  final double executionTimeMs;
}

class ExternalUploadSignedUrlResponse extends JsonBackedResponse {
  ExternalUploadSignedUrlResponse(super.raw)
    : userId = '${raw['user_id'] ?? ''}',
      expiresIn = intValue(raw['expires_in']),
      key = '${raw['key'] ?? ''}',
      url = '${raw['url'] ?? ''}',
      method = '${raw['method'] ?? 'PUT'}';

  final String userId;
  final int expiresIn;
  final String key;
  final String url;
  final String method;
}

class MultipartPart extends JsonBackedResponse {
  MultipartPart(super.raw)
    : partNumber = intValue(raw['part_number']),
      etag = '${raw['etag'] ?? ''}',
      sizeBytes = intValue(raw['size_bytes']);

  final int partNumber;
  final String etag;
  final int sizeBytes;
}

class MultipartSignedPart extends JsonBackedResponse {
  MultipartSignedPart(super.raw)
    : partNumber = intValue(raw['part_number']),
      url = '${raw['url'] ?? ''}',
      method = '${raw['method'] ?? 'PUT'}',
      headers = objectMap(
        raw['headers'],
      ).map((String key, Object? value) => MapEntry(key, '$value'));

  final int partNumber;
  final String url;
  final String method;
  final Map<String, String> headers;
}

class MultipartCreateResponse extends JsonBackedResponse {
  MultipartCreateResponse(super.raw)
    : requestId = '${raw['request_id'] ?? ''}',
      uploadId = '${raw['upload_id'] ?? ''}',
      key = '${raw['key'] ?? ''}',
      sizeBytes = intValue(raw['size_bytes']),
      partSizeBytes = intValue(raw['part_size_bytes']),
      partCount = intValue(raw['part_count']),
      status = '${raw['status'] ?? 'created'}';

  final String requestId;
  final String uploadId;
  final String key;
  final int sizeBytes;
  final int partSizeBytes;
  final int partCount;
  final String status;
}

class MultipartSignResponse extends JsonBackedResponse {
  MultipartSignResponse(super.raw)
    : parts = objectList(raw['parts']).map(MultipartSignedPart.new).toList(),
      expiresIn = intValue(raw['expires_in']);

  final List<MultipartSignedPart> parts;
  final int expiresIn;
}

class MultipartStatusResponse extends JsonBackedResponse {
  MultipartStatusResponse(super.raw)
    : status = '${raw['status'] ?? 'uploading'}',
      parts = objectList(raw['parts']).map(MultipartPart.new).toList(),
      etag = '${raw['etag'] ?? ''}',
      sizeBytes = intValue(raw['size_bytes']);

  final String status;
  final List<MultipartPart> parts;
  final String etag;
  final int sizeBytes;
}

class MultipartCompleteResponse extends JsonBackedResponse {
  MultipartCompleteResponse(super.raw)
    : status = '${raw['status'] ?? 'completed'}',
      key = '${raw['key'] ?? ''}',
      etag = '${raw['etag'] ?? ''}',
      sizeBytes = intValue(raw['size_bytes']),
      alreadyCompleted = raw['already_completed'] == true;

  final String status;
  final String key;
  final String etag;
  final int sizeBytes;
  final bool alreadyCompleted;
}

class UploadResponse extends JsonBackedResponse {
  const UploadResponse(super.raw);
}

class VideoUploadResponse extends JsonBackedResponse {
  VideoUploadResponse(super.raw)
    : userId = '${raw['user_id'] ?? ''}',
      key = '${raw['key'] ?? ''}',
      url = '${raw['url'] ?? ''}',
      method = '${raw['method'] ?? 'PUT'}',
      fileName = '${raw['filename'] ?? ''}',
      sizeBytes = intValue(raw['size_bytes']),
      statusCode = intValue(raw['status_code']),
      uploaded = raw['uploaded'] == true,
      uploadStrategy = '${raw['upload_strategy'] ?? 'single'}',
      uploadId = '${raw['upload_id'] ?? ''}',
      etag = '${raw['etag'] ?? ''}',
      partSizeBytes = intValue(raw['part_size_bytes']),
      partCount = intValue(raw['part_count']),
      partsUploaded = intValue(raw['parts_uploaded']),
      resumed = raw['resumed'] == true,
      attemptCount = intValue(raw['attempt_count']),
      destPath = '${raw['dest_path'] ?? ''}';

  final String userId;
  final String key;
  final String url;
  final String method;
  final String fileName;
  final int sizeBytes;
  final int statusCode;
  final bool uploaded;
  final String uploadStrategy;
  final String uploadId;
  final String etag;
  final int partSizeBytes;
  final int partCount;
  final int partsUploaded;
  final bool resumed;
  final int attemptCount;
  final String destPath;
}

class VideoUploadBulkResponse extends JsonBackedResponse {
  VideoUploadBulkResponse(super.raw)
    : data = objectList(raw['data']).map(VideoUploadResponse.new).toList(),
      total = intValue(raw['total']);

  final List<VideoUploadResponse> data;
  final int total;
}

class FolderUploadResponse extends JsonBackedResponse {
  const FolderUploadResponse(super.raw);
}

class MetadataParquetUploadResponse extends JsonBackedResponse {
  const MetadataParquetUploadResponse(super.raw);
}

class CollectionDescriptionUpdateResponse extends JsonBackedResponse {
  const CollectionDescriptionUpdateResponse(super.raw);
}

class DeleteCollectionResponse extends JsonBackedResponse {
  const DeleteCollectionResponse(super.raw);
}

class CollectionAddAssetsResponse extends JsonBackedResponse {
  const CollectionAddAssetsResponse(super.raw);
}

class IndexationJobsListResponse extends JsonBackedResponse {
  IndexationJobsListResponse(super.raw)
    : data = raw['data'] is List
          ? List<Object?>.from(raw['data']! as List)
          : <Object?>[],
      total = intValue(raw['total']);

  final List<Object?> data;
  final int total;
}

class IndexationSubmitResponse extends JsonBackedResponse {
  IndexationSubmitResponse(super.raw)
    : jobId = '${raw['job_id'] ?? ''}',
      status = '${raw['status'] ?? ''}';

  final String jobId;
  final String status;
}

class IndexationStatusResponse extends JsonBackedResponse {
  IndexationStatusResponse(super.raw)
    : jobId = '${raw['job_id'] ?? ''}',
      status = '${raw['status'] ?? ''}';

  final String jobId;
  final String status;
}

class IndexationDeleteResponse extends JsonBackedResponse {
  IndexationDeleteResponse(super.raw) : status = '${raw['status'] ?? ''}';

  final String status;
}

class AdminUserStatsResponse extends JsonBackedResponse {
  AdminUserStatsResponse(super.raw)
    : data = raw['data'] is List
          ? List<Object?>.from(raw['data']! as List)
          : <Object?>[],
      total = intValue(raw['total']);

  final List<Object?> data;
  final int total;
}

class UserProfile extends JsonBackedResponse {
  UserProfile(super.raw)
    : userId = raw['user_id']?.toString(),
      email = raw['email']?.toString(),
      name = raw['name']?.toString(),
      roles = raw['roles'] is List
          ? List<Object?>.from(raw['roles']! as List)
          : <Object?>[],
      tenantId = raw['tenant_id']?.toString(),
      permissions = raw['permissions'] is List
          ? (raw['permissions']! as List)
                .map((Object? value) => '$value')
                .toList()
          : <String>[],
      type = '${raw['type'] ?? 'user'}';

  final String? userId;
  final String? email;
  final String? name;
  final List<Object?> roles;
  final String? tenantId;
  final List<String> permissions;
  final String type;
}

class UsageUserDetail extends JsonBackedResponse {
  UsageUserDetail(super.raw)
    : date = '${raw['date'] ?? ''}',
      userId = '${raw['user_id'] ?? ''}',
      total = intValue(raw['total']),
      endpoints = objectMap(
        raw['endpoints'],
      ).map((String key, Object? value) => MapEntry(key, intValue(value)));

  final String date;
  final String userId;
  final int total;
  final Map<String, int> endpoints;
}

class CacheStats extends JsonBackedResponse {
  CacheStats(super.raw)
    : apikeyCacheSize = intValue(raw['apikey_cache_size']),
      rateLimiterBuckets = intValue(raw['rate_limiter_buckets']),
      config = objectMap(raw['config']);

  final int apikeyCacheSize;
  final int rateLimiterBuckets;
  final Map<String, Object?> config;
}

class PresignedUploadResponse extends JsonBackedResponse {
  PresignedUploadResponse(super.raw)
    : userId = '${raw['user_id'] ?? ''}',
      expiresIn = intValue(raw['expires_in']),
      key = '${raw['key'] ?? ''}',
      url = '${raw['url'] ?? ''}',
      method = '${raw['method'] ?? 'PUT'}';

  final String userId;
  final int expiresIn;
  final String key;
  final String url;
  final String method;
}

class PresignedFolderItem extends JsonBackedResponse {
  PresignedFolderItem(super.raw)
    : filename = '${raw['filename'] ?? ''}',
      key = '${raw['key'] ?? ''}',
      url = '${raw['url'] ?? ''}',
      method = '${raw['method'] ?? 'PUT'}';

  final String filename;
  final String key;
  final String url;
  final String method;
}

class PresignedFolderResponse extends JsonBackedResponse {
  PresignedFolderResponse(super.raw)
    : userId = '${raw['user_id'] ?? ''}',
      expiresIn = intValue(raw['expires_in']),
      files = objectList(raw['files']).map(PresignedFolderItem.new).toList();

  final String userId;
  final int expiresIn;
  final List<PresignedFolderItem> files;
}

class ImageUrlResponse extends JsonBackedResponse {
  ImageUrlResponse(super.raw)
    : found = raw['found'] == true,
      urlPreSigned = '${raw['url_pre_signed'] ?? ''}',
      fullPath = '${raw['full_path'] ?? ''}',
      expireSec = intValue(raw['expire_sec']),
      error = '${raw['error'] ?? ''}';

  final bool found;
  final String urlPreSigned;
  final String fullPath;
  final int expireSec;
  final String error;
}

class ImageUrlBulkResponse extends JsonBackedResponse {
  ImageUrlBulkResponse(super.raw) : records = objectList(raw['records']);

  final List<Map<String, Object?>> records;
}

class ImageGetBulkResponse extends JsonBackedResponse {
  ImageGetBulkResponse(super.raw) : records = objectList(raw['records']);

  final List<Map<String, Object?>> records;
}

class ImageResponse extends JsonBackedResponse {
  ImageResponse(super.raw)
    : found = raw['found'] == true,
      imgBase64 = '${raw['img_base64'] ?? ''}';

  final bool found;
  final String imgBase64;
}

class FullPathImageResponse extends JsonBackedResponse {
  FullPathImageResponse(super.raw)
    : found = raw['found'] == true,
      imgBase64 = '${raw['img_base64'] ?? ''}',
      fullpath = '${raw['fullpath'] ?? ''}';

  final bool found;
  final String imgBase64;
  final String fullpath;
}

class ImageBulkResponse extends JsonBackedResponse {
  ImageBulkResponse(super.raw) : records = objectList(raw['records']);

  final List<Map<String, Object?>> records;
}

Map<String, Object?> _withoutNull(Map<String, Object?> value) {
  value.removeWhere((String key, Object? item) => item == null);
  return value;
}
