import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

import 'search_gateway.dart';

class ArchiveClip {
  ArchiveClip({
    required this.id,
    required this.title,
    required this.location,
    required this.duration,
    required this.asset,
    required this.poster,
    this.path,
    this.remoteAssetId,
    this.uploaded = false,
    this.bundled = true,
  });
  final String id, title, location, asset, poster;
  final double duration;
  String? path;
  String? remoteAssetId;
  bool uploaded;
  final bool bundled;
  String get filename => '$id.mp4';
  bool get hasLocalCopy => path != null;
  bool get remoteOnly => !bundled && path == null && uploaded;
  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'location': location,
    'duration': duration,
    'asset': asset,
    'poster': poster,
    'path': path,
    'remoteAssetId': remoteAssetId,
    'uploaded': uploaded,
    'bundled': bundled,
  };
  factory ArchiveClip.fromJson(Map<String, dynamic> r) => ArchiveClip(
    id: r['id'] as String,
    title: r['title'] as String,
    location: r['location'] as String,
    duration: (r['duration'] as num).toDouble(),
    asset: r['asset'] as String,
    poster: r['poster'] as String,
    path: r['path'] as String?,
    remoteAssetId: _archiveAssetId(r['remoteAssetId']),
    uploaded: r['uploaded'] == true,
    bundled: r['bundled'] == true,
  );

  ArchiveClip copy() => ArchiveClip.fromJson(toJson());
}

String? _archiveAssetId(Object? value) {
  if (value is! String) return null;
  final clean = value.trim();
  return clean.isEmpty ? null : clean;
}

enum LocalRemovalResult { removed, partial, unavailable }

enum CloudDeletionResult { deleted, partial, failed }

class LibraryDeletionPreview {
  const LibraryDeletionPreview({
    required this.removedBytes,
    required this.sqlRowsDeleted,
    required this.executionTimeMs,
  });

  final int removedBytes;
  final int sqlRowsDeleted;
  final double executionTimeMs;
}

List<ArchiveClip> streetClips() => [
  ArchiveClip(
    id: 'neighborhood_crossing',
    title: 'Neighborhood crossing',
    location: 'San Francisco · Daylight',
    duration: 55.2,
    asset: 'assets/videos/neighborhood_crossing.mp4',
    poster: 'assets/stills/neighborhood_crossing.jpg',
  ),
  ArchiveClip(
    id: 'downtown_traffic',
    title: 'Downtown traffic',
    location: 'Singapore · Afternoon',
    duration: 15.8,
    asset: 'assets/videos/downtown_traffic.mp4',
    poster: 'assets/stills/downtown_traffic.jpg',
  ),
  ArchiveClip(
    id: 'evening_junction',
    title: 'Evening junction',
    location: 'Mexico City · Dusk',
    duration: 75,
    asset: 'assets/videos/evening_junction.mp4',
    poster: 'assets/stills/evening_junction.jpg',
  ),
];

class ArchiveEvent {
  ArchiveEvent(this.title, this.detail, {this.error = false, DateTime? time})
    : time = time ?? DateTime.now();
  final String title, detail;
  final bool error;
  final DateTime time;
  Map<String, Object?> toJson() => {
    'title': title,
    'detail': detail,
    'error': error,
    'time': time.toIso8601String(),
  };
}

