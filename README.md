# VModal Flutter SDK API reference

VModal helps Flutter developers build Android and iOS experiences that upload,
index, and search video or image collections. Users can find moments by meaning,
speech, visible text, or visual content while the SDK handles the VModal HTTP
contract, typed models, upload streams, progress, and cancellation.

The Swagger UI documents the HTTP routes used by the Flutter SDK. Most mobile
apps should call the typed Dart resources on `VmodalClient` instead of sending
raw HTTP requests.

## On this page

- [SDK structure](#sdk-structure)
- [Start a mobile session](#start-a-mobile-session)
- [Typical app flow](#typical-app-flow)
- [Reading this API reference](#reading-this-api-reference)

## SDK structure

Create one `VmodalClient` for the signed-in mobile session. The client groups
operations by feature:

| Resource | Use it for |
|---|---|
| `vmodal.auth` | Check the current identity and API health |
| `vmodal.collections` | List collections and upload or manage media |
| `vmodal.indexes` | Create, inspect, and delete search indexes |
| `vmodal.searches` | Run multimodal video searches |
| `vmodal.images` | Request image and thumbnail URLs |
| `vmodal.admin` | Read usage and cache statistics |
| `vmodal.r2` | Perform advanced presigned object-storage operations |

Requests and responses use typed Dart models where the contract is stable. Raw
JSON remains available so apps can adopt new response fields without waiting for
a package update.

## Start a mobile session

Pass the API key from your app's authenticated session into the SDK. VModal does
not own the login screen or persist credentials.

```dart
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

final keys = MutableApiKeyProvider(runtimeApiKey);
final vmodal = VmodalClient(
  config: SdkConfig(apiKeyProvider: keys),
);
```

Use the same client while that identity is active. When the user logs out or
switches account, cancel active work, clear upload state, clear the key, and
close the client with `await vmodal.close()`.

## Typical app flow

1. Get the runtime API key after your app signs the user in.
2. Use `vmodal.collections` to select a collection or upload media.
3. Use `vmodal.indexes` to create and monitor an index when new media must become
   searchable.
4. Use `vmodal.searches` to find relevant video moments from natural-language
   input.
5. Use `vmodal.images` to load thumbnails or image results in the interface.
6. Cancel in-flight work when a screen closes and close the client at the end of
   the session.

Upload tasks expose progress and cancellation, making them suitable for picker,
camera, progress-dialog, and cancel-button flows. File selection, secure storage,
background scheduling, and lifecycle UI remain under the parent app's control.

## Reading this API reference

Each Swagger operation shows its HTTP method, route, request body, and response
schema. Use it when you need to inspect the wire contract or understand an SDK
model. For app code and complete Flutter examples, start with:

- [Flutter SDK source and quick start](https://github.com/v-modal/vmodal_sdk_flutter)
- [SDK guide](https://github.com/v-modal/vmodal_sdk_flutter/blob/main/doc/sdk_doc.md)
- [Search app guide](https://github.com/v-modal/vmodal_sdk_flutter/blob/main/doc/search_app.md)
- [API key management](https://github.com/v-modal/vmodal_sdk_flutter/blob/main/doc/manage_api_key.md)

VModal Flutter currently targets Android and iOS. Flutter Web and desktop
platforms are not part of the mobile SDK release contract.
