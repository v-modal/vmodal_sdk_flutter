<div align="center">
  <img src="readme_assets/logo_vmodal_owl.jpeg" alt="VModal owl" width="96">
  <h1>VModal for Flutter</h1>
  <p><strong>Give your Android and iOS apps a multimodal memory.</strong></p>
  <p>Upload video. Find moments by meaning, speech, text, or imagery.<br>Keep the experience fast, native, and 100% Flutter.</p>
  <img src="https://flutter.dev/assets/lockup_built-w-flutter.5443036ead976e7afea9249e17cd32b3.svg" alt="Built with Flutter" width="210">
  <br><br>
  <img src="https://img.shields.io/badge/Flutter-3.44%2B-02569B?logo=flutter&logoColor=white" alt="Flutter 3.44+">
  <img src="https://img.shields.io/badge/Dart-3.12%2B-0175C2?logo=dart&logoColor=white" alt="Dart 3.12+">
  <img src="https://img.shields.io/badge/Android-supported-3DDC84?logo=android&logoColor=white" alt="Android supported">
  <img src="https://img.shields.io/badge/iOS-supported-000000?logo=apple&logoColor=white" alt="iOS supported">
  <img src="https://img.shields.io/badge/license-MIT-6C63FF" alt="MIT license">
</div>

<br>

<img src="readme_assets/dev_homepage.jpg" alt="A wall of searchable video moments and developer screens" width="100%">

<p align="center"><em>Turn every video library into an experience your users can explore.</em></p>

## Build the feature people remember

VModal brings multimodal video search and mobile-friendly uploads to Dart with a small, typed API. Your app owns the interface; the SDK handles the VModal gateway, request models, responses, upload streams, progress, and cancellation.

| Your Flutter experience | VModal gives you |
|---|---|
| “Find the cyclist in the red jacket” | Semantic video and image search |
| Search words spoken or shown on screen | ASR and OCR search sources |
| Upload from a picker or camera flow | Streamed, signed uploads with live progress |
| A cancel button that really cancels | Per-operation cancellation tokens |
| Collection and indexing screens | Typed collection, index, usage, and image resources |
| Login and account switching your way | App-owned runtime credentials—no login UI imposed |

## Start in minutes

The public package source is available on GitHub. Add it to your app:

```yaml
dependencies:
  vmodal_sdk_flutter:
    git:
      url: https://github.com/v-modal/vmodal_sdk_flutter.git
      ref: main
```

Then run:

```bash
flutter pub get
```

Create one client from the API key already loaded by your authenticated app:

```dart
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

final keys = MutableApiKeyProvider(runtimeApiKey);
final vmodal = VmodalClient(
  config: SdkConfig(apiKeyProvider: keys),
);
```

> The SDK never owns your login screen or persists your API key. It receives an in-memory credential from your application at runtime.

## Search video with natural language

```dart
final groups = await vmodal.collections.listGroups(mode: 'vid_file');
if (groups.data.isEmpty) {
  throw StateError('No video collection exists for this API key');
}
final group = groups.data.first;
final version = group.latestLancedbVersion;
if (version == null) {
  throw StateError('The collection has no searchable LanceDB version');
}

final results = await vmodal.searches.searchVideo(
  SearchRequest(
    queryText: 'the cyclist crossing the bridge at sunset',
    groupName: group.groupName,
    searchSources: const ['image'],
    versionLancedb: version,
    limit: 20,
  ),
);

print('${results.cntActual} moments found');
for (final moment in results.data) {
  print(moment);
}
```

The collection must be a `vid_file` `GroupItem` returned
for the current runtime API key. Collection access is key-scoped; a name copied
from another account or environment can return HTTP 404 even when the search
route is healthy. The example name `flutter_example` is valid only after that
key has uploaded or otherwise created the collection and a refreshed
`listGroups()` response contains it. Search must also send an advertised
`lancedbVersions` value; `latestLancedbVersion` converts values such as `v1`
to the numeric request field `version_lancedb: 1`.

The response stays typed where the contract is stable and preserves the raw JSON so new server fields remain available immediately.

## Upload with progress and cancellation

The SDK reads an app-accessible `File` as a stream. It does not load the entire video into memory.

```dart
import 'dart:io';

final task = vmodal.collections.videoUpload(
  UploadSource.fromFile(File(videoPath)),
  collectionName: 'travel_diaries',
  subCollectionName: 'mobile_uploads',
);

final progress = task.progress.listen((value) {
  print('Uploading ${value.percent}%');
});

// Connect this to your Flutter cancel button when needed:
// task.cancel();

final uploaded = await task.result;
await progress.cancel();
print('Ready: ${uploaded.fileName}');
```

Signed single upload is the production default for every file size. Multipart upload is experimental and must be enabled explicitly with `VideoUploadOptions(multipart: true)`; it fails with `FeatureDisabled` when the complete backend route family is unavailable.

## Designed for real mobile lifecycles

- Rotate credentials without rebuilding the client: `keys.rotate(newApiKey)`.
- Cancel search or upload work when a screen closes.
- Show upload progress from a broadcast Dart stream.
- Keep file picking, secure storage, background scheduling, and lifecycle UI in the parent app.
- Close network resources deterministically with `await vmodal.close()`.

For logout or account switching, cancel active work, clear upload persistence, call `keys.clear()`, close the client, and create a new client for the next identity. Key rotation alone is not an identity switch.

## One client, focused resources

```text
vmodal.auth          identity and health
vmodal.searches      multimodal video search
vmodal.collections   upload and collection lifecycle
vmodal.indexes       create, inspect, and delete indexes
vmodal.admin         usage and cache statistics
vmodal.r2            presigned object-storage operations
vmodal.images        image retrieval
```

Gateway mode is the safe default and sends caller identity only as a bearer credential. `VmodalClient.unsafeDirect` is reserved for trusted private networks.

## Platform support

| Platform | Status | Notes |
|---|---:|---|
| Android | ✅ Supported | Flutter-native Dart API |
| iOS | ✅ Supported | Flutter-native Dart API |
| Flutter Web | ⛔ Not supported | Not part of the 1.0 release contract |
| macOS, Windows, Linux | ⏳ Not targeted | Mobile-first release |

Minimum toolchain: Flutter `3.44.0` and Dart `3.12.0`.

## Explore the SDK

- [Browse the public SDK reference](https://v-modal.github.io/vmodal_sdk_flutter/)
- [Run the complete example app](https://github.com/v-modal/vmodal_sdk_flutter/tree/main/example)
- [Read the SDK guide](https://github.com/v-modal/vmodal_sdk_flutter/blob/main/doc/sdk_doc.md)
- [Manage API keys safely](https://github.com/v-modal/vmodal_sdk_flutter/blob/main/doc/manage_api_key.md)
- [Build a search experience](https://github.com/v-modal/vmodal_sdk_flutter/blob/main/doc/search_app.md)
- [Review the API contract](https://github.com/v-modal/vmodal_sdk_flutter/blob/main/doc/sdk_contract.md)
- [Open an issue](https://github.com/v-modal/vmodal_sdk_flutter/issues)

## Development

```bash
git clone https://github.com/v-modal/vmodal_sdk_flutter.git
cd vmodal_sdk_flutter
bash install.sh install
bash test.sh all
```

The offline gate analyzes the package, runs the SDK and example tests, checks route synchronization, and validates Android/iOS example builds. Live tests require the repository's existing test credentials and are intentionally separate.

---

<p align="center"><strong>Build video experiences people can search, not just scroll.</strong></p>

<sub>Flutter and the related logo are trademarks of Google LLC. VModal is not endorsed by or affiliated with Google LLC.</sub>