class ArchiveController extends ChangeNotifier {
  ArchiveController({this.persist = true, this.supportDirectory});
  final bool persist;
  final Directory? supportDirectory;
  List<ArchiveClip> clips = streetClips();
  final List<ArchiveEvent> events = [];
  bool initialized = false, connecting = false, busy = false, searching = false;
  String phase = '', notice = '', activeQuery = '', pendingJob = '';
  SessionJob? _pendingHandle;
  double? progress;
  SearchBatch? batch;
  int? indexVersion;
  SearchGateway? _gateway;
  Directory? _directory;
  UploadTask<VideoUploadResponse>? _upload;
  CancellationToken? _work, _queryToken;
  int _searchGeneration = 0;
  int _generation = 0;
  bool _disposed = false;
  String _scopeId = '';
  bool canRead = false, canWrite = false;
  SessionStorageLease? _writer;
  Map<String, Object?>? _owner;
  String? get archiveDirectory => _directory?.path;
  String? get sessionId => _gateway?.session.sessionId;
  bool get connected => _gateway != null;
  bool get ready => connected && indexVersion != null;
  bool get hasPendingUploads => clips.any((c) => !c.uploaded);
  bool get canDeleteCloudLibrary =>
      connected && canWrite && !busy && pendingJob.isEmpty;

