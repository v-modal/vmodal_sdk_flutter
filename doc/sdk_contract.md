# Flutter SDK contract inventory

The route authority is `vmx_avideo/infra/search_api_ui/routers/apionly_routes.py`
plus `apionly_serve_img.py`. The Python SDK defines the cross-SDK wire contract;
the Android SDK defines mobile cancellation, streaming, upload, and key-rotation
behavior. `test/fixtures/routes_contract.json` is the reviewed normalized mirror.

| Resource | Public Flutter operations | Contract status |
|---|---|---|
| App-user sessions | `UserSessionManager`, `UserSession`, `UserScope`, `ContentMapping` | Opt-in same-tenant app-user isolation; gateway only |
| Scoped facade | `VModal.configure`, `VModal.fromClient`, `VModalProject.scope`, `listCollections`, `close` | Compatible tenant-scoped API; bypasses session guarantees |
| Scoped operations | `upload`, `uploadMetadata`, `search`, `addAssets`, `updateAsset`, index lifecycle, collection deletion | Immutable organization; delegates to resources |
| Client/auth | `health`, `authCheck`, `auth.me` | Active; gateway bearer only |
| Searches | `searchVideo(SearchRequest)`, `searchBatch(List<SearchRequest>)` | Active; exact single-search contract and bounded client-side batch scheduling |
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

## App-user session contract

This opt-in interface is implemented in the 1.3.0 source release. Existing
pub.dev `1.2.3` and `v1.2.3` installs retain their earlier API. Source publication
through GitHub Actions does not create a pub.dev release or version tag.

VModal credentials authenticate a tenant principal. A and B can have identical
tenant IDs, API keys, and `auth.me()` responses while remaining different local
app users. The authenticated host resolves each stable `appUserId` and allowed
mapping; `auth.me()` does not supply them. Do not use app-user identity as
`SdkConfig.userId`, a direct-mode header, an API-key-derived cache name, or a
collection typed by the user. No new environment variable represents the user.

`UserSessionManager(config: ..., credentialSource: ...)` owns one active
identity flow. `openUserSession(tenantId: ..., appUserId: ...,
allowedContentMapping: ..., policyRevision: ...)` captures immutable policy.
Use `openResolvedSession(() async => UserSessionPolicy(...))` when identity
and mapping require asynchronous resolution: it invalidates the outgoing
session before invoking the resolver. `current` is null during resolution or
after failure. Only the latest activation ticket can publish a session.

Each activation has a fresh `sessionId`, private provider/client, and distinct
gateway and signed-upload transports. A returned `UserScope` stays attached to
that instance. Opening B, logout, or closing A invalidates A synchronously,
closes its provider, cancels registered work, and detaches internal state before
host invalidation callbacks. Cleanup targets A even if a callback activates B.
Repeated `close()` calls share one cleanup Future. Cleanup errors cannot restore
A's lease; both transport cleanup paths are attempted.

Every supported operation captures inputs and ownership before asynchronous
work. Preparation, retries, gateway sends, signed PUT phases, response chunks,
Future settlement, and upload progress delivery check the same originating
lease. After invalidation, calls fail with cancellation and late payloads are
dropped; the public operation settles even if a custom transport ignores
cancellation. Caller-owned cancellation tokens are never canceled by the SDK.
An upload/index/delete already accepted by the server can continue, but remains
owned by A. Data delivered while A was active cannot be recalled.

These guarantees require all user-data operations to pass through
`UserSession`/`UserScope`. `VmodalClient`, `VModalProject`, raw HTTP, admin/R2
resources, arbitrary URLs, sinks, and direct-mode identity overrides bypass
them. The restricted interface exposes none of those capabilities. A modified
client can use a shared tenant bearer for arbitrary tenant-authorized requests.
Preventing intentional cross-user access requires server-side app-user
authorization independent of tenant authentication and local selector syntax.

### Exact mapping and supported actions

`ContentMapping.logical` reuses the validated `projectId__collectionName`
encoding. `ContentMapping.opaque` uses the exact backend `collectionId` without
prefixing it. Both capture `streamName`, `mode`, an immutable `actions` set,
and `collectionWide` (false by default). `session.scope(mapping)` matches the
representation and all selectors, then uses the session's frozen permitted
actions rather than a caller's replacement grants. Duplicate mappings are
rejected. Local actions are policy guardrails, not server-issued claims.

