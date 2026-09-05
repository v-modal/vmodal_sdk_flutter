import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

import 'scene.dart';
import 'settings.dart';

const String _stream = 'astream';
const String _mode = 'vid_file';
const String _indexType = 'vid_img_emb';

/// How many ranked frames to ask for. Has to be well above the number of
/// frames one clip can contribute, or a collection of several clips gets cut
/// off by this rather than by relevance — 12 made every query return 12.
const int _resultLimit = 50;

/// Frames shown per clip. The heading still reports the true total, so a clip
/// with 39 matching moments says so while showing its best few.
const int shownPerClip = 6;

/// Results are cut two ways, both on the backend's `score`, which is a
/// **distance** — lower is closer. Each scene sets its own numbers, see
/// [Scene.relevanceWindow] and [Scene.relevanceCeiling], because one camera and
/// a whole archive want different answers.
///
/// Neither can be tuned into a presence test. The score does not measure
/// whether the subject is there: `a person` scores 0.875 with dozens of people
/// visible, while `a giraffe` scores 0.877 with none. So the ceiling only
/// rejects the absurd, and an empty result says "nothing close enough" rather
/// than claiming the subject is absent. The SDK's own `textEmbScoreMin` filters
/// nothing at all — 0.9, 0.5 and 0.0 return identical results.

/// Modality the image endpoints expect for video frames.
///
/// The SDK's own Flutter example sends `image` here and resolves nothing; the
/// Android example sends `vid_img`, which is the value that works.
const String _imageModality = 'vid_img';

/// Where a scene's footage has got to.
enum FootageStage { idle, uploading, indexing, ready, failed }

/// One frame the search came back with.
@immutable
class SearchHit {
  const SearchHit({
    required this.fileName,
    required this.stream,
    required this.timestampMs,
    required this.token,
    this.bytes,
  });

  final String fileName;
  final String stream;
  final int timestampMs;

  /// `url_pre_signed`: a gateway token to POST, never a URL to fetch.
  final String token;

  final Uint8List? bytes;

  SearchHit withBytes(Uint8List? value) => SearchHit(
    fileName: fileName,
    stream: stream,
    timestampMs: timestampMs,
    token: token,
    bytes: value,
  );

  /// How far into the clip this frame is. The backend reports frame time as a
  /// millisecond offset from the start, zero-padded to 13 digits.
  String get timeLabel {
    final int total = (timestampMs / 1000).round();
    String two(int v) => v.toString().padLeft(2, '0');
    final int hours = total ~/ 3600;
    final String rest = '${two(total % 3600 ~/ 60)}:${two(total % 60)}';
    return hours > 0 ? '$hours:$rest' : rest;
  }
}

/// Everything one tab needs to know about its own footage and results.
class SceneState {
  FootageStage stage = FootageStage.idle;

  /// Footage progress: uploading, indexing, or what went wrong with it.
  String message = '';

  /// How the last search went, when it found nothing worth showing.
  String searchMessage = '';
  int uploadedBytes = 0;
  int totalBytes = 0;
  String indexStatus = '';
  bool searching = false;
  String query = '';

  /// The picture searched with, when the query was an image rather than words.
  Uint8List? queryImage;

  /// Frames the search returned per clip before the relevance cut, so a result
  /// can say three of twenty-eight rather than just three.
  Map<String, int> framesPerClip = const <String, int>{};
  bool hasSearched = false;
  List<SearchHit> hits = const <SearchHit>[];
  int matchCount = 0;
  double elapsedMs = 0;

  double get uploadFraction =>
      totalBytes <= 0 ? 0 : (uploadedBytes / totalBytes).clamp(0, 1);
}

/// Owns the SDK client and the per-scene state for both tabs.
class SightlineController extends ChangeNotifier {
  VmodalClient? _client;
  MutableApiKeyProvider? _keys;
  bool _connecting = false;
  String? _connectError;
  final Map<String, SceneState> _states = <String, SceneState>{};

  /// Set when a search resolves nothing, so the screen can say why.
  String _diagnostic = '';

  Settings _settings = Settings();

  /// The saved key and collection names, if the user asked to keep them.
  Settings get settings => _settings;

  /// The collection this scene searches: whatever the user typed for it.
  String collectionFor(Scene scene) =>
      _settings.collections[scene.id]?.trim() ?? '';