  void emit() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    initialized = true;
    emit();
  }

  Future<void> activate(
    String scopeId,
    SearchGateway gateway, {
    required bool canRead,
    required bool canWrite,
    required String serviceNamespace,
    required String tenantId,
    required String appUserId,
    required String policyRevision,
  }) async {
    deactivate();
    if ([
      serviceNamespace,
      tenantId,
      appUserId,
      policyRevision,
      scopeId,
    ].any((value) => value.trim().isEmpty)) {
      throw const ValidationException('Resolved archive owner is required');
    }
    final generation = _generation;
    final owner = <String, Object?>{
      'serviceNamespace': serviceNamespace,
      'tenantId': tenantId,
      'appUserId': appUserId,
      'scopeId': scopeId,
      'representation': 'opaque',
      'streamName': archiveStream,
      'mode': 'vid_file',
      'policyRevision': policyRevision,
    };
    _owner = owner;
    final writer = gateway.scope.storageLease;
    _writer = writer;
    _scopeId = scopeId;
    this.canRead = canRead;
    this.canWrite = canWrite;
    _gateway = gateway;
    indexVersion = gateway.version;
    try {
      final root = supportDirectory ?? await getApplicationSupportDirectory();
      if (generation != _generation) return;
      await root.create(recursive: true);
      final rootPath = await root.resolveSymbolicLinks();
      writer.check();
      String safe(String value) =>
          sha256.convert(utf8.encode(value)).toString();
      final directory = Directory(
        '$rootPath/accounts/'
        '${safe(serviceNamespace)}/${safe(tenantId)}/${safe(appUserId)}/${safe(scopeId)}',
      );
      _directory = directory;
      if (persist) {
        await writer.run(() async {
          final state = File('${directory.path}/archive.json');
          if (await state.exists()) {
            final data =
                jsonDecode(await state.readAsString()) as Map<String, dynamic>;
            writer.check();
            if (jsonEncode(data['owner']) != jsonEncode(owner)) return;
            final saved = (data['clips'] as List)
                .map(
                  (r) =>
                      ArchiveClip.fromJson(Map<String, dynamic>.from(r as Map)),
                )
                .toList();
            if (generation != _generation) return;
            for (final clip in saved) {
              if (clip.path != null &&
                  !await _contained(directory, clip.path!)) {
                clip.path = null;
              }
            }
            writer.check();
            clips = saved
                .where((c) => c.bundled || c.path != null || c.uploaded)
                .toList();
            if (clips.isEmpty) clips = streetClips();
            pendingJob = data['pendingJob'] as String? ?? '';
            for (final raw in (data['events'] as List? ?? [])) {
              final r = Map<String, dynamic>.from(raw as Map);
              events.add(
                ArchiveEvent(
                  r['title'] as String,
                  r['detail'] as String,
                  error: r['error'] == true,
                  time: DateTime.parse(r['time'] as String),
                ),
              );
            }
          }
        });
      }
    } on Object {
      if (generation != _generation) return;
      notice =
          'Local archive could not be restored. Built-in clips are available.';
    }
    if (generation != _generation) return;
    initialized = true;
    emit();
  }

  void deactivate() {
    _generation++;
    _writer?.retire();
    _writer = null;
    _owner = null;
    stopWork();
    invalidateSearch();
    _gateway = null;
    _directory = null;
    _scopeId = '';
    canRead = false;
    canWrite = false;
    clips = streetClips();
    events.clear();
    initialized = false;
    connecting = false;
    busy = false;
    searching = false;
    phase = notice = activeQuery = pendingJob = '';
    _pendingHandle = null;
    progress = null;
    batch = null;
    indexVersion = null;
    emit();
  }

  Future<void> save() {
    if (!persist || _directory == null || _scopeId.isEmpty) {
      return Future<void>.value();
    }
    // Snapshot and serialize writes so progress events cannot truncate each other.
    // Never serialize the client, key, response rows or signed URLs.
    final writer = _writer;
    if (writer == null) return Future<void>.value();
    final snapshot = _manifestJson(clips, pendingJob, events, _owner!);
    final path = '${_directory!.path}/archive.json';
    return writer.run(() => _writeManifest(path, snapshot, writer)).catchError((
      _,
    ) {
      /* Optional history must not cancel network work. */
    });
  }

  String _manifestJson(
    List<ArchiveClip> savedClips,
    String savedJob,
    List<ArchiveEvent> savedEvents,
    Map<String, Object?> owner,
  ) => jsonEncode({
    'owner': owner,
    'clips': savedClips.map((c) => c.toJson()).toList(),
    'pendingJob': savedJob,
    'events': savedEvents.take(40).map((e) => e.toJson()).toList(),
  });

  Future<void> _writeManifest(
    String path,
    String snapshot,
    SessionStorageLease writer,
  ) async {
    final target = File(path);
    await target.parent.create(recursive: true);
    final temp = File('$path.${DateTime.now().microsecondsSinceEpoch}.tmp');
    try {
      await temp.writeAsString(snapshot, flush: true);
      writer.check();
      temp.renameSync(path);
    } on Object {
      if (await temp.exists()) await temp.delete();
      rethrow;
    }
  }

  Future<void> _saveStrict(
    Directory directory,
    List<ArchiveClip> savedClips,
    String savedJob,
    List<ArchiveEvent> savedEvents,
    SessionStorageLease writer,
    Map<String, Object?> owner,
  ) async {
    if (!persist) return;
    final snapshot = _manifestJson(savedClips, savedJob, savedEvents, owner);
    final path = '${directory.path}/archive.json';
    await writer.run(() => _writeManifest(path, snapshot, writer));
  }

  Future<bool> _contained(Directory directory, String path) async {
    try {
      final root = await directory.resolveSymbolicLinks();
      final file = await File(path).resolveSymbolicLinks();
      return file.startsWith('$root${Platform.pathSeparator}');
    } on FileSystemException {
      return false;
    }
  }

  void record(String title, String detail, {bool error = false}) {
    events.insert(0, ArchiveEvent(title, detail, error: error));
    if (events.length > 40) events.removeLast();
    unawaited(save());
    emit();
  }

  Future<File> localFile(ArchiveClip clip) async {
    final directory = _directory;
    final writer = _writer;
    final path = clip.path;
    if (directory == null || writer == null || !clips.contains(clip)) {
      throw const FileSystemException('No active library');
    }
    return writer.run(() async {
      if (path != null && await _contained(directory, path)) {
        writer.check();
        return File(path);
      }
      if (!clip.bundled ||
          clip.filename.contains('/') ||
          clip.filename.contains('\\')) {
        throw const FileSystemException('Recording no longer available');
      }
      final file = File('${directory.path}/${clip.filename}');
      await file.parent.create(recursive: true);
      if (!await _contained(directory, file.path)) {
        final data = await rootBundle.load(clip.asset);
        final temp = File('${file.path}.${writer.sessionId}.tmp');
        try {
          await temp.writeAsBytes(
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
            flush: true,
          );
          writer.check();
          temp.renameSync(file.path);
        } finally {
          if (temp.existsSync()) temp.deleteSync();
        }
      }
      writer.check();
      clip.path = file.path;
      return file;
    });
  }

  Future<LocalRemovalResult> removeLocalCopy(ArchiveClip clip) async {
    final directory = _directory;
    final scope = _scopeId;
    final generation = _generation;
    final path = clip.path;
    final writer = _writer;
    final owner = _owner;
    if (directory == null ||
        writer == null ||
        owner == null ||
        scope.isEmpty ||
        busy ||
        pendingJob.isNotEmpty ||
        clip.bundled ||
        path == null ||
        !clips.contains(clip)) {
      return LocalRemovalResult.unavailable;
    }
    final target = File(path);
    try {
      await writer.run(() async {
        if (!await _contained(directory, path)) {
          throw const FileSystemException(
            'Recording is outside selected owner',
          );
        }
        writer.check();
        target.deleteSync();
      });
    } on Object {
      if (generation == _generation && scope == _scopeId) {
        notice = 'The video could not be removed from this device.';
        emit();
      }
      return LocalRemovalResult.unavailable;
    }

    if (generation != _generation || scope != _scopeId) {
      return LocalRemovalResult.removed;
    }
    if (clip.uploaded) {
      clip.path = null;
    } else {
      clips.remove(clip);
    }
    invalidateSearch();
    events.insert(
      0,
      ArchiveEvent(
        'Device copy removed',
        clip.uploaded
            ? '${clip.title} · cloud copy kept'
            : '${clip.title} · local-only recording removed',
      ),
    );
    if (events.length > 40) events.removeLast();
    notice = clip.uploaded
        ? 'Device copy removed. The cloud copy remains searchable.'
        : 'Video removed from this device.';
    emit();
    try {
      await _saveStrict(directory, clips, pendingJob, events, writer, owner);
      return LocalRemovalResult.removed;
    } on Object {
      notice =
          'The video was removed, but the local library status could not be saved.';
      emit();
      return LocalRemovalResult.partial;
    }
  }

  Future<void> importFile(String path, double duration) async {
    if (!canWrite || _directory == null || _writer == null) return;
    final generation = _generation;
    final directory = _directory!;
    final writer = _writer!;
    final id = 'street_${DateTime.now().microsecondsSinceEpoch}';
    final file = File('${directory.path}/$id.mp4');
    await writer.run(() async {
      await directory.create(recursive: true);
      final temp = File('${file.path}.${writer.sessionId}.tmp');
      try {
        await File(path).copy(temp.path);
        writer.check();
        temp.renameSync(file.path);
      } finally {
        if (temp.existsSync()) temp.deleteSync();
      }
    });
    if (generation != _generation) return;
    final sourceName = basename(path);
    clips.add(
      ArchiveClip(
        id: id,
        title: sourceName,
        location: 'Imported recording',
        duration: duration,
        asset: '',
        poster: '',
        path: file.path,
        bundled: false,
      ),
    );
    invalidateSearch();
    await save();
    record('Recording added', '$sourceName · stored on device only');
  }

  ArchiveClip? clipFor(VideoSearchHit hit) {
    final assetId = hit.assetId;
    if (assetId != null) {
      for (final clip in clips) {
        if (clip.remoteAssetId == assetId) return clip;
      }
    }
    final clean = basename(hit.fileName ?? '').toLowerCase();
    if (clean.isEmpty) return null;
    for (final clip in clips) {
      if (assetId != null && clip.remoteAssetId != null) continue;
      if (clean == clip.id.toLowerCase() ||
          clean == clip.filename.toLowerCase() ||
          clean.startsWith('${clip.id.toLowerCase()}.')) {
        return clip;
      }
    }
    return null;
  }

  Future<LibraryDeletionPreview?> previewCloudLibraryDeletion() async {
    final gateway = _gateway;
    if (gateway == null || !canDeleteCloudLibrary) return null;
    final generation = _generation;
    final scope = _scopeId;
    busy = true;
    phase = 'Checking cloud library';
    notice = '';
    invalidateSearch();
    final token = CancellationToken();
    _work = token;
    emit();
    try {
      final response = await gateway.previewLibraryDeletion(token);
      token.throwIfCanceled();
      _validateDeletion(response, 'dry_run', scope);
      final raw = response.raw;
      return LibraryDeletionPreview(
        removedBytes: _safeInt(raw['removed_bytes']),
        sqlRowsDeleted: _safeInt(raw['sql_rows_deleted']),
        executionTimeMs: _safeDouble(raw['execution_time_ms']),
      );
    } on Object catch (error) {
      if (generation == _generation && scope == _scopeId) {
        notice = error is MalformedResponse
            ? 'The deletion preview could not be verified. Nothing was deleted.'
            : _cloudDeletionError(error, preview: true);
        emit();
      }
      return null;
    } finally {
      if (generation == _generation && scope == _scopeId) {
        busy = false;
        phase = '';
        _work = null;
        emit();
      }
    }
  }

  Future<CloudDeletionResult> deleteCloudLibrary() async {
    final gateway = _gateway;
    final directory = _directory;
    final writer = _writer;
    final owner = _owner;
    if (gateway == null ||
        directory == null ||
        writer == null ||
        owner == null ||
        !canDeleteCloudLibrary) {
      return CloudDeletionResult.failed;
    }
    final generation = _generation;
    final scope = _scopeId;
    final savedClips = clips.map((c) => c.copy()).toList();
    final savedEvents = List<ArchiveEvent>.from(events);
    busy = true;
    phase = 'Deleting cloud library';
    notice = '';
    invalidateSearch();
    final token = CancellationToken();
    _work = token;
    emit();
    try {
      final response = await gateway.deleteLibrary(token);
      writer.check();
      token.throwIfCanceled();
      _validateDeletion(response, 'ok', scope);

      for (final clip in savedClips) {
        clip.uploaded = false;
        clip.remoteAssetId = null;
      }
      savedClips.removeWhere((clip) => !clip.bundled && clip.path == null);
      savedEvents.insert(
        0,
        ArchiveEvent(
          'Cloud library deleted',
          'All cloud videos, metadata, and search indexes removed; device videos kept',
        ),
      );
      if (savedEvents.length > 40) savedEvents.removeLast();
      gateway.version = null;

      final current = generation == _generation && scope == _scopeId;
      if (current) {
        clips = savedClips;
        events
          ..clear()
          ..addAll(savedEvents);
        pendingJob = '';
        indexVersion = null;
        activeQuery = '';
        batch = null;
        notice = 'Cloud library deleted. Videos on this device were kept.';
        emit();
      }
      try {
        await _saveStrict(
          directory,
          savedClips,
          '',
          savedEvents,
          writer,
          owner,
        );
        return CloudDeletionResult.deleted;
      } on Object {
        if (current) {
          notice =
              'Cloud library was deleted, but local status could not be saved. Your device videos were kept.';
          emit();
        }
        return CloudDeletionResult.partial;
      }
    } on Object catch (error) {
      if (generation == _generation && scope == _scopeId) {
        notice = _cloudDeletionError(error);
        emit();
      }
      return CloudDeletionResult.failed;
    } finally {
      if (generation == _generation && scope == _scopeId) {
        busy = false;
        phase = '';
        _work = null;
        emit();
      }
    }
  }

  void _validateDeletion(
    DeleteCollectionResponse response,
    String expectedStatus,
    String scope,
  ) {
    final raw = response.raw;
    if ('${raw['status'] ?? ''}' != expectedStatus ||
        raw.containsKey('group_name') && '${raw['group_name']}' != scope ||
        raw.containsKey('mode') && '${raw['mode']}' != 'vid_file' ||
        raw.containsKey('scope') && '${raw['scope']}' != 'all') {
      throw const MalformedResponse('Unverified collection deletion');
    }
  }

  Future<void> uploadAndIndex() async {
    final gateway = _gateway;
    if (gateway == null || busy || !canWrite) return;
    final generation = _generation;
    busy = true;
    notice = '';
    invalidateSearch();
    final token = CancellationToken();
    _work = token;
    emit();
    try {
      for (final clip in clips.where((c) => !c.uploaded)) {
        token.throwIfCanceled();
        phase = 'Uploading ${clip.title}';
        progress = 0;
        emit();
        final file = await localFile(clip);
        token.throwIfCanceled();
        final task = await gateway.upload(file);
        _upload = task;
        if (token.isCanceled) task.cancel();
        final watch = Stopwatch()..start();
        final subscription = task.progress.listen((p) {
          if (generation != _generation) return;
          progress = p.totalBytes > 0 ? p.uploadedBytes / p.totalBytes : null;
          emit();
        });
        try {
          final result = await task.result;
          token.throwIfCanceled();
          if (!result.uploaded) throw const TransportException();
          if (result.assetId != null) clip.remoteAssetId = result.assetId;
          clip.uploaded = true;
          record(
            'Uploaded',
            '${clip.title} · ${(file.lengthSync() / 1048576).toStringAsFixed(1)} MB · ${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)} s',
          );
          await save();
        } finally {
          await subscription.cancel();
          _upload = null;
        }
      }
      token.throwIfCanceled();
      phase = 'Creating visual index';
      progress = null;
      emit();
      final job = await gateway.createIndex(token);
      token.throwIfCanceled();
      pendingJob = job.jobId;
      _pendingHandle = job;
      await save();
      if (pendingJob.isEmpty) {
        throw const MalformedResponse('No index job identifier');
      }
      record('Index queued', 'Visual index · ${clips.length} recordings');
      await _pollIndex(gateway, token);
    } on OperationCanceled {
      if (generation != _generation) return;
      notice = pendingJob.isEmpty
          ? 'Upload canceled. Completed uploads are kept.'
          : 'Stopped waiting. Indexing continues on the server; use Resume.';
      record('Operation stopped', notice);
    } on Object catch (e) {
      if (generation != _generation) return;
      gateway.reportFailure(e);
      if (generation != _generation) return;
      notice = safeError(e);
      record('Processing failed', notice, error: true);
    } finally {
      if (generation == _generation) {
        busy = false;
        phase = '';
        progress = null;
        _work = null;
        emit();
      }
    }
  }

  Future<void> resumeIndex() async {
    final gateway = _gateway;
    if (gateway == null || busy || !canWrite || pendingJob.isEmpty) return;
    final generation = _generation;
    busy = true;
    notice = '';
    final token = CancellationToken();
    _work = token;
    emit();
    try {
      await _pollIndex(gateway, token);
    } on OperationCanceled {
      if (generation != _generation) return;
      notice = 'Stopped waiting. The server job continues.';
    } on Object catch (e) {
      if (generation != _generation) return;
      gateway.reportFailure(e);
      if (generation != _generation) return;
      notice = safeError(e);
      record('Index check failed', notice, error: true);
    } finally {
      if (generation == _generation) {
        busy = false;
        phase = '';
        _work = null;
        emit();
      }
    }
  }

  Future<void> _pollIndex(
    SearchGateway gateway,
    CancellationToken token,
  ) async {
    final watch = Stopwatch()..start();
    final job =
        _pendingHandle ??
        await gateway.rebindJob(
          DurableJobReference(
            jobId: pendingJob,
            ownerKey: gateway.context.ownerKey,
            scopeKey: gateway.scope.scopeKey,
            policyRevision: gateway.context.policyRevision,
          ),
        );
    token.throwIfCanceled();
    _pendingHandle = job;
    for (var attempt = 0; attempt < 120; attempt++) {
      token.throwIfCanceled();
      final state = await gateway.indexStatus(job, token);
      token.throwIfCanceled();
      if (indexDone(state.status)) {
        await gateway.refreshVersion();
        token.throwIfCanceled();
        indexVersion = gateway.version;
        pendingJob = '';
        await save();
        notice = 'Visual index is ready. Search the street archive.';
        record(
          'Index ready',
          'v$indexVersion · ${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)} s waiting time',
        );
        return;
      }
      if (indexFailed(state.status)) {
        pendingJob = '';
        await save();
        throw const TransportException('Server index job failed');
      }
      phase = 'Index ${state.status} · ${watch.elapsed.inSeconds}s';
      progress = null;
      emit();
      await Future.any([
        Future<void>.delayed(const Duration(seconds: 4)),
        token.whenCanceled,
      ]);
    }
    notice = 'Still processing. Use Resume to check the server job again.';
  }

  void stopWork() {
    _work?.cancel();
    _upload?.cancel();
  }

  void invalidateSearch() {
    _searchGeneration++;
    _queryToken?.cancel();
    searching = false;
    batch = null;
    emit();
  }

  Future<void> search(String query, {double maxDistance = 1.5}) async {
    final gateway = _gateway;
    if (gateway == null ||
        !canRead ||
        indexVersion == null ||
        query.trim().isEmpty ||
        busy) {
      return;
    }
    invalidateSearch();
    final generation = _searchGeneration;
    final token = CancellationToken();
    _queryToken = token;
    searching = true;
    activeQuery = query.trim();
    notice = '';
    emit();
    try {
      final result = await gateway.search(
        activeQuery,
        cancellation: token,
        maxDistance: maxDistance,
      );
      if (_disposed || generation != _searchGeneration) return;
      batch = result;
      record(
        'Search complete',
        '“$activeQuery” · ${result.matches.length} returned · ${result.roundTripMs} ms request · ${result.serverMs.toStringAsFixed(0)} ms server',
      );
    } on OperationCanceled {
      /* A newer query owns the screen. */
    } on Object catch (e) {
      if (generation == _searchGeneration) {
        notice = safeError(e);
        record('Search failed', notice, error: true);
      }
    } finally {
      if (generation == _searchGeneration) {
        searching = false;
        emit();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _writer?.retire();
    _queryToken?.cancel();
    stopWork();
    super.dispose();
  }
}

String safeError(Object error) {
  if (error is AuthException) {
    return 'Authentication failed. Check your API key and beta access.';
  }
  if (error is SdkException) return error.toString();
  if (error is FileSystemException) {
    return 'The local video could not be read. Import it again.';
  }
  return 'The operation could not finish. Check the connection and try again.';
}

int _safeInt(Object? value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;

double _safeDouble(Object? value) =>
    value is num ? value.toDouble() : double.tryParse('$value') ?? 0;

String _cloudDeletionError(Object error, {bool preview = false}) {
  if (error is SdkException && error.statusCode == 409) {
    return 'Cloud processing is still running. Wait for it to finish, then retry.';
  }
  if (error is SdkException &&
      error.statusCode == 500 &&
      '${error.body}'.toLowerCase().contains('partial delete failure')) {
    return 'Cloud deletion may be incomplete. Local videos were kept. Reconnect and verify before retrying.';
  }
  if (preview) {
    return 'The deletion preview could not be verified. Nothing was deleted.';
  }
  return 'Cloud deletion could not be confirmed. Local videos were kept. Reconnect and verify before retrying.';
}

String timeLabel(double seconds) {
  final value = seconds.isFinite ? seconds.floor().clamp(0, 86400) : 0;
  return '${(value ~/ 60).toString().padLeft(2, '0')}:${(value % 60).toString().padLeft(2, '0')}';
}
