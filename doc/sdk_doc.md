# SDK guide

The generated class and method reference is published at
`https://v-modal.github.io/vmodal_sdk_flutter/` and is built from the public
Dart declarations in `lib/vmodal_sdk_flutter.dart`. The monorepo release
pipeline builds the Pages artifact in `docs_sdk/`; that generated tree is not
part of the standalone package. Backend hosts, wire paths, and implementation
bodies are intentionally excluded; mobile applications should use the typed
resources described there.

Use `VModal.configure` with a developer-owned project ID and an app-owned
`ApiKeyProvider`, then create immutable collection/stream scopes:

```dart
final keys = MutableApiKeyProvider(runtimeApiKey);
final project = VModal.configure(
  projectId: 'food_app',
  apiKeyProvider: keys,
);
final scope = project.scope(
  collectionName: 'user_123',
  streamName: 'favorites',
);

final upload = scope.upload(UploadSource.fromFile(video));
final result = await scope.search('birthday dinner');

await project.close();
```

Configuration and scope creation perform no network I/O. Every Future-based
scoped operation accepts `CancellationToken?`; uploads retain `UploadTask`
progress and cancellation. `VModalProject.close()` owns and idempotently closes
the low-level client.

Names are trimmed, required, limited to ASCII letters, digits, and underscore,
and limited to 80 characters. `projectId` and `collectionName` cannot contain
`__`. The SDK internally maps project plus collection to one backend collection
and maps stream directly; callers never construct or parse that value.

`listCollections` returns logical names for the exact project prefix in backend
order, removes duplicates after their first occurrence, and excludes other
projects. A malformed name under the current project is a
`MalformedResponse`.

Common layouts include one `global` collection, one `user_123` collection per
end user, several streams in one user collection, a `product_catalog`
collection, and separate `VModalProject` values for separate apps. Account
switching creates fresh project/client state; API-key rotation alone does not
change identity or content scope.

`VmodalClient` remains the advanced compatibility API for auth, image lookup,
usage, and direct resource access. `VModal.fromClient` accepts an existing
fully configured client and transfers close ownership to the returned project.
All ordinary operations are asynchronous. Gateway mode sends only
`Authorization: Bearer <key>` as caller identity.

Resources are grouped under `auth`, `searches`, `collections`, `indexes`,
`admin`, `r2`, and `images`. Request models preserve server snake_case during
serialization and response classes retain the raw JSON map for extension fields.

Scoped migration replaces low-level `groupName` or `collectionName` plus
`streamName` arguments with one immutable `VModalScope`. Use scoped option
classes for operation settings; they deliberately contain no organization
override fields.

Responses are consumed through one bounded stream reader: JSON/text is limited
to 8 MiB, errors to 1 MiB, and binary results to 64 MiB. Only GET and HEAD retry
recognized transport failures or 500/502/503/504. Mutating requests are sent
once; reconcile server state before explicitly retrying an ambiguous mutation.

Uploads use reopenable `UploadSource` streams. Signed single upload is always
the default. `UploadTask` exposes a result future, broadcast progress stream,
and per-task cancellation. Multipart requires explicit opt-in and is experimental.

CCTV signed uploads use `VideoUploadOptions(videoFilename, metadataText,
metadataTags, startDatetimeUser, reProcess)`. The timestamp input must contain
`Z` or an explicit UTC offset and is sent unchanged; the backend owns
normalization and the canonical `startTsUnixUserMs` response. Tags remain
ordered repeated wire values, including after multipart resume, bulk upload,
or transcoding. A timestamp with no public name derives the original source
filename.

`CollectionsResource.uploadFile` accepts the same CCTV fields for direct
multipart compatibility. Use `SearchRequest.queryMetadataText` or
`ScopedSearchOptions.queryMetadataText` for the backend string metadata
contract. In `vid_file` mode, `startDate` and `endDate` are a required pair,
with inclusive start and exclusive end; datetime values require `Z` or an
explicit UTC offset and are never converted by the SDK.

Flutter Web, login UI, key persistence, file picking, widget state management,
and background scheduling are outside the package. The first release supports
Flutter applications on Android and iOS.
