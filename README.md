
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

## Start here: support, documentation, demo, and API key

| | Resource | Link |
|---|---|---|
| 💬 | **Discord support** | [Join the V-Modal AI Discord](https://discord.gg/XGxgBQqkaY) |
| 📚 | **SDK documentation** | [Read the Flutter SDK reference](https://v-modal.github.io/vmodal_sdk_flutter/) |
| 📦 | **pub.dev package** | [Install vmodal_sdk_flutter](https://pub.dev/packages/vmodal_sdk_flutter) |
| 📱 | **Demo app and community** | [Visit r/v_modal on Reddit](https://www.reddit.com/r/v_modal/) |
| 🔑 | **Get an API key** | [Request a VModal API key](https://v-modal.com/page/contact.ts) |

<img src="readme_assets/dev_homepage.jpg" alt="A wall of searchable video moments and developer screens" width="100%">

<p align="center"><em>Turn every video library into an experience your users can explore.</em></p>

## Build the feature people remember

VModal brings multimodal video search and mobile-friendly uploads to Dart with a small, typed API. Your app owns the interface; the SDK handles the VModal gateway, request models, responses, upload streams, progress, and cancellation.

| Your Flutter experience | VModal gives you |
|---|---|
| “Find the cyclist in the red jacket” | Semantic video and image search |
| Search words spoken or shown on screen | AUDIO and TEXT search sources |
| Upload from a picker or camera flow | Streamed, signed uploads with live progress |
| A cancel button that really cancels | Per-operation cancellation tokens |
| Collection and indexing screens | Typed collection, index, usage, and image resources |
| Login and account switching your way | App-owned runtime credentials—no login UI imposed |

## Gettting started with one prompt

Copy this prompt into your coding agent:

```text
1. Clone https://github.com/v-modal/vmodal_sdk_flutter.git and enter the
   vmodal_sdk_flutter directory.
2. Inspect the repository instructions and
   example/01_full_app/README.md before making changes.
3. Use the repository's pinned Flutter toolchain; do not install another
   global Flutter version. Run:
     bash install.sh install
     bash build.sh pub_get
     bash build.sh analyze
     bash build.sh test
4. Start or select an Android emulator/device or, on macOS, an iOS
   simulator/device. List devices with:
     flutter_bin="$(bash install.sh flutter_bin)"
     "$flutter_bin" devices
5. Run example/01_full_app on the selected mobile device with:
     bash run.sh example --device DEVICE_ID

Keep working until the app builds, installs, and opens. Fix any repository
setup issue you can safely resolve. Do not add Flutter Web support, hard-code
credentials, or persist an API key. When the app opens, explain how to enter a
runtime VModal API key and complete the authentication, collection, upload,
index, and search flow. If a required host tool, emulator, simulator, or API
key is unavailable, stop at that boundary and report the exact blocker and the
next command I should run.
```

### How to get get API KEY :
  Get an API Key : [API Key](https://v-modal.com/page/contact.ts)


## Integrate into an existing app

Start with [the documentation index](https://github.com/v-modal/vmodal_sdk_flutter/blob/main/docs/README.md) and
[Choose authentication](https://github.com/v-modal/vmodal_sdk_flutter/blob/main/docs/authentication.md), then
[ready-to-use app recipes](https://github.com/v-modal/vmodal_sdk_flutter/blob/main/docs/component_patterns.md) for session ownership,
controller/widget wiring, upload/index/search, recovery, and mobile lifecycle.

## Start in minutes

[SDK docs: v-modal.github.io/vmodal_sdk_flutter/](https://v-modal.github.io/vmodal_sdk_flutter/)
    


For production, prefer the exact published pub.dev version when it is
available:

```yaml
dependencies:
  vmodal_sdk_flutter: 1.2.3
```

For a Git install, pin an immutable public revision. Use the version tag only
after a pub.dev release has actually created it:

```yaml
dependencies:
  vmodal_sdk_flutter:
    git:
      url: https://github.com/v-modal/vmodal_sdk_flutter.git
      ref: v1.2.3
```

The default source-only public workflow does not create that tag. For such a
release, replace the `ref` above with the full 40-character commit SHA from the
public repository. The `main` branch is suitable for evaluation and development
only; it is not a production pin.

The opt-in user-session API below is part of the **1.3.0 source release**.
Use that released public source revision for it; the `1.2.3` package and tag
shown above do not contain these additions. A source-only GitHub Actions export
does not publish `1.3.0` to pub.dev or create a version tag.

Then run:

```bash
flutter pub get
```

Create one project from the API key already loaded by your authenticated app,
then retain immutable scopes wherever your app performs content operations:

```dart
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

final keys = MutableApiKeyProvider(runtimeApiKey);
final project = VModal.configure(
  projectId: 'food_app',
  apiKeyProvider: keys,
);
final favorites = project.scope(
  collectionName: 'user_123',
  streamName: 'favorites',
);
```

`projectId`, `collectionName`, and `streamName` accept only letters, digits,
and underscore. Each is trimmed and limited to 80 characters. Project and
collection names cannot contain the reserved `__` separator, and their encoded
backend value is also limited to 80 characters. The SDK performs that encoding
internally.

> The SDK never owns your login screen or persists your API key. Authentication identity is separate from project, collection, and stream organization. `VModalProject` and `VmodalClient` provide tenant-scoped access; use `UserSessionManager` below for app-user isolation.

### Choose authentication: developer-backend scoped tokens

The direct runtime-key setup above remains supported. For server-enforced user
grants, your backend verifies the current app session and obtains a short-lived
VModal token using its registered server credential:

```dart
final backend = await VModal.connectWithBackend(
  expectedAppUserId: signedInUser.id,
  expectedProjectId: 'framebase',
  loadToken: () async => ScopedTokenEnvelope.fromJson(
    await developerApi.createVmodalSession(),
  ),
);
final collections = await backend.session.listCollections();
final library = backend.scope('my_library');
final results = await library.search('a person entering the room');
await backend.close();
```

Both mechanisms use the public gateway; data requests go directly to VModal.
Flutter receives no master key, constructs no backend collection selector, and
adds no identity headers. The SDK confirms auth/me binding/grants before return
and coalesces renewal. Close at the start of logout or account switch.

This source API requires corresponding registered origin, Worker and upstream
capabilities; it is not a claim of live deployment. See
[Choose authentication](https://github.com/v-modal/vmodal_sdk_flutter/blob/main/docs/authentication.md),
[the backend guide](https://github.com/v-modal/vmodal_sdk_flutter/blob/main/docs/backend_authentication.md), and the independent
[backend-auth reference](https://github.com/v-modal/vmodal_sdk_flutter/blob/main/example/06_backend_auth/README.md). The preserved
Framebase user-login app remains a shared-key/local-isolation example.

## Isolate signed-in app users sharing one tenant key

Your authenticated host app resolves a stable user ID and its allowed content
mapping. VModal's API key and `auth.me()` identify the tenant principal; A and B
may use exactly the same key and principal. Neither value identifies the app
user. Keep app-user identity out of `SdkConfig.userId` and `X-User-Id`.

```dart
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

Future<void> openLibrary({
  required String runtimeTenantKey,
  required String tenantId,
  required String tenantPrincipal,
  required String authenticatedAppUserId,
  required String issuedCollectionId,
}) async {
  final config = SdkConfig(); // gateway mode, existing connection defaults
  final credentials = TenantCredentialSource(
    serviceNamespace: SessionContext.serviceNamespaceFor(config),
    tenantId: tenantId,
    expectedPrincipal: tenantPrincipal,
    initialKey: runtimeTenantKey,
  );
  final manager = UserSessionManager(
    config: config,
    credentialSource: credentials,
  );
  final mapping = ContentMapping.opaque(
    collectionId: issuedCollectionId, // trusted host mapping, unchanged on wire
    streamName: 'favorites',
    actions: {UserAction.discover, UserAction.search, UserAction.media},
  );
  try {
    final session = await manager.openUserSession(
      tenantId: tenantId,
      appUserId: authenticatedAppUserId,
      allowedContentMapping: [mapping],
    );
    await session.verifyPrincipal(tenantPrincipal); // optional tenant check
    final collections = await session.listCollections();
    if (!collections.contains(mapping)) return;
    final scope = session.scope(mapping);
    final results = await scope.search('cyclist crossing a bridge');
    for (final hit in results.videoHits) {
      print('${hit.fileName}: ${hit.playbackOffsetMs} ms');
    }
    if (results.assets.isNotEmpty) {
      final frame = await scope.imageBytes(results.assets.first);
      print('${frame.length} image bytes');
    }
  } finally {
    await manager.close();
    credentials.close();
  }
}
```

Retain one manager for the app's identity flow. Starting another activation or
calling `manager.logout()` invalidates the outgoing session synchronously.
Every activation receives a new runtime `sessionId`, private provider/client,
and owned transports. Old scopes cannot dispatch, deliver late search data,
or forward upload progress after invalidation; cancellation settles even when
an underlying custom transport ignores it. Host code must also check the view
generation and clear already displayed images, players, routes, and histories.

`ContentMapping.logical(projectId: ..., collectionName: ..., streamName: ...)`
uses the existing `project__collection` encoding. `ContentMapping.opaque(...)`
preserves the backend collection ID. Actions and collection-wide access come
from trusted host policy. Collection/index deletion requires both
`UserAction.delete` and `collectionWide: true`.

This is a guarantee for operations through `UserSession` and `UserScope`.
`VmodalClient`, `VModalProject`, arbitrary HTTP, and raw media/storage helpers
bypass it. A modified client holding the shared tenant key can make arbitrary
tenant-authorized requests; server protection requires separately verified
app-user authorization. The SDK cannot recall data returned while A was active
or stop work already accepted by the server. Read the
[session contract](https://github.com/v-modal/vmodal_sdk_flutter/blob/main/docs/sdk_contract.md)
and [tenant-key rotation guide](https://github.com/v-modal/vmodal_sdk_flutter/blob/main/docs/manage_api_key.md)
before integration.

## Search video with natural language

```dart
final collections = await project.listCollections(mode: 'vid_file');
if (!collections.contains('user_123')) {
  throw StateError('No video collection exists for this API key');
}

final results = await favorites.search(
  'the cyclist crossing the bridge at sunset',
  options: const ScopedSearchOptions(
    searchSources: ['image'],
    limit: 20,
  ),
);

print('${results.cntActual} moments found');
for (final hit in results.videoHits) {
  print(
    '${hit.assetId ?? 'legacy asset'} · ${hit.fileName ?? 'unnamed'} · '
    '${hit.playbackOffsetMs ?? 'unknown'} ms · distance ${hit.distance}',
  );
}
```

`VideoSearchHit.distance` is the raw lower-is-better distance; it is not a
similarity or confidence score. `assetId` remains `null` when an older server
does not return `asset_id`—the SDK never invents stable identity from a
filename, path, frame identifier, or timestamp. The original entries from the
tenant-scoped facade remain available through `results.data` and each hit's
`raw` map for compatibility. Session-bound search instead exposes allowlisted
fields, recomputed returned-row counts, and live `SessionAsset` handles; signed
URLs and nested tenant metadata stay private.

Collection access is key-scoped. A logical name copied from another account or
environment can return HTTP 404 even when the search route is healthy. Use
`ScopedSearchOptions(versionLancedb: version)` when your application tracks a
specific index version.

The tenant-scoped response stays typed where the contract is stable and
preserves the raw JSON so new server fields remain available immediately.

## Upload with progress and cancellation

The SDK reads an app-accessible `File` as a stream. It does not load the entire video into memory.

```dart
import 'dart:io';

final task = favorites.upload(
  UploadSource.fromFile(File(videoPath)),
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

For CCTV footage, provide the public filename and offset-aware recording
origin in `VideoUploadOptions`. The backend—not the SDK—normalizes the datetime
and returns the canonical UTC epoch milliseconds. Metadata tags are repeated
independently on the wire.

```dart
final task = favorites.upload(
  UploadSource.fromFile(File(cameraClipPath)),
  options: const ScopedUploadOptions(
    uploadOptions: VideoUploadOptions(
      videoFilename: 'entrance-camera.mp4',
      metadataText: 'north entrance delivery lane',
      metadataTags: ['entrance', 'delivery', 'camera-3'],
      startDatetimeUser: '2026-07-30T09:15:00+09:00',
    ),
  ),
);
final uploaded = await task.result;
print(uploaded.startTsUnixUserMs); // canonical backend value
```

Search the same footage using a metadata string and an absolute range. Start is
inclusive and end is exclusive. Datetime values must include `Z` or an explicit
UTC offset; the SDK preserves the caller text without timezone conversion.

```dart
final moments = await favorites.search(
  'vehicle',
  options: const ScopedSearchOptions(
    queryMetadataText: 'delivery',
    startDate: '2026-07-30T09:15:00.000+09:00',
    endDate: '2026-07-30T09:16:00.000+09:00',
    searchSources: ['image'],
  ),
);
```

The low-level direct multipart endpoint accepts the same contract additively:

```dart
await client.collections.uploadFile(
  filePart('file', File(cameraClipPath), contentType: 'video/mp4'),
  groupName: 'camera_archive',
  videoFilename: 'entrance-camera.mp4',
  metadataText: '',
  metadataTags: ['entrance', 'camera-3'],
  startDatetimeUser: '2026-07-30T09:15:00+09:00',
);
```

Signed single upload is the production default for every file size. Multipart upload is experimental and must be enabled explicitly with `VideoUploadOptions(multipart: true)`; it fails with `FeatureDisabled` when the complete backend route family is unavailable.

Uploads use exact file ranges, awaited socket streaming, coalesced progress, and
one network-concurrency budget per bulk task. For image caches, use
`writeImageFromUrl` with a caller-owned sink or `saveImageFromUrl` for atomic
file replacement instead of buffering the image. See
[the performance guide](https://github.com/v-modal/vmodal_sdk_flutter/blob/main/docs/performance.md)
for limits, timeout behavior, and the benchmark command.

## Designed for real mobile lifecycles

- Rotate credentials without rebuilding the client: `keys.rotate(newApiKey)`.
- Cancel search or upload work when a screen closes.
- Show upload progress from a broadcast Dart stream.
- Keep file picking, secure storage, background scheduling, and lifecycle UI in the parent app.
- Close network resources deterministically with `await project.close()`.

For applications using the session API, call `manager.logout()` or activate
the next authenticated policy through the manager, and clear host UI state.
Owner-partitioned archives and checkpoints remain available for a validated
return to that user. Install tenant key replacements through
`TenantCredentialSource.install(...)`; rotation preserves the active session,
owner namespace, and policy. A policy or tenant change requires fresh sessions.

With the older tenant-scoped API, the host owns all isolation: cancel work,
close its private provider and project, partition checkpoints, and create fresh
state for the next identity. Closing a client alone does not isolate the default
process-global multipart checkpoint store.

## Common organization flows

```text
global index       project=video_search  collection=global           stream=uploads
per-user index     project=food_app      collection=user_123         stream=personal_videos
multiple streams  project=food_app      collection=user_123         stream=camera/favorites
catalog            project=shopping_app  collection=product_catalog  stream=merchant_uploads
```

Create a separate `VModalProject` for each developer project. On account
switch, create fresh project/client state; an already running task retains the
immutable scope with which it started.

## Developer use cases from the Android examples

The native Android examples are useful product and data-flow references even
when your application is written in Flutter. Choose the example that matches
the feature you are building, then implement the same SDK contract with Dart
widgets, state, and lifecycle ownership.

| Developer goal | Android reference | What to carry into Flutter |
|---|---|---|
| Learn or troubleshoot one capability | [Kotlin starter examples](https://github.com/v-modal/vmodal_sdk_android/tree/main/examples/01_starter) | Follow focused examples for authentication, health, filtered search, collection listing, picker uploads, cancellation, resumable or bulk uploads, metadata, index lifecycle, images, admin, and R2. Reproduce only the Dart capability your feature needs. |
| Build an upload-and-search screen | [Upload → index → search app](https://github.com/v-modal/vmodal_sdk_android/tree/main/examples/02_search) | Use the complete dependency chain: pick a video, stream the upload with progress, poll the image-index job, search the same collection and stream, resolve image URLs in bulk, and render result states. |
| Validate an integration one stage at a time | [Staged full application](https://github.com/v-modal/vmodal_sdk_android/tree/main/examples/03_fullapp) | Keep configuration, `auth.me()`, collection discovery, upload, indexing, search, and image rendering as visible stages. This makes authentication, data-scope, and asynchronous-index failures easy to isolate. |
| Choose a content tenancy model | [User and business index layouts](https://github.com/v-modal/vmodal_sdk_android/tree/main/examples/04_user) | Model a global library, one private collection per user, several streams per user, or a shared product catalog with stable `projectId`, `collectionName`, and `streamName` values. |

When translating the Android flows:

- Replace `ViewModel` plus `StateFlow` with your Flutter state-management
  approach, but keep one immutable state model for loading, progress, empty,
  success, error, and cleanup states.
- Replace the Android `content://` adapter with a picker result exposed as an
  app-readable Dart `File`, then create `UploadSource.fromFile(...)`.
- Replace coroutine upload Flow collection with `UploadTask.progress`,
  `UploadTask.result`, and `UploadTask.cancel()`. The screen owns the
  subscription and cancels it during disposal.
- Preserve collection and stream coupling across upload, index creation,
  search, and bulk image lookup. Never display a job or result after the user
  has switched scope or identity.
- Load presigned result images without adding the VModal bearer credential.
  Refresh expired URLs by repeating the image lookup.
- Treat Android `WorkManager` patterns as lifecycle guidance only; background
  scheduling remains application-owned and platform-specific in Flutter.

## Advanced low-level resources

`VmodalClient` remains supported for auth, usage, image lookup, and advanced
wire-level integration. To combine it with scopes, construct the client first
and transfer lifecycle ownership to the project:

```dart
final client = VmodalClient(
  config: SdkConfig(apiKeyProvider: keys),
);
final project = VModal.fromClient(
  projectId: 'food_app',
  client: client,
);

final profile = await client.auth.me();
final scope = project.scope(
  collectionName: 'user_123',
  streamName: 'favorites',
);

await project.close(); // closes the transferred client
```

Gateway mode is the default and sends caller identity only as a bearer
credential. `VmodalClient.unsafeDirect` is reserved for trusted private
networks.

## Platform support

| Platform | Status | Notes |
|---|---:|---|
| Android | ✅ Supported | Flutter-native Dart API |
| iOS | ✅ Supported | Flutter-native Dart API |
| Flutter Web | ⛔ Not supported | Not part of the 1.0 release contract |
| macOS, Windows, Linux | ⏳ Not targeted | Mobile-first release |

Minimum toolchain: Flutter `3.44.0` and Dart `3.12.0`.

## Explore the SDK

- [VModal home](https://www.v-modal.com)
- [VModal for developers](https://www.v-modal.com/developers)
- [VModal AI](https://www.v-modal.ai)
- [Browse the public SDK reference](https://v-modal.github.io/vmodal_sdk_flutter/)
- [Run the complete example app](https://github.com/v-modal/vmodal_sdk_flutter/tree/main/example/01_full_app)
- [Organize global, per-user, multi-stream, and catalog indexes](https://github.com/v-modal/vmodal_sdk_flutter/tree/main/example/02_users)
- [Upload timestamped CCTV footage and search an absolute time range](https://github.com/v-modal/vmodal_sdk_flutter/tree/main/example/03_cctv)
- [Read the SDK guide](https://github.com/v-modal/vmodal_sdk_flutter/blob/main/docs/sdk_doc.md)
- [Manage API keys safely](https://github.com/v-modal/vmodal_sdk_flutter/blob/main/docs/manage_api_key.md)
- [Build a search experience](https://github.com/v-modal/vmodal_sdk_flutter/blob/main/docs/search_app.md)
- [Review the API contract](https://github.com/v-modal/vmodal_sdk_flutter/blob/main/docs/sdk_contract.md)
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

------------------------------
## Flutter SDK Goals

Developed as an open-source tool, the SDK abstracts complex machine learning infrastructure into simple, developer-friendly methods. This allows mobile developers to incorporate deep visual intelligence into their apps without managing raw vector databases or heavy AI pipelines. During its current public beta phase, the SDK enables fast, semantic querying across media libraries using natural language text or visual references.
The framework supports unified cross-platform logic, ensuring identical integration paths for both iOS and Android deployment. By optimizing communication with V-Modal AI’s backend, the SDK minimizes network latency and processing overhead on user devices. This makes it ideal for apps requiring real-time asset tracking, e-commerce visual discovery, or intelligent media organization.




------------------------------
## Understand Core Features

* Multimodal Search: Query media asset databases using text prompts or reference images simultaneously.
* Video Analytics: Extract actionable data and contextual timestamps from raw video files during processing.
* Image Recognition: Identify object patterns, text elements, and spatial relationships within static images.
* Vector Indexing: Convert unstructured multimedia content into searchable mathematical representations.
* Secure Authorization: Protect developer access tokens through integrated, secure API headers.
* Asynchronous Execution: Submit asynchronous server indexing jobs and monitor their status from the app.


Developers can quickly query their indexed catalog by passing strings or files to the search client. The SDK processes these inputs, communicates with V-Modal's specialized embedding models, and returns structured data objects. These response objects expose nullable lower-is-better distances, metadata tags, and playback offsets for video matches, allowing apps to jump directly to relevant frames.

------------------------------
## Evaluate Technical Architecture

* Dart Native: Built natively on Dart to ensure seamless compatibility with Flutter 3.x engines.
* Lightweight Footprint: Avoids heavy local binary files by offloading heavy ML math to cloud APIs.
* Reactive Model: Returns search Futures and upload progress streams; app controllers publish UI state.
* Error Resilience: Retries eligible GET/HEAD failures within a bounded budget; apps handle rate limits and reconcile unknown mutation outcomes.

------------------------------
## Review Use Cases

* E-Commerce Apps: Allow users to snap photos of physical products to find identical online listings.
* Security Surveillance: Search hours of recorded footage instantly using simple text descriptions of events.
* Digital Asset Management: Automate the tagging, categorization, and sorting of large corporate media files.
* Content Creation: Enable video editors to locate specific scenes or actions within massive B-roll libraries.

------------------------------
## Learn More About VModal

Explore the full platform and developer resources:

* [VModal](https://www.v-modal.com) — the official home of VModal multimodal video and image search.
* [VModal for Developers](https://www.v-modal.com/developers) — API docs, SDKs, and integration guides for building on VModal.
* [VModal AI](https://www.v-modal.ai) — learn how VModal AI powers semantic search across video, speech, text, and imagery.

Get started today at [www.v-modal.com](https://www.v-modal.com), read the [developer documentation](https://www.v-modal.com/developers), and discover the technology behind [VModal AI](https://www.v-modal.ai).


  
</p>


<sub>Flutter and the related logo are trademarks of Google LLC. VModal is not endorsed by or affiliated with Google LLC.</sub>



<img src="https://gettrack.link/p/github_sdk_flutter" width="1" height="1" alt="" style="display:none" />
