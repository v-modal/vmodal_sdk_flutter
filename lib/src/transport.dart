import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import 'config.dart';
import 'errors.dart';
import 'utils.dart';

/// Expected response representation for a [VmodalRequest].
enum VmodalResponseMode {
  /// Decode a bounded structured response.
  json,

  /// Return bounded binary bytes.
  bytes,
}

/// Cooperative cancellation signal shared with an in-flight operation.
class CancellationToken {
  final Completer<void> _abort = Completer<void>();

  /// Whether [cancel] has been called.
  bool get isCanceled => _abort.isCompleted;

  /// Completes once cancellation is requested.
  Future<void> get whenCanceled => _abort.future;

  /// Requests cancellation. Repeated calls have no effect.
  void cancel() {
    if (!_abort.isCompleted) _abort.complete();
  }

  /// Throws [OperationCanceled] after cancellation has been requested.
  void throwIfCanceled() {
    if (isCanceled) throw const OperationCanceled();
  }
}

/// Replayable file part used by multipart SDK operations.
class VmodalFilePart {
  /// Creates a part backed by [opener].
  ///
  /// Names, content type, and non-negative [contentLength] are validated.
  VmodalFilePart({
    required this.fieldName,
    required this.fileName,
    required this.contentLength,
    required Stream<List<int>> Function() opener,
    this.contentType = 'application/octet-stream',
  }) : _opener = opener {
    strMultipartValue('field name', fieldName, 128);
    strMultipartValue('file name', fileName, 1024);
    strMultipartValue('content type', contentType, 255);
    if (contentLength < 0) {
      throw const ValidationException('content_length must not be negative');
    }
  }

  /// Creates a replayable part from an in-memory byte list.
  factory VmodalFilePart.bytes({
    required String fieldName,
    required String fileName,
    required List<int> bytes,
    String contentType = 'application/octet-stream',
  }) {
    final stable = Uint8List.fromList(bytes);
    return VmodalFilePart(
      fieldName: fieldName,
      fileName: fileName,
      contentLength: stable.length,
      contentType: contentType,
      opener: () => Stream<List<int>>.value(stable),
    );
  }

  /// Form field associated with the file.
  final String fieldName;

  /// File name reported to the service.
  final String fileName;

  /// Exact number of bytes produced by [open].
  final int contentLength;

  /// Media type for the part.
  final String contentType;
  final Stream<List<int>> Function() _opener;

  /// Opens a fresh byte stream for this part.
  Stream<List<int>> open() => _opener();
}

/// Creates a replayable part from [file].
///
/// Throws [ValidationException] when the file does not exist.
VmodalFilePart filePart(String fieldName, File file, {String? contentType}) {
  if (!file.existsSync()) {
    throw const ValidationException('file must exist');
  }
  return VmodalFilePart(
    fieldName: fieldName,
    fileName: file.uri.pathSegments.last,
    contentLength: file.lengthSync(),
    contentType: contentType ?? guessContentType(file.path),
    opener: file.openRead,
  );
}

/// Creates a replayable part from a caller-provided stream factory.
VmodalFilePart streamPart({
  required String fieldName,
  required String fileName,
  required int contentLength,
  required Stream<List<int>> Function() opener,
  String? contentType,
}) => VmodalFilePart(
  fieldName: fieldName,
  fileName: fileName,
  contentLength: contentLength,
  contentType: contentType ?? guessContentType(fileName),
  opener: opener,
);

/// Infers a conservative media type from [name].
String guessContentType(String name) {
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  return switch (ext) {
    'json' || 'jsonl' => 'application/json',
    'txt' => 'text/plain',
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'mp4' => 'video/mp4',
    _ => 'application/octet-stream',
  };
}

/// Transport-neutral request supplied to [VmodalTransport].
///
/// Applications normally use resource methods instead of constructing this
/// type. Custom transport implementations can inspect its immutable fields.
class VmodalRequest {
  /// Creates a request, assigning a fresh cancellation token when omitted.
  VmodalRequest({
    required this.method,
    required this.uri,
    this.headers = const <String, String>{},
    this.jsonBody,
    this.formFields = const <String, Object?>{},
    this.files = const <VmodalFilePart>[],
    this.responseMode = VmodalResponseMode.json,
    CancellationToken? cancellation,
  }) : cancellation = cancellation ?? CancellationToken();

  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final Object? jsonBody;
  final Map<String, Object?> formFields;
  final List<VmodalFilePart> files;
  final VmodalResponseMode responseMode;
  final CancellationToken cancellation;

  @override
  String toString() =>
      'VmodalRequest('
      'method=$method, '
      'pathType=${uri.hasScheme ? 'absolute' : 'relative'}, '
      'queryParameterKeys=${uri.queryParametersAll.keys}, '
      'headerNames=${headers.keys}, '
      'hasJsonBody=${jsonBody != null}, '
      'formFieldNames=${formFields.keys}, '
      'fileCount=${files.length})';
}

