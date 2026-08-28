import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

Future<void> main(List<String> args) async {
  final values = _args(args);
  final sizes = (values['sizes'] ?? '5,64,100')
      .split(',')
      .map(int.parse)
      .toList();
  final delay = Duration(milliseconds: int.parse(values['delay-ms'] ?? '1'));
  final dir = await Directory.systemTemp.createTemp('vmodal-perf-');
  final objects = await _ObjectServer.start(delay);
  final api = _BenchmarkApi(objects);
  final signed = IoSignedUploadTransport(const Duration(minutes: 10));
  final client = VmodalClient(
    config: SdkConfig(
      baseUrl: 'http://127.0.0.1:3099',
      token: 'benchmark-key',
      timeout: const Duration(minutes: 10),
    ),
    transport: api,
    signedUploadTransport: signed,
  );
  try {
    final sources = <UploadSource>[];
    for (var i = 0; i < sizes.length; i++) {
      final file = await _file(dir, 'perf-$i.bin', sizes[i] * 1024 * 1024);
      final source = UploadSource.fromFile(file);
      sources.add(source);
      final task = client.collections.videoUpload(
        source,
        collectionName: 'perf',
        subCollectionName: 'single',
      );
      await _measure('single-${sizes[i]}MiB', task, objects);
    }
    objects.parts.clear();
    final bulk = client.collections.videoUploadBulk(
      sources,
      collectionName: 'perf',
      subCollectionName: 'multipart',
      options: VideoUploadOptions(
        multipart: true,
        partSizeBytes: 5 * 1024 * 1024,
        maxConcurrency: 4,
        sessionStore: MemoryUploadSessionStore(),
      ),
    );
    await _measure('bulk-multipart-${sizes.join('-')}MiB', bulk, objects);
  } finally {
    await client.close();
    await objects.close();
    await dir.delete(recursive: true);
  }
}

Future<void> _measure<T>(
  String name,
  UploadTask<T> task,
  _ObjectServer objects,
) async {
  final startRss = ProcessInfo.currentRss;
  var peakRss = startRss;
  var events = 0;
  final beforeBytes = objects.bytes;
  final beforeRequests = objects.requests;
  final watch = Stopwatch()..start();
  final sampler = Timer.periodic(const Duration(milliseconds: 10), (_) {
    peakRss = max(peakRss, ProcessInfo.currentRss);
  });
  final sub = task.progress.listen((_) => events++);
  await task.result;
  await sub.cancel();
  sampler.cancel();
  watch.stop();
  final bytes = objects.bytes - beforeBytes;
  final seconds = watch.elapsedMicroseconds / Duration.microsecondsPerSecond;
  stdout.writeln(
    jsonEncode(<String, Object?>{
      'name': name,
      'wall_ms': watch.elapsedMilliseconds,
      'mib_per_second': seconds == 0 ? 0 : bytes / 1024 / 1024 / seconds,
      'peak_rss_bytes': peakRss,
      'rss_growth_bytes': max(0, peakRss - startRss),
      'ui_progress_events': events,
      'signed_puts': objects.requests - beforeRequests,
      'signed_bytes': bytes,
      'max_active_signed_puts': objects.maxActive,
    }),
  );
  objects.maxActive = 0;
}

Future<File> _file(Directory dir, String name, int length) async {
  final file = File('${dir.path}/$name');
  final out = await file.open(mode: FileMode.write);
  final chunk = Uint8List(1024 * 1024);
  for (var i = 0; i < chunk.length; i++) {
    chunk[i] = i % 251;
  }
  var left = length;
  while (left > 0) {
    final count = min(left, chunk.length);
    await out.writeFrom(chunk, 0, count);
    left -= count;
  }
  await out.close();
  return file;
}

Map<String, String> _args(List<String> args) {
  final out = <String, String>{};
  for (final arg in args) {
    if (!arg.startsWith('--') || !arg.contains('=')) continue;
    final index = arg.indexOf('=');
    out[arg.substring(2, index)] = arg.substring(index + 1);
  }
  return out;
}

class _ObjectServer {
  _ObjectServer(this.server, this.delay);

