# Flutter component couplings

These diagrams describe the gateway-mode SDK and its opt-in app-user session
API in the 1.3.0 source interface. The host app owns sign-in, trusted identity
and policy resolution, and visible UI state. The SDK owns session guards,
resource operations, transport, and tenant credential coordination.

## Dual authentication and the server authority boundary

The numbered tenant-session sequences below remain the direct-key pattern.
Backend-scoped mode adds a separate credential source while reusing guarded
session operations. Both use the same public gateway. See
[authentication.md](authentication.md) and
[backend_authentication.md](backend_authentication.md).

```mermaid
flowchart LR
  Host["Host identity and policy"] --> Dev["Developer backend"]
  Dev -->|"Registered server credential + exact user grants"| Issuer["VModal issuer / delegation ceiling"]
  Issuer -->|"Short-lived signed envelope"| Dev
  Dev -->|"Authenticated host callback"| Connection["BackendConnection"]
  Connection --> Source["Scoped readiness / renewal coordinator"]
  Connection --> Session["Existing UserSession / UserScope"]
  Source -->|"Candidate auth/me verification"| Gateway["Public edge and origin"]
  Session --> HTTP["Shared guarded HTTP"]
  Source -->|"Immutable accepted revision"| HTTP
  Direct["Direct ApiKeyProvider / tenant source"] --> HTTP
  HTTP -->|"Bearer credential"| Gateway
  Gateway -->|"Storage principal + trusted signed scope"| Search["Canonical resource authorization"]
```

The storage principal determines home selection, billing and aggregate quota.
App subject/project determine delegated ownership and a stable rate bucket.
Grant labels select exact collection/stream/mode and never manufacture authority.
Upstream handlers enforce complete grants even for raw HTTP clients.

```mermaid
stateDiagram-v2
  [*] --> ready: acquire, validate binding, confirm auth/me
  ready --> refreshing: renewal window or explicit refresh
  refreshing --> ready: same identity and policy verified
  refreshing --> unavailable: temporary acquisition failure
  unavailable --> refreshing: retry acquisition
  ready --> expired: expiry gates dispatch
  unavailable --> expired: accepted token expires
  expired --> refreshing: new acquisition
  ready --> invalidated: changed policy or rejected identity
  refreshing --> invalidated: binding or policy mismatch
  invalidated --> closed: close and reconnect separately
  ready --> closed: logout / account switch
  refreshing --> closed: invalidate before awaiting cleanup
  unavailable --> closed: host closes connection
  expired --> closed: host closes connection
```

State is observable behavior, not a host login state machine. A still-valid old
revision can serve independent requests during transient renewal failure;
expired/rejected revisions cannot dispatch. Closing fences late renewal and
search/progress/storage completions. Same-policy rotation preserves owner keys;
new project/user/policy requires a fresh session. Already issued remote jobs or
signed capabilities retain their independently documented lifetime.

## 1. App, user auth, VModal auth, and SDK layers

```mermaid
flowchart TB
  User["App user"] --> UI

  subgraph App["App layer - Flutter host"]
    UI["Screens, navigation, players"]
    Controller["App session controller"]
    HostStore["Owner archives and UI caches"]
    UI --> Controller
    Controller --> HostStore
  end

  subgraph HostAuth["User auth - host integration"]
    Identity["Firebase, Clerk, or another identity provider"]
    Issuer["Trusted host issuer / policy resolver"]
    Identity -->|"Verified app identity at issuer"| Issuer
  end

  subgraph SDK["SDK layer - vmodal_sdk_flutter"]
    Manager["UserSessionManager"]
    Session["UserSession + immutable SessionContext"]
    Scope["UserScope + ContentMapping"]
    Credentials["TenantCredentialSource"]
    Client["Private VmodalClient and resources"]
    HTTP["VmodalHttp + Routes + guarded transports"]
    Manager --> Session
    Session --> Scope
    Scope --> Client
    Credentials -->|"Session-bound API-key provider"| Client
    Client --> HTTP
  end

  subgraph Service["VModal service layer"]
    Gateway["users_api - tenant bearer verification and proxy"]
    Backend["Search, collection, index, and media services"]
    Storage["Object storage - signed capabilities"]
    Gateway -->|"Trusted tenant identity and routed request"| Backend
    Backend --> Storage
  end

  Controller -->|"Host sign-in"| Identity
  Controller -->|"Authenticated credential and policy request"| Issuer
  Issuer -->|"Stable appUserId and allowed mappings via host"| Controller
  Controller -->|"Resolved UserSessionPolicy"| Manager
  Issuer -->|"Tenant key and verified binding via host"| Credentials
  Controller -->|"Session-bound operations"| Scope
  Scope -->|"SessionStorageLease for host commits"| HostStore
  HTTP -->|"Authorization: Bearer tenant key"| Gateway
  HTTP -->|"Signed upload bytes; no tenant bearer"| Storage
  Scope -->|"Restricted results and image bytes"| UI
```

