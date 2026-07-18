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
        .take(5)
        .toList();

String exampleResultTitle(Map<String, Object?> row) {
  for (final key in <String>[
    'effective_title',
    'title',
    'item_id',
    'text_agg_tok',
  ]) {
    final value = '${row[key] ?? ''}'.trim();
    if (value.isNotEmpty) return value;
  }
  return 'Untitled result';
}

String exampleResultDetails(Map<String, Object?> row) {
  final values = <String>[];
  final source = '${row['source'] ?? ''}'.trim();
  final timestamp = '${row['ts_unix'] ?? ''}'.trim();
  final score = row['score_ui'];
  if (source.isNotEmpty) values.add(source.toUpperCase());
  if (timestamp.isNotEmpty) values.add('timestamp $timestamp');
  if (score is num) values.add('score ${(score * 100).toStringAsFixed(1)}%');
  return values.isEmpty ? 'Search result' : values.join(' • ');
}

String exampleSearchNotFound(ApiException error, String collectionName) {
  final body = '${error.body}'.toLowerCase();
  if (body.contains('missing lancedb') || body.contains('missing index')) {
    return 'No searchable index exists for $collectionName. '
        'Upload the video and create its index before searching.';
  }
  return 'The configured gateway does not expose the search route.';
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
  List<Map<String, Object?>> _results = <Map<String, Object?>>[];
  String _jobId = '';
  String _indexStatus = 'not started';
  String _status =
      'Enter a runtime API key supplied by your authenticated app.';
  int _progress = 0;
  bool _busy = false;
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
    _keys?.clear();
    await _client?.close();
    final keys = MutableApiKeyProvider(value);
    final client = VmodalClient(config: SdkConfig(apiKeyProvider: keys));
    _keys = keys;
    _client = client;
    _safeState(() {
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
    await _run(() async {
      final groups = await client.collections.listGroups(mode: 'vid_file');
      final names = exampleCollectionNames(groups);
      final collection = _collection.text.trim();
      final stream = _stream.text.trim();
      _setCollections(names, '', selectFirst: false);
      if (collection.isEmpty || stream.isEmpty) {
        _needCollection();
        return;
      }
      if (!names.contains(collection)) {
        _safeState(
          () => _status =
              'Collection $collection is not available for this '
              'API key. Choose a loaded collection or upload it first.',
        );
        return;
      }
      final version = groups
          .findGroup(collection, mode: 'vid_file')
          ?.latestLancedbVersion;
      if (version == null) {
        _safeState(
          () => _status =
              'Collection $collection has no advertised LanceDB index '
              'version. Create or finish its image index before searching.',
        );
        return;
      }
      try {
        final result = await client.searches.searchVideo(
          exampleSearchRequest(_query.text, collection, stream, version),
        );
        _safeState(() {
          _results = exampleSearchRows(result);
          _hasSearched = true;
          _status =
              'Search returned ${result.cntActual} items from $collection/$stream.';
        });
      } on ApiException catch (error) {
        if (error.statusCode != 404) rethrow;
        _safeState(() => _status = exampleSearchNotFound(error, collection));
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
        _results = <Map<String, Object?>>[];
        _hasSearched = false;
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
        _results = <Map<String, Object?>>[];
        _hasSearched = false;
      }
      if (status.isNotEmpty) _status = status;
    });
  }

  void _scopeChanged(String _) {
    if (_jobId.isEmpty && _results.isEmpty) return;
    _safeState(() {
      _jobId = '';
      _indexStatus = 'not started';
      _results = <Map<String, Object?>>[];
      _hasSearched = false;
      _status = 'Collection changed. Upload or index this collection next.';
    });
  }

  void _safeState(VoidCallback change) {
    if (mounted) setState(change);
  }

  @override
  void dispose() {
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
            decoration: const InputDecoration(labelText: 'Search query'),
          ),
          FilledButton(
            onPressed: _busy ? null : _search,
            child: const Text('Search'),
          ),
          if (_hasSearched && _results.isEmpty)
            const Text('No matching results.'),
          for (final row in _results)
            Card(
              child: ListTile(
                title: Text(exampleResultTitle(row)),
                subtitle: Text(exampleResultDetails(row)),
              ),
            ),
          const SizedBox(height: 16),
          Text(_status, key: const Key('status')),
        ],
      ),
    ),
  );
}