  /// Whether the scene has both a key and a collection to work with.
  bool isReady(Scene scene) => isConnected && collectionFor(scene).isNotEmpty;

  /// Loads anything saved from a previous run and connects if it can.
  Future<void> restore() async {
    _settings = Settings.load();
    notifyListeners();
    if (_settings.apiKey.isNotEmpty) await connect(_settings.apiKey);
  }

  /// Stores what the user typed in the setup sheet.
  Future<bool> applySetup({
    required Scene scene,
    required String apiKey,
    required String collection,
    required bool remember,
  }) async {
    _settings
      ..apiKey = apiKey.trim()
      ..remember = remember;
    _settings.collections[scene.id] = collection.trim();
    _settings.save();
    return connect(_settings.apiKey);
  }

  /// Drops the saved copy from the device.
  void forgetSaved() {
    _settings
      ..remember = false
      ..forget();
    notifyListeners();
  }

  final Set<String> _bundled = <String>{};
  final Map<String, Set<String>> _uploaded = <String, Set<String>>{};

  /// The clip names the server has actually reported for a scene's collection,
  /// alphabetically. There is no endpoint that lists a collection, so this is
  /// built from names seen in search results plus anything uploaded here.
  List<String> uploadedClips(Scene scene) =>
      (_uploaded[collectionFor(scene)]?.toList() ?? <String>[])..sort();

  /// The clips actually present in this build. A scene can name clips that are
  /// not bundled yet, and the UI must not pretend they exist.
  bool isBundled(FootageClip clip) => _bundled.contains(clip.asset);

  /// Clips from [scene] that this build really carries.
  List<FootageClip> bundledFootage(Scene scene) =>
      scene.footage.where(isBundled).toList();

  bool get isConnected => _client != null;
  bool get isConnecting => _connecting;
  String? get connectError => _connectError;

  SceneState stateOf(Scene scene) =>
      _states.putIfAbsent(scene.id, SceneState.new);

  /// Authenticates by making a call that actually requires the key.
  ///
  /// The key is held in memory by the SDK's own provider and is never written
  /// anywhere by this app.
  Future<bool> connect(String key) async {
    _connecting = true;
    _connectError = null;
    notifyListeners();
    MutableApiKeyProvider? keys;
    VmodalClient? client;
    try {
      keys = MutableApiKeyProvider(key.trim());
      client = VmodalClient(config: SdkConfig(apiKeyProvider: keys));
      final GroupsResponse groups = await client.collections.listGroups(
        mode: _mode,
      );
      _markAlreadyIndexed(groups);
      await _dispose();
      _keys = keys;
      _client = client;
      await _readCollections(client, groups);
      return true;
    } on SdkException catch (error) {
      await client?.close();
      keys?.close();
      _connectError = _readable(error);
      return false;
    } finally {
      _connecting = false;
      notifyListeners();
    }
  }

  /// Asks each collection what it holds. There is no listing endpoint, so this
  /// runs a few unrelated searches over a deep page and keeps every clip name
  /// that comes back. Unrelated queries on purpose: one query only surfaces
  /// what resembles it, and a deep page so nothing is cut off by paging.
  Future<void> _readCollections(
    VmodalClient client,
    GroupsResponse groups,
  ) async {
    for (final Scene scene in scenes) {
      final int? version = groups
          .findGroup(collectionFor(scene), mode: _mode)
          ?.latestLancedbVersion;
      if (version == null) continue;
      final Set<String> found = <String>{};
      for (final String probe in const <String>[
        'a photo',
        'an animal',
        'water',
        'a street',
        'food',
      ]) {
        try {
          final SearchResponse response = await client.searches.searchVideo(
            SearchRequest(
              queryText: probe,
              mode: _mode,
              groupName: collectionFor(scene),
              streamName: _stream,
              searchSources: const <String>['image'],
              versionLancedb: version,
              limit: 200,
            ),
          );
          for (final Object? row in response.data) {
            if (row is Map) found.add(_titleOf('${row['title']}'));
          }
        } on SdkException {
          // Try the next probe.
        }
      }
      found.remove('');
      if (found.isNotEmpty) _uploaded[collectionFor(scene)] = found;
    }
    notifyListeners();
  }

