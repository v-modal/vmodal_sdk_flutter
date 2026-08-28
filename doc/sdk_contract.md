# Flutter SDK contract inventory

The route authority is `vmx_avideo/infra/search_api_ui/routers/apionly_routes.py`
plus `apionly_serve_img.py`. The Python SDK defines the cross-SDK wire contract;
the Android SDK defines mobile cancellation, streaming, upload, and key-rotation
behavior. `test/fixtures/routes_contract.json` is the reviewed normalized mirror.

| Resource | Public Flutter operations | Contract status |
|---|---|---|
| Scoped facade | `VModal.configure`, `VModal.fromClient`, `VModalProject.scope`, `listCollections`, `close` | Preferred additive API |
| Scoped operations | `upload`, `uploadMetadata`, `search`, `addAssets`, `updateAsset`, index lifecycle, collection deletion | Immutable organization; delegates to resources |
| Client/auth | `health`, `authCheck`, `auth.me` | Active; gateway bearer only |
| Searches | `searchVideo(SearchRequest)` | Active; exact Python/Android defaults |
| Collections | `listGroups`, `uploadFile`, `uploadMetadataJsonl`, `addAssets`, `updateDescription`, `delete` | Active |
| Signed upload | `videoUpload`, `videoUploadBulk` | Active; signed single is default |
| Indexes | `jobsList`, `createIndex`, `indexStatus`, `deleteIndex` | Active |
| Admin | `userStats`, `usage`, `cacheStats` | Active; split external/users API bases |
| R2 | `presignUploadFile`, `presignUploadFolderVideo` | Active users API routes |
| Images | `getUrl`, `getUrlBulk`, `getImageFromUrl`, `writeImageFromUrl`, `saveImageFromUrl`, `getImageBulkFromUrls` | Active image routes; buffered, sink, and atomic-file download choices |
| Multipart | explicit `VideoUploadOptions(multipart: true)` | Experimental; never selected by size |
| GDrive/SQL/auto-index/folder scan | compatibility methods | Disabled before transport |
| Google Drive collection upload | no public method | Mounted upstream but deprecated by SDK contract |

Every operation uses the centralized `Routes`, `VmodalHttp`, bounded chunked
response readers, retry classifier, and cancellation token. `SdkConfig.timeout`
bounds request/upload phases; `idleTimeout` bounds silence between response-body
events and defaults to `timeout`. Gateway payload serializers
remove caller identity; only unsafe direct mode may emit trusted identity fields.
Application-visible error bodies and details retain their structured shape, but
the SDK replaces Unix, Windows, UNC, and `file:` filesystem paths with `****`
before constructing a server-response exception. Exception strings continue to
omit response bodies entirely.

The facade's single organization mapping is:

```text
projectId + "__" + collectionName  -> backend group/collection
streamName                          -> backend stream/sub-collection
```

All public names are trimmed and accept only `[A-Za-z0-9_]`, with an
80-character field limit. Project and collection reject `__`; their encoded
value must also fit 80 characters. Authentication identity is never derived
from these names.

The facade changes no route, serializer, response, retry, upload, cancellation,
or API-key-provider contract. `VmodalClient` remains public and compatible.
`VModal.fromClient` transfers lifecycle ownership, so the project is the object
that must be closed.

Android regression groups map to Flutter suites as follows: configuration/routes
and credentials (`config_routes_test`, `auth_http_test`), transport/bounds and
cancellation (`transport_test`), resources/models (`resources_models_test`),
signed/bulk upload (`upload_test`), multipart/checkpoint (`multipart_upload_test`),
adaptive vectors (`adaptive_upload_test`), and release/tooling
(`shell_scripts_test`, `workflow_layout_test`).
