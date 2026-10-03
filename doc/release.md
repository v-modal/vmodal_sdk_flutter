# Release process

## Scoped authentication rollout gate

The source includes `connectWithBackend` and a separate
[backend-auth reference](../example/06_userlogin_backend_auth/README.md). Neither local
fixtures nor source export establish live support. Before releasing this mode,
complete the [backend acceptance sequence](auth_user_backend_mode.md#deployment-and-acceptance):
registered project/key/resource authority, bounded registry distribution,
origin RS256 issuance/validation, independent Worker VModal policy, and upstream
default-deny canonical grant enforcement. Test the real public edge chain with
raw cross-user requests and preserve direct-key regression.

The initial scoped route allowlist covers search, filtered group discovery and
four image operations. Indexation/upload/metadata/delete are denied until their
complete handler and side-protocol ownership contracts are enabled and tested.
Do not document these writes as available merely because Flutter exposes those
actions in its existing direct-auth session API.

The normal Dart build gates include the backend reference's dependency,
format, analysis and tests. Node is optional for Flutter consumers. Run the
reference backend's separate offline gate explicitly with Node 22+:

```bash
node --test example/06_userlogin_backend_auth/developer_backend/session_test.mjs
```

The Dart SDK suite covers strict envelopes, auth/me agreement, expiry, renewal,
and account fencing. The standalone export regression checks auth guides,
source, reference files and their local links, keeping `docs/todo` excluded.
Release workflows retain their existing secret-detection and publication gates.
Disabling issuance/registration rolls back scoped access while preserving direct
keys. No deployment or public publication is performed by adding these sources.

The package is pinned to Flutter 3.44.6. `install.sh` verifies the official
archive checksum and installs only into a user-owned cache. Run `bash test.sh all`
for the offline gate and `bash test.sh live` only after explicitly loading the
existing repository test credential variables.

The CCTV contract has a separate opt-in gate, `bash test.sh cctv_live`. It
uploads its own fixture and collection, verifies canonical timestamp fields,
metadata filters, and absolute JST/UTC ranges, then deletes only that temporary
collection. It remains outside `test.sh all` and the Flutter release workflow;
run it explicitly against a backend that has the CCTV search contract deployed.

The release workflow is manually dispatched during development. Exact-candidate
`ref` overrides remain commented, so jobs use the normal workflow checkout and
do not enforce a separate `git rev-parse` guard on the fast release path. The
workflow explicitly maps `github.sha` to `RELEASE_SHA`; release artifacts,
public commits, tags, and documentation metadata record that value for
traceability. Workflow steps only orchestrate named functions from a
monorepo-owned release helper; that private CI helper is not part of the
standalone SDK export. Its workspace, runner-temporary directory, publication
input, repository targets, and URLs remain explicit in the workflow. Credential
steps source `.github/workflows/utils.sh` and use the GitHub Actions secret
`INFISICAL_TOKEN` to load scoped Infisical keys. `GH_TOKEN` supplies public
repository and documentation publication; `TEST_CLIENT_CLERK_USER_API_TOKEN`
supplies `VMODAL_API_KEY` for live tests. The helper masks values and writes
them to `GITHUB_ENV` for subsequent steps in each job. A secret-detection job scans the Flutter SDK tree and source
publication waits for secret detection, offline tests, Android and iOS builds,
the live test, and the tested package artifact. Protected release approval
remains disabled during this development mode. Optional pub.dev publication is
triggered only by the exported version tag and uses OIDC trusted publishing; no
long-lived pub token is stored.

The Ubuntu Android build and package jobs clear unused preinstalled toolchains
and emulator images before building, since both examples can exhaust the hosted
runner's disk space.

The offline job also analyzes and tests `example/05_framebase_userlogin` with
fake auth and transport. Its real Firebase and credential issuer integration
requires separate device verification once that server contract exists.

After the tested SDK source is published, the same workflow installs the pinned
Flutter toolchain, regenerates `doc` from the public Dart library, and
publishes the immutable class/method reference to the `gh-pages` branch of the
existing public repository `v-modal/vmodal_sdk_flutter`. Generation removes
only Dartdoc Implementation sections, validates required public symbols, and
fails when backend hosts, route prefixes, or implementation-only types appear.
The workflow pushes that branch directly, without opening a pull request, and
configures GitHub Pages for branch-based (`legacy`) publishing. It verifies the
recorded `RELEASE_SHA` at `https://v-modal.github.io/vmodal_sdk_flutter/`. The
deployment depends on both source publication and the active
secret-detection job. The private monorepo maintainer handbook owns the local
generation commands because the generator is intentionally absent from the
standalone public package.

Multipart is excluded from production live claims until all five backend routes
are verified. A failed publication is fixed forward with a new version after the
entire candidate pipeline passes again. Before publishing, the package dry-run
must list `lib/vmodal_sdk_flutter.dart`; the release workflow also verifies
that the uploaded pub.dev archive contains that entrypoint, otherwise pub.dev
cannot build the SDK's Dartdoc library.
