# VModal Flutter SDK examples and capabilities

This folder contains runnable, compile-checked examples for the VModal Flutter
SDK. The SDK is a UI-free Dart client: your Flutter application owns login,
state management, file selection, screens, and lifecycle decisions, while the
SDK owns typed VModal API calls, request and response models, streamed media
upload, cancellation, and error handling.

## Quick links

| Resource | Link |
|---|---|
| Discord support | [Join the V-Modal AI Discord](https://discord.gg/XGxgBQqkaY) |
| Flutter SDK reference | [v-modal.github.io/vmodal_sdk_flutter](https://v-modal.github.io/vmodal_sdk_flutter/) |
| Demo app and community | [r/v_modal on Reddit](https://www.reddit.com/r/v_modal/) |
| API key | [Request a VModal API key](https://v-modal.com/page/contact.ts) |

## Example applications

| Example | Focus | Capabilities shown |
|---|---|---|
| [`01_full_app`](01_full_app/README.md) | End-to-end mobile UI | Runtime API key, identity resolution, collection and index discovery, video upload, index creation, natural-language search, and image-result rendering. |
| [`02_users`](02_users/README.md) | Content organization patterns | Shared global search, private per-user collections, multiple streams per user, and business/product catalog layouts. |
| [`03_cctv`](03_cctv/README.md) | Timestamped surveillance media | CCTV filename and timestamp metadata, searchable tags/text, image indexing, and absolute-time metadata search. |
| [`04_example`](04_example/README.md) | Searchable-video demo app | Traffic-camera moment search and multi-video visual discovery in one Android/iOS application. |

## SDK capabilities

### Project, collection, and stream organization

- Configure a `VModalProject` with `VModal.configure` or adopt an existing
  low-level client through `VModal.fromClient`.
- Create immutable `VModalScope` values for a logical project, collection, and
  stream. A scope keeps upload, indexing, and search calls coupled to the same
  content location.
- List the collections visible under the configured project.
- Model one global library, a private collection for each app user, multiple
  streams within one collection, or a product/business catalog.
- Close the project when the corresponding application session ends.

### Runtime authentication and configuration

- Supply an API key at runtime with `ApiKeyProvider` or
  `MutableApiKeyProvider`; the SDK does not render login UI or persist keys.
- Check gateway health, validate credentials, and resolve the authenticated
  identity with `auth.me()`.
- Rotate or clear an in-memory runtime key when the host application changes
  session or signs the user out.
- Use typed configuration, timeouts, retry behavior, and cancellation tokens.

### Video and media upload

- Stream an app-readable `File` through `UploadSource` without loading the
  whole media file into memory.
- Use signed single-file upload as the production default.
- Observe live upload progress through `UploadTask.progress` and await the
  final response through `UploadTask.result`.
- Cancel an individual operation with `UploadTask.cancel()` or a
  `CancellationToken`.
- Upload one file, upload a bulk set, add existing assets, and update asset or
  collection descriptions through the typed resource APIs.
- Use direct multipart upload only when explicitly selected; it is an
  experimental capability.

### CCTV and media metadata

- Send a caller-selected public video filename.
- Attach searchable metadata text and ordered metadata tags.
- Include an offset-aware recording start time using `startDatetimeUser`.
- Receive the backend-normalized timestamp and canonical UTC epoch value in
  the upload response.
- Reprocess media explicitly when the use case requires it.
- Upload metadata JSONL through the collection metadata resource.

### Index lifecycle

- List existing index jobs for a collection and stream.
- Create image/vector indexes with typed options for mode, modality, version,
  embedding model, index type, insertion mode, reprocessing, and date bounds.
- Query index status, use an indexed version for a search, and delete an index
  with an explicit confirmation option.
- Keep UI states separate for empty, queued, ready, failed, and cancelled work.

### Search and retrieval

- Search video and image-derived moments with natural-language queries.
- Select search sources such as image, ASR, or OCR when supported by the
  backend collection.
- Apply limits, metadata-text filters, and a specific index version.
- Search within paired absolute date/time bounds; the start is inclusive and
  the end is exclusive.
- Submit a bounded batch of typed search requests through the advanced client.
- Read typed counts, result records, execution time, and raw response fields.

### Images and result delivery

- Resolve one image URL or a batch of image URLs for search results.
- Download result images into memory, a sink, or an atomically written file.
- Refresh image lookup when a presigned URL has expired rather than attaching
  the VModal bearer credential to that URL.

### Advanced resources

- Access typed low-level resources through `VmodalClient`: `auth`, `searches`,
  `collections`, `indexes`, `admin`, `r2`, and `images`.
- Read account usage, cache statistics, and user statistics where the API key
  permits those administrative operations.
- Request R2 presigned upload URLs for compatible advanced workflows.
- Use the transport abstraction for custom or test transports while retaining
  typed requests, responses, errors, response-size limits, and cancellation.

## Platform and application boundaries

- Supported targets: Flutter applications for Android and iOS.
- Not included: Flutter Web, widgets, a login screen, key persistence, file
  picking, application state management, and background scheduling.
- The host application should retain its API key in memory only, pass an
  app-readable selected file to `UploadSource`, and close project/client
  resources when its session ends.

## Recommended validation order

```text
runtime API key
  -> auth.me()
  -> list collections
  -> list index jobs
  -> upload media if needed
  -> create or wait for an index
  -> search the same immutable scope
  -> resolve and display result images
```

Run the package checks from `uinterface/sdk_flutter`:

```bash
bash build.sh pub_get
bash build.sh analyze
bash build.sh test
```
