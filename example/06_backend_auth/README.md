# Developer-backend scoped authentication reference

This separate integration reference leaves `05_framebase_userlogin` unchanged.
That existing app demonstrates host login with shared-key local isolation. This
reference obtains a VModal-issued scoped token through your authenticated
developer backend and uses the same guarded SDK session operations.

It is a host integration library, not another login UI or deployable identity
provider. Prerequisites are a verified host identity/session, an existing policy
store, and a VModal deployment with registered scoped issuance and complete
resource enforcement. Use [Choose authentication](../../docs/authentication.md)
and [Backend authentication](../../docs/backend_authentication.md) alongside it.

## 1. Authenticate and connect

Add this SDK as a local development dependency or pin a verified immutable
published revision containing `connectWithBackend`. The reference `pubspec.yaml`
already points to the sibling SDK checkout.

```dart
final owner = BackendSessionOwner();
final connection = await owner.activate(
  appUserId: signedInUser.id,
  projectId: 'framebase',
  loadToken: () async {
    // Uses your CURRENT authenticated backend client; no master key in Flutter.
    final response = await developerApi.post('/vmodal/session', body: {});
    return parseBackendResponse(
      response.statusCode,
      response.decodedJson,
      retryAfter: response.safeRetryAfter,
    );
  },
);
```

`developerApi`, `signedInUser` and its response adapter belong to your host app.
Map network/timeouts to `BackendAuthFailure.unavailable`. JSON decoding or a
malformed envelope is `invalidResponse`; never include raw response bodies or
identity tokens in errors. `parseBackendResponse` demonstrates safe status
classification, including identity rejection, policy denial and throttling.

The SDK confirms the candidate through VModal auth/me before returning ready.
The owner fences activation results when login changes during acquisition.

## 2. Discover allowed content, then search

```dart
final collections = await connection.session.listCollections();
final library = connection.scope('my_library');
final info = await library.collectionInfo();
final results = await library.search('a cyclist entering the street');
if (results.assets.isNotEmpty) {
  final bytes = await library.imageBytes(results.assets.first);
}
```

The grant label resolves the backend's exact collection/stream/mode mapping;
Flutter constructs no collection name. Index discovery requires `indexation`
and is unavailable until the deployment enforces and enables that action.
The initial read-only scoped deployment does not offer upload, metadata,
indexation or delete. Those existing SDK APIs remain usable in direct auth.

## 3. Implement the developer backend handoff

[developer_backend/session.mjs](developer_backend/session.mjs) exports a small
`node:http` handler. Node 22+ provides the built-in fetch, AbortSignal and native
test APIs it uses. It has no npm dependencies. Translate its handoff into your
existing server stack if your application uses another language.

Mount it in your existing backend:

```js
import { createVmodalSessionHandler, IdentityRejected, AccessDenied }
  from './developer_backend/session.mjs';

const sessionHandler = createVmodalSessionHandler({
  projectId: serverConfig.vmodalProject,
  vmodalOrigin: serverConfig.vmodalOrigin,
  loadServerKey: async ({ signal }) => secrets.currentRegisteredVmodalKey({ signal }),
  verifyIdentity: async (req, { signal }) => {
    const session = await hostAuth.verifyCurrentRequest(req, { signal });
    if (!session) throw new IdentityRejected();
    return { subject: session.stableSubject };
  },
  resolvePolicy: async (subject, { signal }) => {
    const policy = await policies.forVerifiedSubject(subject, { signal });
    if (!policy?.enabled) throw new AccessDenied();
    return { enabled: true, revision: policy.revision, grants: policy.exactGrants };
  },
});
// Route POST /vmodal/session to sessionHandler(req, res) in your server.
```

The named configuration, auth, policy and secret objects are mandatory host
adapters. No built-in verifier accepts a phone-supplied user ID. A cookie-based
host can verify cookies instead of Bearer identity tokens. Do not validate
identity by decoding an unsigned JWT or comparing an unverified UID.

The handler accepts only `{}`; the host determines subject, project and grants.
It re-verifies identity and reloads policy for every renewal. Only the registered
server credential goes to `/api/v1/auth/scoped-token`. Issuer redirects are
rejected so that credential does not follow another origin. The host identity
credential is never forwarded to VModal.

Successful envelopes pass through unchanged after expected identity/project/
policy checks. Responses are not cacheable. Identity rejection is `401`, access
denial is `403`, issuer contract/configuration rejection is `502`, temporary
issuer failure is `503`, and throttling is `429` with bounded `Retry-After`.
Errors never relay issuer bodies or server secrets. Acquisition is bounded by a
single timeout, including response decoding, and adapters receive its cancellation
signal. The Dart adapter recognizes the safe `issuer_contract_rejected` code
on `502` as `invalidResponse`; other unclassified gateway `5xx` responses are
temporary `unavailable` errors.

This handler requires server configuration/secret injection; it creates no new
Flutter environment variables and no server process or deployment. Your backend
retains its own configuration conventions and login/session lifecycle.

## 4. Renewal, transition and cleanup

The SDK coalesces renewal and performs request-time expiry gating. A temporary
issuer outage preserves host login and may retain a still-valid scoped token.
Failed POST searches are surfaced, and writes are not automatically replayed.

At the start of account switch/logout, clear host UI and call:

```dart
await owner.close(); // immediately retires VModal state; host owns sign-out
await hostAuth.signOut();
```

For another verified account, call `activate` again. Changed policy/grants also
require fresh activation. Widgets retain a session-owned `UserScope` and must
discard it on invalidation. Feature pages do not close a connection shared by
other pages. Already issued signed URLs and remote jobs retain their separate
lifetime; local close does not promise distributed instant revocation.

## 5. Run offline reference checks

From the SDK root:

```bash
# The normal build gates include this reference's Dart pub_get/format/analyze/test.
# The backend handler has an optional separate Node gate (no npm dependencies).
node --test example/06_backend_auth/developer_backend/session_test.mjs
flutter_bin="$(bash install.sh flutter_bin)"
cd example/06_backend_auth
"$flutter_bin" pub get
"$flutter_bin" analyze
"$flutter_bin" test
```

Backend tests exercise verified identity, spoof attempts, denied policy, unchanged
envelopes, no master-key return, safe issuer errors, renewal re-verification and
timeout, malformed issuer JSON and response-decoding timeout. Dart checks cover callback error classification; the SDK's
`test/backend_auth_test.dart` covers credential/session behavior.

Expected result: all offline checks pass without a live key or identity provider.
Tests create temporary local HTTP listeners and close them after each case.
No scoped production availability is inferred from fake issuers. Before enabling
your integration, run the public-edge acceptance checks in the backend guide.