  final HttpServer server;
  final Duration delay;
  final Map<String, Map<int, _Part>> parts = <String, Map<int, _Part>>{};
  int bytes = 0;
  int requests = 0;
  int active = 0;
  int maxActive = 0;

  static Future<_ObjectServer> start(Duration delay) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final value = _ObjectServer(server, delay);
    server.listen(value._handle);
    return value;
  }

  Uri url(String name, int number) => Uri.parse(
    'http://127.0.0.1:${server.port}/${Uri.encodeComponent(name)}/$number',
  );

  Future<void> _handle(HttpRequest request) async {
    requests++;
    active++;
    maxActive = max(maxActive, active);
    final name = Uri.decodeComponent(request.uri.pathSegments[0]);
    final number = int.parse(request.uri.pathSegments[1]);
    final sink = _DigestSink();
    final input = md5.startChunkedConversion(sink);
    var size = 0;
    try {
      await for (final chunk in request) {
        input.add(chunk);
        size += chunk.length;
        bytes += chunk.length;
        if (delay > Duration.zero) await Future<void>.delayed(delay);
      }
      input.close();
      final digest = sink.value.toString();
      parts.putIfAbsent(name, () => <int, _Part>{})[number] = _Part(
        size,
        digest,
      );
      request.response.headers.set('etag', digest);
      await request.response.close();
    } finally {
      active--;
    }
  }

  Future<void> close() => server.close(force: true);
}

class _BenchmarkApi implements VmodalTransport {
  _BenchmarkApi(this.objects);

  final _ObjectServer objects;
  final Map<String, String> sessions = <String, String>{};

  @override
  Future<VmodalResponse> send(VmodalRequest request) async {
    final path = request.uri.path;
    if (path.endsWith(Routes.externalUploadGetSignedUrl)) {
      final name = request.uri.queryParameters['filename']!;
      return _json(<String, Object?>{
        'url': '${objects.url(name, 1)}',
        'method': 'PUT',
        'key': name,
      });
    }
    if (path.endsWith(Routes.externalUploadMultipartCreate)) {
      final body = request.jsonBody! as Map<String, Object?>;
      final name = '${body['filename']}';
      final size = body['size_bytes']! as int;
      final partSize = body['part_size_bytes']! as int;
      sessions[name] = name;
      return _json(<String, Object?>{
        'request_id': 'r-$name',
        'upload_id': name,
        'key': name,
        'part_count': 1 + (size - 1) ~/ partSize,
        'part_size_bytes': partSize,
      });
    }
    if (path.endsWith(Routes.externalUploadMultipartStatus)) {
      final name = request.uri.queryParameters['upload_id']!;
      final rows = (objects.parts[name] ?? <int, _Part>{}).entries
          .map(
            (MapEntry<int, _Part> item) => <String, Object?>{
              'part_number': item.key,
              'size_bytes': item.value.size,
              'etag': item.value.md5,
            },
          )
          .toList();
      return _json(<String, Object?>{'status': 'uploading', 'parts': rows});
    }
    if (path.endsWith(Routes.externalUploadMultipartSignParts)) {
      final body = request.jsonBody! as Map<String, Object?>;
      final name = '${body['upload_id']}';
      final numbers = (body['part_numbers']! as List).cast<int>();
      return _json(<String, Object?>{
        'parts': numbers
            .map(
              (int number) => <String, Object?>{
                'part_number': number,
                'url': '${objects.url(name, number)}',
                'method': 'PUT',
              },
            )
            .toList(),
      });
    }
    if (path.endsWith(Routes.externalUploadMultipartComplete)) {
      return _json(<String, Object?>{'etag': 'complete'});
    }
    if (path.endsWith(Routes.externalUploadDone)) {
      return _json(<String, Object?>{'dest_path': 'benchmark'});
    }
    throw StateError('unexpected benchmark route: $path');
  }

  VmodalResponse _json(Map<String, Object?> value) {
    final bytes = utf8.encode(jsonEncode(value));
    return VmodalResponse(
      statusCode: 200,
      contentLength: bytes.length,
      headers: const <String, String>{'content-type': 'application/json'},
      body: Stream<List<int>>.value(bytes),
    );
  }

  @override
  Future<void> close() async {}
}

class _Part {
  const _Part(this.size, this.md5);

  final int size;
  final String md5;
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
