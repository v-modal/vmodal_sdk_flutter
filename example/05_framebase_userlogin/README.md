# Framebase user library

This Flutter example connects host sign-in, an exact opaque library mapping,
and the SDK's opt-in `UserSessionManager`. Two app users can share the same
tenant API key and VModal principal while keeping separate sessions, archives,
search results, and pending work. The host's authenticated adapter supplies the
stable Firebase UID; `auth.me()` verifies only the tenant principal.

## Screenshots

| Video library | Search results | Playback at a match |
| --- | --- | --- |
| ![Three street videos in the Framebase library](readme_assets/library.png) | ![Matching frames grouped by source video](readme_assets/search.png) | ![Local video opened at the matching timestamp](readme_assets/playback.png) |

The unconfigured offline app opens on **Sign in to your street library**.

## Run the offline example

From `uinterface/sdk_flutter`:

```bash
bash install.sh install
cd example/05_framebase_userlogin
flutter_bin="$(bash ../../install.sh flutter_bin)"
"$flutter_bin" pub get
"$flutter_bin" run --device-id DEVICE_ID
```

`MockFirebaseAuth` defaults to no accounts, and the mock credential source has
no usable key. Inject fake accounts and queued `VmodalCredential` responses as
the tests do to exercise the library. Fixture keys are placeholders. Production
requires a real Firebase adapter and trusted issuer; this example contains no
Firebase token verifier or app-user-scoped server authorization service.

## 1. Authenticate the app user

The auth adapter resolves the signed-in user and supplies a Firebase ID token.
The trusted issuer must verify that token server-side, derive its UID, and
return the user's exact allowed mapping. User-entered collections, email
addresses, and unverified decoded tokens never establish ownership.

The version-1 example envelope is:

```json
{
  "version": 1,
  "session_id": "<opaque issuer session identifier>",
  "issued_at": "2030-01-01T00:00:00Z",
  "expires_at": "2030-01-01T00:05:00Z",
  "api_token": "<tenant VMODAL bearer>",
  "firebase_uid": "<verified Firebase subject>",
  "vmodal_user_id": "<tenant auth.me user_id>",
  "tenant_id": "<stable tenant identifier>",
  "scope_id": "<exact opaque backend collection identifier>",
  "allowed": true,
  "permissions": ["library:read", "library:write"],
  "collection_wide": true
}
```

`tenant_id` is optional for older version-1 responses; its compatibility
fallback is `vmodal_user_id`. Neither identifies the app user. `session_id` is
an issuer value and can rotate; the SDK generates its own fresh runtime
`sessionId` for each activation. `issued_at`/`expires_at` must be valid UTC
times with issuance before expiry. `collection_wide` defaults to false; a
write permission alone does not grant collection deletion or aggregate metadata.

`UserSessionController` validates the authenticated UID, expiry, allowed flag,
and read permission. It constructs `TenantCredentialSource` with the normalized
service namespace and tenant/principal binding, then opens a SDK session with
the Firebase UID as `appUserId`. `SearchGateway.connect()` uses
`session.verifyPrincipal(...)` for the optional tenant-principal check.

## 2. Discover collections and indexing work

`scope_id` stays unchanged as backend `group_name`; the app never prefixes it
with a project or appends a UID. The example validates a nonempty
`[A-Za-z0-9_]+` selector of at most 80 characters, then uses
`ContentMapping.opaque(collectionId: scopeId, streamName: 'street_study', ...)`.
Syntax is a local contract check, not server authorization.

Read policy maps to `discover`, `search`, and `media`; write policy additionally
maps to `upload`, `metadata`, and `indexation`. `delete` requires explicit
collection-wide access and write permission. All requests use the frozen exact
collection, stream, and mode. Collection and job discovery return restricted
results. Job handles are minted only from scoped submission or discovery rows
with exact collection/stream/mode provenance.

Collection-wide index versions can be used only with `collection_wide: true`
or a discovery row naming the exact stream. A stream-only mapping whose service
returns only aggregate collection metadata cannot obtain that version; setup
fails closed instead of widening access. Hosts must supply a legitimately
collection-wide policy or a supported stream-specific discovery contract.

## 3. Upload, index, search, and playback

Choose **Prepare videos for search** to upload clips not already marked uploaded,
submit an image-index job, and poll its live `SessionJob`. Existing pending job
records are rebound only after exact owner/scope/policy validation and fresh
scoped discovery; a bare tenant-wide job status lookup is insufficient.

Search uses `UserScope.search` and its allowlisted `SessionSearchResponse`.
Matching frames use live `SessionAsset` handles and `scope.imageBytes(...)`;
signed URLs and arbitrary media sinks are not exposed. Tapping a result plays
the owner's local MP4 at the returned offset. The host clears images/player
controllers and checks view generations during account changes.

Canonical server `asset_id` reconnects a hit to an `ArchiveClip`. Filename
matching is only a compatibility fallback when either side lacks canonical
identity; different non-null IDs never match by filename alone. The SDK never
invents an asset ID from a frame, timestamp, filename, or path.

Skipping uploaded manifest rows avoids ordinary repeats, but is not once-only
upload behavior. Ambiguous upload failures retain unknown completion. Robust
retry or cross-device deduplication needs a scope-bound server idempotency
contract synchronized with the Python reference SDK; filenames, hashes,
`sourceId`, ETags, and checkpoint keys are not undocumented authorization or
deduplication contracts.

## 4. Rotation, account changes, and host state

Same-tenant credential-only refresh installs through `TenantCredentialSource`
and preserves the SDK session, app user, owner namespace, and policy. Shared
renewal uses accepted revisions/tickets; late results cannot overwrite a newer
key or reopen a closed A provider. Changed scope, actions, or collection-wide
policy invalidate and rebuild the app-user session. Changed tenant/principal
requires a fresh correctly bound source and session.

