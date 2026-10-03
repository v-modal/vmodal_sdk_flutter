# Developer-backend authentication

Start with [Choose authentication](authentication.md) for the direct and scoped
quickstarts. This guide specifies the server handoff, connection lifecycle,
permissions and acceptance checks for a developer-backend scoped connection.

## Who owns each boundary

```mermaid
sequenceDiagram
    participant App as Host app / Flutter SDK
    participant Dev as Developer backend
    participant VM as VModal origin and edge
    participant Search as Search / media service
    App->>Dev: Authenticated request for VModal session
    Dev->>Dev: Verify current host identity and resolve policy
    Dev->>VM: Scoped issuance with registered server API key
    VM->>VM: Check principal/project ceiling and sign token
    VM-->>Dev: Short-lived version-1 envelope
    Dev-->>App: Envelope unchanged; no master key
    App->>VM: Scoped bearer to /auth/me
    VM-->>App: Verified identity and canonical grants
    App->>VM: Search/discovery/media with scoped bearer
    VM->>Search: Principal routing and trusted delegated context
    Search->>Search: Authorize exact resource before result or side effect
    Search-->>App: Authorized result through gateway
```

The SDK checks contracts and fences stale local work. Server signature,
registration and resource checks authorize requests even if a caller changes
the Flutter app or uses raw HTTP. The developer backend authorizes its own
app users within a delegation ceiling registered with VModal. VModal does not
query or replicate the developer's user directory.

## Implement your session endpoint

Your backend chooses its route and authentication mechanism. The independent
[Node handler reference](../example/06_userlogin_backend_auth/developer_backend/session.mjs)
uses `POST /vmodal/session` with `{}` and mandatory injected identity/policy
adapters. Mount the equivalent handler in your existing backend stack.

For every acquisition and renewal:

1. Verify the current host token or cookie session and derive `app_user_id`.
2. Load enabled access, exact grants and a stable `policy_revision` from your
   policy store. Project and server credential come from server configuration.
3. Send the request below using the registered server-side `ak_...` credential.
4. Return the successful VModal envelope unchanged with `Cache-Control: no-store`.
5. Return classified safe errors; do not return a master-key fallback.

```http
POST /api/v1/auth/scoped-token
Authorization: Bearer <registered developer-server ak_ credential>
Content-Type: application/json

{
  "version": 1,
  "project_id": "framebase",
  "app_user_id": "verified_app_subject",
  "policy_revision": "policy_42",
  "expires_in": 300,
  "grants": [
    {
      "grant_id": "my_library",
      "collection_id": "library_a7f9",
      "stream_name": "street_study",
      "mode": "vid_file",
      "actions": ["discover", "search", "media"],
      "collection_wide": false
    }
  ]
}
```

The public issuance endpoint belongs to users_api; it is not a search route.
An ordinary runtime key cannot issue scoped tokens without explicit registered
issuance authority. A scoped token cannot issue child tokens. Do not send a host
identity token, refresh token, password, caller-selected principal or tenant to
this endpoint.

Use an opaque stable host subject, unique within the registered project. The
phone's expected subject is a consistency check; the backend must derive the
authorizing subject itself. Recheck identity and policy at every renewal,
including after host login changes. A previous VModal token is not proof that
the host session is still valid.

## Envelope contract

`ScopedTokenEnvelope.fromJson` parses this separate version-1 contract:

| Field | Meaning |
| --- | --- |
| `version`, `auth_mode`, `token_type` | `1`, `developer_backend`, `Bearer` |
| `access_token` | VModal-issued compact JWT, at most 8192 characters |
| `issued_at`, `expires_at` | UTC RFC 3339 timestamps ending in `Z` |
| `expires_in` | Original issuance lifetime, 60–900 seconds; default server request is 300 |
| `principal_id` | VModal owner resolved from the registered server key; storage and billing owner |
| `tenant_id` | Provisioned delegation tenant; never inferred from app UID |
| `project_id` | Registered developer integration |
| `app_user_id` | Backend-verified opaque app subject |
| `policy_revision` | Host version of this user's complete effective policy |
| `delegation_revision` | Monotonic VModal registration revision |
| `grants` | One to sixteen exact canonical grants |

The parser rejects unsupported versions, unknown fields, wrong scalar types,
invalid times, duplicate grant IDs/selector tuples, empty or unknown actions,
and unusable credentials. Parsed values are immutable and string formatting
redacts the bearer. Do not calculate expiry as “received now + expires_in”;
network time does not extend a token's lifetime. Use `expires_at`.

