import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'errors.dart';
import 'transport.dart';
import 'utils.dart';

/// Replayable media source with a known byte length.
///
/// Multipart resume requires stable [sourceId] and [versionTag] values and a
/// source that can reopen the requested ranges.
class UploadSource {
  /// Creates a source from stream factories.
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

  /// Creates a range-capable source from a local [file].
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

  /// Name associated with the uploaded object.
  final String fileName;

  /// Exact source length in bytes.
  final int contentLength;

  /// Media type sent with the upload.
  final String contentType;

  /// Stable local identity used by resume checkpoints.
  final String sourceId;

  /// Version marker used to reject stale resume checkpoints.
  final String versionTag;
  final Stream<List<int>> Function() _opener;
  final Stream<List<int>> Function(int offset)? _rangeOpener;

  /// Opens a validated source range.
  ///
  /// Throws [ValidationException] for an invalid range and
  /// [TransportException] if the source ends early.
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

/// Monotonic upload progress snapshot.
class UploadProgress {
  /// Creates a snapshot from uploaded and total byte counts.
  const UploadProgress(this.uploadedBytes, this.totalBytes);

  /// Bytes uploaded so far.
  final int uploadedBytes;

  /// Total bytes expected for the task.
  final int totalBytes;

  /// Integer percentage clamped to the inclusive range 0–100.
  int get percent =>
      totalBytes <= 0 ? 0 : ((uploadedBytes * 100) ~/ totalBytes).clamp(0, 100);
}

/// Lifecycle state of an [UploadTask].
enum UploadTaskState { running, succeeded, failed, canceled }

/// Work function used to create an [UploadTask].
typedef UploadRunner<T> =
    Future<T> Function(
      CancellationToken cancellation,
      void Function(UploadProgress progress) emit,
    );

/// Running upload with result, progress, state, and cooperative cancellation.
class UploadTask<T> {
  /// Starts [runner] immediately.
  UploadTask.start(UploadRunner<T> runner) {
    unawaited(_start(runner));
  }

  final Completer<T> _result = Completer<T>();
  final StreamController<UploadProgress> _progress =
      StreamController<UploadProgress>.broadcast(sync: true);

  /// Token passed to the running upload operation.
  final CancellationToken cancellation = CancellationToken();
  UploadTaskState _state = UploadTaskState.running;
  int _lastBytes = 0;

  /// Completes with the typed upload response or the task error.
  Future<T> get result => _result.future;

  /// Broadcast stream of monotonic progress updates.
  Stream<UploadProgress> get progress => _progress.stream;

  /// Current task state.
  UploadTaskState get state => _state;

  /// Whether cancellation won the terminal-state race.
  bool get isCanceled => _state == UploadTaskState.canceled;

  /// Requests cancellation and completes [result] with [OperationCanceled].
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

/// Integrity and response metadata from a completed byte upload.
class SignedUploadResult {
  /// Creates an immutable result.
  const SignedUploadResult({
    required this.statusCode,
    this.etag = '',
    this.localMd5 = '',
  });

  final int statusCode;
  final String etag;
  final String localMd5;
}

/// Transport failure that retains partial-upload integrity information.
class SignedUploadFailure extends TransportException {
  /// Creates a failure with the number of bytes already sent.
  const SignedUploadFailure({
    required this.sentBytes,
    required this.localMd5,
    Object? cause,
  }) : super(cause);

  final int sentBytes;
  final String localMd5;
}

/// Pluggable transport for temporary signed media uploads.
abstract interface class SignedUploadTransport {
  /// Uploads all or part of [source] and reports optional progress.
  ///
  /// Implementations must honor [cancellation] and must not attach app
  /// credentials to the temporary upload destination.
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

  /// Releases transport resources. Implementations should be idempotent.
  Future<void> close();
}

/// `dart:io` implementation of [SignedUploadTransport].
class IoSignedUploadTransport implements SignedUploadTransport {
  /// Creates a transport with [defaultTimeout].
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

/// Stores resumable multipart-upload checkpoints.
abstract interface class UploadSessionStore {
  /// Loads a checkpoint or returns `null` when absent.
  Future<Map<String, Object?>?> load(String key);

  /// Persists a checkpoint under [key].
  Future<void> save(String key, Map<String, Object?> value);

  /// Removes the checkpoint under [key].
  Future<void> remove(String key);
}

/// Process-local upload checkpoint store.
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

/// File-backed upload checkpoint store with bounded, atomic JSON writes.
class FileUploadSessionStore implements UploadSessionStore {
  /// Creates a store in [directory], creating it when necessary.
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

/// Shared built-in upload checkpoint stores.
abstract final class UploadSessionStores {
  /// Process-local store used when no explicit store is configured.
  static final UploadSessionStore memory = MemoryUploadSessionStore();
}

/// Calculates the MD5 digest for a validated range of [source].
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
