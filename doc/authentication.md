# Choose authentication

Choose one of the three integration modes below. They use two credential types:
a direct VModal API key or a VModal-issued scoped token. Your app owns end-user
login, signup, guest identity, user permissions and
the identity provider. The SDK owns VModal request credentials and connection
cleanup. All three modes send search and media requests directly to VModal.

| Pattern | Credential supplied to Flutter | Server authority | Best fit |
| --- | --- | --- | --- |
| Direct runtime credential | Existing VModal API key, static or synchronous provider | Existing VModal principal authority | Tenant applications, evaluation, existing integrations |
| Direct credential with app-user sessions | Same API key plus host-resolved local user policy | Same principal authority; SDK narrows local operations | Cooperative clients requiring local account isolation |
| Developer-backend scoped connection | Short-lived VModal-issued scoped token returned by your backend | Signed exact grants checked by VModal and upstream handlers | Apps whose users must have distinct server-enforced access |

The second row adds local ownership and cancellation to the first. A shared
tenant key can still authorize a modified client to perform tenant-wide
operations. Use the scoped connection when the server must enforce the
app-user boundary.

This guide describes source APIs. A successful local test is not evidence that
your public VModal deployment supports delegated access. Configure the origin,
edge, registrations and upstream enforcement and complete the
[rollout checks](auth_user_backend_mode.md#deployment-and-acceptance) before
enabling the scoped pattern in a production app.

---

## 1. Direct runtime credential

**Example:** [`uinterface/sdk_flutter/example/05_framebase`](../example/05_framebase/README.md).

**End-user authentication:** This example has no separate app-user sign-in.
The user enters a VModal API key at runtime. VModal authenticates the principal
that owns that key; the key's existing authority governs cloud access.

**SDK entry point:** `MutableApiKeyProvider` and `VModal.configure`.

Preserve your existing integration:

```dart
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

final keys = MutableApiKeyProvider(runtimeVmodalKey);
final project = VModal.configure(
  projectId: 'food_app',
  apiKeyProvider: keys,
);
final library = project.scope(
  collectionName: 'user_123',
  streamName: 'favorites',
);
final collections = await project.listCollections();
final results = await library.search('a person entering the room');

await project.close();
keys.close();
```

`SdkConfig(token:)`, `SdkConfig(apiKeyProvider:)`, `VmodalClient`, and custom
`ApiKeyProvider.current()` implementations retain their public contract.
`VModal.configure` performs no token exchange. Its logical collection mapping
uses `projectId__collectionName`; these names organize data and do not verify
app identity or narrow the API key's server authority.

---

## 2. Direct credential with app-user sessions

**Example:** [`uinterface/sdk_flutter/example/05_framebase_userlogin`](../example/05_framebase_userlogin/README.md).

**End-user authentication:** The host app signs in the person using its own
identity provider. A trusted host issuer verifies that identity and returns a
direct VModal tenant credential together with the user's allowed library policy.
Different app users can share the same VModal key and principal.

**SDK entry point:** `TenantCredentialSource` and `UserSessionManager`, as shown
in [manage_api_key.md](manage_api_key.md).

**Access boundary:** SDK sessions isolate local account data, operations and
callbacks. Cloud access still uses the direct key's authority; the local user
policy does not turn that key into a server-enforced app-user credential.

The host resolves the verified subject
and allowed content mapping, and invalidates the outgoing session at the start
of a switch. `auth.me()` and `session.verifyPrincipal(...)` check the VModal
storage principal; they do not identify the host app user in this pattern.

The preserved [Framebase user-login example](../example/05_framebase_userlogin/README.md)
demonstrates this host orchestration and shared-key local isolation. Its mock
issuer and `api_token`/`firebase_uid` envelope are a separate contract from a
VModal-issued scoped token.

---

## 3. User backend authentication (scoped connection)

**Example:** [`uinterface/sdk_flutter/example/06_userlogin_backend_auth`](../example/06_userlogin_backend_auth/README.md).

**End-user authentication:** The host app signs in the person, then calls its
authenticated developer backend. That backend verifies the current identity,
resolves exact permissions, and obtains a short-lived scoped token from VModal.
Flutter receives the scoped envelope; the registered server key stays on the backend.

**SDK entry point:** `VModal.connectWithBackend`.

**Access boundary:** VModal and the upstream handlers enforce the token's
app-user grants on the server once the scoped deployment is configured.
See [auth_user_backend_mode.md](auth_user_backend_mode.md) for the backend
handoff, token contract, renewal and deployment checks.

Sign your user in using the host app's existing identity stack, then connect:

```dart
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

final backend = await VModal.connectWithBackend(
  expectedAppUserId: signedInUser.id,
  expectedProjectId: 'framebase',
  loadToken: () async {
    final json = await developerApi.createVmodalSession();
    return ScopedTokenEnvelope.fromJson(json);
  },
);

final collections = await backend.session.listCollections();
final library = backend.scope('my_library');
final info = await library.collectionInfo();
final results = await library.search('a person entering the room');
if (results.assets.isNotEmpty) {
  final image = await library.imageBytes(results.assets.first);
}

await backend.close();
```

`developerApi` is your authenticated host API client. The SDK does not hardcode
its URL or depend on Firebase, Auth0, Clerk, cookies or a particular backend
framework. The callback returns a typed envelope; it never returns your server
master key. The connection validates the expected app user and project, confirms
the complete binding and grants through VModal `/auth/me`, and then publishes
a guarded `UserSession`.

Choose a grant by its stable `grant_id`. The exact collection selector is
provided by the issuer and passed unchanged to VModal. Do not construct a
collection name from the user ID, prepend the project, lowercase selectors, or
reuse a logical direct-auth scope for a backend grant.

The example deliberately progresses from authentication to collection discovery
and search. Index/job discovery requires `indexation` and is available only
after the deployment enables and enforces that action. The initial scoped
read implementation denies unsupported writes and index operations. Your
direct tenant integration retains its existing upload/index APIs.

### Host login options for user backend authentication

| Host login pattern | Callback responsibility |
| --- | --- |
| Firebase/Auth0/Clerk identity token | Send current host token to your backend; backend verifies it and derives its stable subject |
| Existing session cookie | Use the authenticated host HTTP client; backend verifies the current cookie session |
| Custom login/session | Reuse your established verifier and policy store; derive identity server-side |
| Guest access | Backend verifies and assigns a stable guest subject with explicit grants; SDK does not invent authorization identity |
| Multi-project app | Create a separate connection for each registered project; project is part of local ownership |

Host identity tokens are not VModal credentials. Send them only to your
developer backend. VModal signs its own scoped token after authenticating your
registered backend credential; the developer does not sign VModal tokens.

### Scoped connection lifetime and account changes

Keep the connection at the host account lifetime and inject its `UserScope`
into feature controllers. Pages dispose their own subscriptions, players and
operation tokens. The host account owner closes the connection.

At the start of logout or an account switch, call `close()` immediately, before
waiting for identity-provider sign-out. It invalidates local work synchronously
and then performs asynchronous cleanup. Clear host widgets, playback, image
caches, navigation state and history as part of that transition. Create a fresh
connection after verifying the next host identity.

Credential renewal with identical identity and policy preserves the active
session and local owner keys. Changed identity, tenant, principal, project,
policy revision or grants invalidates the connection and requires fresh
activation. A same-ID policy change is still a policy change.

Tokens are kept in memory. Archives and upload checkpoints may contain scoped
owner references, but never a bearer or envelope. Reauthorize before restoring
owner data. Logout does not instantly revoke a copied token or an already
issued standalone signed media URL; those capabilities have separate validity.

---

## Terminology and next guides

All three integration modes normally use `SdkConfig.mode == 'gateway'` and
`Authorization: Bearer <credential>`. The SDK's internal-development
`mode: 'direct'` / `unsafeDirect` is a different connection mode that can send
trusted identity fields. It is not the direct authentication pattern described
here. Mobile callers never supply `X-User-Id`, `X-Tenant-Id` or grant headers.

- [Backend setup, contracts and lifecycle](auth_user_backend_mode.md)
- [Tenant key rotation and local user sessions](manage_api_key.md)
- [Controller and widget integration](component_patterns.md)
- [Exact ownership and resource contract](sdk_contract.md)
- [Independent backend-auth reference](../example/06_userlogin_backend_auth/README.md)
