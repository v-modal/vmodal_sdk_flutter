## 1.1.0

- Added ordered asynchronous batch search with mini-batch ownership, bounded
  worker concurrency, preflight validation, and cooperative cancellation.
- Streamed signed upload bodies with awaited socket backpressure, exact file
  ranges, source-version checks, and bounded body/response timeouts.
- Enforced one signed-upload concurrency budget across bulk multipart tasks and
  coalesced monotonic progress before O(1) aggregation.
- Added bounded image downloads to caller-owned sinks and atomic files, plus a
  smaller per-call cap for buffered image responses.
- Added response-body idle timeouts with attempt-scoped GET retries and bounded
  chunked JSON decoding.
- Added a throttled upload/RSS benchmark harness and public caller injection for
  `HttpVmodalTransport` without adding native HTTP dependencies.

## 1.0.0

- Added the immutable `VModal`, `VModalProject`, and `VModalScope` facade.
- Added centralized project/collection/stream validation and mapping across
  upload, metadata, search, collection mutation, index lifecycle, listing, and
  deletion.
- Preserved `VmodalClient` as the low-level compatibility API with unchanged
  wire, upload, cancellation, retry, and API-key rotation behavior.
- Initial Android/iOS Flutter SDK with typed API resources.
- Bearer-only gateway authentication and request-time API-key rotation.
- Bounded streamed responses and cancelable signed uploads.
- Explicit experimental multipart upload with checkpoint reconciliation.
- Collection helpers select the latest advertised LanceDB version for search.