  /// The index lives on the server, so footage indexed in an earlier session
  /// is still searchable. Reflect that instead of asking for it again.
  void _markAlreadyIndexed(GroupsResponse groups) {
    for (final Scene scene in scenes) {
      final bool indexed =
          groups
              .findGroup(collectionFor(scene), mode: _mode)
              ?.latestLancedbVersion !=
          null;
      if (!indexed) continue;
      stateOf(scene)
        ..stage = FootageStage.ready
        ..message = '';
    }
  }

  Future<void> signOut() async {
    await _dispose();
    _states.clear();
    notifyListeners();
  }

  /// Copies the bundled clips into the app's Documents folder, which iOS
  /// publishes to the Files app, so they can be picked like any other video.
  /// Anything already there is left alone.
  Future<void> publishBundledFootage() async {
    for (final Scene scene in scenes) {
      for (final FootageClip clip in scene.footage) {
        try {
          await rootBundle.load(clip.asset);
          _bundled.add(clip.asset);
        } on FlutterError {
          // Not in this build.
        }
      }
    }
    notifyListeners();
    if (!Platform.isIOS) return;
    final Directory docs = Directory(
      '${Directory.systemTemp.parent.path}/Documents',
    );
    if (!docs.existsSync()) docs.createSync(recursive: true);
    for (final Scene scene in scenes) {
      for (final FootageClip clip in scene.footage) {
        await _copyToFiles(clip.asset, docs);
      }
    }
    for (final String image in queryImages) {
      await _copyToFiles(image, docs);
    }
  }

  /// Surfaces a problem from outside the controller, so a failure shows on the
  /// card rather than disappearing into the console.
  void reportProblem(Scene scene, String message) {
    stateOf(scene).message = message;
    notifyListeners();
  }

  /// Uploads footage and indexes it for search. Uses [files] when given,
  /// otherwise the clips bundled with the app.
  ///
  /// Footage is added to the collection. Nothing here deletes.
  Future<void> prepare(Scene scene, {List<File>? files}) async {
    final VmodalClient? client = _client;
    if (client == null) return;
    final SceneState state = stateOf(scene);
    state
      ..stage = FootageStage.uploading
      ..message = 'Adding footage'
      ..uploadedBytes = 0
      ..totalBytes = 0
      ..indexStatus = ''
      ..hits = const <SearchHit>[]
      ..hasSearched = false;
    notifyListeners();

    try {
      final List<({File file, String label, bool temporary})> queue =
          <({File file, String label, bool temporary})>[
            if (files != null)
              for (final File chosen in files)
                (
                  file: chosen,
                  label: chosen.uri.pathSegments.last,
                  temporary: false,
                )
            else
              for (final FootageClip clip in scene.footage)
                if (await _materialise(clip.asset) case final File ready)
                  (file: ready, label: clip.label, temporary: true),
          ];

      for (final ({File file, String label, bool temporary}) item in queue) {
        final File file = item.file;
        final UploadSource source = UploadSource.fromFile(file);
        final UploadTask<VideoUploadResponse> task = client.collections
            .videoUpload(
              source,
              collectionName: collectionFor(scene),
              subCollectionName: _stream,
            );
        state.totalBytes = source.contentLength;
        final StreamSubscription<UploadProgress> sub = task.progress.listen((
          UploadProgress p,
        ) {
          state
            ..uploadedBytes = p.uploadedBytes
            ..totalBytes = p.totalBytes
            ..message = 'Uploading ${item.label} · ${p.percent}%';
          notifyListeners();
        });
        try {
          await task.result;
        } finally {
          await sub.cancel();
        }
        _uploaded
            .putIfAbsent(collectionFor(scene), () => <String>{})
            .add(_titleOf(file.uri.pathSegments.last));
        if (item.temporary) {
          try {
            await file.parent.delete(recursive: true);
          } on FileSystemException {
            // A leftover temp file is harmless.
          }
        }
      }

      state
        ..stage = FootageStage.indexing
        ..indexStatus = 'queued'
        ..message = 'Indexing footage';
      notifyListeners();

      final IndexationSubmitResponse job = await client.indexes.createIndex(
        IndexationSubmitRequest(
          mode: _mode,
          groupName: collectionFor(scene),
          streamName: _stream,
          indexType: _indexType,
          modality: _indexType,
          reProcess: true,
        ),
      );
      await _awaitIndex(client, state, job.jobId);
    } on SdkException catch (error) {
      state
        ..stage = FootageStage.failed
        ..message = _readable(error);
      notifyListeners();
    }
  }