The JWT uses RS256, type `vmodal-scoped+jwt`, a configured `kid`, environment
issuer and audience `vmodal:search-api`. VModal retains the private key. Its
signature/time/schema/registration checks are independent of any identity
provider's JWT policy. JWT issuer, audience and expiration semantics follow
[RFC 7519](https://www.rfc-editor.org/rfc/rfc7519); separate token types and
explicit algorithm/issuer checks follow
[RFC 8725](https://www.rfc-editor.org/rfc/rfc8725). The particular VModal
algorithm, grants and lifetime limits are this service's product contract.

The envelope is not Framebase's legacy mock `api_token`/`firebase_uid`
response. Do not adapt that mock by renaming fields or presume its tenant-wide
key becomes scoped. The preserved example documents a different auth pattern.

## Exact grants and discovery

`grant_id` is a stable developer label used by `backend.scope('my_library')`.
`collection_id` is the exact backend selector serialized as `group_name`, not
an asset-association database ID. Stream and mode remain exact and
case-sensitive. A logical project prefix or a user ID never adds authority.

Each request must satisfy one complete grant. Action permission from one grant
cannot combine with collection/stream authority from another. Wildcards are
not accepted. `collection_wide: true` explicitly permits actions across the
collection/mode; it does not change the operation's default stream.

| Action | Scope behavior |
| --- | --- |
| `discover` | List allowed collections/streams; withhold inaccessible aggregates and versions |
| `search` | Require or safely narrow exact collection, stream and mode; restrict alternative sources |
| `media` | Resolve canonical ownership before bytes or URL issuance; validate every bulk member |
| `indexation` | Job/index discovery and creation require handler ownership enforcement before enablement |
| `upload`, `metadata` | Every upload side protocol or referenced asset must be authorized before enablement |
| `delete` | Requires explicit collection-wide authority and existing confirmation semantics before enablement |

The initial deployment supports a defined read-route allowlist and rejects
unsupported scoped actions at issuance. Direct credentials retain their existing
resource contract. Do not add a write action to a mobile envelope to enable it.
Generic forwarding, admin and raw storage-credential routes are denied to scoped
tokens regardless of the action strings.

Scoped job, media or asset routes with only an ID must resolve canonical
principal/collection/stream/mode ownership; principal membership alone is
insufficient. Explicit scope denial returns `403`. A missing or inaccessible
selector-less resource returns non-enumerating `404`. Bulk operations validate
all members before returning protected results or mutating data.

## Connect and own the connection

```dart
final connection = await VModal.connectWithBackend(
  expectedAppUserId: hostUser.id,
  expectedProjectId: 'framebase',
  loadToken: loadCurrentHostVmodalEnvelope,
  // baseUri: configuredPublicGatewayUri,
  timeout: const Duration(seconds: 30),
  refreshLeeway: const Duration(seconds: 60),
);
```

`initialToken` can seed a previously fetched envelope, but `loadToken` remains
required for renewal. Seeded and callback credentials undergo the same expected
identity, expiry and `/auth/me` checks. A candidate is not installed until the
gateway confirms principal, tenant, project, app subject, revisions and exact
grants. An older gateway that only understands API keys fails activation.

The connection reuses `UserSession` and `UserScope`. It does not expose an
unrestricted tenant client or duplicate search/upload implementations. Existing
feature controllers that accept `UserScope` can use the returned scope.

| API | Responsibility |
| --- | --- |
| `session` | Current active guarded session; invalid access fails |
| `scope(grantId)` | Select exact frozen mapping; unknown ID fails locally |
| `refresh()` | Explicit credential renewal, coalesced with an active renewal |
| `state`, `states` | Current lifecycle and token-free state events |
| `close()` | Immediate local invalidation followed by idempotent cleanup |

Subscribe to states in the connection owner, and cancel the subscription with
that owner. App resume can call `refresh()` when appropriate; request-time
expiry checks remain authoritative for dispatch. Do not implement another
per-widget token timer or send raw Authorization headers from resources.

## Renewal and failure behavior

Effective proactive leeway is the smaller of configured leeway and half the
issued lifetime. Parallel renewal uses one acquisition. Shared HTTP readiness
checks every gateway request before taking its immutable credential/revision
snapshot, including binary and streaming paths.

A still-valid accepted token may continue during a temporary renewal outage.
An expired or rejected revision cannot dispatch. Candidate validation failures
must not overwrite a valid accepted revision; authoritative identity or policy
rejection invalidates the connection. Acquisition has bounded attempts and a
timeout spanning callback and candidate verification.

| State | Host UI behavior |
| --- | --- |
| `ready` | Use permitted operations |
| `refreshing` | Renewal is in progress; still-valid old credentials may serve work |
| `unavailable` | Show a recoverable connection failure; preserve host login |
| `expired` | Require successful credential renewal before more requests |
| `invalidated` | Retire scopes and UI; resolve identity/policy and reconnect |
| `closed` | Permanently retired; create another connection for a new activation |

| Failure | Action |
| --- | --- |
| Host session `401` | Invalidate VModal connection; host decides how to sign in again |
| Host policy `403` | Invalidate; obtain a fresh authorized setup |
| Temporary backend/issuer failure | Keep a still-valid token; gate after expiry; retry within bounded acquisition policy |
| VModal eligible GET/HEAD `401` | One credential recovery and one eligible read replay; stale denial cannot reject a newer revision |
| VModal POST/mutation `401` | Surface failure; block reuse of failed revision; do not replay automatically |
| VModal `403` | Resource/action denial; no renewal loop or tenant-key fallback |
| VModal `404` | Preserve not-found semantics; no credential refresh |
| Identity/policy/envelope mismatch | Safe contract failure; invalidate or fail activation |

Search is currently a POST. A failed POST search is surfaced even though its
business intent is a read; the host may deliberately resubmit after credential
recovery. Unknown mutation completion after a timeout requires reconciliation,
not automatic replay. No scoped failure falls back to a master or tenant key.

Host callback adapters must map HTTP failures to SDK-classified errors; throwing
a generic exception for every response loses identity-versus-outage behavior.
The separate reference explains those classifications. Keep response bodies,
identity tokens and server credentials out of exception messages and logs.

Use the public error contract:

```dart
// These exceptions contain only classification and safe retry metadata.
throw const BackendAuthException(BackendAuthFailure.identityRejected); // 401
throw const BackendAuthException(BackendAuthFailure.accessDenied); // 403
throw BackendAuthException(
  BackendAuthFailure.unavailable, // timeout, 429 or temporary 5xx
  retryAfter: safeRetryAfter,
);
throw const BackendAuthException(BackendAuthFailure.invalidResponse);
```

Do not throw every response as a generic AuthException or expose backend bodies.
The coordinator bounds transient retries and interprets authoritative identity/
policy rejection separately. The
[reference adapter](../example/06_userlogin_backend_auth/lib/backend_auth_example.dart)
maps HTTP status to these classifications.

### Enabled read routes

The initial origin/upstream allowlist is explicit:

| Downstream search route | Required action |
| --- | --- |
| `POST /api/external/v1/search` | `search` |
| `GET /api/external/v1/collection/groups` | `discover` |
| `POST /api/external/v1/image/get_url` | `media` |
| `POST /api/external/v1/image/get_url_bulk` | `media` |
| `POST /api/external/v1/image/get_image` | `media` |
| `POST /api/external/v1/image/get_image_bulk` | `media` |

Flutter uses its existing proxy routes for these operations; developers do not
manually build these downstream URLs. Modes are `img_file`, `vid_file`, and
`vid_stream_day`. Missing search selectors are narrowed only when one complete
grant matches. Empty/aggregate streams and widened metadata queries are denied.
Group discovery withholds collection aggregate versions/modalities/timestamps;
stream-only users cannot infer another stream's metadata. `collectionInfo()`
and `latestVersion()` return null when discovery supplies no exact stream row;
do not interpret absent aggregate data as an empty collection. Audio and ASR
search in `vid_stream_day` are denied because the legacy retrieval path cannot
preserve exact delegated stream ownership. All other data routes
and services are denied for scoped credentials until deliberately enabled.

## Ownership, persistence and revocation

Backend local ownership includes gateway namespace, project, tenant, app subject,
exact scope and policy. The same UID in different projects cannot share archived
content or checkpoints. Token text, expiry and `jti` are excluded from owner
identity so same-policy rotation preserves a live session and handles.

Changed grants or revisions require fresh activation even for the same subject.
Close the outgoing connection at the beginning of logout or an account switch;
late acquisition/search/progress/storage results cannot reactivate it. The host
still clears its own rendered state, player and caches.

VModal does not promise fleet-wide immediate per-user logout. A copied scoped
token remains valid until expiry unless its registered delegation is invalidated.
Disabling a registration or incrementing its revision takes effect within the
configured bounded registry distribution window, at most 30 seconds under the
deployment contract. Host policy revisions are checked on new issuance; changing
one does not remotely revoke an already issued token.

Standalone signed URLs and server jobs have separate lifetimes. Scope-check new
capability issuance and cap its lifetime to the bearer where supported; do not
claim closing a local connection cancels a server job or immediately revokes an
already issued storage capability.

## Deployment and acceptance

Keep delegation disabled until the complete chain is deployed and checked:

1. Provision authoritative principal-owned resource metadata and exact registered
   project ceiling, tenant, server-key fingerprint and lifetime/revision policy.
2. Configure signing and verification keys on users_api and the separate VModal
   verification policy on the Worker. Preserve old verification keys through the
   expiry of the last token using their `kid`.
3. Deploy upstream canonical scope checks and gateway default-deny route coverage.
4. Verify registration freshness/distribution in every origin process. Missing
   or stale registry/key dependencies deny scoped access and preserve direct auth.
5. Run direct regression and a dedicated registered-project smoke through the
   real public edge → origin → upstream path.
6. Use A's raw bearer to request B's collection, stream, media and bare resource
   IDs; verify `403`/non-enumerating `404` before output or side effects.
7. Check expiry, concurrent renewal, A→B→A fencing, same-policy rotation, changed
   policy, stable subject rate buckets, principal aggregate limits and log fields.
8. Enable the tested project and release a verified immutable SDK artifact.

Rollback disables issuance/registration for scoped access while retaining direct
credentials. Tokens, subject metadata and rate controls must continue using the
principal for billing and home selection; renewals must not reset rate buckets.
Access logs record nullable delegated metadata and a token identifier, never the
bearer or host session token.

Local checks cover lifecycle and contracts; only real public-path acceptance
establishes deployment compatibility. See [release.md](release.md) and the
server's auth/route/storage/release documentation for operational configuration.