| API | Required action / ownership |
| --- | --- |
| `session.listCollections()` | `discover`; returns mapped selectors, no raw tenant list or count |
| `scope.collectionInfo()`, `latestVersion()` | `discover`; exact stream row or `collectionWide` required for aggregate versions |
| `scope.search(...)` | `search`; captured exact collection/stream/mode |
| `scope.upload(...)` | `upload`; session-owned upload/checkpoint boundary |
| `scope.addAssets(...)`, `updateAsset(...)`, `uploadMetadata(...)` | `metadata`; every resource must have this live scope's provenance |
| `scope.createIndex()`, `listIndexJobs()`, `indexStatus(...)`, `rebindJob(...)` | `indexation`; live or freshly revalidated scoped job provenance |
| `scope.imageBytes(...)` | `media`; live scoped asset, signed URL retained privately |
| `scope.deleteIndex(...)`, `deleteCollection(...)` | `delete` plus `collectionWide: true`; backend deletion affects the collection |

Stream-only mappings cannot obtain collection-wide index versions from
aggregate discovery. `collectionInfo`/`latestVersion` return null without an
exact stream row. Explicit wider host policy is required to use aggregate
metadata; write permission alone does not imply collection-wide ownership.

### Restricted results and provenance

`SessionSearchResponse` retains typed `videoHits`, allowlisted `data`/`raw`
fields, and an immutable `assets` list of live `SessionAsset` handles. Returned
row counts are recomputed from retained rows. Unknown fields, nested records,
signed URLs, storage credentials, and broader tenant counts are omitted.
Scoped requests supply ownership for results without echoed selectors;
conflicting echoed selectors are rejected/filtered. Discovery job rows must
include exact `group_name`, `stream_name`, and `mode` before minting a handle.
Restricted errors omit raw response bodies, capabilities, and underlying causes.

`addAssets` accepts handles rather than bare IDs; `updateAsset` and `imageBytes`
require a validated basename. Every batch member is checked before dispatch.
`SessionUploadResponse.asset` is nullable when completion provides no usable
identity. Neither filenames nor frame IDs synthesize a canonical asset ID.
Handles from A, another scope, or a closed session are rejected even when IDs
or filenames are equal.

```dart
final job = await scope.createIndex(); // mapping includes indexation
final durable = job.toDurableReference();
final status = await scope.indexStatus(job);
// Persist only jobId/ownerKey/scopeKey/policyRevision in the owner's manifest.
// After a new activation for the same authenticated owner and exact policy:
final rebound = await newScope.rebindJob(durable);
final resumedStatus = await newScope.indexStatus(rebound);
```

`DurableJobReference` is ownership metadata, not an ownership proof. Rebinding
requires exact owner, scope, and policy revision, followed by fresh exact scoped
job discovery (bounded to 1000 rows); a tenant-wide status response alone is
insufficient. Missing/unknown jobs fail closed. No durable asset or raw upload
ID rebinding API is supported. Policy changes require fresh discovery rather
than accepting references under old grants.

`uploadMetadata` accepts bounded UTF-8 JSONL (at most 8 MiB), snapshots its bytes,
and validates every nonempty row before sending. Supported fields are
`filename`, `filename_sanitized`, `asset_id`, `description`, `metadata_text`,
`tags`, and `tag`. Values must be strings or lists of strings. Each row needs a
live scoped `asset_id` or filename; if both are supplied, both must match the
same handle. Both filename aliases must agree. Unknown fields, malformed JSON,
unproven assets, and arbitrary nested metadata fail locally.

### Stable storage ownership

`SessionContext.serviceNamespaceFor(config)` derives the normalized connection
namespace. `ownerKey` canonically encodes service namespace, tenant, and stable
app-user ID. `scopeKey(mapping)` adds representation, exact backend collection,
stream, and mode. Neither key contains API-key bytes, credential revision, or
runtime session identity. The default policy revision fingerprints immutable
selectors/actions/collection-wide grants; the host can supply its trusted
revision explicitly. Any policy change requires a new session.

Uploads always inject an owner/scope-partitioned checkpoint adapter. Lookup
keys wrap the existing upload contract key; envelopes validate owner, scope,
policy, and exact contract before reuse. Credential-only rotation preserves
checkpoints. A new session can resume only after the older writer is fenced and
accepted writes have completed. Logout does not clear another owner's store.
Inject a custom `UploadSessionStore` only through `UserSessionManager`; per-task
stores and custom transcoders are rejected. Only `PassthroughVideoTranscoder`
is supported through this restricted interface.

