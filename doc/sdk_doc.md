# SDK guide

The generated class and method reference is published at
`https://v-modal.github.io/vmodal_sdk_flutter/` and is built from the public
Dart declarations in `lib/vmodal_sdk_flutter.dart`. The monorepo release
pipeline builds the Pages artifact in `docs_sdk/`; that generated tree is not
part of the standalone package. Backend hosts, wire paths, and implementation
bodies are intentionally excluded; mobile applications should use the typed
resources described there.

Construct `VmodalClient` with an explicit `SdkConfig` and an app-owned
`ApiKeyProvider`. All ordinary operations are asynchronous. Gateway mode is the
default and sends only `Authorization: Bearer <key>` as caller identity.

Resources are grouped under `auth`, `searches`, `collections`, `indexes`,
`admin`, `r2`, and `images`. Request models preserve server snake_case during
serialization and response classes retain the raw JSON map for extension fields.

Responses are consumed through one bounded stream reader: JSON/text is limited
to 8 MiB, errors to 1 MiB, and binary results to 64 MiB. Only GET and HEAD retry
recognized transport failures or 500/502/503/504. Mutating requests are sent
once; reconcile server state before explicitly retrying an ambiguous mutation.

Uploads use reopenable `UploadSource` streams. Signed single upload is always
the default. `UploadTask` exposes a result future, broadcast progress stream,
and per-task cancellation. Multipart requires explicit opt-in and is experimental.

Flutter Web, login UI, key persistence, file picking, widget state management,
and background scheduling are outside the package. The first release supports
Flutter applications on Android and iOS.
