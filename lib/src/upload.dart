import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'errors.dart';
import 'transport.dart';
import 'utils.dart';

class UploadSource {
  UploadSource({
    required this.fileName,
    required this.contentLength,
    required Stream<List<int>> Function() opener,
    this.contentType = 'application/octet-stream',
    String? sourceId,
    this.versionTag = '',
    Stream<List<int>> Function(int offset)? rangeOpener,
  }) : sourceId = sourceId ?? fileName,
       _opener = opener,
       _rangeOpener = rangeOpener {
    strMultipartValue('file name', fileName, 1024);
    strMultipartValue('content type', contentType, 255);
    strMultipartValue('source id', this.sourceId, 4096);
    if (contentLength < 0) {
      throw const ValidationException(
        'content_length must be known for a signed upload',
      );
    }
  }

  factory UploadSource.fromFile(File file, {String? contentType}) {
    if (!file.existsSync()) {
      throw const ValidationException('file must exist');
    }
    final stat = file.statSync();
    final name = file.uri.pathSegments.last;
    return UploadSource(
      fileName: name,
      contentLength: stat.size,
      contentType: contentType ?? guessContentType(name),
      sourceId: file.absolute.path,
      versionTag: '${stat.size}:${stat.modified.millisecondsSinceEpoch}',
      opener: file.openRead,
      rangeOpener: (int offset) => file.openRead(offset),
    );
  }

  final String fileName;
  final int contentLength;
  final String contentType;
  final String sourceId;
  final String versionTag;
  final Stream<List<int>> Function() _opener;
  final Stream<List<int>> Function(int offset)? _rangeOpener;

  Stream<List<int>> open({int offset = 0, int? length}) async* {
    final wanted = length ?? contentLength - offset;
    if (offset < 0 || wanted < 0 || offset + wanted > contentLength) {
      throw const ValidationException('upload source range is invalid');
    }
    final direct = _rangeOpener;
    var skip = direct == null ? offset : 0;
    var left = wanted;
    final stream = direct?.call(offset) ?? _opener();
    await for (final chunk in stream) {
      var start = 0;
      if (skip > 0) {
        if (skip >= chunk.length) {
          skip -= chunk.length;
          continue;
        }
        start = skip;
        skip = 0;
      }
      if (left == 0) break;
      final count = left < chunk.length - start ? left : chunk.length - start;
      if (count > 0) {
        yield Uint8List.fromList(chunk.sublist(start, start + count));
        left -= count;
      }
      if (left == 0) break;
    }
    if (skip != 0 || left != 0) {
      throw const TransportException('upload source ended early');
    }
  }
}

class UploadProgress {
  const UploadProgress(this.uploadedBytes, this.totalBytes);

  final int uploadedBytes;
  final int totalBytes;

  int get percent =>
      totalBytes <= 0 ? 0 : ((uploadedBytes * 100) ~/ totalBytes).clamp(0, 100);
}

enum UploadTaskState { running, succeeded, failed, canceled }

typedef UploadRunner<T> =
    Future<T> Function(
      CancellationToken cancellation,
      void Function(UploadProgress progress) emit,
    );

class UploadTask<T> {
  UploadTask.start(UploadRunner<T> runner) {
    unawaited(_start(runner));
  }

  final Completer<T> _result = Completer<T>();
  final StreamController<UploadProgress> _progress =
      StreamController<UploadProgress>.broadcast(sync: true);
  final CancellationToken cancellation = CancellationToken();
  UploadTaskState _state = UploadTaskState.running;
  int _lastBytes = 0;

  Future<T> get result => _result.future;
  Stream<UploadProgress> get progress => _progress.stream;
  UploadTaskState get state => _state;
  bool get isCanceled => _state == UploadTaskState.canceled;

  void cancel() {
    if (_state != UploadTaskState.running) return;
    _state = UploadTaskState.canceled;
    cancellation.cancel();
    if (!_result.isCompleted) _result.completeError(const OperationCanceled());
    unawaited(_progress.close());
  }

  Future<void> _start(UploadRunner<T> runner) async {
    try {
      final value = await runner(cancellation, _emit);
      if (_state != UploadTaskState.running) return;
      _state = UploadTaskState.succeeded;
      _result.complete(value);
    } on Object catch (error, stack) {
      if (_state != UploadTaskState.running) return;
      _state = error is OperationCanceled
          ? UploadTaskState.canceled
          : UploadTaskState.failed;
      _result.completeError(error, stack);
    } finally {
      if (!_progress.isClosed) await _progress.close();
    }
  }

