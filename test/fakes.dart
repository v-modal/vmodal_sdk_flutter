import 'dart:async';
import 'dart:typed_data';

import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

class FakeTransport implements VmodalTransport {
  final List<VmodalRequest> requests = <VmodalRequest>[];
  final List<Object> queued = <Object>[];
  bool closed = false;

  void addJson(
    Map<String, Object?> value, {
    int status = 200,
    Map<String, String> headers = const <String, String>{
      'content-type': 'application/json',
    },
  }) {
    final bytes = Uint8List.fromList(
      value.isEmpty
          ? <int>[123, 125]
          : Uint8List.fromList(
              // Keep fake serialization independent from SDK internals.
              _jsonBytes(value),
            ),
    );
    queued.add(
      VmodalResponse(
        statusCode: status,
        headers: headers,
        contentLength: bytes.length,
        body: Stream<List<int>>.value(bytes),
      ),
    );
  }

  void addResponse(VmodalResponse response) => queued.add(response);
  void addError(Object error) => queued.add(error);

  @override
  Future<VmodalResponse> send(VmodalRequest request) async {
    requests.add(request);
    if (queued.isEmpty) throw StateError('fake response queue is empty');
    final value = queued.removeAt(0);
    if (value is VmodalResponse) return value;
    throw value;
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

class HandlerTransport implements VmodalTransport {
  HandlerTransport(this.handler);

  final Future<VmodalResponse> Function(VmodalRequest request) handler;
  final List<VmodalRequest> requests = <VmodalRequest>[];

  @override
  Future<VmodalResponse> send(VmodalRequest request) {
    requests.add(request);
    return handler(request);
  }

  @override
  Future<void> close() async {}
}

class CountingKeyProvider implements ApiKeyProvider {
  CountingKeyProvider(this.value);

  String value;
  int reads = 0;

  @override
  String current() {
    reads++;
    return value;
  }
}

class SignedCall {
  SignedCall({
    required this.url,
    required this.method,
    required this.headers,
    required this.offset,
    required this.length,
  });

  final Uri url;
  final String method;
  final Map<String, String> headers;
  final int offset;
  final int length;
}

class FakeSignedUploadTransport implements SignedUploadTransport {
  final List<SignedCall> calls = <SignedCall>[];
  final List<Object> queued = <Object>[];
  int active = 0;
  int maxActive = 0;
  bool closed = false;

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
    final wanted = length ?? source.contentLength - offset;
    calls.add(
      SignedCall(
        url: url,
        method: method,
        headers: Map<String, String>.from(headers),
        offset: offset,
        length: wanted,
      ),
    );
    active++;
    if (active > maxActive) maxActive = active;
    final value = queued.isEmpty
        ? const SignedUploadResult(statusCode: 200, etag: 'etag')
        : queued.removeAt(0);
    try {
      var sent = 0;
      await for (final chunk in source.open(offset: offset, length: wanted)) {
        cancellation.throwIfCanceled();
        sent += chunk.length;
        onProgress?.call(UploadProgress(sent, wanted));
      }
      if (value is SignedUploadResult) return value;
      throw value;
    } finally {
      active--;
    }
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

VmodalResponse jsonResponse(
  String json, {
  int status = 200,
  int? declaredLength,
  List<int>? chunks,
}) {
  final bytes = Uint8List.fromList(json.codeUnits);
  final sizes = chunks ?? <int>[bytes.length];
  Stream<List<int>> body() async* {
    var offset = 0;
    for (final size in sizes) {
      if (offset >= bytes.length) break;
      final end = (offset + size).clamp(0, bytes.length);
      yield bytes.sublist(offset, end);
      offset = end;
    }
    if (offset < bytes.length) yield bytes.sublist(offset);
  }

  return VmodalResponse(
    statusCode: status,
    headers: const <String, String>{'content-type': 'application/json'},
    contentLength: declaredLength ?? bytes.length,
    body: body(),
  );
}

List<int> _jsonBytes(Map<String, Object?> value) {
  String string(Object? item) {
    if (item == null) return 'null';
    if (item is bool || item is num) return '$item';
    if (item is String) {
      return '"${item.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';
    }
    if (item is List) return '[${item.map(string).join(',')}]';
    if (item is Map) {
      return '{${item.entries.map((MapEntry<Object?, Object?> row) => '${string('${row.key}')}:${string(row.value)}').join(',')}}';
    }
    return string('$item');
  }

  return string(value).codeUnits;
}
