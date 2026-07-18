import 'errors.dart';
import 'utils.dart';

/// Base response retaining unmodeled service fields in [raw].
class JsonBackedResponse {
  /// Creates a response backed by [raw].
  const JsonBackedResponse([this.raw = const <String, Object?>{}]);

  /// Complete decoded response, including extension fields unknown to the SDK.
  final Map<String, Object?> raw;
}

/// One untyped search result with forward-compatible [raw] data.
class SearchResultItem extends JsonBackedResponse {
  const SearchResultItem(super.raw);
}

/// Typed summary of one collection group.
class GroupItem extends JsonBackedResponse {
  GroupItem(super.raw)
    : userId = '${raw['user_id'] ?? ''}',
      mode = '${raw['mode'] ?? ''}',
      groupName = '${raw['group_name'] ?? ''}',
      videoGroup = '${raw['video_group'] ?? ''}',
      modalityTypes = stringList(raw['modality_types']),
      lancedbVersions = stringList(raw['lancedb_versions']),
      lastUpdated = raw['last_updated']?.toString();

  final String userId;
  final String mode;
  final String groupName;
  final String videoGroup;
  final List<String> modalityTypes;
  final List<String> lancedbVersions;
  final String? lastUpdated;

  /// Highest numeric `vN` value in [lancedbVersions], when present.
  int? get latestLancedbVersion {
    int? latest;
    for (final value in lancedbVersions) {
      final match = RegExp(
        r'^v(\d+)$',
        caseSensitive: false,
      ).firstMatch(value.trim());
      final version = int.tryParse(match?.group(1) ?? '');
      if (version != null && (latest == null || version > latest)) {
        latest = version;
      }
    }
    return latest;
  }
}

/// One item returned by a folder-upload operation.
class FolderUploadItem extends JsonBackedResponse {
  const FolderUploadItem(super.raw);
}

/// One asset associated with a collection.
class CollectionAsset extends JsonBackedResponse {
  const CollectionAsset(super.raw);
}

/// One indexation job with forward-compatible [raw] data.
class IndexationJobItem extends JsonBackedResponse {
  const IndexationJobItem(super.raw);
}

/// One user-statistics row with forward-compatible [raw] data.
class AdminUserStatItem extends JsonBackedResponse {
  const AdminUserStatItem(super.raw);
}

/// Parameters for a multimodal media search.
///
/// At least one of [queryText] or [imageQuery] must be nonblank. Defaults
/// search common speech, visible-text, and image sources with union semantics.
class SearchRequest {
  /// Creates a search request with mobile-oriented defaults.
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

  /// Validates the required query input.
  void validate() {
    if (queryText.trim().isEmpty && (imageQuery?.trim().isEmpty ?? true)) {
      throw const ValidationException('query_text or image_query is required');
    }
  }

  /// Converts this request to its structured transport representation.
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

/// Parameters for previewing or confirming collection deletion.
class DeleteCollectionRequest {
  /// Creates a deletion request. [dryRun] and [confirm] default to `false`.
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

  /// Validates required collection identifiers.
  void validate() {
    strRequired(groupName, 'group_name');
    strRequired(mode, 'mode');
  }

  /// Converts this request to its structured transport representation.
  Map<String, Object?> toJson() => <String, Object?>{
    'group_name': groupName,
    'mode': mode,
    'scope': scope,
    'dry_run': dryRun,
    'confirm': confirm,
  };
}

/// Parameters for associating existing assets with a collection.
class CollectionAddAssetsRequest {
  /// Creates an add-assets request.
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

  /// Validates identifiers and requires at least one asset.
  void validate() {
    strRequired(collectionId, 'collection_id');
    if (assetIds.isEmpty) {
      throw const ValidationException('asset_ids is required');
    }
    strRequired(mode, 'mode');
    strRequired(groupName, 'group_name');
  }

  /// Converts this request to its structured transport representation.
  Map<String, Object?> toJson() => <String, Object?>{
    'collection_id': collectionId,
    'asset_ids': assetIds,
    'mode': mode,
    'group_name': groupName,
    'stream_name': streamName,
  };
}

/// Parameters for creating an indexation job.
class IndexationSubmitRequest {
  /// Creates an indexation request with append and index-creation defaults.
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

