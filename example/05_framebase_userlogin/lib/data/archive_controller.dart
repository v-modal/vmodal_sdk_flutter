import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
    this.uploaded = false,
    this.bundled = true,
  });
  final String id, title, location, asset, poster;
  final double duration;
  String? path;
  bool uploaded;
  final bool bundled;
  String get filename => '$id.mp4';
  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'location': location,
    'duration': duration,
    'asset': asset,
    'poster': poster,
    'path': path,
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
    uploaded: r['uploaded'] == true,
    bundled: r['bundled'] == true,
  );
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
  String _collectionUserId = '';
  bool canRead = false, canWrite = false;
  Future<void> _saveQueue = Future<void>.value();
  bool get connected => _gateway != null;
  bool get ready => connected && indexVersion != null;
  bool get hasPendingUploads => clips.any((c) => !c.uploaded);

  void emit() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    initialized = true;
    emit();
  }

  Future<void> activate(
    String collectionUserId,
    SearchGateway gateway, {
    required bool canRead,
    required bool canWrite,
  }) async {
    deactivate();
    final generation = _generation;
    _collectionUserId = collectionUserId;
    this.canRead = canRead;
    this.canWrite = canWrite;
    _gateway = gateway;
    indexVersion = gateway.version;
    try {
      final root = supportDirectory ?? await getApplicationSupportDirectory();
      if (generation != _generation) return;
      _directory = Directory('${root.path}/accounts/$collectionUserId');
      if (persist) {
        final state = File('${_directory!.path}/archive.json');
        if (await state.exists()) {
          final data =
              jsonDecode(await state.readAsString()) as Map<String, dynamic>;
          final saved = (data['clips'] as List)
              .map(
                (r) =>
                    ArchiveClip.fromJson(Map<String, dynamic>.from(r as Map)),
              )
              .toList();
          if (generation != _generation) return;
          clips = saved
              .where(
                (c) =>
                    c.bundled || (c.path != null && File(c.path!).existsSync()),
              )
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
      }
    } on Object {
      notice =
          'Local archive could not be restored. Built-in clips are available.';
    }
    if (generation != _generation) return;
    initialized = true;
    emit();
  }

  void deactivate() {
    _generation++;
    stopWork();
    invalidateSearch();
    _gateway = null;
    _directory = null;
    _collectionUserId = '';
    canRead = false;
    canWrite = false;
    clips = streetClips();
    events.clear();
    initialized = false;
    connecting = false;
    busy = false;
    searching = false;
    phase = notice = activeQuery = pendingJob = '';
    progress = null;
    batch = null;
    indexVersion = null;
    emit();
  }

  Future<void> save() {
    if (!persist || _directory == null || _collectionUserId.isEmpty) {
      return Future<void>.value();
    }
    // Snapshot and serialize writes so progress events cannot truncate each other.
    // Never serialize the client, key, response rows or signed URLs.
    final snapshot = jsonEncode({
      'clips': clips.map((c) => c.toJson()).toList(),
      'pendingJob': pendingJob,
      'events': events.take(40).map((e) => e.toJson()).toList(),
    });
    final path = '${_directory!.path}/archive.json';
    _saveQueue = _saveQueue.then((_) async {
      try {
        await File(path).parent.create(recursive: true);
        await File(path).writeAsString(snapshot, flush: true);
      } on Object {
        /* Optional history must not cancel network work. */
      }
    });
    return _saveQueue;
  }

  void record(String title, String detail, {bool error = false}) {
    events.insert(0, ArchiveEvent(title, detail, error: error));
    if (events.length > 40) events.removeLast();
    unawaited(save());
    emit();
  }

  Future<File> localFile(ArchiveClip clip) async {
    if (clip.path != null && await File(clip.path!).exists()) {
      return File(clip.path!);
    }
    if (!clip.bundled) {
      throw const FileSystemException('Recording no longer available');
    }
    if (_directory == null || _collectionUserId.isEmpty) {
      throw const FileSystemException('No active library');
    }
    final file = File('${_directory!.path}/${clip.filename}');
    if (!await file.exists()) {
      await file.parent.create(recursive: true);
      final data = await rootBundle.load(clip.asset);
      await file.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }
    clip.path = file.path;
    return file;
  }

  Future<void> importFile(String path, double duration) async {
    if (!canWrite || _directory == null) return;
    final generation = _generation;
    final directory = _directory!;
    await directory.create(recursive: true);
    if (generation != _generation) return;
    final id = 'street_${DateTime.now().millisecondsSinceEpoch}';
    final file = await File(path).copy('${directory.path}/$id.mp4');
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

  ArchiveClip? clipFor(String filename) {
    final clean = basename(filename).toLowerCase();
    for (final clip in clips) {
      if (clean == clip.id.toLowerCase() ||
          clean == clip.filename.toLowerCase() ||
          clean.startsWith('${clip.id.toLowerCase()}.')) {
        return clip;
      }
    }
    return null;
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
    for (var attempt = 0; attempt < 120; attempt++) {
      token.throwIfCanceled();
      final state = await gateway.indexStatus(pendingJob, token);
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

String timeLabel(double seconds) {
  final value = seconds.isFinite ? seconds.floor().clamp(0, 86400) : 0;
  return '${(value ~/ 60).toString().padLeft(2, '0')}:${(value % 60).toString().padLeft(2, '0')}';
}
