# Flutter SDK contract inventory

The route authority is `vmx_avideo/infra/search_api_ui/routers/apionly_routes.py`
plus `apionly_serve_img.py`. The Python SDK defines the cross-SDK wire contract;
the Android SDK defines mobile cancellation, streaming, upload, and key-rotation
behavior. `test/fixtures/routes_contract.json` is the reviewed normalized mirror.

| Resource | Public Flutter operations | Contract status |
|---|---|---|
| Client/auth | `health`, `authCheck`, `auth.me` | Active; gateway bearer only |
| Searches | `searchVideo(SearchRequest)` | Active; exact Python/Android defaults |
| Collections | `listGroups`, `uploadFile`, `uploadMetadataJsonl`, `addAssets`, `updateDescription`, `delete` | Active |
| Signed upload | `videoUpload`, `videoUploadBulk` | Active; signed single is default |
| Indexes | `jobsList`, `createIndex`, `indexStatus`, `deleteIndex` | Active |
| Admin | `userStats`, `usage`, `cacheStats` | Active; split external/users API bases |
| R2 | `presignUploadFile`, `presignUploadFolderVideo` | Active users API routes |
| Images | `getUrl`, `getUrlBulk`, `getImageFromUrl`, `getImageBulkFromUrls` | Active image routes |
| Multipart | explicit `VideoUploadOptions(multipart: true)` | Experimental; never selected by size |
| GDrive/SQL/auto-index/folder scan | compatibility methods | Disabled before transport |
| Google Drive collection upload | no public method | Mounted upstream but deprecated by SDK contract |

Every operation uses the centralized `Routes`, `VmodalHttp`, bounded response
reader, retry classifier, and cancellation token. Gateway payload serializers
remove caller identity; only unsafe direct mode may emit trusted identity fields.

Android regression groups map to Flutter suites as follows: configuration/routes
and credentials (`config_routes_test`, `auth_http_test`), transport/bounds and
cancellation (`transport_test`), resources/models (`resources_models_test`),
signed/bulk upload (`upload_test`), multipart/checkpoint (`multipart_upload_test`),
adaptive vectors (`adaptive_upload_test`), and release/tooling
(`shell_scripts_test`, `workflow_layout_test`).