/// Streaming transport response consumed by the SDK.
class VmodalResponse {
  /// Creates a response with immutable status and metadata.
  const VmodalResponse({
    required this.statusCode,
    required this.body,
    this.headers = const <String, String>{},
    this.contentLength = -1,
  });

  final int statusCode;
  final Stream<List<int>> body;
  final Map<String, String> headers;
  final int contentLength;

  @override
  String toString() =>
      'VmodalResponse('
      'statusCode=$statusCode, headerNames=${headers.keys}, '
      'contentLength=$contentLength)';
}

/// Pluggable request transport owned by [VmodalClient].
abstract interface class VmodalTransport {
  /// Sends [request] and returns its streaming response.
  Future<VmodalResponse> send(VmodalRequest request);

  /// Releases transport resources. Implementations should be idempotent.
  Future<void> close();
}

class HttpVmodalTransport implements VmodalTransport {
  HttpVmodalTransport(SdkConfig config, {http.Client? client})
    : _config = config,
      _client = client ?? http.Client();

  final SdkConfig _config;
  final http.Client _client;
  bool _closed = false;

  @override
  Future<VmodalResponse> send(VmodalRequest request) async {
    if (_closed) throw const TransportException();
    request.cancellation.throwIfCanceled();
    final http.BaseRequest wire = request.files.isNotEmpty
        ? _multipart(request)
        : _ordinary(request);
    wire.followRedirects = false;
    wire.headers.addAll(request.headers);
    wire.headers.putIfAbsent('Accept', () => 'application/json');
    try {
      final response = await _client.send(wire).timeout(_config.timeout);
      final headers = <String, String>{};
      response.headers.forEach((String key, String value) {
        headers[key] = value;
      });
      return VmodalResponse(
        statusCode: response.statusCode,
        body: response.stream,
        headers: headers,
        contentLength: response.contentLength ?? -1,
      );
    } on http.RequestAbortedException {
      throw const OperationCanceled();
    } on TimeoutException catch (error) {
      request.cancellation.cancel();
      throw TransportException(error);
    } on SocketException catch (error) {
      throw TransportException(error);
    } on http.ClientException catch (error) {
      throw TransportException(error);
    }
  }

  http.BaseRequest _ordinary(VmodalRequest request) {
    final wire = http.AbortableRequest(
      request.method,
      request.uri,
      abortTrigger: request.cancellation.whenCanceled,
    );
    if (request.jsonBody != null) {
      wire.headers['Content-Type'] = 'application/json';
      wire.bodyBytes = utf8.encode(jsonEncode(request.jsonBody));
    } else if (request.formFields.isNotEmpty) {
      wire.headers['Content-Type'] = 'application/x-www-form-urlencoded';
      wire.bodyFields = _formStrings(request.formFields);
    }
    return wire;
  }

  http.BaseRequest _multipart(VmodalRequest request) {
    final wire = http.AbortableMultipartRequest(
      request.method,
      request.uri,
      abortTrigger: request.cancellation.whenCanceled,
    );
    request.formFields.forEach((String key, Object? value) {
      strMultipartValue('field name', key, 128);
      if (value == null) return;
      if (value is Iterable) {
        for (final item in value) {
          if (item != null) wire.fields[key] = '$item';
        }
      } else {
        wire.fields[key] = '$value';
      }
    });
    for (final part in request.files) {
      wire.files.add(
        http.MultipartFile(
          part.fieldName,
          http.ByteStream(part.open()),
          part.contentLength,
          filename: part.fileName,
          contentType: MediaType.parse(part.contentType),
        ),
      );
    }
    return wire;
  }

  Map<String, String> _formStrings(Map<String, Object?> values) {
    final out = <String, String>{};
    values.forEach((String key, Object? value) {
      if (value != null) out[key] = '$value';
    });
    return out;
  }

  @override
  Future<void> close() async {
    _closed = true;
    _client.close();
  }
}

Future<Uint8List> readBounded(
  VmodalResponse response,
  int limitBytes, {
  CancellationToken? cancellation,
}) async {
  if (limitBytes <= 0) {
    throw const ValidationException('response limit is invalid');
  }
  if (response.contentLength < -1) {
    throw const MalformedResponse('invalid Content-Length');
  }
  if (response.contentLength > limitBytes) {
    cancellation?.cancel();
    throw ResponseTooLarge(limitBytes, response.contentLength);
  }
  final builder = BytesBuilder(copy: false);
  var total = 0;
  await for (final chunk in response.body) {
    cancellation?.throwIfCanceled();
    if (chunk.length > limitBytes - total) {
      cancellation?.cancel();
      throw ResponseTooLarge(limitBytes, total + chunk.length);
    }
    builder.add(chunk);
    total += chunk.length;
  }
  return builder.takeBytes();
}
