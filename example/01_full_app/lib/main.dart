import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

const String exampleCollectionName = 'flutter_example';
const String exampleStreamName = 'astream';
const String exampleIndexType = 'vid_img_emb';

List<String> exampleCollectionNames(GroupsResponse response) {
  final names = response.data
      .where((GroupItem item) => item.mode == 'vid_file')
      .map((GroupItem item) => item.groupName.trim())
      .where((String name) => name.isNotEmpty)
      .toSet()
      .toList();
  names.sort();
  return names;
}

SearchRequest exampleSearchRequest(
  String query,
  String collectionName,
  String streamName,
  int versionLancedb,
) => SearchRequest(
  queryText: query.trim(),
  groupName: collectionName.trim(),
  streamName: streamName.trim(),
  searchSources: const <String>['image'],
  versionLancedb: versionLancedb,
);

IndexationSubmitRequest exampleIndexRequest(
  String collectionName,
  String streamName,
) => IndexationSubmitRequest(
  mode: 'vid_file',
  groupName: collectionName.trim(),
  streamName: streamName.trim(),
  indexType: exampleIndexType,
  modality: exampleIndexType,
  reProcess: true,
);

bool exampleIndexDone(String status) => const <String>{
  'success',
  'succeeded',
  'done',
  'completed',
  'ok',
}.contains(status.trim().toLowerCase());

List<Map<String, Object?>> exampleSearchRows(SearchResponse response) =>
    response.data
        .whereType<Map<Object?, Object?>>()
        .map(
          (Map<Object?, Object?> row) =>
              row.map((Object? key, Object? value) => MapEntry('$key', value)),
        )
        .toList();

String exampleFirstText(Map<String, Object?> row, List<String> keys) {
  for (final key in keys) {
    final value = '${row[key] ?? ''}'.trim();
    if (value.isNotEmpty) return value;
  }
  return '';
}

String exampleFilename(String value) {
  final clean = value.trim().replaceAll('\\', '/');
  return clean.split('/').last.trim();
}

String exampleTimestamp13(Object? value) {
  final digits = '${value ?? ''}'.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.length >= 13) return digits.substring(0, 13);
  if (digits.length == 10) return '${int.parse(digits) * 1000}';
  if (digits.isNotEmpty) return digits.padLeft(13, '0');
  return '';
}

String exampleScore(Map<String, Object?> row) {
  final scoreUi = row['score_ui'];
  if (scoreUi is num && scoreUi.isFinite && scoreUi >= 0 && scoreUi <= 1) {
    return '${(scoreUi * 100).toStringAsFixed(1)}%';
  }
  for (final key in <String>[
    'score_ui',
    'score',
    'similarity',
    'image_score',
    'text_score',
  ]) {
    final value = row[key];
    if (value is num && !value.isFinite) continue;
    final clean = '${value ?? ''}'.trim();
    if (clean.isNotEmpty) return clean;
  }
  return '';
}

class ExampleSearchCandidate {
  const ExampleSearchCandidate({
    required this.searchIndex,
    required this.row,
    required this.record,
  });

  final int searchIndex;
  final Map<String, Object?> row;
  final Map<String, Object?> record;
}

class ExampleSearchImage {
  const ExampleSearchImage({
    required this.id,
    required this.url,
    required this.title,
    required this.filename,
    required this.stream,
    required this.timestamp,
    required this.score,
  });

  final String id;
  final String url;
  final String title;
  final String filename;
  final String stream;
  final String timestamp;
  final String score;
}

List<ExampleSearchCandidate> exampleSearchCandidates(
  SearchResponse response,
  String collectionName,
  String streamName,
) {
  final rows = exampleSearchRows(response);
  final candidates = <ExampleSearchCandidate>[];
  for (var index = 0; index < rows.length; index++) {
    final row = rows[index];
    final rawName = exampleFirstText(row, const <String>[
      'filename',
      'filename_sanitized',
      'video_filename',
      'video',
      'source_path',
      'path',
    ]);
    final filename = exampleFilename(rawName);
    if (filename.isEmpty) continue;
    final stream = exampleFirstText(row, const <String>['stream_name']);
    final timestamp = exampleTimestamp13(
      exampleFirstText(row, const <String>[
        'ts_unix_13digits',
        'ts_unix',
        'timestamp_ms',
      ]),
    );
    final record = <String, Object?>{
      'mode': 'vid_file',
      'group_name': collectionName.trim(),
      'modality': 'image',
      'stream_name': stream.isEmpty ? streamName.trim() : stream,
      'filename': filename,
      if (timestamp.isNotEmpty) 'ts_unix_13digits': timestamp,
    };
    candidates.add(
      ExampleSearchCandidate(searchIndex: index, row: row, record: record),
    );
  }
  return candidates;
}

