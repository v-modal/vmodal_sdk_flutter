# Manage tenant API keys and app-user sessions

Retrieve credentials through the host's authenticated, trusted service and
keep them in memory. VModal credentials identify the tenant principal; Firebase,
Clerk, or another host identity system supplies the stable app-user ID. A and B
may share one tenant key and `auth.me()` response. That response never selects
their local owner namespace or proves their content permissions.

## Session-bound configuration

```dart
final config = SdkConfig(); // gateway mode
final namespace = SessionContext.serviceNamespaceFor(config);
final credentials = TenantCredentialSource(
  serviceNamespace: namespace,
  tenantId: tenantId,
  expectedPrincipal: tenantPrincipal,
  initialKey: runtimeTenantKey,
  renew: () async => TenantCredential(
    serviceNamespace: namespace,
    tenantId: tenantId,
    principal: tenantPrincipal,
    apiKey: await trustedIssuer.currentTenantKey(),
  ),
);
final manager = UserSessionManager(
  config: config,
  credentialSource: credentials,
);
```

The host's issuer/resolver must authenticate and validate the credential's
service/tenant/principal binding. These fields are compared locally; self-reported
labels on an arbitrary key are not proof. `session.verifyPrincipal(...)` can
add an `auth.me()` tenant-principal check. It does not identify the app user or
validate that user's mapping. Prefer authoritative integer `issuerVersion`
values when the issuer supports them; when absent, the trusted resolver must
return its currently valid key. `auth.me()` cannot order opaque keys by age.

## Coordinate tenant rotation

`credentials.renewCredential()` shares one normal renewal Future across active
matching providers. `install(TenantCredential(...))` installs a trusted external
replacement. `renewCredential(supersede: true)` deliberately fences earlier
renewal tickets. Accepted revision and request ticket checks reject late results;
authoritative issuer versions reject rollback. Commit is atomic within the
isolate, updates only live matching providers, and new sessions attach/read the
latest revision without an asynchronous gap. Closing A unsubscribes its provider
without canceling shared renewal needed by B.

```dart
credentials.install(TenantCredential(
  serviceNamespace: namespace,
  tenantId: tenantId,
  principal: tenantPrincipal,
  apiKey: replacementTenantKey,
));
```

A credential-only replacement preserves `sessionId`, stable owner/scope keys,
app user, mapping, policy, and multipart checkpoint namespace. Tenant, endpoint,
or principal changes are rejected in place: build a correctly bound source and
fresh sessions. Grant/mapping changes also require invalidation and fresh policy
resolution, even when the key or app-user ID stays equal.

By default renewal failure blocks tenant calls, retains no fallback authority,
and returns a classified `TenantAuthException`. It does not log out the host
app user or change the active owner. `retainOnRenewalFailure: true` is available
only when the host's authoritative validity policy permits using the prior key.
`revoke()` is an authoritative current-credential revocation and blocks gateway
calls; a stale request's `401` cannot revoke a newer accepted revision. Recover
the tenant connection through the trusted source rather than falling back to a
broader credential. `credentials.close()` retires the shared coordinator;
closing one user session leaves the coordinator available to another.

## Request snapshots and recovery

The HTTP layer captures a binding/revision and header snapshot at request
construction. Ordinary retries retain that snapshot. Rotation does not rewrite
an existing request. New requests read the latest committed credential. Existing
calls can finish with the prior key while the service still accepts it; every
attempt and delivery remains guarded by its original app-user lease.

An eligible active GET/HEAD read can recover from `401` at most once per logical
request by consulting the coordinator and reconstructing fresh headers. It
shares a bounded attempt budget with ordinary retries. A second denial returns
a tenant-auth error while preserving app-user identity. `403` is never a general
refresh trigger. Uploads, index submissions, deletions, and other mutations are
never automatically replayed through auth recovery; ambiguous completion remains
unknown and requires deliberate reconciliation. Multipart continuation uses only
its existing explicit status/part/resume protocol and validated owner checkpoints.

Signed URLs have independent validity and expiry. Rotating or revoking the
tenant key does not promise to revoke an already issued storage/media capability.
Never attach a replacement bearer to a signed storage request. The session guard
still blocks later local signed-upload dispatch and media delivery after logout.

## Account changes and the host boundary

Call `manager.logout()` or `manager.openResolvedSession(...)` at the start of
an identity transition. Invalidation happens before asynchronous resolution or
cleanup. Clear old displayed images, playback, navigation/restoration, and
histories; check the current view generation before applying asynchronous host
state updates. Persisted owner data may remain for a later verified activation,
but old runtime handles never become valid again. Local cache reuse requires
current policy validation.

The compatible tenant-scoped API still accepts `MutableApiKeyProvider`:

```dart
final provider = MutableApiKeyProvider(runtimeTenantKey);
final project = VModal.configure(
  projectId: 'food_app',
  apiKeyProvider: provider,
);
provider.rotate(replacementTenantKey); // later requests only
provider.close(); // permanently disables reads and rotation
await project.close();
```

`VmodalClient`/`VModalProject` bypass user-session isolation; the host must own
their complete cancellation, cache/checkpoint partitioning, and account-switch
contract. Never use `projectId` or tenant identity as proof of app-user identity.
Never commit keys, put them in assets, log them, persist them in jobs/archives,
or treat compile-time `--dart-define` values as production credential storage.

See [the SDK contract](sdk_contract.md) for result provenance, restricted media,
local storage fencing, and the shared-key modified-client limitation.
