import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

void main() => runApp(const VmodalExampleApp());

class VmodalExampleApp extends StatefulWidget {
  const VmodalExampleApp({super.key});

  @override
  State<VmodalExampleApp> createState() => _VmodalExampleAppState();
}

class _VmodalExampleAppState extends State<VmodalExampleApp> {
  final _key = TextEditingController();
  final _query = TextEditingController(text: 'red bicycle');
  final _path = TextEditingController();
  MutableApiKeyProvider? _keys;
  VmodalClient? _client;
  UploadTask<VideoUploadResponse>? _upload;
  StreamSubscription<UploadProgress>? _progressSub;
  String _status =
      'Enter a runtime API key supplied by your authenticated app.';
  int _progress = 0;
  bool _busy = false;

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
      _status = 'Client configured. Resolve identity or search next.';
    });
  }

  Future<void> _identity() async {
    final client = _client;
    if (client == null) return _needClient();
    await _run(() async {
      final me = await client.auth.me();
      _safeState(() => _status = 'Authenticated user type: ${me.type}');
    });
  }

  Future<void> _search() async {
    final client = _client;
    if (client == null) return _needClient();
    await _run(() async {
      final result = await client.searches.searchVideo(
        SearchRequest(queryText: _query.text.trim()),
      );
      _safeState(() => _status = 'Search returned ${result.cntActual} items.');
    });
  }

  Future<void> _startUpload() async {
    final client = _client;
    if (client == null) return _needClient();
    final file = File(_path.text.trim());
    if (!file.existsSync()) {
      _safeState(() => _status = 'Select an app-accessible file first.');
      return;
    }
    final task = client.collections.videoUpload(
      UploadSource.fromFile(file),
      collectionName: 'flutter_example',
      subCollectionName: 'astream',
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
        _status = 'Upload complete: ${result.fileName}';
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
          TextField(
            controller: _query,
            decoration: const InputDecoration(labelText: 'Search query'),
          ),
          FilledButton(
            onPressed: _busy ? null : _search,
            child: const Text('Search'),
          ),
          const Divider(),
          TextField(
            controller: _path,
            decoration: const InputDecoration(
              labelText: 'App-accessible file path',
              helperText: 'A picker adapter belongs to the parent app.',
            ),
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
          const SizedBox(height: 16),
          Text(_status, key: const Key('status')),
        ],
      ),
    ),
  );
}
