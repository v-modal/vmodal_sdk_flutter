import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import 'config.dart';
import 'errors.dart';
import 'utils.dart';

enum VmodalResponseMode { json, bytes }

class CancellationToken {
  final Completer<void> _abort = Completer<void>();

  bool get isCanceled => _abort.isCompleted;
  Future<void> get whenCanceled => _abort.future;

  void cancel() {
    if (!_abort.isCompleted) _abort.complete();
  }

  void throwIfCanceled() {
    if (isCanceled) throw const OperationCanceled();
  }
}

class VmodalFilePart {
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

  final String fieldName;
  final String fileName;
  final int contentLength;
  final String contentType;
  final Stream<List<int>> Function() _opener;

  Stream<List<int>> open() => _opener();
}

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

class VmodalRequest {
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

class VmodalResponse {
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

abstract interface class VmodalTransport {
  Future<VmodalResponse> send(VmodalRequest request);

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