int? _exampleInputIndex(Object? value) {
  if (value is num && value.isFinite) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

List<ExampleSearchImage> exampleSearchImages(
  List<ExampleSearchCandidate> candidates,
  ImageUrlBulkResponse response,
) {
  final resolved = <int, ExampleSearchImage>{};
  for (var rowIndex = 0; rowIndex < response.records.length; rowIndex++) {
    final row = response.records[rowIndex];
    final rawIndex = row['input_index'];
    final inputIndex = rawIndex == null
        ? rowIndex
        : _exampleInputIndex(rawIndex);
    if (inputIndex == null ||
        inputIndex < 0 ||
        inputIndex >= candidates.length ||
        resolved.containsKey(inputIndex) ||
        row['found'] == false) {
      continue;
    }
    final url = '${row['url_pre_signed'] ?? ''}'.trim();
    if (url.isEmpty) continue;
    final candidate = candidates[inputIndex];
    final hit = candidate.row;
    final filename = '${candidate.record['filename'] ?? ''}'.trim();
    final timestamp = '${candidate.record['ts_unix_13digits'] ?? ''}'.trim();
    final stream = '${candidate.record['stream_name'] ?? ''}'.trim();
    final title = exampleFirstText(hit, const <String>[
      'effective_title',
      'title',
      'text',
      'caption',
      'ocr',
      'asr',
      'description',
      'item_id',
      'text_agg_tok',
    ]);
    resolved[inputIndex] = ExampleSearchImage(
      id: '$inputIndex-$filename-$timestamp',
      url: url,
      title: title.isEmpty ? filename : title,
      filename: filename,
      stream: stream,
      timestamp: timestamp,
      score: exampleScore(hit),
    );
  }
  final indexes = resolved.keys.toList()..sort();
  return indexes.map((int index) => resolved[index]!).toList();
}

String exampleSearchNotFound(ApiException error, String collectionName) {
  final body = '${error.body}'.toLowerCase();
  if (body.contains('missing lancedb') || body.contains('missing index')) {
    return 'No searchable index exists for $collectionName. '
        'Upload the video and create its index before searching.';
  }
  return 'The configured gateway does not expose the search route.';
}

typedef ExampleImageProviderFactory =
    ImageProvider<Object> Function(String url);

ImageProvider<Object> exampleNetworkImageProvider(String url) =>
    NetworkImage(url);

class ExampleSearchResults extends StatelessWidget {
  const ExampleSearchResults({
    required this.images,
    required this.total,
    required this.returned,
    required this.elapsedMs,
    required this.hasSearched,
    required this.searching,
    this.imageProviderFactory = exampleNetworkImageProvider,
    super.key,
  });

  final List<ExampleSearchImage> images;
  final int total;
  final int returned;
  final double elapsedMs;
  final bool hasSearched;
  final bool searching;
  final ExampleImageProviderFactory imageProviderFactory;

  @override
  Widget build(BuildContext context) {
    if (searching) {
      return const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text('Searching and resolving images...'),
      );
    }
    if (!hasSearched) return const SizedBox.shrink();
    final elapsed = elapsedMs > 0 ? ' • ${elapsedMs.round()} ms' : '';
    final returnedText = returned < total ? ' ($returned returned)' : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 8),
          child: Text(
            'Showing ${images.length} images from $total matches'
            '$returnedText$elapsed',
            key: const Key('search-summary'),
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        if (total == 0)
          const Text('No matching results.')
        else if (images.isEmpty)
          const Text('No image-backed matches were found.')
        else
          GridView.builder(
            key: const Key('search-image-grid'),
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 300,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 0.58,
            ),
            itemCount: images.length,
            itemBuilder: (BuildContext context, int index) =>
                ExampleSearchImageCard(
                  image: images[index],
                  imageProviderFactory: imageProviderFactory,
                ),
          ),
      ],
    );
  }
}

