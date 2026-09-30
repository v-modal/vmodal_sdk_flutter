import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';
import '../user/library_scope.dart';

const archiveStream = 'street_study';

String basename(String path) => path.replaceAll('\\', '/').split('/').last;

class FrameMatch {
  const FrameMatch({required this.hit, this.imageUrl, this.imageBytes});
  final VideoSearchHit hit;
  final String? imageUrl;
  final Uint8List? imageBytes;
  String? get assetId => hit.assetId;
  String get fileName => hit.fileName ?? '';
  String get sourceKey => hit.assetId ?? hit.fileName ?? '';
  double? get seconds =>
      hit.playbackOffsetMs == null ? null : hit.playbackOffsetMs! / 1000;
  double? get distance => hit.distance;
}

bool trustedPreviewUrl(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      (uri.scheme == 'https' ||
          (!uri.hasScheme &&
              !uri.hasAuthority &&
              uri.path == '/api/external/v1/image/get_image'));
}

class SearchBatch {
  const SearchBatch({
    required this.matches,
    required this.total,
    required this.serverMs,
    required this.roundTripMs,
    required this.imageMs,
  });
  final List<FrameMatch> matches;
  final int total;
  final double serverMs;
  final int roundTripMs;
  final int imageMs;
}

/// One session, one application-owned collection. No credentials or signed URLs
/// are persisted. The low-level SDK is used consistently for collection selectors.
class SearchGateway {
  SearchGateway(
    this.keys,
    String scopeId, {
    VmodalTransport? transport,
    Future<void> Function()? ensureFresh,
  }) : collection = validateLibraryScope(scopeId),
       // ignore: prefer_initializing_formals
       _ensureFresh = ensureFresh {
    client = VmodalClient(
      config: SdkConfig(
        apiKeyProvider: keys,
        timeout: const Duration(seconds: 60),
      ),
      transport: transport,
    );
  }

  final MutableApiKeyProvider keys;
  final String collection;
  final Future<void> Function()? _ensureFresh;
  void Function(int status)? onAccessFailure;
  late final VmodalClient client;
  String accountId = '';
  int? version;

  Future<void> _fresh() async => await _ensureFresh?.call();

  void reportFailure(Object error) {
    if (error is SdkException &&
        (error.statusCode == 401 || error.statusCode == 403)) {
      onAccessFailure?.call(error.statusCode);
    }
  }

  Future<T> _call<T>(Future<T> Function() run) async {
    await _fresh();
    try {
      return await run();
    } on SdkException catch (error) {
      reportFailure(error);
      rethrow;
    }
  }

  Future<void> connect(String expectedUserId) async {
    final profile = await client.auth.me();
    if (profile.userId != expectedUserId) {
      throw const AuthException('No authenticated identity');
    }
    accountId = profile.userId!;
    await refreshVersion();
    await listJobs();
  }

  Future<void> refreshVersion() async {
    final groups = await _call(
      () => client.collections.listGroups(mode: 'vid_file'),
    );
    version = groups
        .findGroup(collection, mode: 'vid_file')
        ?.latestLancedbVersion;
  }

  Future<void> listJobs() async {
    await _call(
      () => client.indexes.jobsList(mode: 'vid_file', groupName: collection),
    );
  }

  Future<DeleteCollectionResponse> previewLibraryDeletion(
    CancellationToken cancellation,
  ) => _call(
    () => client.collections.delete(
      groupName: collection,
      mode: 'vid_file',
      scope: 'all',
      dryRun: true,
      confirm: false,
      cancellation: cancellation,
    ),
  );

  Future<DeleteCollectionResponse> deleteLibrary(
    CancellationToken cancellation,
  ) => _call(
    () => client.collections.delete(
      groupName: collection,
      mode: 'vid_file',
      scope: 'all',
      dryRun: false,
      confirm: true,
      cancellation: cancellation,
    ),
  );

  Future<UploadTask<VideoUploadResponse>> upload(File file) async {
    await _fresh();
    return client.collections.videoUpload(
      UploadSource.fromFile(file),
      collectionName: collection,
      subCollectionName: archiveStream,
    );
  }

  Future<IndexationSubmitResponse> createIndex(
    CancellationToken cancellation,
  ) async {
    return _call(
      () => client.indexes.createIndex(
        IndexationSubmitRequest(
          mode: 'vid_file',
          groupName: collection,
          streamName: archiveStream,
          indexType: 'vid_img_emb',
          modality: 'vid_img_emb',
          reProcess: true,
        ),
        cancellation: cancellation,
      ),
    );
  }

  Future<IndexationStatusResponse> indexStatus(
    String job,
    CancellationToken cancellation,
  ) async {
    return _call(
      () => client.indexes.indexStatus(job, cancellation: cancellation),
    );
  }

