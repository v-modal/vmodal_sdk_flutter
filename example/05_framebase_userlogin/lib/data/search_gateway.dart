import 'dart:io';
import 'dart:typed_data';

import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';
import '../user/library_scope.dart';

const archiveStream = 'street_study';
String basename(String path) => path.replaceAll('\\', '/').split('/').last;

class FrameMatch {
  const FrameMatch({required this.hit, this.imageBytes});
  final VideoSearchHit hit;
  final Uint8List? imageBytes;
  String? get imageUrl => null;
  String? get assetId => hit.assetId;
  String get fileName => hit.fileName ?? '';
  String get sourceKey => hit.assetId ?? hit.fileName ?? '';
  double? get seconds =>
      hit.playbackOffsetMs == null ? null : hit.playbackOffsetMs! / 1000;
  double? get distance => hit.distance;
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

/// Every cloud operation uses the same immutable SDK app-user session.
class SearchGateway {
  SearchGateway(
    this.session,
    String scopeId, {
    Future<void> Function()? ensureFresh,
  }) : collection = validateLibraryScope(scopeId),
       // Public constructor keeps the host renewal callback named consistently.
       // ignore: prefer_initializing_formals
       _ensureFresh = ensureFresh {
    scope = session.scope(
      ContentMapping.opaque(
        collectionId: collection,
        streamName: archiveStream,
      ),
    );
  }

  final UserSession session;
  late final UserScope scope;
  final String collection;
  final Future<void> Function()? _ensureFresh;
  void Function(int status)? onAccessFailure;
  String get accountId => session.context.appUserId;
  SessionContext get context => session.context;
  int? version;

  void _active() {
    if (!session.isActive) throw const SessionInvalidated();
  }

  Future<void> _fresh() async {
    _active();
    await _ensureFresh?.call();
    _active();
  }

  void reportFailure(Object error) {
    if (session.isActive &&
        error is SdkException &&
        (error.statusCode == 401 || error.statusCode == 403)) {
      onAccessFailure?.call(error.statusCode);
    }
  }

  Future<T> _call<T>(Future<T> Function() run) async {
    await _fresh();
    try {
      final result = await run();
      _active();
      return result;
    } on SdkException catch (error) {
      reportFailure(error);
      rethrow;
    }
  }

  Future<void> connect(String expectedPrincipal) async {
    await session.verifyPrincipal(expectedPrincipal);
    await refreshVersion();
    if (scope.mapping.actions.contains(UserAction.indexation)) await listJobs();
  }

  Future<void> refreshVersion() async {
    final next = await _call(() => scope.latestVersion());
    _active();
    version = next;
  }

  Future<void> listJobs() async => await _call(() => scope.listIndexJobs());

  Future<DeleteCollectionResponse> previewLibraryDeletion(
    CancellationToken cancellation,
  ) => _call(
    () => scope.deleteCollection(
      options: const ScopedDeleteCollectionOptions(dryRun: true),
      cancellation: cancellation,
    ),
  );

  Future<DeleteCollectionResponse> deleteLibrary(
    CancellationToken cancellation,
  ) => _call(
    () => scope.deleteCollection(
      options: const ScopedDeleteCollectionOptions(confirm: true),
      cancellation: cancellation,
    ),
  );

  Future<UploadTask<VideoUploadResponse>> upload(File file) async {
    await _fresh();
    return scope.upload(UploadSource.fromFile(file));
  }

  Future<SessionJob> createIndex(CancellationToken cancellation) => _call(
    () => scope.createIndex(
      options: const ScopedCreateIndexOptions(
        indexType: 'vid_img_emb',
        modality: 'vid_img_emb',
        reProcess: true,
      ),
      cancellation: cancellation,
    ),
  );

  Future<IndexationStatusResponse> indexStatus(
    SessionJob job,
    CancellationToken cancellation,
  ) => _call(() => scope.indexStatus(job, cancellation: cancellation));

  Future<SessionJob> rebindJob(DurableJobReference reference) =>
      _call(() => scope.rebindJob(reference));

  Future<SearchBatch> search(
    String query, {
    CancellationToken? cancellation,
    String? imageQuery,
    double maxDistance = 1.5,
  }) async {
    final token = cancellation ?? CancellationToken();
    final timer = Stopwatch()..start();
    final response = await _call(
      () => scope.search(
        query,
        options: ScopedSearchOptions(
          imageQuery: imageQuery,
          limit: 30,
          imageEmbScoreMin: maxDistance,
          versionLancedb: version,
        ),
        cancellation: token,
      ),
    );
    final searchMs = timer.elapsedMilliseconds;
    final matches = <FrameMatch>[];
    for (var i = 0; i < response.videoHits.length; i++) {
      final hit = response.videoHits[i];
      if ((hit.assetId ?? hit.fileName ?? '').trim().isEmpty ||
          (hit.distance != null && hit.distance! > maxDistance)) {
        continue;
      }
      Uint8List? bytes;
      if (i < response.assets.length) {
        try {
          bytes = await _call(
            () => scope.imageBytes(
              response.assets[i],
              maxBytes: 8 * 1024 * 1024,
              cancellation: token,
            ),
          );
        } on FeatureDisabled {
          // Unavailable media retains its local result-card placeholder.
        }
      }
      _active();
      matches.add(FrameMatch(hit: hit, imageBytes: bytes));
    }
    token.throwIfCanceled();
    _active();
    return SearchBatch(
      matches: List<FrameMatch>.unmodifiable(matches),
      total: matches.length,
      serverMs: response.executionTimeMs,
      roundTripMs: searchMs,
      imageMs: timer.elapsedMilliseconds - searchMs,
    );
  }

  Future<void> close() => session.close();
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