  Future<void> _awaitIndex(
    VmodalClient client,
    SceneState state,
    String jobId,
  ) async {
    for (int attempt = 0; attempt < 120; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 5));
      final IndexationStatusResponse job = await client.indexes.indexStatus(
        jobId,
      );
      final String status = job.status.trim().toLowerCase();
      state
        ..indexStatus = status.isEmpty ? 'unknown' : status
        ..message = 'Indexing footage · $status';
      notifyListeners();
      if (_indexDone(status)) {
        state
          ..stage = FootageStage.ready
          ..message = 'Footage indexed and searchable';
        notifyListeners();
        return;
      }
      if (status == 'failed' || status == 'error') {
        state
          ..stage = FootageStage.failed
          ..message = 'Indexing failed';
        notifyListeners();
        return;
      }
    }
    state
      ..stage = FootageStage.failed
      ..message = 'Indexing did not finish in time';
    notifyListeners();
  }

  /// Searches with one of the pictures bundled in the app.
  Future<void> searchByAsset(Scene scene, String asset) async {
    final File? file = await _materialise(asset);
    if (file != null) await searchByImage(scene, file);
  }

  /// Searches with a picture instead of words. The SDK exposes this through
  /// `image_query`, which takes base64 image bytes — undocumented, and its own
  /// example never uses it.
  Future<void> searchByImage(Scene scene, File image) async {
    final VmodalClient? client = _client;
    if (client == null) return;
    final SceneState state = stateOf(scene);
    state
      ..searching = true
      ..query = ''
      ..hasSearched = true
      ..hits = const <SearchHit>[]
      ..matchCount = 0
      ..searchMessage = '';
    notifyListeners();

    try {
      final ({String base64, Uint8List preview}) prepared = await _encodeQuery(
        image,
      );
      state.queryImage = prepared.preview;
      await _runSearch(client, scene, state, imageQuery: prepared.base64);
    } on SdkException catch (error) {
      state
        ..searching = false
        ..searchMessage = _readable(error);
      notifyListeners();
    } on Object catch (error) {
      state
        ..searching = false
        ..searchMessage = 'Could not read that picture: $error';
      notifyListeners();
    }
  }

  /// Shrinks the picture before sending it, since a phone photo would be
  /// megabytes of base64.
  Future<({String base64, Uint8List preview})> _encodeQuery(File image) async {
    final Uint8List raw = await image.readAsBytes();
    final ui.Codec codec = await ui.instantiateImageCodec(
      raw,
      targetWidth: 512,
    );
    final ui.FrameInfo frame = await codec.getNextFrame();
    final ByteData? png = await frame.image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    frame.image.dispose();
    codec.dispose();
    final Uint8List bytes = png == null
        ? raw
        : png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
    return (base64: base64Encode(bytes), preview: bytes);
  }

  /// Runs one search and resolves a thumbnail for every hit.
  Future<void> search(Scene scene, String query) async {
    final VmodalClient? client = _client;
    final String clean = query.trim();
    if (client == null || clean.isEmpty) return;
    final SceneState state = stateOf(scene);
    state
      ..searching = true
      ..query = clean
      ..queryImage = null
      ..hasSearched = true
      ..hits = const <SearchHit>[]
      ..matchCount = 0
      ..searchMessage = '';
    notifyListeners();

    try {
      await _runSearch(client, scene, state, queryText: clean);
    } on SdkException catch (error) {
      state
        ..searching = false
        ..searchMessage = _readable(error);
      notifyListeners();
    }
  }

  /// The one request path shared by text and image search.
  Future<void> _runSearch(
    VmodalClient client,
    Scene scene,
    SceneState state, {
    String queryText = '',
    String? imageQuery,
  }) async {
    // Search needs the collection's advertised index version, and only the
    // group listing carries it.
    final GroupsResponse groups = await client.collections.listGroups(
      mode: _mode,
    );
    final int? version = groups
        .findGroup(collectionFor(scene), mode: _mode)
        ?.latestLancedbVersion;
    if (version == null) {
      state
        ..searching = false
        ..searchMessage = 'This collection has no finished index yet.';
      notifyListeners();
      return;
    }

    final SearchResponse response = await client.searches.searchVideo(
      SearchRequest(
        queryText: queryText,
        imageQuery: imageQuery,
        mode: _mode,
        groupName: collectionFor(scene),
        streamName: _stream,
        searchSources: const <String>['image'],
        versionLancedb: version,
        limit: _resultLimit,
      ),
    );

    _diagnostic = '';
    final List<SearchHit> hits = await _resolveHits(client, scene, response);
    state
      ..hits = hits
      ..matchCount = response.cntTotal
      ..elapsedMs = response.executionTimeMs
      ..searching = false
      ..searchMessage = hits.isEmpty ? _diagnostic : '';
    notifyListeners();
  }

  /// Turns raw search rows into frames with pixels.
  Future<List<SearchHit>> _resolveHits(
    VmodalClient client,
    Scene scene,
    SearchResponse response,
  ) async {
    final List<Map<String, Object?>> rows = response.data
        .whereType<Map<Object?, Object?>>()
        .map(
          (Map<Object?, Object?> row) => row.map(
            (Object? k, Object? v) => MapEntry<String, Object?>('$k', v),
          ),
        )
        .toList();

    final Map<String, int> perClip = <String, int>{};
    for (final Map<String, Object?> row in rows) {
      final String name = _fileName(row);
      if (name.isNotEmpty) {
        perClip[name] = (perClip[name] ?? 0) + 1;
      }
    }
    stateOf(scene).framesPerClip = perClip;

    // Ranked already, but the list always runs to the limit, so drop the tail
    // that trails away from this query's best frame.
    final double? best = rows
        .map((Map<String, Object?> row) => row['score'])
        .whereType<num>()
        .where((num s) => s.isFinite)
        .fold<double?>(
          null,
          (double? lowest, num s) =>
              lowest == null || s < lowest ? s.toDouble() : lowest,
        );
    if (best != null) {
      final double cut = (best + scene.relevanceWindow).clamp(
        0,
        scene.relevanceCeiling,
      );
      rows.retainWhere((Map<String, Object?> row) {
        final Object? score = row['score'];
        return score is num && score.isFinite && score <= cut;
      });
    }

    final List<Map<String, Object?>> records = <Map<String, Object?>>[];
    final List<SearchHit> pending = <SearchHit>[];
    final List<String> dropped = <String>[];
    for (final Map<String, Object?> row in rows) {
      final String name = _fileName(row);
      if (name.isEmpty) {
        dropped.add(row.keys.join(','));
        continue;
      }
      final String stream = _firstText(row, const <String>[
        'stream',
        'stream_name',
      ]);
      final String ts = _timestamp13(row);
      records.add(<String, Object?>{
        'mode': _mode,
        'group_name': collectionFor(scene),
        'modality': _imageModality,
        'stream_name': stream.isEmpty ? _stream : stream,
        'filename': name,
        // Required for video modes even when the frame time is all zeros.
        'ts_unix_13digits': ts,
      });
      pending.add(
        SearchHit(
          fileName: name,
          stream: stream.isEmpty ? _stream : stream,
          timestampMs: int.tryParse(ts) ?? 0,
          token: '',
        ),
      );
    }
    if (records.isEmpty) {
      _diagnostic = dropped.isEmpty
          ? 'Nothing close enough in this footage.'
          : 'Rows came back with no filename. Fields present: '
                '${dropped.first}';
      return const <SearchHit>[];
    }

    final ImageUrlBulkResponse urls = await client.images.getUrlBulk(records);
    final List<SearchHit> resolved = <SearchHit>[];
    for (int i = 0; i < pending.length; i++) {
      final String token = i < urls.records.length
          ? '${urls.records[i]['url_pre_signed'] ?? ''}'
          : '';
      if (token.isEmpty) {
        _diagnostic =
            'Rows parsed, but the image endpoint returned no token. '
            'Raw reply: ${urls.records.isEmpty ? '(empty)' : urls.records.first}';
        continue;
      }
      resolved.add(
        SearchHit(
          fileName: pending[i].fileName,
          stream: pending[i].stream,
          timestampMs: pending[i].timestampMs,
          token: token,
        ),
      );
    }

    // `url_pre_signed` is a token to POST, not a URL to GET, so the bytes have
    // to come back through the authenticated client.
    return Future.wait(
      resolved.map((SearchHit hit) async {
        try {
          return hit.withBytes(await client.images.getImageFromUrl(hit.token));
        } on SdkException {
          return hit;
        }
      }),
    );
  }

  Future<void> _copyToFiles(String asset, Directory docs) async {
    final File target = File('${docs.path}/${asset.split('/').last}');
    if (target.existsSync()) return;
    final File? source = await _materialise(asset);
    if (source != null) await source.copy(target.path);
  }

  /// Copies a bundled asset to a real file, which is what an upload needs.
  /// Returns null when the clip is not bundled, so an archive can be filled in
  /// one clip at a time.
  Future<File?> _materialise(String asset) async {
    final ByteData data;
    try {
      data = await rootBundle.load(asset);
    } on FlutterError {
      return null;
    }
    final Directory dir = await Directory.systemTemp.createTemp('sightline');
    final File file = File('${dir.path}/${asset.split('/').last}');
    await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    return file;
  }

  Future<void> _dispose() async {
    await _client?.close();
    _keys?.close();
    _client = null;
    _keys = null;
  }

  @override
  void dispose() {
    _dispose();
    super.dispose();
  }
}