  Future<SearchBatch> search(
    String query, {
    CancellationToken? cancellation,
    String? imageQuery,
    double maxDistance = 1.5,
  }) async {
    final token = cancellation ?? CancellationToken();
    final timer = Stopwatch()..start();
    final response = await _call(
      () => client.searches.searchVideo(
        SearchRequest(
          queryText: query,
          imageQuery: imageQuery,
          mode: 'vid_file',
          groupName: collection,
          streamName: archiveStream,
          searchSources: const ['image'],
          limit: 30,
          imageEmbScoreMin: maxDistance,
          versionLancedb: version,
        ),
        cancellation: token,
      ),
    );
    final searchMs = timer.elapsedMilliseconds;
    // Enforce the displayed cutoff defensively on returned rows as well.
    // A client-filtered result is distinct from the raw server result count.
    final usable = response.videoHits.where((hit) {
      final distance = hit.distance;
      return (hit.assetId ?? hit.fileName ?? '').trim().isNotEmpty &&
          (distance == null || distance <= maxDistance);
    }).toList();
    final urls = <int, String>{};
    final imageBytes = <int, Uint8List>{};
    for (var i = 0; i < usable.length; i++) {
      final preview = usable[i].previewImageUrl;
      if (preview != null && trustedPreviewUrl(preview)) urls[i] = preview;
    }
    final lookupIndexes = <int>[
      for (var i = 0; i < usable.length; i++)
        if (usable[i].previewImageUrl == null &&
            (usable[i].fileName?.isNotEmpty ?? false))
          i,
    ];
    if (lookupIndexes.isNotEmpty) {
      final resolved = await _call(
        () => client.images.getUrlBulk(
          lookupIndexes
              .map(
                (index) => <String, Object?>{
                  'mode': 'vid_file',
                  'group_name': collection,
                  'modality': 'vid_img',
                  'stream_name': archiveStream,
                  'filename': usable[index].fileName,
                  if (usable[index].playbackOffsetMs != null)
                    'ts_unix_13digits': usable[index].playbackOffsetMs
                        .toString()
                        .padLeft(13, '0'),
                },
              )
              .toList(),
          cancellation: token,
        ),
      );
      for (var i = 0; i < resolved.records.length; i++) {
        final row = resolved.records[i];
        final rawIndex = row['input_index'];
        final parsed = num.tryParse('$rawIndex');
        final recordIndex = rawIndex == null
            ? i
            : parsed != null && parsed.isFinite && parsed == parsed.toInt()
            ? parsed.toInt()
            : null;
        final url = '${row['url_pre_signed'] ?? ''}';
        if (recordIndex != null &&
            recordIndex >= 0 &&
            recordIndex < lookupIndexes.length &&
            row['found'] != false &&
            trustedPreviewUrl(url)) {
          final index = lookupIndexes[recordIndex];
          urls.putIfAbsent(index, () => url);
        }
      }
    }
    // Relative signed routes are downloaded through the SDK without guessing
    // an absolute origin. A malformed image remains local to its result card.
    if (urls.isNotEmpty) {
      final downloaded = await _call(
        () => client.images.getImageBulkFromUrls(
          urls.values.toList(),
          cancellation: token,
        ),
      );
      final byUrl = <String, Uint8List>{};
      for (final row in downloaded.records) {
        final url = '${row['url_pre_signed'] ?? ''}';
        final encoded = '${row['content_base64'] ?? ''}';
        if (url.isNotEmpty && encoded.isNotEmpty) {
          try {
            byUrl[url] = base64Decode(encoded);
          } on FormatException {
            /* Keep a per-card placeholder. */
          }
        }
      }
      for (final entry in urls.entries) {
        if (byUrl[entry.value] != null) {
          imageBytes[entry.key] = byUrl[entry.value]!;
        }
      }
    }
    token.throwIfCanceled();
    return SearchBatch(
      matches: [
        for (var i = 0; i < usable.length; i++)
          FrameMatch(
            hit: usable[i],
            imageUrl: urls[i]?.startsWith('https://') == true ? urls[i] : null,
            imageBytes: imageBytes[i],
          ),
      ],
      total: response.cntTotal,
      serverMs: response.executionTimeMs,
      roundTripMs: searchMs,
      imageMs: timer.elapsedMilliseconds - searchMs,
    );
  }

  Future<void> close() async {
    keys.close();
    await client.close();
  }
}

bool indexDone(String state) => const {
  'success',
  'succeeded',
  'done',
  'completed',
  'ok',
}.contains(state.toLowerCase());
bool indexFailed(String state) => const {
  'failed',
  'failure',
  'error',
  'cancelled',
  'canceled',
}.contains(state.toLowerCase());
