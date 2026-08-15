# Pre-upload 360px video transcode

The SDK can reduce a video to a smaller resolution (longer side = 360px) *before*
uploading, to cut upload bytes. The core package stays free of native code: it owns only
the `VideoTranscoder` interface and the upload lifecycle. **By default there is no
transcoding** (`PassthroughVideoTranscoder`). Your app injects a real reducer.

This mirrors the Python SDK `video_upload(reduce_size=...)` contract.

## Contract

- Provide a **file-backed** source: `UploadSource.fromFile(File(path))`. A non-passthrough
  transcoder on a stream-only source raises `ValidationException`.
- Set the transcoder in options: `VideoUploadOptions(transcoder: My360Transcoder())`.
- Your `reduce(File input)` returns a `TranscodeResult(output, reused: ...)`:
  - return `input` unchanged for an identity passthrough (no cleanup);
  - return a **new** file to upload that temp instead — the SDK deletes it after a
    successful upload and leaves your original untouched;
  - set `reused: true` when you served a cached reduced file.
- The 100 MB limit is checked against the **original** file first.

## Response fields (parity with Python)

On `VideoUploadResponse`:

- `reduceSize` — true when a reduce path ran.
- `sizeBytes` — bytes actually uploaded (the temp).
- `sourceSizeBytes` — original file size.
- `sourceFilePath` / `filePath` — the original local path.
- `temporaryFileDeleted` — true when a produced temp was deleted.
- `temporaryFileReused` — true when the reduced file came from your cache.

## App-side example

Add a transcoding plugin to your **app** `pubspec.yaml` (the SDK does not depend on it),
for example `ffmpeg_kit_flutter` or `video_compress`, then implement `VideoTranscoder`:

```dart
import 'dart:io';
import 'package:ffmpeg_kit_flutter/ffmpeg_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

/// Reduces a video so its longer side is 360px, writing an mp4 to the temp dir.
class Ffmpeg360Transcoder implements VideoTranscoder {
  @override
  bool get isPassthrough => false;

  @override
  Future<TranscodeResult> reduce(File input) async {
    final dir = await getTemporaryDirectory();
    final out = File('${dir.path}/${input.uri.pathSegments.last}.360.mp4');
    if (out.existsSync() && out.lengthSync() > 0) {
      return TranscodeResult(out, reused: true); // served from cache
    }
    // Longer side -> 360, keep aspect, even dimensions.
    const scale =
        "scale='if(gte(iw,ih),min(360,iw),-2)':'if(gte(iw,ih),-2,min(360,ih))'";
    await FFmpegKit.execute(
      "-y -i '${input.path}' -vf \"$scale\" "
      '-c:v libx264 -preset veryfast -crf 28 -pix_fmt yuv420p '
      "-c:a aac -b:a 96k -movflags +faststart '${out.path}'",
    );
    return TranscodeResult(out);
  }
}
```

Use it through a scope:

```dart
final task = project
    .scope(collectionName: 'user_123', streamName: 'clips')
    .upload(
      UploadSource.fromFile(File('/path/to/clip.mp4')),
      options: ScopedUploadOptions(
        uploadOptions: VideoUploadOptions(transcoder: Ffmpeg360Transcoder()),
      ),
    );
final res = await task.result;
assert(res.reduceSize == true);
```

Or call the client extension directly:

```dart
final task = client.collections.videoUpload(
  UploadSource.fromFile(File('/path/to/clip.mp4')),
  collectionName: 'user_123',
  subCollectionName: 'clips',
  options: VideoUploadOptions(transcoder: Ffmpeg360Transcoder()),
);
```