The identity provider and issuer are host integrations. The
[Framebase userlogin example](../example/05_framebase_userlogin/README.md) has
mock adapters; a production issuer must verify the host identity and resolve
its authorized content policy. It is not an SDK login endpoint.

| Identity / selector | Supplied by | Meaning |
| --- | --- | --- |
| `appUserId` | Authenticated host | Stable app user; A and B remain different even with one tenant key |
| `tenantId`, expected principal, API key | Trusted tenant issuer | VModal connection binding; `auth.me()` checks the tenant principal |
| `sessionId` | SDK on every activation | Runtime lease for requests, callbacks, and live resource handles |
| `ContentMapping` | Trusted host policy | Exact collection, stream, mode, actions, and collection-wide permission |
| `ownerKey`, `scopeKey`, `policyRevision` | SDK context / trusted policy | Stable storage partition and policy validation |

App-user identity is separate from `SdkConfig.userId`, gateway identity
headers, and collection names. The gateway derives its identity from the
tenant bearer. Under a shared key, local SDK policy does not establish
server-side app-user authorization.

## 2. Sign-in and session activation

```mermaid
sequenceDiagram
  autonumber
  actor User as App user
  participant App as Host app
  participant Auth as Host identity provider
  participant Issuer as Trusted issuer / resolver
  participant Keys as TenantCredentialSource
  participant Manager as UserSessionManager
  participant Session as UserSession
  participant Gateway as VModal users_api

  User->>App: Sign in
  App->>Auth: Authenticate
  Auth-->>App: Stable app identity and host credential
  App->>Issuer: Request tenant credential and content policy
  Issuer->>Auth: Verify host credential / identity
  Auth-->>Issuer: Verified app-user subject
  Issuer-->>App: Tenant binding, key, exact mappings, policy
  App->>Keys: Create source with service / tenant / principal binding
  App->>Manager: openResolvedSession(resolver)
  Manager->>Manager: Invalidate outgoing session before awaiting resolver
  Manager->>App: Invoke policy resolver
  App-->>Manager: UserSessionPolicy from trusted host resolution
  Manager->>Keys: Attach fresh session provider at current revision
  Manager->>Session: Create fresh sessionId, guard, private client / transports
  Manager-->>App: Active session (latest activation ticket only)
  opt Optional tenant-principal verification
    App->>Session: verifyPrincipal(expectedPrincipal)
    Session->>Gateway: auth.me() with tenant bearer
    Gateway-->>Session: Tenant principal profile
    Session-->>App: Expected principal verified
  end
  App->>Session: listCollections(), then scope(allowedMapping)
  Session-->>App: Restricted discovery and immutable UserScope
```

For account changes, begin `openResolvedSession` before asynchronous identity
or mapping resolution. The diagram's first credential acquisition assumes an
initial activation. `openUserSession` is available when the host already has
the verified policy. `auth.me()` verifies neither the app-user ID nor its
allowed mapping.

## 3. Data requests, signed uploads, and media

```mermaid
flowchart LR
  App["App operation"] --> Scope["UserScope - frozen selectors and actions"]
  Scope --> Guard["Capture originating session lease and inputs"]
  Guard --> Resource["Existing SDK resources and upload helpers"]
  Resource --> HTTP["VmodalHttp - credential/header snapshot"]
  HTTP --> Gateway["users_api - verify tenant bearer"]
  Gateway --> Backend["Routed data service"]
  Backend --> Response["Results, job / asset identity, or signed upload grant"]
  Response --> Delivery["Lease check + restricted result / provenance validation"]
  Delivery --> App

  Response -->|"Signed upload grant"| PUT["Guarded signed-upload transport"]
  PUT -->|"PUT bytes with signed grant; no tenant bearer"| Storage["Object storage"]
  Storage -->|"Upload completion"| Finalize["Guarded finalization via gateway resources"]
  Finalize --> HTTP

  App -->|"imageBytes(live SessionAsset)"| Media["Scope validates handle and resolves media privately"]
  Media --> Download["Guarded media download; no tenant bearer on signed URL"]
  Download -->|"Bytes through originating lease"| App
```

