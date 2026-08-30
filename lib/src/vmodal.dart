import 'api_key_provider.dart';
import 'client.dart';
import 'collection_uploads.dart';
import 'config.dart';
import 'content_scope.dart';
import 'models.dart';
import 'transport.dart';
import 'upload.dart';
import 'utils.dart';

/// Preferred entry point for project, collection, and stream scoped clients.
abstract final class VModal {
  /// Creates one owned project client without performing network I/O.
  static VModalProject configure({
    required String projectId,
    required ApiKeyProvider apiKeyProvider,
    Uri? baseUri,
    Duration timeout = const Duration(seconds: 30),
    String mode = 'gateway',
    int maxRetries = 1,
  }) {
    final project = ContentScope.project(projectId);
    final config = SdkConfig(
      baseUrl: baseUri?.toString(),
      timeout: timeout,
      mode: mode,
      maxRetries: maxRetries,
      apiKeyProvider: apiKeyProvider,
    );
    return VModalProject._(project, VmodalClient(config: config));
  }

  /// Creates a project and transfers ownership of [client] to it.
  ///
  /// After this call, close the returned project instead of closing [client]
  /// separately.
  static VModalProject fromClient({
    required String projectId,
    required VmodalClient client,
  }) => VModalProject._(ContentScope.project(projectId), client);
}

/// Immutable client for one developer-owned project.
final class VModalProject {
  VModalProject._(this.projectId, this._client);

  /// Normalized public project identifier.
  final String projectId;
  final VmodalClient _client;
  bool _closed = false;

  /// Creates an immutable collection and stream scope without network I/O.
  VModalScope scope({
    required String collectionName,
    required String streamName,
  }) => VModalScope._(
    ContentScope.create(projectId, collectionName, streamName),
    _client,
  );

  /// Lists decoded logical collection names owned by this project.
  ///
  /// Backend order and the first occurrence of duplicates are preserved.
  Future<List<String>> listCollections({
    String? mode,
    CancellationToken? cancellation,
  }) async {
    final response = await _client.collections.listGroups(
      mode: mode,
      cancellation: cancellation,
    );
    final found = <String>{};
    for (final item in response.data) {
      final name = ContentScope.decodeCollection(projectId, item.groupName);
      if (name != null) found.add(name);
    }
    return found.toList(growable: false);
  }

  /// Closes the owned low-level client. Repeated calls have no effect.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _client.close();
  }
}

/// Immutable operations for one project, collection, and stream.
final class VModalScope {
  VModalScope._(this._scope, this._client)
    : projectId = _scope.projectId,
      collectionName = _scope.collectionName,
      streamName = _scope.streamName;

  final ContentScope _scope;
  final VmodalClient _client;

  /// Normalized public project identifier.
  final String projectId;

  /// Normalized logical collection name.
  final String collectionName;

  /// Normalized stream name.
  final String streamName;

  /// Starts a signed upload using this scope.
  UploadTask<VideoUploadResponse> upload(
    UploadSource source, {
    ScopedUploadOptions options = const ScopedUploadOptions(),
  }) => _client.collections.videoUpload(
    source,
    collectionName: _scope.backendCollectionName,
    subCollectionName: streamName,
    mode: options.mode,
    modality: options.modality,
    ttl: options.ttl,
    options: options.uploadOptions,
  );

  /// Uploads JSON Lines metadata using this scope.
  Future<MetadataParquetUploadResponse> uploadMetadata(
    VmodalFilePart part, {
    ScopedMetadataOptions options = const ScopedMetadataOptions(),
    CancellationToken? cancellation,
  }) => _client.collections.uploadMetadataJsonl(
    part,
    mode: options.mode,
    groupName: _scope.backendCollectionName,
    streamName: streamName,
    writeMode: options.writeMode,
    allowOverlap: options.allowOverlap,
    cancellation: cancellation,
  );

  /// Searches only this collection and stream.
  Future<SearchResponse> search(
    String query, {
    ScopedSearchOptions options = const ScopedSearchOptions(),
    CancellationToken? cancellation,
  }) => _client.searches.searchVideo(
    SearchRequest(
      queryText: query,
      queryMetadata: options.queryMetadata,
      queryMetadataText: options.queryMetadataText,
      imageQuery: options.imageQuery,
      mode: options.mode,
      groupName: _scope.backendCollectionName,
      streamName: streamName,
      searchSources: options.searchSources,
      searchCombineMode: options.searchCombineMode,
      startDate: options.startDate,
      endDate: options.endDate,
      offset: options.offset,
      limit: options.limit,
      textEmbScoreMin: options.textEmbScoreMin,
      imageEmbScoreMin: options.imageEmbScoreMin,
      versionLancedb: options.versionLancedb,
    ),
    cancellation: cancellation,
  );

  /// Associates existing asset identifiers with this collection and stream.
  Future<CollectionAddAssetsResponse> addAssets(
    String collectionId,
    List<String> assetIds, {
    ScopedAddAssetsOptions options = const ScopedAddAssetsOptions(),
    CancellationToken? cancellation,
  }) => _client.collections.addAssets(
    collectionId: collectionId,
    assetIds: assetIds,
    mode: options.mode,
    groupName: _scope.backendCollectionName,
    streamName: streamName,
    cancellation: cancellation,
  );

  /// Updates one asset in this collection and stream.
  Future<CollectionDescriptionUpdateResponse> updateAsset(
    String filename, {
    required ScopedAssetChanges changes,
    CancellationToken? cancellation,
  }) {
    final clean = strRequired(filename, 'filename');
    final mode = strRequired(changes.mode, 'mode');
    return _client.collections.updateDescription(
      groupName: _scope.backendCollectionName,
      mode: mode,
      streamName: streamName,
      filenameSanitized: clean,
      description: changes.description,
      tag: changes.tags,
      cancellation: cancellation,
    );
  }