  void _emit(UploadProgress value) {
    if (_state != UploadTaskState.running) return;
    final safe = value.uploadedBytes.clamp(_lastBytes, value.totalBytes);
    _lastBytes = safe;
    _progress.add(UploadProgress(safe, value.totalBytes));
  }
}

class SignedUploadResult {
  const SignedUploadResult({
    required this.statusCode,
    this.etag = '',
    this.localMd5 = '',
  });

  final int statusCode;
  final String etag;
  final String localMd5;
}

class SignedUploadFailure extends TransportException {
  const SignedUploadFailure({
    required this.sentBytes,
    required this.localMd5,
    Object? cause,
  }) : super(cause);

  final int sentBytes;
  final String localMd5;
}

abstract interface class SignedUploadTransport {
  Future<SignedUploadResult> upload({
    required UploadSource source,
    required Uri url,
    String method = 'PUT',
    int offset = 0,
    int? length,
    Map<String, String> headers = const <String, String>{},
    Duration? timeout,
    required CancellationToken cancellation,
    void Function(UploadProgress progress)? onProgress,
  });

  Future<void> close();
}

class IoSignedUploadTransport implements SignedUploadTransport {
  IoSignedUploadTransport(this.defaultTimeout, {HttpClient? client})
    : _client = client ?? HttpClient();

  final Duration defaultTimeout;
  final HttpClient _client;
  bool _closed = false;

  @override
  Future<SignedUploadResult> upload({
    required UploadSource source,
    required Uri url,
    String method = 'PUT',
    int offset = 0,
    int? length,
    Map<String, String> headers = const <String, String>{},
    Duration? timeout,
    required CancellationToken cancellation,
    void Function(UploadProgress progress)? onProgress,
  }) async {
    if (_closed) throw const TransportException();
    cancellation.throwIfCanceled();
    if (url.scheme != 'https' &&
        !(url.scheme == 'http' && _isLoopback(url.host))) {
      throw const ValidationException('invalid signed upload URL');
    }
    final safeHeaders = _signedHeaders(headers);
    final wanted = length ?? source.contentLength - offset;
    HttpClientRequest? request;
    var sent = 0;
    final digestSink = _DigestSink();
    final digest = md5.startChunkedConversion(digestSink);
    try {
      request = await _client
          .openUrl(method.toUpperCase(), url)
          .timeout(timeout ?? defaultTimeout);
      request.followRedirects = false;
      request.contentLength = wanted;
      request.headers.contentType = ContentType.parse(source.contentType);
      safeHeaders.forEach(request.headers.set);
      unawaited(
        cancellation.whenCanceled.then((_) {
          request?.abort(const OperationCanceled());
        }),
      );
      await for (final chunk in source.open(offset: offset, length: wanted)) {
        cancellation.throwIfCanceled();
        request.add(chunk);
        digest.add(chunk);
        sent += chunk.length;
        onProgress?.call(UploadProgress(sent, wanted));
      }
      digest.close();
      final response = await request.close().timeout(timeout ?? defaultTimeout);
      if (response.statusCode < 200 || response.statusCode > 299) {
        final bytes = await _readIoBounded(response, errorResponseLimitBytes);
        throw ApiException(
          'signed upload failed',
          statusCode: response.statusCode,
          body: utf8.decode(bytes, allowMalformed: true),
        );
      }
      await response.drain<void>();
      return SignedUploadResult(
        statusCode: response.statusCode,
        etag: (response.headers.value('etag') ?? '').replaceAll('"', '').trim(),
        localMd5: digestSink.value?.toString() ?? '',
      );
    } on OperationCanceled {
      rethrow;
    } on ApiException {
      rethrow;
    } on Object catch (error) {
      request?.abort(error);
      try {
        digest.close();
      } on Object {
        // Digest may already be closed after all bytes were sent.
      }
      throw SignedUploadFailure(
        sentBytes: sent,
        localMd5: digestSink.value?.toString() ?? '',
        cause: error,
      );
    }
  }