  /// Validates required collection identifiers.
  void validate() {
    strRequired(mode, 'mode');
    strRequired(groupName, 'group_name');
  }

  /// Converts this request to its structured transport representation.
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

/// Parameters for previewing or confirming index deletion.
class IndexationDeleteRequest {
  /// Creates an index deletion request.
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

  /// Validates the required collection and version identifiers.
  void validate() {
    strRequired(mode, 'mode');
    strRequired(groupName, 'group_name');
    strRequired(version, 'version');
  }

  /// Converts this request to its structured transport representation.
  Map<String, Object?> toJson() => _withoutNull(<String, Object?>{
    'mode': mode,
    'group_name': groupName,
    'modality': modality,
    'version': version,
    'dry_run': dryRun,
    'confirm': confirm,
  });
}

/// Stored-image selector used by image lookup helpers.
class ImageRecord {
  /// Creates an image selector.
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

  /// Converts this selector to structured data.
  ///
  /// Set [includeIdentity] to `false` outside trusted direct integrations.
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

/// Stored-image selector for temporary URL lookup.
class ImageUrlRecord {
  /// Creates an image URL selector.
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

  /// Converts this selector to structured data.
  Map<String, Object?> toJson() => _withoutNull(<String, Object?>{
    'mode': mode,
    'group_name': groupName,
    'modality': modality,
    'stream_name': streamName,
    'filename': filename,
    'ts_unix_13digits': tsUnix13digits,
  });
}

/// Service health, version, and dependency summary.
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

/// Search results, counts, and execution timing.
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

/// Typed collection-group listing.
class GroupsResponse extends JsonBackedResponse {
  GroupsResponse(super.raw)
    : data = objectList(raw['data']).map(GroupItem.new).toList(),
      total = intValue(raw['total']),
      executionTimeMs = doubleValue(raw['execution_time_ms']);

  final List<GroupItem> data;
  final int total;
  final double executionTimeMs;

  /// Finds a group by trimmed name and optional mode.
  GroupItem? findGroup(String groupName, {String? mode}) {
    final name = groupName.trim();
    for (final item in data) {
      if (item.groupName.trim() == name &&
          (mode == null || item.mode == mode)) {
        return item;
      }
    }
    return null;
  }
}

/// Temporary upload grant returned for a signed upload.
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

/// Uploaded multipart part summary.
class MultipartPart extends JsonBackedResponse {
  MultipartPart(super.raw)
    : partNumber = intValue(raw['part_number']),
      etag = '${raw['etag'] ?? ''}',
      sizeBytes = intValue(raw['size_bytes']);

  final int partNumber;
  final String etag;
  final int sizeBytes;
}

/// Temporary upload grant for one multipart part.
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

/// Newly created multipart session and its resolved limits.
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

/// Temporary grants for a requested set of multipart parts.
class MultipartSignResponse extends JsonBackedResponse {
  MultipartSignResponse(super.raw)
    : parts = objectList(raw['parts']).map(MultipartSignedPart.new).toList(),
      expiresIn = intValue(raw['expires_in']);

  final List<MultipartSignedPart> parts;
  final int expiresIn;
}

/// Current multipart session status and accepted parts.
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

/// Completed multipart object metadata.
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

/// Result of a basic collection upload.
class UploadResponse extends JsonBackedResponse {
  const UploadResponse(super.raw);
}

/// Detailed result of one signed video upload.
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

/// Ordered results for a bulk signed upload.
class VideoUploadBulkResponse extends JsonBackedResponse {
  VideoUploadBulkResponse(super.raw)
    : data = objectList(raw['data']).map(VideoUploadResponse.new).toList(),
      total = intValue(raw['total']);

  final List<VideoUploadResponse> data;
  final int total;
}

/// Folder-upload compatibility response.
class FolderUploadResponse extends JsonBackedResponse {
  const FolderUploadResponse(super.raw);
}

/// Result of a metadata JSON Lines upload.
class MetadataParquetUploadResponse extends JsonBackedResponse {
  const MetadataParquetUploadResponse(super.raw);
}

/// Result of updating collection-item metadata.
class CollectionDescriptionUpdateResponse extends JsonBackedResponse {
  const CollectionDescriptionUpdateResponse(super.raw);
}

/// Result or preview of collection deletion.
class DeleteCollectionResponse extends JsonBackedResponse {
  const DeleteCollectionResponse(super.raw);
}

/// Result of associating assets with a collection.
class CollectionAddAssetsResponse extends JsonBackedResponse {
  const CollectionAddAssetsResponse(super.raw);
}

/// Indexation job rows and total count.
class IndexationJobsListResponse extends JsonBackedResponse {
  IndexationJobsListResponse(super.raw)
    : data = raw['data'] is List
          ? List<Object?>.from(raw['data']! as List)
          : <Object?>[],
      total = intValue(raw['total']);

