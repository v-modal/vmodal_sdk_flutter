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

### User-auth components and responsibilities

There are two authentication contexts. Firebase identifies the person using
the app; the VModal bearer identifies the tenant principal making cloud calls.
The trusted issuer connects the verified person to an allowed library policy.
For example, Firebase users A and B can receive the same `api_token` and
`vmodal_user_id`, but different `firebase_uid` and `scope_id` values. Their
SDK sessions and local archives remain separate.

| Component | Owner / location | Responsibility |
| --- | --- | --- |
| `FirebaseAuthAdapter` | Host app; [auth_adapter.dart](lib/user/auth_adapter.dart) | Implements `signIn`, `signOut`, nullable `users` events, and `idToken(AppUser)`. Translates token-acquisition failures into `FirebaseIdentityExpired` or `FirebaseIdentityTransient`. |
| Trusted issuer / policy resolver | Host backend; production integration required | Verifies the Firebase token, derives the authenticated UID, authorizes library access, and returns the bound tenant credential, exact scope, permissions, and expiry. It is the authority for the envelope. |
| `VmodalCredentialSource` | Host issuer client; [vmodal_credential.dart](lib/user/vmodal_credential.dart) | Implements `acquire(AppUser, String? firebaseIdToken)` against the trusted issuer and classifies identity rejection, policy denial, temporary failure, and invalid responses. This example supplies a mock implementation. |
| `VmodalCredential` | App contract model; same file | Parses the version-1 envelope and validates UID agreement, required fields, scope syntax, permission, expiry, and tenant/principal continuity during renewal. These local checks do not verify a Firebase token or establish server authorization. |
| `UserSessionController` | App orchestration; [user_session_controller.dart](lib/user/user_session_controller.dart) | Subscribes to identity changes, retires outgoing data state, acquires and validates credentials, builds SDK policy, connects the library, and exposes readiness/failure state to the UI. Owns renewal scheduling, bounded issuer retries, and activation-generation checks. |
| `TenantCredentialSource` | SDK; [api_key_provider.dart](../../lib/src/api_key_provider.dart) | Coordinates accepted tenant-key revisions and renewal across live session providers. Checks service/tenant/principal binding and fences stale renewal results. It supplies credentials to transport; it does not sign in the app user. |
| `UserSessionManager`, `UserSession`, `UserScope` | SDK; [user_session.dart](../../lib/src/user_session.dart) | Freeze the resolved app-user identity and content policy, create a fresh runtime session, and guard requests, callbacks, handles, and storage leases against invalidation. |
| `SearchGateway` | App cloud adapter; [search_gateway.dart](lib/data/search_gateway.dart) | Wraps session-bound library operations, calls the host freshness callback, verifies the tenant principal during `connect`, and reports `401`/`403` to the controller. This Dart class is distinct from the remote VModal gateway. |
| `ArchiveController` | App storage; [archive_controller.dart](lib/data/archive_controller.dart) | Activates only the resolved owner's archive, validates persisted ownership/policy, commits through the scope's storage lease, and retires local work when deactivated. |
| `FramebaseApp` and its views | App UI; [main.dart](lib/main.dart) | Display sign-in/recovery/denial states, clear decoded image caches on runtime-session changes, replace navigation state, and fence dialogs, playback, and asynchronous view updates. |

`VmodalCredentialSource` and `TenantCredentialSource` are separate objects.
The first retrieves the host envelope; the second manages the accepted VModal
key inside the SDK. Neither replaces the host identity provider. The remote
VModal gateway verifies the tenant bearer and routes cloud calls; `auth.me()`
reports that principal rather than the Firebase user.

Email/password belong to the host sign-in flow. The Firebase ID token goes
to the issuer client, while SDK gateway calls use the tenant VModal bearer.
`auth.me()` does not exchange a Firebase token, and neither issuer nor runtime
session IDs are bearer credentials. Credentials remain in memory and are
excluded from the owner archive.

### Activation handoff

1. The UI calls `UserSessionController.signIn`. The auth adapter performs
   sign-in and emits the resulting `AppUser` through `users`.