Typed temporary issuer failures use bounded retries. Exhaustion gates operations
until manual recovery. A tenant `401` becomes a connection-recovery state while
retaining the authenticated Firebase UID and owner context; it does not become
app-user logout. Denied policy, invalid identity, or expired Firebase identity
deactivate user-data state. No write is replayed merely because a key rotated.

Account switch/logout invalidate the outgoing SDK session before asynchronous
cleanup. A→B→A creates three distinct runtime identities even with the same
tenant key. Late A search/progress/errors cannot update B, and delayed A cleanup
targets only A's resources. Closing the session is idempotent.

When the app is paused/hidden/detached it cancels active upload/local index wait
and invalidates the search view. A brief inactive interruption does not cancel
work. Resume does not replay mutations or searches. An already accepted server
job can continue; explicit **Resume** revalidates its owner-bound reference.

## 5. Owner storage, sign-out, and deletion

Local archives are partitioned under application support:

```text
accounts/<sha256(serviceNamespace)>/<sha256(tenantId)>/<sha256(appUserId)>/<sha256(scopeId)>/
```

The manifest records exact service/tenant/app-user/scope/representation/stream/
mode/policy metadata. Restore compares that ownership envelope and validates
paths remain within the selected directory. Policy mismatch and legacy
`accounts/<scope_id>/` data are not restored. Before identity resolution, no
private archive is shown. Tenant key rotation does not change the directory.

Archive commits use the scope's `SessionStorageLease`, shared by owner/scope
within one isolate. Writer retirement and serialized commits fence old A writes
before a newer A reads/writes the namespace. Captured immutable destinations
and atomic replacement prevent partial manifests. Use one storage-owner isolate
or a real transactional lock when multiple isolates/processes share storage.

`archive.json` contains allowlisted media/work records, remote asset identity,
pending job metadata, and bounded events. API keys, credential envelopes,
signed URLs, search responses, and downloaded frame images are not persisted.
This example adds no secure-storage/shared-preferences credential cache.

**Sign out** clears in-memory session resources and hides the library while
preserving owner-local files. Returning as the same verified owner with the
same policy can restore them. Local storage remains until explicit removal,
uninstall, or platform cleanup. Removing an imported device MP4 keeps a
cloud-only row if the clip was uploaded; cloud content remains searchable.

| Domain | Explicit action | Result |
| --- | --- | --- |
| Device MP4 and manifest | Remove device copy | Removes the local copy; uploaded cloud identity remains |
| Cloud video, metadata, derived indexes | Delete cloud library | Deletes the entire collection; local MP4s remain |

Cloud deletion requires `collection_wide` and write access, previews with
`dry_run: true`, and commits only after a second confirmation using
`dry_run: false, confirm: true`. It calls collection deletion with `scope: all`
and does not issue a second index-delete call. No individual remote-video
deletion API is available. Commits are never automatically replayed: `409`
requires waiting, and unknown network outcomes preserve conservative state.
Cloud success plus a failed local manifest update is reported separately.

## SDK isolation and server authorization

The supported SDK/app flow isolates A and B using stable host identity, exact
mapping, runtime leases, provenance, and owner storage. Low-level
`VmodalClient`/`VModalProject` or arbitrary HTTP bypass that guarantee. A
modified client holding the shared tenant key can access anything that tenant
bearer authorizes. Local checks and `auth.me()` cannot prevent it.

Server protection requires independent app-user authorization: verify the host
identity, authorize every collection/stream/action, filter discovery, and check
selector-less jobs/assets/media/upload resources. Only deployments that actually
bind an app-user identity to requests can expect A's raw request for B's resource
to return `403` or a non-enumerating `404`. This same-key example and its offline
tests demonstrate SDK isolation, not those server authorization guarantees.

See [the SDK contract](https://github.com/v-modal/vmodal_sdk_flutter/blob/main/doc/sdk_contract.md)
and [tenant key management](https://github.com/v-modal/vmodal_sdk_flutter/blob/main/doc/manage_api_key.md).

## Code map and verification

| File | Responsibility |
| --- | --- |
| [`lib/user/auth_adapter.dart`](lib/user/auth_adapter.dart) | Host app-user identity |
| [`lib/user/vmodal_credential.dart`](lib/user/vmodal_credential.dart) | Trusted envelope contract and mock source |
| [`lib/user/library_scope.dart`](lib/user/library_scope.dart) | Opaque selector syntax |
| [`lib/user/user_session_controller.dart`](lib/user/user_session_controller.dart) | Session lifecycle, policy, tenant recovery |
| [`lib/data/search_gateway.dart`](lib/data/search_gateway.dart) | Session-bound operations and safe media |
| [`lib/data/archive_controller.dart`](lib/data/archive_controller.dart) | Owner manifests and storage commits |
| [`lib/main.dart`](lib/main.dart) | Sign-in, library views, and host UI cleanup |

From `example/05_framebase_userlogin`:

```bash
flutter_bin="$(bash ../../install.sh flutter_bin)"
"$flutter_bin" pub get
"$(bash ../../install.sh dart_bin)" format --output=none --set-exit-if-changed lib test
"$flutter_bin" analyze
"$flutter_bin" test
```

Run the SDK-wide offline gate with `bash test.sh all` from the SDK root.
Same-key tests cover account switches, late work, tenant rotation, owner archive
separation, and storage fencing. Live service authorization is a separate check.
Bundled footage/license details are in [MEDIA_SOURCES.md](MEDIA_SOURCES.md).
