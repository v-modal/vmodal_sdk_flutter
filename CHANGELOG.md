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
