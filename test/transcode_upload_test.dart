import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

import 'fakes.dart';

/// Writes [output] (a smaller temp) beside the input and reports it produced.
class FakeReduceTranscoder implements VideoTranscoder {
  FakeReduceTranscoder(this.output, {this.reused = false});

  final File output;
  final bool reused;
  int calls = 0;

  @override
  Future<TranscodeResult> reduce(File input) async {
    calls++;
    return TranscodeResult(output, reused: reused);
  }

  @override
  bool get isPassthrough => false;
}

VmodalClient _client(FakeTransport api, FakeSignedUploadTransport signed) =>
    VmodalClient(
      config: SdkConfig(baseUrl: 'https://gateway.test', token: 'key'),
      transport: api,
      signedUploadTransport: signed,
    );

void main() {
  test('passthrough default uploads the original, no reduce fields', () async {
    final dir = Directory.systemTemp.createTempSync('vmx_tc_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final original = File('${dir.path}/a.mp4')
      ..writeAsBytesSync(<int>[1, 2, 3, 4]);
    final api = FakeTransport()
      ..addResponse(
        jsonResponse(
          '{"url":"https://objects.test/u","method":"PUT","key":"k"}',
        ),
      )
      ..addResponse(jsonResponse('{"dest_path":"done/a.mp4"}'));
    final signed = FakeSignedUploadTransport()
      ..queued.add(const SignedUploadResult(statusCode: 200, etag: 'e'));
    final client = _client(api, signed);
    final result = await client.collections
        .videoUpload(
          UploadSource.fromFile(original),
          collectionName: 'g',
          subCollectionName: 's',
        )
        .result;
    expect(result.reduceSize, isFalse);
    expect(result.sizeBytes, 4);
    expect(result.temporaryFileDeleted, isFalse);
    expect(original.existsSync(), isTrue);
  });

  test(
    'injected transcoder uploads temp, deletes it, sets parity fields',
    () async {
      final dir = Directory.systemTemp.createTempSync('vmx_tc_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final original = File('${dir.path}/big.mp4')
        ..writeAsBytesSync(List<int>.filled(10, 7));
      final temp = File('${dir.path}/big.reduced.mp4')
        ..writeAsBytesSync(<int>[1, 2, 3]);
      final api = FakeTransport()
        ..addResponse(
          jsonResponse(
            '{"url":"https://objects.test/u","method":"PUT","key":"k"}',
          ),
        )
        ..addResponse(jsonResponse('{"dest_path":"done/big.mp4"}'));
      final signed = FakeSignedUploadTransport()
        ..queued.add(const SignedUploadResult(statusCode: 200, etag: 'e'));
      final client = _client(api, signed);
      final result = await client.collections
          .videoUpload(
            UploadSource.fromFile(original),
            collectionName: 'g',
            subCollectionName: 's',
            options: VideoUploadOptions(transcoder: FakeReduceTranscoder(temp)),
          )
          .result;
      expect(result.reduceSize, isTrue);
      expect(result.sizeBytes, 3);
      expect(result.sourceSizeBytes, 10);
      expect(result.sourceFilePath, original.path);
      expect(result.filePath, original.path);
      expect(result.temporaryFileDeleted, isTrue);
      expect(result.temporaryFileReused, isFalse);
      expect(signed.calls.single.length, 3);
      expect(original.existsSync(), isTrue);
      expect(temp.existsSync(), isFalse);
    },
  );

  test('reused flag propagates from the transcoder', () async {
    final dir = Directory.systemTemp.createTempSync('vmx_tc_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final original = File('${dir.path}/c.mp4')
      ..writeAsBytesSync(List<int>.filled(8, 5));
    final temp = File('${dir.path}/c.reduced.mp4')
      ..writeAsBytesSync(<int>[9, 9]);
    final api = FakeTransport()
      ..addResponse(
        jsonResponse(
          '{"url":"https://objects.test/u","method":"PUT","key":"k"}',
        ),
      )
      ..addResponse(jsonResponse('{"dest_path":"done/c.mp4"}'));
    final signed = FakeSignedUploadTransport()
      ..queued.add(const SignedUploadResult(statusCode: 200, etag: 'e'));
    final result = await _client(api, signed).collections
        .videoUpload(
          UploadSource.fromFile(original),
          collectionName: 'g',
          subCollectionName: 's',
          options: VideoUploadOptions(
            transcoder: FakeReduceTranscoder(temp, reused: true),
          ),
        )
        .result;
    expect(result.temporaryFileReused, isTrue);
    expect(result.temporaryFileDeleted, isTrue);
  });

  test('stream-only source with a real transcoder is rejected', () async {
    final dir = Directory.systemTemp.createTempSync('vmx_tc_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final temp = File('${dir.path}/t.mp4')..writeAsBytesSync(<int>[1]);
    final source = UploadSource(
      fileName: 'stream.mp4',
      contentLength: 2,
      sourceId: 'stream',
      opener: () => Stream<List<int>>.value(<int>[1, 2]),
    );
    final client = _client(FakeTransport(), FakeSignedUploadTransport());
    await expectLater(
      client.collections
          .videoUpload(
            source,
            collectionName: 'g',
            subCollectionName: 's',
            options: VideoUploadOptions(transcoder: FakeReduceTranscoder(temp)),
          )
          .result,
      throwsA(isA<ValidationException>()),
    );
  });
}