2. On an identity change, the controller advances its generation, invalidates
   the outgoing SDK session, and deactivates the archive before awaiting new
   credentials. A null user leaves the app signed out.
3. The controller obtains `auth.idToken(user)`, calls
   `credentials.acquire(user, token)`, and validates the returned envelope
   against that same user and the current clock. Late results from an older
   generation cannot activate a library.
4. The controller configures the tenant source and opens a SDK session using
   the verified UID as `appUserId`. It converts issuer permissions into a
   frozen opaque mapping for the exact `scope_id` and `street_study` stream.
5. `SearchGateway.connect(vmodal_user_id)` verifies the tenant principal and
   discovers usable index metadata and, when permitted, jobs. The archive
   then activates with the SDK's service/tenant/app-user/policy context.
6. Only after connection and archive activation complete does the controller
   publish `SessionState.ready`. UI read/write controls also check the
   envelope's corresponding permission.

The issuer's `session_id` identifies its envelope. The SDK's `sessionId`
identifies one runtime activation, while the controller's generation fences
its own asynchronous work. Stable Firebase UID and owner keys identify
persisted data. These values serve different lifecycle responsibilities.

### Expiry, failures, and sign-out ownership

The controller schedules renewal 60 seconds before envelope expiry, and
`SearchGateway` checks `ensureFresh()` before cloud operations. A renewal
acquires a current Firebase token and a fresh issuer envelope. An unchanged
policy installs through the tenant source; a changed scope or permission set
retires the outgoing session and resolves a new one.

| Event | Controller behavior | Integration responsibility |
| --- | --- | --- |
| Temporary Firebase token or issuer failure | Up to three acquisition attempts, with 250 ms and 500 ms backoff; exhaustion enters `recoverable` and gates operations | Adapter/source must use the typed transient exceptions; UI offers `retry()` |
| Rejected or expired Firebase identity | Deactivates private data and enters `error` with `firebaseIdentityExpired` | Host requires fresh sign-in; tenant-key rotation cannot repair app identity |
| Issuer policy denial or VModal `403` | Deactivates private data and enters `denied` | Host resolves authorization with the issuer; a broader key is not a fallback |
| Invalid envelope, UID mismatch, or invalid connection contract | Deactivates private data and enters `error` with `contract` | Correct the adapter/issuer contract before allowing library activation |
| VModal `401` / tenant-auth failure | Enters tenant-connection recovery while retaining the authenticated Firebase UID; retry renews an established connection or resolves a fresh one | Keep tenant recovery separate from Firebase sign-out; mutations are not automatically replayed |
| Explicit sign-out | Retires SDK/archive state and publishes `signedOut` before awaiting `auth.signOut()` | Auth adapter ends host sign-in; UI clears visible state; owner-local files remain available for later verified restoration |

### Connecting production user auth

The default app constructs `MockFirebaseAuth` and
`MockVmodalCredentialSource`. The auth mock returns no ID token and performs
no real password verification; the credential mock only returns queued
fixtures. Mock success demonstrates the local flow, not verified identity.

Implement the two host interfaces, then inject them into
`UserSessionController(auth: ..., credentials: ..., archive: ...)` and pass
that controller to `FramebaseApp(session: ..., controller: ...)`, using the
same archive instance. A production credential source must require a usable
host token and obtain the envelope from the trusted issuer; an arbitrary
caller-supplied UID is not identity proof. No production issuer URL, Firebase
configuration, or server verifier is supplied by this example.

When the embedding host supplies these controllers, it owns their disposal;
`FramebaseApp` disposes only instances it creates itself. The session
controller's `dispose()` retires SDK state, closes the tenant coordinator,
cancels its auth subscription, and closes the auth adapter. The host must
also dispose its archive controller.

See [component coupling diagrams](../../docs/diagrams.md),
[the session contract](../../docs/sdk_contract.md), and
[tenant credential management](../../docs/manage_api_key.md) for the SDK
boundaries. Server enforcement requirements are described below under
[SDK isolation and server authorization](#sdk-isolation-and-server-authorization).

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

See [the SDK contract](../../docs/sdk_contract.md)
and [tenant key management](../../docs/manage_api_key.md).

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