  Map<String, String> _signedHeaders(Map<String, String> values) {
    const forbidden = <String>{
      'authorization',
      'cookie',
      'origin',
      'referer',
      'x-user-id',
      'x-tenant-id',
      'x-user-email',
    };
    final out = <String, String>{};
    values.forEach((String key, String value) {
      final lower = key.toLowerCase();
      if (forbidden.contains(lower)) {
        throw const ValidationException(
          'signed upload contains forbidden authentication headers',
        );
      }
      final allowed =
          lower == 'content-md5' ||
          lower == 'content-type' ||
          lower == 'content-length' ||
          lower.startsWith('x-amz-') ||
          lower.startsWith('x-goog-');
      if (!allowed) {
        throw const ValidationException('signed upload header is not allowed');
      }
      out[key] = strHeaderValue('signed header', value);
    });
    return out;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _client.close(force: true);
  }
}

abstract interface class UploadSessionStore {
  Future<Map<String, Object?>?> load(String key);
  Future<void> save(String key, Map<String, Object?> value);
  Future<void> remove(String key);
}

class MemoryUploadSessionStore implements UploadSessionStore {
  final Map<String, Map<String, Object?>> _values =
      <String, Map<String, Object?>>{};

  @override
  Future<Map<String, Object?>?> load(String key) async {
    final value = _values[key];
    return value == null ? null : Map<String, Object?>.from(value);
  }

  @override
  Future<void> save(String key, Map<String, Object?> value) async {
    _values[key] = Map<String, Object?>.from(value);
  }

  @override
  Future<void> remove(String key) async {
    _values.remove(key);
  }
}

class FileUploadSessionStore implements UploadSessionStore {
  FileUploadSessionStore(this.directory) {
    if (!directory.existsSync()) directory.createSync(recursive: true);
    if (!directory.statSync().type.toString().contains('directory')) {
      throw const TransportException('upload checkpoint path is invalid');
    }
  }

  final Directory directory;

  @override
  Future<Map<String, Object?>?> load(String key) async {
    final primary = _file(key);
    final backup = File('${primary.path}.bak');
    final source = await primary.exists()
        ? primary
        : await backup.exists()
        ? backup
        : null;
    if (source == null) return null;
    final size = await source.length();
    if (size > checkpointJsonLimitBytes) {
      throw ResponseTooLarge(checkpointJsonLimitBytes, size);
    }
    final bytes = await source.readAsBytes();
    final value = jsonDecodeStrict(bytes);
    if (value is! Map) {
      throw const MalformedResponse('upload checkpoint is invalid');
    }
    return objectMap(value);
  }

  @override
  Future<void> save(String key, Map<String, Object?> value) async {
    final bytes = utf8.encode(jsonEncode(value));
    if (bytes.length > checkpointJsonLimitBytes) {
      throw ResponseTooLarge(checkpointJsonLimitBytes, bytes.length);
    }
    final primary = _file(key);
    final temp = File(
      '${primary.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    final backup = File('${primary.path}.bak');
    await temp.writeAsBytes(bytes, flush: true);
    if (await backup.exists()) await backup.delete();
    if (await primary.exists()) await primary.rename(backup.path);
    try {
      await temp.rename(primary.path);
      if (await backup.exists()) await backup.delete();
    } on Object {
      if (await backup.exists()) await backup.rename(primary.path);
      if (await temp.exists()) await temp.delete();
      rethrow;
    }
  }

  @override
  Future<void> remove(String key) async {
    final primary = _file(key);
    final backup = File('${primary.path}.bak');
    if (await primary.exists()) await primary.delete();
    if (await backup.exists()) await backup.delete();
  }

  File _file(String key) =>
      File('${directory.path}/${sha256.convert(utf8.encode(key))}.json');
}

abstract final class UploadSessionStores {
  static final UploadSessionStore memory = MemoryUploadSessionStore();
}

Future<String> md5Hex(
  UploadSource source, {
  required int offset,
  required int length,
}) async {
  final sink = _DigestSink();
  final input = md5.startChunkedConversion(sink);
  await for (final chunk in source.open(offset: offset, length: length)) {
    input.add(chunk);
  }
  input.close();
  return sink.value?.toString() ?? '';
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}

Future<Uint8List> _readIoBounded(HttpClientResponse response, int limit) async {
  final declared = response.contentLength;
  if (declared > limit) throw ResponseTooLarge(limit, declared);
  final out = BytesBuilder(copy: false);
  var count = 0;
  await for (final chunk in response) {
    if (chunk.length > limit - count) {
      throw ResponseTooLarge(limit, count + chunk.length);
    }
    out.add(chunk);
    count += chunk.length;
  }
  return out.takeBytes();
}

bool _isLoopback(String host) => const <String>{
  'localhost',
  '127.0.0.1',
  '::1',
  '0:0:0:0:0:0:0:1',
}.contains(host.toLowerCase());