  /// Creates an index job for this collection and stream.
  Future<IndexationSubmitResponse> createIndex({
    ScopedCreateIndexOptions options = const ScopedCreateIndexOptions(),
    CancellationToken? cancellation,
  }) => _client.indexes.createIndex(
    IndexationSubmitRequest(
      mode: options.mode,
      groupName: _scope.backendCollectionName,
      streamName: streamName,
      indexType: options.indexType,
      modality: options.modality,
      insertMode: options.insertMode,
      createIndex: options.createIndex,
      version: options.version,
      startDate: options.startDate,
      endDate: options.endDate,
      embeddingModel: options.embeddingModel,
      reProcess: options.reProcess,
      dryRun: options.dryRun,
    ),
    cancellation: cancellation,
  );

  /// Lists index jobs filtered to this collection.
  Future<IndexationJobsListResponse> listIndexJobs({
    ScopedIndexJobsOptions options = const ScopedIndexJobsOptions(),
    CancellationToken? cancellation,
  }) => _client.indexes.jobsList(
    status: options.status,
    mode: options.mode,
    groupName: _scope.backendCollectionName,
    limit: options.limit,
    cancellation: cancellation,
  );

  /// Reads one index job without organization overrides.
  Future<IndexationStatusResponse> indexStatus(
    String jobId, {
    CancellationToken? cancellation,
  }) => _client.indexes.indexStatus(jobId, cancellation: cancellation);

  /// Deletes one index version from this collection.
  Future<IndexationDeleteResponse> deleteIndex(
    String version, {
    ScopedDeleteIndexOptions options = const ScopedDeleteIndexOptions(),
    CancellationToken? cancellation,
  }) => _client.indexes.deleteIndex(
    IndexationDeleteRequest(
      mode: options.mode,
      groupName: _scope.backendCollectionName,
      version: version,
      modality: options.modality,
      dryRun: options.dryRun,
      confirm: options.confirm,
    ),
    cancellation: cancellation,
  );

  /// Deletes the complete logical collection, including all streams.
  Future<DeleteCollectionResponse> deleteCollection({
    ScopedDeleteCollectionOptions options =
        const ScopedDeleteCollectionOptions(),
    CancellationToken? cancellation,
  }) => _client.collections.delete(
    groupName: _scope.backendCollectionName,
    mode: options.mode,
    scope: options.scope,
    dryRun: options.dryRun,
    confirm: options.confirm,
    cancellation: cancellation,
  );
}

/// Signed-upload behavior without organization fields.
final class ScopedUploadOptions {
  const ScopedUploadOptions({
    this.mode = 'vid_file',
    this.modality = 'vid_raw',
    this.ttl = 12600,
    this.uploadOptions = const VideoUploadOptions(),
  });

  final String mode;
  final String modality;
  final int ttl;
  final VideoUploadOptions uploadOptions;
}

/// Metadata-upload behavior without organization fields.
final class ScopedMetadataOptions {
  const ScopedMetadataOptions({
    this.mode = 'img_file',
    this.writeMode = 'append',
    this.allowOverlap = false,
  });

  final String mode;
  final String writeMode;
  final bool allowOverlap;
}

/// Search behavior without organization fields.
final class ScopedSearchOptions {
  const ScopedSearchOptions({
    this.queryMetadata,
    this.queryMetadataText,
    this.imageQuery,
    this.mode = 'vid_file',
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

  /// Legacy structured metadata query kept for source compatibility.
  @Deprecated('Use queryMetadataText for the current CCTV string contract.')
  final Map<String, Object?>? queryMetadata;

  /// CCTV metadata text serialized as the `query_metadata` string.
  final String? queryMetadataText;
  final String? imageQuery;
  final String mode;
  final List<String> searchSources;
  final String searchCombineMode;
  final String? startDate;
  final String? endDate;
  final int offset;
  final int limit;
  final double textEmbScoreMin;
  final double imageEmbScoreMin;
  final int? versionLancedb;
}

/// Add-assets behavior without organization fields.
final class ScopedAddAssetsOptions {
  const ScopedAddAssetsOptions({this.mode = 'vid_file'});

  final String mode;
}

/// Asset changes for the selected scope.
final class ScopedAssetChanges {
  const ScopedAssetChanges({
    this.mode = 'vid_file',
    this.description,
    this.tags,
  });

  final String mode;
  final String? description;
  final List<String>? tags;
}

/// Index-creation behavior without organization fields.
final class ScopedCreateIndexOptions {
  const ScopedCreateIndexOptions({
    this.mode = 'vid_file',
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
}

/// Index-job filters without organization fields.
final class ScopedIndexJobsOptions {
  const ScopedIndexJobsOptions({this.status, this.mode, this.limit = 200});

  final String? status;
  final String? mode;
  final int limit;
}

/// Index-deletion behavior without organization fields.
final class ScopedDeleteIndexOptions {
  const ScopedDeleteIndexOptions({
    this.mode = 'vid_file',
    this.modality,
    this.dryRun = false,
    this.confirm = false,
  });

  final String mode;
  final String? modality;
  final bool dryRun;
  final bool confirm;
}

/// Collection-deletion behavior without organization fields.
final class ScopedDeleteCollectionOptions {
  const ScopedDeleteCollectionOptions({
    this.mode = 'vid_file',
    this.scope = 'all',
    this.dryRun = false,
    this.confirm = false,
  });

  final String mode;
  final String scope;
  final bool dryRun;
  final bool confirm;
}