The shared owner commit coordinator serializes load/save/remove and retires
older writer leases, including A→B→A. Accepted noncancelable store writes finish
in their captured namespace before a later writer can read it. This barrier is
within one isolate. Use one storage-owner isolate or a real transactional
cross-isolate/process lock for shared storage; independent in-memory queues do
not provide that guarantee. Custom stores must preserve atomic storage behavior
and must not perform unbound user-visible side effects.

Host archives can use `scope.storageLease`, a supported `SessionStorageLease`
with `check()`, `run(...)`, `retire()`, and its originating `sessionId`. It
coordinates the captured owner/collection namespace and expires with the
session. Capture immutable file paths/payloads before queueing, execute writes
through `run`, and call `check` immediately before publishing a staged file.
`retire` ends a host writer even if the SDK session remains active; do not reopen
a retired writer under that same session. This adapter does not grant arbitrary
filesystem paths ownership automatically.

Host caches must additionally include current policy and all result-affecting
parameters (version, pagination, query/date filters, media variant). In-flight
deduplication must include `sessionId`. Validate owner metadata and paths on
restore; quarantine legacy data with unknown ownership. Clear or partition
Flutter image caches, player controllers, navigation/restoration, search
history, and copied/downloaded files at identity transitions. The SDK exposes
session invalidation; it cannot manage these host-owned surfaces.

Tenant renewal and bounded read recovery are documented in
[Manage API keys](manage_api_key.md). Implemented block and verification notes
are in [User-session implementation](user_session_implementation.md).

## Typed video-search results

`SearchResponse.videoHits` is an additive typed view of map-shaped entries in
the unchanged `SearchResponse.data` list. It preserves map-entry order, ignores
non-map entries, and retains every original field through `VideoSearchHit.raw`.

| Field | Canonical wire field | Meaning |
|---|---|---|
| `assetId` | `asset_id` | Nullable stable source-asset identity |
| `fileName` | `file_name` | Nullable normalized basename for display and legacy lookup |
| `playbackOffsetMs` | `playback_offset_ms` | Nullable elapsed milliseconds from source-video start |
| `distance` | `distance` | Nullable raw lower-is-better distance |
| `previewImageUrl` | `preview_image_url` | Nullable absolute HTTPS or relative signed image route |

Legacy filename/path, seconds, relative-millisecond, `score`/`_distance`, and
image URL aliases remain accepted. Invalid, blank, negative, non-finite, and
epoch-like playback values become null rather than throwing. `score_ui`,
similarity, and confidence are not distance and are never transformed into it.
Missing `asset_id` is never synthesized from an item ID, filename, path,
stream, or timestamp. `VideoUploadResponse.assetId` follows the same
canonical-only identity rule, allowing applications to persist upload identity
and reconnect later search hits without weakening legacy compatibility.

## CCTV timestamp and metadata contract

`VideoUploadOptions` carries `videoFilename`, `metadataText`, repeated
`metadataTags`, `startDatetimeUser`, and `reProcess` through signed single,
multipart, completed-resume, bulk, and transcoded uploads. A timestamp without
an explicit public filename derives the original source filename; a generated
transcode filename never becomes the public CCTV name. Multiple bulk sources
cannot share one explicit public filename.

`startDatetimeUser` must include `Z` or an explicit UTC offset. Flutter sends
the value unchanged and never calculates `start_ts_unix_user_ms`; the backend
returns that canonical integer together with the normalized datetime and
`timestamp_source`. Null optional values are omitted, `metadataText: ''` is an
explicit empty value, and each metadata tag is a separate query or multipart
field. `re_process` is always sent on signed finalization.

Direct `uploadFile` supports the same additive fields while retaining legacy
`description` and repeated `tag`. Search uses `queryMetadataText` as the string
`query_metadata` value. The legacy `queryMetadata` map remains temporarily
available but cannot be combined with the string form. For `vid_file`, date
bounds must be paired; start is inclusive, end is exclusive, date-only values
are allowed, and datetime values require `Z` or an explicit offset.

Android regression groups map to Flutter suites as follows: configuration/routes
and credentials (`config_routes_test`, `auth_http_test`), transport/bounds and
cancellation (`transport_test`), resources/models (`resources_models_test`),
signed/bulk upload (`upload_test`), multipart/checkpoint (`multipart_upload_test`),
adaptive vectors (`adaptive_upload_test`), and release/tooling
(`shell_scripts_test`, `workflow_layout_test`).