/// Clip names come back without their extension.
String _titleOf(String fileName) =>
    fileName.contains('.') ? fileName.split('.').first : fileName;

bool _indexDone(String status) => const <String>{
  'success',
  'succeeded',
  'done',
  'completed',
  'ok',
}.contains(status);

String _firstText(Map<String, Object?> row, List<String> keys) {
  for (final String key in keys) {
    final String value = '${row[key] ?? ''}'.trim();
    if (value.isNotEmpty) return value;
  }
  return '';
}

/// Filename for the frame. Video rows carry no `filename` at all, so this
/// falls back to `title`, and then to a name rebuilt from `item_id`.
///
/// All three are needed. Some uploads come back with an empty `title` too, and
/// then `item_id` is the only thing left — a clip uploaded from the device did
/// exactly that, ranked top for every query, and every one of its rows was
/// being thrown away. `item_id` reads `astream-dog_playing_01-0000000004838`,
/// so stripping the stream prefix and the timestamp gives the name the image
/// endpoint wants.
String _fileName(Map<String, Object?> row) {
  String raw = _firstText(row, const <String>[
    'filename',
    'filename_sanitized',
    'video_filename',
    'source_filename',
    'source_path',
    'path',
  ]);
  raw = raw.isEmpty ? _firstText(row, const <String>['title']) : raw;
  if (raw.isEmpty) raw = _nameFromItemId(row);
  return raw.replaceAll(r'\', '/').split('/').last.trim();
}

String _nameFromItemId(Map<String, Object?> row) {
  final String itemId = _firstText(row, const <String>['item_id']);
  if (itemId.isEmpty) return '';
  final String stream = _firstText(row, const <String>[
    'stream',
    'stream_name',
  ]);
  final String ts = _firstText(row, const <String>[
    'ts_unix_13digits',
    'ts_unix',
  ]);
  String name = itemId;
  if (stream.isNotEmpty && name.startsWith('$stream-')) {
    name = name.substring(stream.length + 1);
  }
  if (ts.isNotEmpty && name.endsWith('-$ts')) {
    name = name.substring(0, name.length - ts.length - 1);
  }
  return name;
}

/// Frame time as the 13-digit string the image endpoints expect.
String _timestamp13(Map<String, Object?> row) {
  final String digits = _firstText(row, const <String>[
    'ts_unix_13digits',
    'ts_unix',
    'timestamp_ms',
    'timestamp',
  ]).replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.isEmpty) return '0000000000000';
  if (digits.length >= 13) return digits.substring(0, 13);
  if (digits.length == 10) return '${digits}000';
  return digits.padLeft(13, '0');
}

String _readable(SdkException error) {
  if (error is AuthException) return 'That key was not accepted.';
  if (error is ApiException) {
    return 'Server said ${error.statusCode}. Try again in a moment.';
  }
  return 'Something went wrong talking to VModal.';
}
