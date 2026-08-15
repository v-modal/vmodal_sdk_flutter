import 'dart:io';

/// Outcome of a pre-upload video transcode.
///
/// [output] is the file to upload. When it equals the transcoder input the run
/// is an identity passthrough and nothing is deleted afterwards. [reused] is
/// `true` when the transcoder returned a previously-cached reduced file.
class TranscodeResult {
  /// Creates a result wrapping the [output] file.
  const TranscodeResult(this.output, {this.reused = false});

  /// File whose bytes are uploaded.
  final File output;

  /// Whether [output] came from a transcoder-side cache.
  final bool reused;
}

/// Optional on-device video reducer applied before a signed upload.
///
/// The core SDK stays free of native/plugin transcoding code: it owns only this
/// interface and the upload lifecycle. Apps inject a real 360px reducer
/// (ffmpeg_kit / video_compress) via [VideoUploadOptions.transcoder]; the
/// default is [PassthroughVideoTranscoder] (no transcoding).
abstract interface class VideoTranscoder {
  /// Returns the file to upload, reducing [input] when applicable.
  ///
  /// Returning a file whose path differs from [input] marks it a produced temp
  /// that the SDK deletes after a successful upload. Returning [input] itself is
  /// an identity passthrough.
  Future<TranscodeResult> reduce(File input);

  /// Whether this transcoder performs no work and can be skipped entirely.
  bool get isPassthrough => false;
}

/// Identity transcoder: uploads the original file unchanged.
class PassthroughVideoTranscoder implements VideoTranscoder {
  /// Creates the default no-op transcoder.
  const PassthroughVideoTranscoder();

  @override
  Future<TranscodeResult> reduce(File input) async => TranscodeResult(input);

  @override
  bool get isPassthrough => true;
}
