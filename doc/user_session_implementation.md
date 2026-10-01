# App-user session implementation notes

Date: 2026-10-02

The nine requested specification blocks are implemented as an opt-in gateway
interface. Existing tenant-scoped wire APIs remain compatible. The specification
is a design input; this authored note and [SDK contract](sdk_contract.md) describe
the actual supported interface.

| Block | Implemented boundary | Verification focus |
| --- | --- | --- |
| 1. Credential model and guarantee | Shared tenant auth separated from stable host app-user identity; documented modified-client limitation | Same-key A/B tests; same tenant principal |
| 2. Tenant configuration / context | `TenantCredentialSource`, immutable `SessionContext`, policy fingerprints, revisions and renewal tickets | Coalesced/out-of-order renewal, external installs, rotation without identity change |
| 3. Session API | `UserSessionManager`, `UserSession`, `UserScope`, logical/opaque `ContentMapping` | Frozen mappings, exact selectors, private clients/providers/transports |
| 4. Central guard | Session/operation lease checks through preparation, retries, signed phases, response and listener delivery | Prompt cancellation with uncooperative I/O; caller token ownership; paused streams |
| 5. Resource identifiers / discovery | Live asset/job handles, restricted fields/counts/errors, durable job rebinding, bounded JSONL provenance | Cross-owner batches, unknown IDs, nested data, stream-only aggregate discovery |
| 6. Account switch / logout | Synchronous invalidation, latest activation ticket, instance-owned idempotent cleanup | A→B→A, late activation, reentrant callbacks, cleanup failure |
| 7. Cache / storage | Owner/policy multipart envelopes, serialized writer fences, public host storage lease | Identical upload contracts, same-owner reopen, stale save/remove, policy narrowing |
| 8. Reuse / host integration | Existing resources/transports reused; Framebase session gateway and exact owner archives | Host identity transitions, safe image bytes, no tenant-key-derived archive |
| 9. Acceptance tests | Focused same-key/session/rotation/storage tests plus existing SDK and example suites | SDK isolation asserted separately from server authorization |

## Docs impact checklist

- Subject changed: tenant credential versus app-user identity; runtime lifecycle,
  rotation, provenance/discovery, owner storage, host UI handoff, source release.
- Updated: root README, `sdk_contract.md`, `manage_api_key.md`, Framebase userlogin
  README, and this implementation note.
- Neighboring references checked: public API exports, config/provider/session/
  guard/resource implementations, Framebase credential/controller/gateway/archive
  contracts, existing package-install and source-publication guidance.
- Removed stale claims in touched docs: `auth.me()` as app-user owner, guaranteed
  per-user bearer authorization under a shared tenant key, scope-only archives,
  write grants implying collection-wide deletion, unrestricted session result
  URLs, and tenant `401` meaning Firebase logout.
- Existing low-level examples remain labeled tenant-scoped; they bypass the
  session guarantees. Published pub.dev `1.2.3`/tag install examples remain
  distinct from the new 1.3.0 source-only interface.

## Validation and publication

Local gates from the SDK root are `bash build.sh pub_get`, `bash build.sh format`,
`bash build.sh analyze`, `bash test.sh all`, and the pinned Dart command
`run tool/check_route_sync.dart`. They cover every SDK/example test suite,
formatting, analysis, package export, secret checks, simulation, and upstream
route synchronization. GitHub Actions separately gates Android/iOS builds and
the production live lifecycle before public publication. Focused session/guard/provider/
storage and Framebase suites cover deterministic account-switch and rotation
races. These are offline SDK-flow checks, not evidence of server-side app-user
authorization.

Final local results: all 207 SDK tests and all five example suites pass, including
53 Framebase tests. Formatting and analysis pass across the SDK and examples;
all 42 upstream route operations match. Package validation reports zero warnings,
secret detection reports zero leaks, simulation passes, and generated reference
validation verifies 1,011 sanitized source sections. The public revision is
recorded by the release change and GitHub Actions run. Public source publication uses
`.github/workflows/sdk_flutter_test_release.yml`; only its successful export
establishes the released public commit. This task does not publish a pub.dev
package or create a pub.dev version tag.

Storage coordination is guaranteed within one isolate. Shared files across
isolates/processes require one storage owner or a transactional lock. Signed
capabilities have independent revocation/expiry. Host UI caches, navigation,
players, copied files, and already delivered data require host cleanup; server
work already accepted remains owned by its originating user.

Framebase clears decoded image caches and replaces its navigation tree using
the SDK runtime session identity. Recording sheets retire their player on
invalidation; file selection and confirmation dialogs capture that same
identity before awaiting so a later activation cannot consume an earlier view's
decision.
