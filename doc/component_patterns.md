# Flutter app integration recipes

Use this guide to add VModal to an existing Android/iOS app. Start with a
verified host user, resolve that user's allowed library, discover existing
collections and jobs, and then attach a screen controller. Upload and index
only when the user needs new content.

The recipes target the local **1.3.0 session API**, Flutter **3.44.0+**, and
Dart **3.12.0+**. The repository pins Flutter **3.44.6**. Public package/tag
availability is not established by this guide: use the local dependency below
to reproduce these recipes. Before shipping, select an immutable public source
revision containing these symbols or a verified published compatible package.
An older `1.2.3` dependency cannot run the session recipes.

## Find the recipe you need

| Goal | Read / reuse |
| --- | --- |
| Choose sessions or tenant-scoped access | [API choice](#1-choose-the-api-and-own-its-lifetime) |
| Connect real sign-in and issuer adapters | [Activation](#2-activate-a-verified-user-and-discover-content) |
| Add a search screen without a state-management dependency | [Complete controller and widget](#3-copy-a-session-bound-search-screen) |
| Upload with progress and cancellation | [Upload recipe](#4-upload-with-owned-progress-and-cleanup) |
| Wait for an accepted index job | [Pipeline and polling](#5-orchestrate-upload-index-and-search) |
| Recover from a failed operation | [Error table](#6-map-failures-to-ui-and-permitted-recovery) |
| Switch accounts or rotate credentials | [Transition recipe](#7-handle-logout-account-switch-and-rotation) |
| Restore jobs and owner files after restart | [Storage recipe](#8-persist-owner-data-and-rebind-jobs) |
| Handle picker files, pause, and process death | [Mobile lifecycle](#9-set-mobile-file-and-interruption-policies) |
| Verify the host app before release | [Acceptance recipes](#10-test-and-release-the-host-integration) |

Canonical contracts remain in [sdk_contract.md](sdk_contract.md) and
[manage_api_key.md](manage_api_key.md). Component diagrams are in
[diagrams.md](diagrams.md). The complete working app is
[Framebase](../example/05_framebase_userlogin/README.md); its auth and issuer
implementations are mocks unless the host replaces them.

## Choose authentication first

[Choose authentication](authentication.md) puts the two quickstarts together.
The existing recipes below demonstrate direct keys with local app-user policy.
For server-issued exact user grants, replace that setup with:

```dart
final backend = await VModal.connectWithBackend(
  expectedAppUserId: verifiedHostUser.id,
  expectedProjectId: 'framebase',
  loadToken: () async => ScopedTokenEnvelope.fromJson(
    await authenticatedDeveloperApi.createVmodalSession(),
  ),
);
final collections = await backend.session.listCollections();
final library = backend.scope('my_library');
```

Inject `library` into the same session-bound search controller. BackendConnection
owns the manager/source lifecycle and confirms delegated binding/grants through
auth/me before return. The callback uses current host identity, maps failures
to `BackendAuthException`, and returns no master key. The separate
[backend-auth reference](../example/06_backend_auth/README.md) demonstrates
generation fencing and mandatory verified backend adapters, preserving Framebase.

Scope actions determine usable recipes. Initial scoped reads support discovery,
search and media; upload/index/metadata/delete recipes require enforced server
handler support and enabled grants. Direct scope instances keep their existing
resource contract. Mobile action sets do not enable server capabilities.

Close the backend connection at the start of account switch/logout, clear host
view/player/cache state, and activate another after authorization. Observe state
at the account owner. Temporary failure preserves host login; identity/policy
invalidation retires scopes. Same-policy rotation preserves handles/storage,
and project participates in backend owner identity.

## 1. Choose the API and own its lifetime

| Integration | Use when | Host responsibility |
| --- | --- | --- |
| `BackendConnection` → `UserSession` → `UserScope` | Backend issues exact server-enforced user grants | Own host login/callback; close connection and clear UI on transition |
| `UserSessionManager` → `UserSession` → `UserScope` | A signed-in user has an exact allowed library policy | Verify host identity/policy; clear app-owned UI, players, caches, and navigation on transition |
| `VModalProject` → `VModalScope` | Tenant-scoped evaluation or an app that implements its own complete isolation | Own identity fencing, cancellation, storage partitions, and every low-level resource lifecycle |
| `VmodalClient` resources | Advanced tenant operations outside the restricted session interface | Own all isolation and selector contracts; never mix these calls into a feature claiming session guarantees |

A direct VModal API-key bearer authenticates the tenant. Its `auth.me()` reports that tenant
principal. It cannot determine which app user is signed in or which content
that user may access. Local session isolation does not establish server-side
app-user authorization under a shared tenant key; the deployment must enforce
that boundary independently where required.

### Ownership table

| Object | Lifetime | Creates / disposes it | Responsibilities |
| --- | --- | --- | --- |
| Host auth adapter and issuer client | Host connection | App composition root | Verify identity, acquire trusted credentials/policy, classify expiry/temporary failure |
| `TenantCredentialSource` | One service/tenant/principal connection | App connection owner; call `close()` | Coordinate accepted key revisions and renewal; remain available across user sessions |
| `UserSessionManager` | One active identity flow | Session coordinator; await `close()` | Activate, switch, invalidate, and close session transports |
| `UserSession` | One activation | Manager | Immutable app identity/policy; fresh runtime `sessionId` |
| `UserScope` / feature gateway | One session and exact mapping | Session coordinator / feature owner | Retain provenance across search, uploads, jobs, metadata, and media |
| Screen `ChangeNotifier` | One page or retained feature | Page or feature owner | Own debounce, tokens, query generations, progress subscriptions, and local waits |
| Widget / player | View lifetime | Owning widget | Render; dispose view resources and players |
| Archive / cache adapter | Validated stable owner/scope | Host storage owner | Validate restore, partition paths, commit through captured storage lease |

An injected shared dependency belongs to its injector. A page may dispose its
own notifier, but must not close an injected manager, source, or session that
other features use. The manager does not close the shared credential source;
the connection owner closes both when their lifetimes end.

Provider, Riverpod, or BLoC can implement the same table. None is an SDK
dependency. Keep the gateway/session out of tile constructors and network work
out of `build()`.

## 2. Activate a verified user and discover content

### Install for local integration

From your app, point to the SDK checkout with a relative path appropriate to
your directory layout:

```yaml
dependencies:
  flutter:
    sdk: flutter
  vmodal_sdk_flutter:
    path: ../vmodal_sdk_flutter
```

Run `flutter pub get` using a compatible toolchain. Within the SDK checkout,
`bash install.sh flutter_bin` locates its pinned Flutter executable. A path
dependency is a development arrangement; replace it with the verified immutable
release dependency before distributing the app.

### Define the host handoff

| Trusted input | Meaning / validation |
| --- | --- |
| Stable app-user ID | Subject verified by your host auth system; never inferred from the tenant key or user-entered collection |
| Service namespace, tenant ID, expected principal | Connection binding validated by the issuer client |
| Tenant bearer and expiry/revision | Runtime credential returned by the trusted issuer; kept out of archives |
| Exact content mapping | Logical project/collection or opaque collection ID, exact stream and mode |
| Actions and collection-wide flag | Allowed policy; write permission does not automatically grant deletion or aggregate discovery |
| Policy revision | Trusted revision, or SDK fingerprint of immutable grants/selectors |

For a concrete envelope parser and injection interfaces, reuse
[vmodal_credential.dart](../example/05_framebase_userlogin/lib/user/vmodal_credential.dart),
[auth_adapter.dart](../example/05_framebase_userlogin/lib/user/auth_adapter.dart), and
[user_session_controller.dart](../example/05_framebase_userlogin/lib/user/user_session_controller.dart).
Those are **example app components**, not SDK APIs. Implement the host auth
adapter and issuer transport; the example supplies no production verifier or
issuer URL. The issuer verifies the host token and derives its subject server-side.

Construct `TenantCredentialSource` as shown in
[manage_api_key.md](manage_api_key.md#session-bound-configuration), then inject
it into `UserSessionManager`. Use `openResolvedSession` when policy resolution
is asynchronous: it retires outgoing SDK state before awaiting the resolver.
Also fence the host resolver with an activation generation so late issuer
responses cannot install credentials or update host state for another user.

The following helper receives an already trusted resolver and a mapping from
that same policy. It performs discovery before returning the feature scope:

```dart
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

Future<UserScope> activateLibrary({
  required UserSessionManager manager,
  required Future<UserSessionPolicy> Function() resolve,
  required ContentMapping mapping,
}) async {
  final session = await manager.openResolvedSession(resolve);
  final scope = session.scope(mapping);
  await session.listCollections();
  if (!session.isActive) throw const SessionInvalidated();
  await scope.collectionInfo();
  if (!session.isActive) throw const SessionInvalidated();
  if (scope.mapping.actions.contains(UserAction.indexation)) {
    await scope.listIndexJobs();
    if (!session.isActive) throw const SessionInvalidated();
  }
  return scope;
}
```

Preconditions: grant `discover` for collection discovery, `search` for the next
recipe, and `media` for previews. Grant `indexation` only when permitted. A
scope uses the session's frozen grants even if the supplied mapping attempts to
replace them. Do not manufacture a broader mapping after a denied call.

Use `ContentMapping.logical` for a host-defined project and logical collection;
the SDK encodes `projectId__collectionName`. Use `ContentMapping.opaque` for an
issuer's exact backend collection ID; leave it unchanged. Both retain stream,
mode, and representation through every operation.

### Interpret discovery before enabling actions

| Result | UI / next action |
| --- | --- |
| No discoverable collections | Show “No available library”; resolve host provisioning/access before offering search |
| `collectionInfo()` or `latestVersion()` is null | Show “Search index unavailable”; investigate stream-specific metadata and policy |
| Existing scoped job | Show current work; monitor the live handle rather than submit another job |
| Search returns zero retained rows | Show an empty result for this query/filter; no automatic upload/index creation |
| Auth/access failure | Route to identity, tenant recovery, or denied state; not an empty library |

Aggregate collection versions require `collectionWide: true` unless discovery
returns an exact stream row. An absent stream version is not permission to
request a broader collection. Host policy controls that choice.

## 3. Copy a session-bound search screen

Copy this complete block into an app file. It uses only Flutter and public SDK
types. Pass a live `UserScope` after activation. For `vid_file`, pass a paired
offset-aware date range in `ScopedSearchOptions`; keep all selectors in the
scope. This screen displays typed filenames/distances. The media recipe below
adds images without exposing signed URLs.

```dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

enum SearchPhase { idle, loading, empty, ready, error, canceled }

class SearchState {
  const SearchState(this.phase, {this.result, this.message});
  final SearchPhase phase;
  final SessionSearchResponse? result;
  final String? message;
}

class LibrarySearchController extends ChangeNotifier {
  LibrarySearchController(this.scope, {required this.options});
  final UserScope scope;
  final ScopedSearchOptions options;
  SearchState state = const SearchState(SearchPhase.idle);
  Timer? _timer;
  CancellationToken? _token;
  int _generation = 0;
  bool _disposed = false;

  bool _current(int gen) => !_disposed && gen == _generation;

  void _publish(SearchState next) {
    if (_disposed) return;
    state = next;
    notifyListeners();
  }

  void queryChanged(String text) {
    if (_disposed) return;
    final gen = ++_generation;
    _timer?.cancel();
    _token?.cancel();
    final query = text.trim();
    if (query.isEmpty) {
      _publish(const SearchState(SearchPhase.idle));
      return;
    }
    _publish(const SearchState(SearchPhase.loading));
    _timer = Timer(const Duration(milliseconds: 300), () {
      unawaited(_search(query, gen));
    });
  }

  Future<void> _search(String query, int gen) async {
    if (!_current(gen)) return;
    final token = CancellationToken();
    _token = token;
    try {
      final result = await scope.search(
        query, options: options, cancellation: token,
      );
      token.throwIfCanceled();
      if (!_current(gen)) return;
      _publish(SearchState(
        result.assets.isEmpty ? SearchPhase.empty : SearchPhase.ready,
        result: result,
      ));
    } on SessionInvalidated {
      if (_current(gen)) {
        _publish(const SearchState(SearchPhase.canceled));
      }
    } on OperationCanceled {
      if (_current(gen)) {
        _publish(const SearchState(SearchPhase.canceled));
      }
    } on SdkException catch (error) {
      if (_current(gen)) {
        _publish(SearchState(SearchPhase.error, message: error.message));
      }
    } on Object {
      if (_current(gen)) {
        _publish(const SearchState(
          SearchPhase.error, message: 'Unexpected search failure',
        ));
      }
    } finally {
      if (identical(_token, token)) _token = null;
    }
  }

  void cancel() {
    if (_disposed) return;
    ++_generation;
    _timer?.cancel();
    _token?.cancel();
    _publish(const SearchState(SearchPhase.canceled));
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _timer?.cancel();
    _token?.cancel();
    super.dispose();
  }
}

class LibrarySearchPage extends StatefulWidget {
  const LibrarySearchPage({
    super.key, required this.scope, required this.options,
  });
  final UserScope scope;
  final ScopedSearchOptions options;

  @override
  State<LibrarySearchPage> createState() => _LibrarySearchPageState();
}

class _LibrarySearchPageState extends State<LibrarySearchPage> {
  late final LibrarySearchController controller;

  @override
  void initState() {
    super.initState();
    controller = LibrarySearchController(widget.scope, options: widget.options);
  }

  @override
  void dispose() {
    controller.dispose(); // This page owns only its notifier.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Search library')),
    body: Column(children: [
      TextField(onChanged: controller.queryChanged),
      TextButton(onPressed: controller.cancel, child: const Text('Cancel')),
      Expanded(child: ListenableBuilder(
        listenable: controller,
        builder: (context, child) {
          final state = controller.state;
          switch (state.phase) {
            case SearchPhase.idle:
              return const Center(child: Text('Enter a query'));
            case SearchPhase.loading:
              return const Center(child: CircularProgressIndicator());
            case SearchPhase.empty:
              return const Center(child: Text('No matching moments'));
            case SearchPhase.error:
              return Center(child: Text(state.message ?? 'Search failed'));
            case SearchPhase.canceled:
              return const Center(child: Text('Search stopped'));
            case SearchPhase.ready:
              final hits = state.result!.videoHits;
              return ListView.builder(
                itemCount: hits.length,
                itemBuilder: (context, index) => ListTile(
                  title: Text(hits[index].fileName ?? 'Unnamed asset'),
                  subtitle: Text('Distance: ${hits[index].distance ?? "unknown"}'),
                ),
              );
          }
        },
      )),
    ]),
  );
}
```

**Mount contract:** key the page by runtime session identity **and** the exact
scope/options identity, so changed dependencies recreate its state. For example,
a parent that rebuilds on activation can use a `ValueKey` derived from
`scope.sessionId`, `scope.scopeKey`, and a host options revision. This recipe's
`late final` controller deliberately captures dependencies once. Replace the
route/key on account or filter-policy changes; do not update its scope in place.

Auth/tenant states belong above this feature: signed out, resolving, ready,
recoverable connection, denied, and identity expired. A production gateway can
report `401`/`403` to that coordinator as
[SearchGateway](../example/05_framebase_userlogin/lib/data/search_gateway.dart)
does, preserving the feature's failure instead of turning it into empty data.

### Why cancellation and generations both exist

The SDK session guard rejects work from an inactive session. The controller's
generation rejects older queries **inside the same active session**. The timer
reduces dispatch; the token requests local cancellation; the generation prevents
late success and late errors from replacing a newer state. Guard after every
await, including media loads, renewal callbacks, and host storage writes.

### Load a preview through its live asset

```dart
import 'dart:typed_data';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

Future<Uint8List> loadPreview(
  UserScope scope,
  SessionAsset asset,
  CancellationToken token,
) async {
  final bytes = await scope.imageBytes(
    asset, maxBytes: 2 * 1024 * 1024, cancellation: token,
  );
  token.throwIfCanceled();
  return bytes;
}
```

The 2 MiB limit is an app choice. Use `Image.memory(bytes)` only after checking
the originating query/view generation. Load a bounded number of visible tiles;
own their cancellation and cache entries. Some hits have no usable basename or
frame time, so media can be unavailable: show a placeholder and preserve the
search hit. Never obtain an arbitrary URL through a low-level client to bypass
that failure. The restricted session API keeps signed capabilities private.

Distance is nullable and lower-is-better; do not label it confidence or convert
it to a percentage. Playback offset is nullable elapsed milliseconds, not an
absolute recording timestamp. Resolve a hit to an owner-local clip by canonical
asset ID; differing non-null IDs must not match merely because filenames agree.

## 4. Upload with owned progress and cleanup

Use this helper inside a controller that owns one active task. The callback
provides the task for a cancel button before awaiting completion. `onProgress`
must check the controller's current session/view generation before publishing.
The helper releases its subscription on every exit and preserves the failure
for the owning controller to classify.

```dart
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

Future<SessionUploadResponse> uploadClip({
  required UserScope scope,
  required UploadSource source,
  required void Function(UploadTask<SessionUploadResponse>) onStarted,
  required void Function(UploadProgress) onProgress,
}) async {
  final task = scope.upload(source);
  final progress = task.progress.listen(onProgress);
  try {
    onStarted(task);
    return await task.result;
  } finally {
    task.cancel(); // Also ends unfinished work if a host callback failed.
    await progress.cancel();
  }
}
```

Controller sequence: publish uploading → retain the started task → publish
guarded byte progress → await result → check generation → record completion →
clear task reference in `finally`. Publish canceled for local cancellation and
unknown completion when a dispatched mutation has an ambiguous outcome. A
subscription callback should update state synchronously; route callback failures
through your app's error reporting rather than throwing from a stream listener.

Keep feature state immutable: phase, progress, nullable uploaded identity,
pending job, and user-facing message. Suggested pipeline phases are picking,
uploading, uploaded, indexing, ready, canceled, failed, and completionUnknown.
Keep auth recovery separate. Progress reaching 100% is not finalization success
and upload success is not index readiness.

Choose one navigation policy:

| Policy | Owner / page behavior |
| --- | --- |
| Screen-owned foreground upload | Page disposal calls `task.cancel()`; controller awaits/handles the result and cleans subscription |
| Retained foreground feature | App feature owner retains task/controller; page detaches only its view; explicit stop/logout still cancels |
| Platform background transfer | Host implements scheduling and durable recovery; a Dart Future alone supplies no process-death guarantee |

Signed single upload is the default for every size. Multipart requires explicit
`VideoUploadOptions(multipart: true)` and remains experimental; unavailable route
families fail with `FeatureDisabled`. Inject a persistent checkpoint store at the
manager if needed. Per-task stores and custom transcoders are rejected by the
restricted session interface; only `PassthroughVideoTranscoder` is supported.

## 5. Orchestrate upload, index, and search

Keep one immutable scope through the entire pipeline:

```text
verified activation → collections → existing jobs/version
                    → upload when requested → completion + nullable asset
                    → metadata on live proven asset when needed
                    → reuse suitable job or submit index → accepted job
                    → bounded local polling → discover usable version → search
```

`SessionUploadResponse.asset` is nullable. Even an asset handle may have a null
canonical `assetId`. Preserve those nulls; filenames/frame IDs do not synthesize
asset identity. Metadata/add/update calls require live scoped provenance. JSONL
metadata is bounded to 8 MiB and uses the allowlisted scalar/string-list fields
described in [the contract](sdk_contract.md#restricted-results-and-provenance).

Index submission returns acceptance, not search readiness. Reuse a suitable job
from `scope.listIndexJobs()` when policy and product behavior allow it. Creating
an index automatically on every empty search can duplicate work and widen the
feature's responsibilities.

### Bounded, cancelable local wait

The helper below uses the terminal-state classifications already used by the
Framebase gateway. Confirm the backend states used by your deployment in live
contract checks. Unknown states keep polling until the app's deadline.

```dart
import 'dart:async';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

Future<IndexationStatusResponse> waitForIndex(
  UserScope scope,
  SessionJob job,
  CancellationToken token, {
  Duration maxWait = const Duration(minutes: 2),
}) async {
  final clock = Stopwatch()..start();
  while (clock.elapsed < maxWait) {
    token.throwIfCanceled();
    final status = await scope.indexStatus(job, cancellation: token);
    token.throwIfCanceled();
    final state = status.status.toLowerCase();
    if (const {'success', 'succeeded', 'done', 'completed', 'ok'}.contains(state)) {
      return status;
    }
    if (const {'failed', 'failure', 'error', 'cancelled', 'canceled'}.contains(state)) {
      throw ApiException('Index job ended: $state');
    }
    // Short slices bound local cancellation latency between HTTP reads.
    for (var n = 0; n < 20; n++) {
      token.throwIfCanceled();
      if (clock.elapsed >= maxWait) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      token.throwIfCanceled();
    }
  }
  throw TimeoutException('Stopped waiting locally; the server job may continue');
}
```

The deadline bounds the polling loop; a currently running status request is
additionally bounded by `SdkConfig.timeout` and its read retry budget. Thus a
request already in progress can finish after `maxWait`. If your UI needs a hard
deadline, its owner must also cancel the token with a timer and cancel that timer
in `finally`. Canceling local polling does not cancel the accepted server job.

After success, rediscover `latestVersion()` with the same scope. If unavailable,
show “Index finished; search metadata unavailable” and investigate discovery;
do not assume a nullable version means ready. Pass the discovered version and
paired dates for `vid_file` in `ScopedSearchOptions`. The host controller checks
its operation generation after the wait and discovery before enabling search.

### Resolve ambiguous mutations

| Stage / failure | Retained fact | Permitted recovery |
| --- | --- | --- |
| Local validation before SDK dispatch | No operation accepted by this attempt | Correct input/policy and deliberately start again |
| Dispatched upload/finalization times out | Completion unknown | Reconcile using documented scoped service data / supported multipart status protocol; do not infer failure from local cancel |
| Index submission response lost | Acceptance unknown | Rediscover exact scoped jobs; offer deliberate reconciliation before another submission |
| Local polling canceled/times out | Known accepted job can continue | Save durable reference; rediscover/rebind and resume waiting |
| Cloud success, archive commit failed | Remote completion known, local persistence failed | Report both stages; repair local record without replaying the remote mutation |

The generic `TransportException` alone does not prove a request was never sent.
No documented once-only upload guarantee comes from filename, hash, checkpoint,
or source ID. Do not offer a blind automatic “retry upload” for unknown completion.

### Collection deletion is a separate feature

Require `UserAction.delete` and `collectionWide: true`. Preview with
`ScopedDeleteCollectionOptions(dryRun: true)`, show collection-wide consequences,
obtain explicit host UI confirmation, then commit with
`ScopedDeleteCollectionOptions(dryRun: false, confirm: true)`. Capture the same
session and scope across preview/confirmation; recheck them before commit.
Cloud deletion does not delete owner-local MP4s. No individual remote-video
deletion API is exposed. Reconcile unknown outcomes; `409` is not permission to
replay a commit immediately. See Framebase's deletion flow for UI and archive
handling.

## 6. Map failures to UI and permitted recovery

Catch `SessionInvalidated` before `OperationCanceled` because it subclasses
cancellation. Catch credential failures before the generic `SdkException`.
Preserve the original failure for controller/repository callers, and always
release task subscriptions and timers in `finally`.

| Public failure | UI state | Next action |
| --- | --- | --- |
| `SessionInvalidated` | Retire feature; clear old results | Recreate feature only after fresh activation; never reuse handles |
| `OperationCanceled` | Normal stopped state | Explicit user restart where outcome is known; accepted mutations may continue |
| `TenantAuthException` / `AuthException` | Tenant connection recovery | Renew through trusted source; retain host user unless host identity itself is invalid |
| `ApiException` | Context-specific failure | Classify status and operation stage; preserve unknown write outcome |
| `ValidationException` | Input/policy problem | Fix contract or grant; do not repeat unchanged input |
| `TransportException` | Read failure or unknown mutation completion | Manual read retry; reconcile mutations |
| `FeatureDisabled` | Feature/media unavailable | Hide unsupported action or show placeholder; no low-level bypass |
| `ResponseTooLarge` | Resource exceeds app/SDK limit | Reduce result count/media size; avoid unbounded buffering |
| `MalformedResponse` | Service-contract failure | Record safe classification; correct contract before replaying writes |

| Status | Meaning depends on stage | Recovery rule |
| --- | --- | --- |
| `401` | Tenant bearer rejected or connection blocked | Eligible GET/HEAD can recover once within bounded attempt budget; write is not replayed |
| `403` | Access/policy denied | Resolve policy; no generic credential refresh or broader-key fallback |
| `404` | Missing collection/job/media or unavailable resource | Refresh allowed discovery or show missing media; do not mint ownership from a bare ID |
| `409` | Conflicting/busy operation | Reconcile/wait; destructive commit is not blindly repeated |
| `429` | Service rate limiting | Gate actions and use verified service retry guidance; SDK promises no generic automatic 429 recovery |
| `500/502/503/504` | Eligible read server failure | GET/HEAD may retry within configured budget; writes still require reconciliation |

Search uses POST even though the user perceives it as a read. Do not assume it
receives GET/HEAD retry or auth-recovery behavior. Request retry snapshots retain
their credential revision; eligible auth recovery reconstructs headers under the
coordinator. Other statuses/transport failures are not a blanket retry promise.

Diagnostics should record operation stage, elapsed time, exception class, status,
and runtime generation. Use a request identifier only when the actual response
contract exposes it. Do not invent a universal request-ID header or log raw
response bodies, API keys, signed URLs, or issuer envelopes. Restricted session
errors already remove raw tenant bodies and underlying capabilities.

## 7. Handle logout, account switch, and rotation

Execute this order in the host session coordinator:

1. Advance host activation/view generations and stop accepting feature actions.
2. Call `manager.logout()` or start `openResolvedSession(...)` immediately;
   outgoing SDK invalidation occurs before asynchronous cleanup/resolution.
3. Detach and dispose old feature controllers, cancel local tokens/tasks, stop
   players, clear displayed images/search/history, and replace private routes and
   restoration state. Perform these host changes before publishing new user data.
4. Retire archive writers; finish captured storage cleanup for the old owner.
5. Resolve and validate the new identity/issuer envelope under the new host
   generation; activate the exact policy, discover content, restore validated
   owner data, then publish ready.

An invalidation callback must clean up resources captured for the outgoing
session, not whatever manager session happens to be current later. Delayed A
cleanup must not dispose B's controller/player. A→B→A creates three runtime
session IDs; old A handles and callbacks do not become valid on return to A.

`TenantCredentialSource.install(...)` or `renewCredential()` replaces credentials
without changing session identity when service/tenant/principal/policy remain
equal. A changed policy requires fresh activation; a changed tenant/principal
requires a correctly bound fresh source and sessions. Host identity expiry needs
host sign-in; tenant renewal cannot repair it. A temporary tenant failure should
not automatically sign out the app user.

At final connection shutdown, await manager cleanup and close the source in a
`finally` block so a transport cleanup failure cannot leave the coordinator open.
Dispose host auth/issuer/archive components according to their ownership. Do
not close shared credentials when only one page leaves.

## 8. Persist owner data and rebind jobs

| Value | Persistent use |
| --- | --- |
| `session.context.ownerKey` | Stable service/tenant/app-user namespace |
| `scope.scopeKey` | Exact representation/collection/stream/mode namespace |
| `policyRevision` | Required restore validation; include it in result cache identity |
| `sessionId` | In-flight generation/dedup guards only; not a stable archive directory |
| API-key bytes/revision | Credentials; never an owner partition |
| `SessionAsset`, `SessionJob`, `UserScope` | Live capabilities; never serialize/reuse after activation ends |

Persist a job with `job.toDurableReference()`: allowlist `jobId`, `ownerKey`,
`scopeKey`, and `policyRevision`. After verified activation for that same owner
and policy, construct the durable reference from validated manifest data and
call `newScope.rebindJob(reference)`. Rebinding checks ownership and performs
fresh exact scoped discovery bounded to 1000 rows. A reference is not proof;
missing jobs fail closed. There is no durable asset/raw upload ID rebinding API.

Use the existing
[ArchiveController](../example/05_framebase_userlogin/lib/data/archive_controller.dart)
for the filesystem recipe: immutable captured destinations/payloads, validated
owner metadata, paths constrained to the owner directory, staged writes, and
atomic replacement through `scope.storageLease.run(...)`. Call lease `check()`
immediately before publishing a staged file. Retire a host writer when its
feature ends; do not reopen a retired writer under the same session.

SDK owner commit coordination fences older writers, including A→B→A, within
one isolate. Shared multi-isolate/process storage needs one owner isolate or
transactional locking. Never assume independent in-memory queues synchronize it.

Cache identity adds current policy and every result-affecting parameter:
query, dates, version, pagination, search sources, and media variant. In-flight
dedup also includes `sessionId`. Quarantine legacy records with unknown ownership;
do not assign them to whoever next signs in. Sign-out can preserve partitioned
files for a later verified restoration while immediately hiding them from UI.

## 9. Set mobile file and interruption policies

The SDK targets Android/iOS; Web is outside this contract. Toolchain minimums
above are package constraints, not a claim about a particular app's Android
API level or iOS deployment target. Preserve your app's native targets and
check its plugin/build requirements on device. The SDK has no picker/camera UI
and does not justify broad photo/storage/camera permissions by itself.

### Picker/camera → reopenable upload

1. Obtain the file through the host's chosen picker/camera adapter and its actual
   platform permission flow. A `content://` URI is not automatically a Dart path.
2. If access is temporary, copy it into an app-owned owner-partitioned location
   while permission is valid. Keep filename, length, and contents stable.
3. Pass the readable `File` to `UploadSource.fromFile`. The SDK can reopen ranges;
   do not pass a one-shot stream as though it supports replay/resume.
4. Keep the file until the owning task and supported resume policy release it.
   Record temporary-file ownership and clean only files this feature owns.
5. After restart, validate owner, source existence/contract, and checkpoint
   envelope before offering continuation. Process death does not settle a Dart
   Future or prove that remote finalization failed.

### Adopt an explicit lifecycle policy

| Event | Framebase policy to reuse | Host decision |
| --- | --- | --- |
| Brief inactive interruption | Keep foreground work | Avoid unnecessary cancellation for transient system UI |
| Paused/hidden/detached | Cancel upload/local job wait and invalidate search view | Choose retained work only with explicit host ownership |
| Resume | No mutation/search replay | Rediscover current state; offer explicit resume/retry |
| Page pop | End view work | Cancel screen-owned work or detach from retained feature |
| Process death | Runtime session/controllers gone | Reauthenticate, restore validated records, rebind jobs, reconcile unknown mutations |

Hook these decisions into the app's lifecycle observer; keep them outside widget
`build()`. Do not claim a Dart upload survives termination. Background scheduling
and operating-system transfer semantics are host responsibilities.

Set image byte/count limits and bound concurrent loads. Dispose players on
view/session transitions and profile real devices. See
[performance.md](performance.md) for streaming and timeout budgets.
[transcode_360.md](transcode_360.md) describes a **tenant-scoped** custom reducer:
it cannot be injected into the restricted session upload API. A host adopting
that advanced path must own native success checking, output validity, cache
identity, concurrent destinations, temporary cleanup, and isolation.

## 10. Test and release the host integration

Use the SDK's existing injected transport factories and example fixtures;
do not introduce a second fake networking stack. Manager transport factories
must return distinct gateway/signed transports for each session. Start with
[session_fixture.dart](../example/05_framebase_userlogin/test/session_fixture.dart),
[user_session_controller_test.dart](../example/05_framebase_userlogin/test/user_session_controller_test.dart),
and [search_gateway_test.dart](../example/05_framebase_userlogin/test/search_gateway_test.dart).
Keep fake keys/envelopes clearly marked as fixtures.

| Arrange / act | Assert |
| --- | --- |
| Fake verified user and allowed envelope | Activation discovers collections before index/search; exact opaque ID unchanged |
| Empty discovery, missing version, empty search | Three distinct UI states; no implicit index submission |
| Query 1 finishes after query 2 | Only query 2 changes state; late errors also ignored |
| Dispose during debounce/media await | No dispatch after debounce disposal, no late UI publish, owned subscriptions end |
| Denied action or policy | Local failure before transport; no broader mapping fallback |
| Identity expiry vs tenant renewal failure | Sign-in required only for identity failure; connection recovery retains host user |
| A→B→A with delayed responses/progress/store writes | B never displays A; new A rejects old handles; old writer cannot overwrite new owner's state |
| Upload result lost / index acceptance lost | Unknown completion retained; no automatic duplicate mutation |
| Accepted job + restart | Durable owner fields restored; fresh rebind required; changed policy rejects old reference |
| Cloud success + local commit failure | Remote success retained; local repair does not re-upload/delete again |
| Widget account transition | Old players, decoded images, navigation/restoration, and controller references removed |

From the SDK checkout, use the pinned tools to verify SDK contracts and the
reference app. These commands are existing offline tests, not backend checks:

```bash
flutter_bin="$(bash install.sh flutter_bin)"
"$flutter_bin" test test/user_session_test.dart test/session_lifecycle_test.dart \
  test/session_storage_test.dart test/tenant_credentials_test.dart \
  test/user_provenance_test.dart
cd example/05_framebase_userlogin
"$flutter_bin" analyze
"$flutter_bin" test
```

For a host app, run its own analyzer/controller/widget tests and Android/iOS
device acceptance. Separate these from live service checks proving discovery,
date filters, actual terminal states, multipart availability, and any server
app-user authorization. Offline tests cannot prove server access isolation.

### Migration and app release checklist

- Choose a verified dependency containing the public APIs used; resolve the
  lockfile and inspect the actual package, not only a README version example.
- Replace project/client selectors with a trusted `UserScope`; replace raw IDs
  and signed media URLs with live handles and `imageBytes` in session features.
- Move key replacement to the tenant source; move account/policy changes to the
  manager. Preserve canonical nullable IDs and typed distance/offset semantics.
- Validate or quarantine legacy cache/archive ownership; persist durable job
  metadata rather than old live handles.
- Inject real host auth/issuer adapters; verify exact allowed mappings and
  backend features on the intended service.
- Exercise cancellation, pause/resume, restart, account switch, renewal failure,
  and unknown mutation completion on Android/iOS devices.
- Confirm foreground/background/file-retention policy and diagnostics in the
  app. SDK publication steps remain in [release.md](release.md).

### Common implementation mistakes

| Mistake | Apply this pattern |
| --- | --- |
| Call search in `build()` or create clients per tile | Inject one scope, start work from controller actions |
| Keep a scope across account/policy change | Recreate session-bound feature; key/replace the route |
| Use query cancellation without latest-result guard | Advance generation on query/cancel/dispose and check after await |
| Cancel token and report remote write rolled back | Record accepted/unknown outcome; reconcile |
| Treat tenant auth failure as host logout | Separate connection and identity state machines |
| Save API keys or runtime session IDs as archive identity | Use validated stable owner/scope/policy metadata |
| Show low-level signed URLs in a session feature | Use live `SessionAsset` and scoped media bytes |
| Treat upload complete or job accepted as searchable | Wait for terminal result and rediscover usable index version |

Documentation basis: local source and existing Framebase implementation reviewed
on 2026-10-02. This guide describes reusable app patterns; it does not claim a
production issuer, public package publication, device certification, or live
backend acceptance has been supplied by the example.
