## 1.2.1

- Reissued the CCTV release with a reproducible public-source manifest that
  tracks the SDK and example lockfiles before tag verification and pub.dev
  publication.

## 1.2.0

- Added CCTV uploads with caller-selected public filenames, searchable metadata
  text, repeated tags, offset-aware footage origins, and canonical timestamp
  response fields across signed, multipart, resumed, bulk, and transcoded paths.
- Added the same additive CCTV fields to direct multipart uploads and fixed the
  transport so every iterable form value is emitted as an independent text
  part on the wire.
- Added absolute-time CCTV search with string metadata queries, paired
  timezone-aware `[start, end)` bounds, scoped propagation, compatibility for
  the legacy metadata map, and an explicit opt-in live contract gate.

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