class ExampleSearchImageCard extends StatelessWidget {
  const ExampleSearchImageCard({
    required this.image,
    this.imageProviderFactory = exampleNetworkImageProvider,
    super.key,
  });

  final ExampleSearchImage image;
  final ExampleImageProviderFactory imageProviderFactory;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final meta = <String>[
      if (image.stream.isNotEmpty) image.stream,
      if (image.timestamp.isNotEmpty) image.timestamp,
      if (image.score.isNotEmpty) image.score,
    ].join(' • ');
    return Card(
      key: Key('search-image-${image.id}'),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AspectRatio(
            aspectRatio: 1,
            child: Image(
              image: imageProviderFactory(image.url),
              fit: BoxFit.cover,
              semanticLabel: 'Search result image: ${image.title}',
              loadingBuilder:
                  (
                    BuildContext context,
                    Widget child,
                    ImageChunkEvent? progress,
                  ) => progress == null
                  ? child
                  : ColoredBox(
                      color: colors.surfaceContainerHighest,
                      child: const Center(child: CircularProgressIndicator()),
                    ),
              errorBuilder:
                  (BuildContext context, Object error, StackTrace? stack) =>
                      Semantics(
                        label: 'Image unavailable for ${image.title}',
                        child: ColoredBox(
                          color: colors.errorContainer,
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Icon(
                                  Icons.broken_image_outlined,
                                  color: colors.onErrorContainer,
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Image unavailable',
                                  style: TextStyle(
                                    color: colors.onErrorContainer,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Flexible(
                    flex: 2,
                    child: Text(
                      image.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                  if (image.filename.isNotEmpty &&
                      image.filename != image.title) ...<Widget>[
                    const SizedBox(height: 4),
                    Flexible(
                      child: Text(
                        image.filename,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                  if (meta.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 4),
                    Flexible(
                      child: Text(
                        meta,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

void main() => runApp(const VmodalExampleApp());

class VmodalExampleApp extends StatefulWidget {
  const VmodalExampleApp({super.key});

  @override
  State<VmodalExampleApp> createState() => _VmodalExampleAppState();
}

class _VmodalExampleAppState extends State<VmodalExampleApp> {
  static const _sampleAsset = 'asset/video_10frames.mp4';
  final _key = TextEditingController();
  final _query = TextEditingController(text: 'red');
  final _collection = TextEditingController(text: exampleCollectionName);
  final _stream = TextEditingController(text: exampleStreamName);
  final _path = TextEditingController();
  MutableApiKeyProvider? _keys;
  VmodalClient? _client;
  UploadTask<VideoUploadResponse>? _upload;
  StreamSubscription<UploadProgress>? _progressSub;
  List<ExampleSearchImage> _images = <ExampleSearchImage>[];
  String _jobId = '';
  String _indexStatus = 'not started';
  String _status =
      'Enter a runtime API key supplied by your authenticated app.';
  int _progress = 0;
  int _searchGeneration = 0;
  int _searchTotal = 0;
  int _searchReturned = 0;
  double _searchElapsedMs = 0;
  bool _busy = false;
  bool _searching = false;
  bool _hasSearched = false;
  bool _collectionsLoaded = false;
  List<String> _collections = <String>[];

  @override
  void initState() {
    super.initState();
    unawaited(_prepareSample());
  }

  Future<void> _prepareSample() async {
    final data = await rootBundle.load(_sampleAsset);
    final file = File('${Directory.systemTemp.path}/video_10frames.mp4');
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    await file.writeAsBytes(bytes, flush: true);
    _safeState(() {
      _path.text = file.path;
      _status = 'Bundled 10-frame sample video is ready.';
    });
  }

  Future<void> _connect() async {
    final value = _key.text.trim();
    if (value.isEmpty) {
      _safeState(() => _status = 'A runtime API key is required.');
      return;
    }
    _safeState(_clearSearchState);
    _keys?.clear();
    await _client?.close();
    final keys = MutableApiKeyProvider(value);
    final client = VmodalClient(config: SdkConfig(apiKeyProvider: keys));
    _keys = keys;
    _client = client;
    _safeState(() {
      _clearSearchState();
      _key.clear();
      _collectionsLoaded = false;
      _collections = <String>[];
      _status = 'Client configured. Resolve identity to load its collections.';
    });
  }

  Future<void> _identity() async {
    final client = _client;
    if (client == null) return _needClient();
    await _run(() async {
      final me = await client.auth.me();
      final groups = await client.collections.listGroups(mode: 'vid_file');
      final names = exampleCollectionNames(groups);
      _setCollections(
        names,
        names.isEmpty
            ? 'Authenticated user type: ${me.type}. No existing video '
                  'collections were found; upload to create one.'
            : 'Authenticated user type: ${me.type}. Loaded '
                  '${names.length} video collection(s).',
        selectFirst: true,
      );
    });
  }

  Future<void> _loadCollections() async {
    final client = _client;
    if (client == null) return _needClient();
    await _run(() async {
      final groups = await client.collections.listGroups(mode: 'vid_file');
      final names = exampleCollectionNames(groups);
      _setCollections(
        names,
        names.isEmpty
            ? 'No existing video collections are available for this API key.'
            : 'Loaded ${names.length} video collection(s).',
      );
    });
  }

  Future<void> _pickVideo() async {
    XFile? picked;
    try {
      picked = await openFile(
        acceptedTypeGroups: const <XTypeGroup>[
          XTypeGroup(
            label: 'videos',
            mimeTypes: <String>['video/*'],
            uniformTypeIdentifiers: <String>['public.movie'],
          ),
        ],
        confirmButtonText: 'Choose',
      );
    } on PlatformException {
      _safeState(() => _status = 'Unable to open the native video picker.');
      return;
    }
    final selected = picked;
    if (selected == null) {
      _safeState(() => _status = 'Video selection canceled.');
      return;
    }
    final path = selected.path.trim();
    if (path.isEmpty || !File(path).existsSync()) {
      _safeState(() => _status = 'The selected video has no readable path.');
      return;
    }
    _safeState(() {
      _path.text = path;
      _status = 'Selected ${selected.name}. Upload it next.';
    });
  }

  Future<void> _createIndex() async {
    final client = _client;
    if (client == null) return _needClient();
    final collection = _collection.text.trim();
    final stream = _stream.text.trim();
    if (collection.isEmpty || stream.isEmpty) return _needCollection();
    await _run(() async {
      final job = await client.indexes.createIndex(
        exampleIndexRequest(collection, stream),
      );
      _safeState(() {
        _jobId = job.jobId;
        _indexStatus = job.status.isEmpty ? 'queued' : job.status;
        _status = 'Index job created. Refresh until its status is success.';
      });
    });
  }

  Future<void> _refreshIndex() async {
    final client = _client;
    if (client == null) return _needClient();
    if (_jobId.isEmpty) {
      _safeState(() => _status = 'Create an index job first.');
      return;
    }
    await _run(() async {
      final job = await client.indexes.indexStatus(_jobId);
      _safeState(() {
        _indexStatus = job.status.isEmpty ? 'unknown' : job.status;
        _status = exampleIndexDone(_indexStatus)
            ? 'Index is ready. Search the collection next.'
            : 'Index status refreshed: $_indexStatus.';
      });
    });
  }

  Future<void> _search() async {
    final client = _client;
    if (client == null) return _needClient();
    final query = _query.text.trim();
    final collection = _collection.text.trim();
    final stream = _stream.text.trim();
    _safeState(() {
      _clearSearchState();
      _searching = true;
      _status = 'Searching and resolving images...';
    });
    final generation = _searchGeneration;
    await _run(() async {
      try {
        final groups = await client.collections.listGroups(mode: 'vid_file');
        if (!_currentSearch(generation, query, collection, stream)) return;
        final names = exampleCollectionNames(groups);
        _setCollections(names, '', selectFirst: false);
        if (collection.isEmpty || stream.isEmpty) {
          _safeState(() {
            _searching = false;
            _status = 'Collection and stream are required.';
          });
          return;
        }
        if (!names.contains(collection)) {
          _safeState(() {
            _searching = false;
            _status =
                'Collection $collection is not available for this '
                'API key. Choose a loaded collection or upload it first.';
          });
          return;
        }
        final version = groups
            .findGroup(collection, mode: 'vid_file')
            ?.latestLancedbVersion;
        if (version == null) {
          _safeState(() {
            _searching = false;
            _status =
                'Collection $collection has no advertised LanceDB index '
                'version. Create or finish its image index before searching.';
          });
          return;
        }
        late SearchResponse result;
        try {
          result = await client.searches.searchVideo(
            exampleSearchRequest(query, collection, stream, version),
          );
        } on ApiException catch (error) {
          if (error.statusCode != 404) rethrow;
          if (_currentSearch(generation, query, collection, stream)) {
            _safeState(() {
              _clearSearchState();
              _status = exampleSearchNotFound(error, collection);
            });
          }
          return;
        }
        if (!_currentSearch(generation, query, collection, stream)) return;
        final candidates = exampleSearchCandidates(result, collection, stream);
        var images = <ExampleSearchImage>[];
        if (candidates.isNotEmpty) {
          final urls = await client.images.getUrlBulk(
            candidates
                .map((ExampleSearchCandidate item) => item.record)
                .toList(),
          );
          if (!_currentSearch(generation, query, collection, stream)) return;
          images = exampleSearchImages(candidates, urls);
        }
        _safeState(() {
          _images = images;
          _searchTotal = result.cntTotal;
          _searchReturned = result.cntActual;
          _searchElapsedMs = result.executionTimeMs;
          _hasSearched = true;
          _searching = false;
          _status =
              'Search resolved ${images.length} images from '
              '${result.cntTotal} matches in $collection/$stream.';
        });
      } on SdkException {
        if (_currentSearch(generation, query, collection, stream)) {
          _safeState(_clearSearchState);
        }
        rethrow;
      }
    });
  }

  Future<void> _startUpload() async {
    final client = _client;
    if (client == null) return _needClient();
    final collection = _collection.text.trim();
    final stream = _stream.text.trim();
    if (collection.isEmpty || stream.isEmpty) return _needCollection();
    final file = File(_path.text.trim());
    if (!file.existsSync()) {
      _safeState(() => _status = 'Select an app-accessible file first.');
      return;
    }
    final task = client.collections.videoUpload(
      UploadSource.fromFile(file),
      collectionName: collection,
      subCollectionName: stream,
    );
    _upload = task;
    await _progressSub?.cancel();
    _progressSub = task.progress.listen((UploadProgress value) {
      _safeState(() => _progress = value.percent);
    });
    _safeState(() {
      _clearSearchState();
      _busy = true;
      _progress = 0;
      _status = 'Uploading with signed single upload...';
    });
    try {
      final result = await task.result;
      _safeState(() {
        _progress = 100;
        _jobId = '';
        _indexStatus = 'not started';
        _clearSearchState();
        _status = 'Upload complete: ${result.fileName}. Create its index next.';
      });
    } on OperationCanceled {
      _safeState(() => _status = 'Upload canceled.');
    } on SdkException catch (error) {
      _safeState(() => _status = error.toString());
    } finally {
      _safeState(() => _busy = false);
    }
  }

  void _cancelUpload() => _upload?.cancel();

  Future<void> _run(Future<void> Function() action) async {
    _safeState(() => _busy = true);
    try {
      await action();
    } on SdkException catch (error) {
      _safeState(() => _status = error.toString());
    } finally {
      _safeState(() => _busy = false);
    }
  }

  void _needClient() {
    _safeState(() => _status = 'Configure the client first.');
  }

  void _needCollection() {
    _safeState(() => _status = 'Collection and stream are required.');
  }

  void _setCollections(
    List<String> names,
    String status, {
    bool selectFirst = false,
  }) {
    final current = _collection.text.trim();
    final selected = selectFirst && names.isNotEmpty && !names.contains(current)
        ? names.first
        : current;
    _safeState(() {
      _collections = names;
      _collectionsLoaded = true;
      if (selected != current) {
        _collection.text = selected;
        _jobId = '';
        _indexStatus = 'not started';
        _clearSearchState();
      }
      if (status.isNotEmpty) _status = status;
    });
  }

  void _scopeChanged(String _) {
    if (_jobId.isEmpty && _images.isEmpty && !_hasSearched && !_searching) {
      return;
    }
    _safeState(() {
      _jobId = '';
      _indexStatus = 'not started';
      _clearSearchState();
      _status = 'Collection changed. Upload or index this collection next.';
    });
  }

  void _searchChanged(String _) {
    if (_images.isEmpty && !_hasSearched && !_searching) return;
    _safeState(() {
      _clearSearchState();
      _status = 'Search scope changed. Run the search again.';
    });
  }

  bool _currentSearch(
    int generation,
    String query,
    String collection,
    String stream,
  ) =>
      mounted &&
      generation == _searchGeneration &&
      query == _query.text.trim() &&
      collection == _collection.text.trim() &&
      stream == _stream.text.trim();

  void _clearSearchState() {
    _searchGeneration++;
    _images = <ExampleSearchImage>[];
    _searchTotal = 0;
    _searchReturned = 0;
    _searchElapsedMs = 0;
    _hasSearched = false;
    _searching = false;
  }

  void _safeState(VoidCallback change) {
    if (mounted) setState(change);
  }

  @override
  void dispose() {
    _searchGeneration++;
    _upload?.cancel();
    unawaited(_progressSub?.cancel());
    _keys?.clear();
    unawaited(_client?.close());
    _key.dispose();
    _query.dispose();
    _collection.dispose();
    _stream.dispose();
    _path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'VModal SDK Example',
    theme: ThemeData(colorSchemeSeed: Colors.indigo),
    home: Scaffold(
      appBar: AppBar(title: const Text('VModal Flutter SDK')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          TextField(
            controller: _key,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Runtime API key',
              helperText: 'Injected by the parent app; never committed.',
            ),
          ),
          FilledButton(
            onPressed: _busy ? null : _connect,
            child: const Text('Configure client'),
          ),
          const Divider(),
          FilledButton(
            onPressed: _busy ? null : _identity,
            child: const Text('Resolve auth.me'),
          ),
          OutlinedButton(
            onPressed: _busy ? null : _loadCollections,
            child: const Text('Refresh collections'),
          ),
          TextField(
            controller: _collection,
            onChanged: _scopeChanged,
            decoration: const InputDecoration(
              labelText: 'Collection',
              helperText: 'Must exist for the current API key before search.',
            ),
          ),
          if (_collectionsLoaded)
            Text(
              _collections.isEmpty
                  ? 'Available collections: none'
                  : 'Available collections: ${_collections.join(', ')}',
              key: const Key('available-collections'),
            ),
          TextField(
            controller: _stream,
            onChanged: _scopeChanged,
            decoration: const InputDecoration(labelText: 'Stream'),
          ),
          const Divider(),
          TextField(
            controller: _path,
            decoration: const InputDecoration(
              labelText: 'App-accessible file path',
              helperText: 'The bundled 10-frame sample is preloaded.',
            ),
          ),
          OutlinedButton.icon(
            onPressed: _busy ? null : _pickVideo,
            icon: const Icon(Icons.video_file),
            label: const Text('Choose video'),
          ),
          LinearProgressIndicator(value: _progress / 100),
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton(
                  onPressed: _busy ? null : _startUpload,
                  child: const Text('Upload'),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _cancelUpload,
                child: const Text('Cancel'),
              ),
            ],
          ),
          const Divider(),
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton(
                  onPressed: _busy ? null : _createIndex,
                  child: const Text('Create index'),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _busy ? null : _refreshIndex,
                child: const Text('Refresh status'),
              ),
            ],
          ),
          Text(
            'Index: $_indexStatus${_jobId.isEmpty ? '' : ' ($_jobId)'}',
            key: const Key('index-status'),
          ),
          const Divider(),
          TextField(
            controller: _query,
            onChanged: _searchChanged,
            textInputAction: TextInputAction.search,
            onSubmitted: _busy ? null : (_) => _search(),
            decoration: const InputDecoration(labelText: 'Search query'),
          ),
          FilledButton(
            onPressed: _busy ? null : _search,
            child: const Text('Search'),
          ),
          ExampleSearchResults(
            images: _images,
            total: _searchTotal,
            returned: _searchReturned,
            elapsedMs: _searchElapsedMs,
            hasSearched: _hasSearched,
            searching: _searching,
          ),
          const SizedBox(height: 16),
          Text(_status, key: const Key('status')),
        ],
      ),
    ),
  );
}