  final List<Object?> data;
  final int total;
}

/// Identifier and initial state of a new indexation job.
class IndexationSubmitResponse extends JsonBackedResponse {
  IndexationSubmitResponse(super.raw)
    : jobId = '${raw['job_id'] ?? ''}',
      status = '${raw['status'] ?? ''}';

  final String jobId;
  final String status;
}

/// Identifier and current state of an indexation job.
class IndexationStatusResponse extends JsonBackedResponse {
  IndexationStatusResponse(super.raw)
    : jobId = '${raw['job_id'] ?? ''}',
      status = '${raw['status'] ?? ''}';

  final String jobId;
  final String status;
}

/// Result of deleting index data.
class IndexationDeleteResponse extends JsonBackedResponse {
  IndexationDeleteResponse(super.raw) : status = '${raw['status'] ?? ''}';

  final String status;
}

/// User-statistics rows and total count.
class AdminUserStatsResponse extends JsonBackedResponse {
  AdminUserStatsResponse(super.raw)
    : data = raw['data'] is List
          ? List<Object?>.from(raw['data']! as List)
          : <Object?>[],
      total = intValue(raw['total']);

  final List<Object?> data;
  final int total;
}

/// Identity and permissions resolved for the current credential.
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

/// Usage totals grouped by operation for one date.
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

/// Cache, limiter, and related service configuration counters.
class CacheStats extends JsonBackedResponse {
  CacheStats(super.raw)
    : apikeyCacheSize = intValue(raw['apikey_cache_size']),
      rateLimiterBuckets = intValue(raw['rate_limiter_buckets']),
      config = objectMap(raw['config']);

  final int apikeyCacheSize;
  final int rateLimiterBuckets;
  final Map<String, Object?> config;
}

/// Temporary object-upload grant for one file.
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

/// One file and its temporary object-upload grant.
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

/// Batch of temporary object-upload grants.
class PresignedFolderResponse extends JsonBackedResponse {
  PresignedFolderResponse(super.raw)
    : userId = '${raw['user_id'] ?? ''}',
      expiresIn = intValue(raw['expires_in']),
      files = objectList(raw['files']).map(PresignedFolderItem.new).toList();

  final String userId;
  final int expiresIn;
  final List<PresignedFolderItem> files;
}

/// Temporary image location and lookup status.
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

/// Raw per-record results for bulk image URL lookup.
class ImageUrlBulkResponse extends JsonBackedResponse {
  ImageUrlBulkResponse(super.raw) : records = objectList(raw['records']);

  final List<Map<String, Object?>> records;
}

/// Raw per-record results for bulk image download.
class ImageGetBulkResponse extends JsonBackedResponse {
  ImageGetBulkResponse(super.raw) : records = objectList(raw['records']);

  final List<Map<String, Object?>> records;
}

/// Base64-encoded image result.
class ImageResponse extends JsonBackedResponse {
  ImageResponse(super.raw)
    : found = raw['found'] == true,
      imgBase64 = '${raw['img_base64'] ?? ''}';

  final bool found;
  final String imgBase64;
}

/// Base64-encoded image result with its stored path.
class FullPathImageResponse extends JsonBackedResponse {
  FullPathImageResponse(super.raw)
    : found = raw['found'] == true,
      imgBase64 = '${raw['img_base64'] ?? ''}',
      fullpath = '${raw['fullpath'] ?? ''}';

  final bool found;
  final String imgBase64;
  final String fullpath;
}

/// Raw per-record base64 image results.
class ImageBulkResponse extends JsonBackedResponse {
  ImageBulkResponse(super.raw) : records = objectList(raw['records']);

  final List<Map<String, Object?>> records;
}

Map<String, Object?> _withoutNull(Map<String, Object?> value) {
  value.removeWhere((String key, Object? item) => item == null);
  return value;
}