Session checks cover preparation, sends, retries, signed phases, response
chunks, completion, and progress callbacks. `SessionAsset` and `SessionJob`
handles belong to the originating live session and scope. Signed URLs remain
private in the restricted interface and have independent expiry. A server
operation already accepted can continue after local cancellation.

The compatible `VModalProject` / `VModalScope` and direct `VmodalClient` APIs
delegate to the same resources but bypass app-user session guarantees. Their
host must manage account cancellation, storage partitioning, and UI cleanup.

## 4. Account switch and logout

```mermaid
sequenceDiagram
  autonumber
  participant App as Host app / view generation
  participant Manager as UserSessionManager
  participant A as Session A and scopes
  participant IO as Pending A work
  participant UI as Images / players / navigation
  participant B as Fresh session B

  App->>Manager: openResolvedSession(resolve B) or logout()
  Manager->>Manager: Advance activation ticket, set current to null
  Manager->>A: Invalidate synchronously
  A->>A: Retire lease, close provider, detach internal state
  A->>IO: Cancel registered work and retire storage writers
  A-->>App: onInvalidated(A)
  App->>UI: Advance view generation and clear A-owned visible state
  IO-->>A: Late A response or progress
  A->>A: Reject delivery under expired lease
  A->>IO: Finish instance-owned transport / storage cleanup
  opt Account switch
    Manager->>App: Resolve B's verified identity and policy
    App-->>Manager: UserSessionPolicy for B
    Manager->>B: Create fresh sessionId, provider, client, and transports
    Manager-->>App: Publish B if activation ticket is still current
    App->>UI: Render B after session / view-generation check
  end
```

A → B → A creates three runtime sessions. Returning to A may reuse validated
owner storage, but cannot reactivate old scopes or handles. Cleanup remains
bound to the outgoing instance even if a callback opens a newer session.
Logout invalidates SDK user data; the host also owns identity-provider sign-out
and cleanup of data already displayed or copied.

## 5. Tenant-key rotation and stable storage ownership

```mermaid
flowchart TB
  Trigger["Trusted replacement or coordinated renewal"] --> Source["TenantCredentialSource"]
  Source --> Validate["Check service / tenant / principal binding,<br/>renewal ticket, accepted revision, issuer version when supplied"]
  Validate --> Commit["Atomically accept credential revision"]
  Commit --> Provider["Update live matching session providers"]
  Provider --> NewRequest["New request captures latest key and revision"]
  OldRequest["Already constructed request"] --> Snapshot["Retains original headers and credential snapshot"]

  Source --> Failure["Renewal failure or revocation: block tenant calls by default"]
  Failure --> Recovery["Host tenant-connection recovery; app-user identity retained"]
  NewRequest --> Denied["401 on eligible active GET / HEAD"]
  Denied --> Once["At most one auth recovery; rebuild headers within attempt budget"]
  Once --> Source

  Context["Stable SessionContext"] --> Owner["ownerKey = service namespace + tenantId + appUserId"]
  Owner --> ScopeKey["scopeKey adds representation + collection + stream + mode"]
  ScopeKey --> Store["Owner / scope storage + policy validation"]
  Store --> Checkpoints["SDK multipart checkpoint envelopes"]
  Store --> Archive["Host archives via SessionStorageLease"]
  Context --> Lifetime["Credential-only rotation preserves sessionId and policy"]
```

Keys and credential revisions are excluded from stable owner/scope keys.
Host cache entries additionally include policy and result-affecting parameters;
in-flight deduplication includes `sessionId`. Writer retirement and serialized
commits fence older activations within one isolate.

Tenant, endpoint, principal, or content-policy changes require fresh sessions;
changed connection bindings also require a correctly bound credential source.
Mutations are never automatically replayed through auth recovery, and `403` is
not a general refresh trigger. Key rotation does not revoke previously issued
signed capabilities.

## Implementation and contract references

- [Session contracts, provenance, and storage](sdk_contract.md)
- [Tenant credential coordination and recovery](manage_api_key.md)
- [Framebase host integration and issuer envelope](../example/05_framebase_userlogin/README.md)
- [Session manager, context, policy, and scopes](../lib/src/user_session.dart)
- [Tenant credential source and providers](../lib/src/api_key_provider.dart)
- [Session and storage guards](../lib/src/session_guard.dart)
- [Client composition](../lib/src/client.dart) and [shared HTTP](../lib/src/http.dart)

The host issuer must authorize each app user independently. A modified client
with a shared tenant key can call any resource that key authorizes. Server
enforcement therefore needs verified app-user identity and per-resource policy;
the SDK's local isolation alone does not supply that server contract.
