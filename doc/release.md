# Release process

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
`RELEASE_SHA` checkout and `git rev-parse` verification lines are retained as
comments so they can be restored later, but they do not gate the fast release
path. Jobs use the normal workflow checkout, while GitHub's built-in
`GITHUB_SHA` is recorded in artifacts, public commits, tags, and documentation
metadata for traceability. A secret-detection job scans the Flutter SDK tree
before source and documentation publication. Protected release approval remains
disabled during this development mode. Optional pub.dev publication is
triggered only by the exported version tag and uses OIDC trusted publishing; no
long-lived pub token is stored.

The offline job also analyzes and tests `example/05_framebase_userlogin` with
fake auth and transport. Its real Firebase and credential issuer integration
requires separate device verification once that server contract exists.

After the tested SDK source is published, the same workflow installs the pinned
Flutter toolchain, regenerates `docs_sdk` from the public Dart library, and
publishes the immutable class/method reference to the `gh-pages` branch of the
existing public repository `v-modal/vmodal_sdk_flutter`. Generation removes
only Dartdoc Implementation sections, validates required public symbols, and
fails when backend hosts, route prefixes, or implementation-only types appear.
The workflow pushes that branch directly, without opening a pull request, and
configures GitHub Pages for branch-based (`legacy`) publishing. It verifies the
recorded `GITHUB_SHA` at `https://v-modal.github.io/vmodal_sdk_flutter/`. The
deployment depends on both source publication and the active
secret-detection job. The private monorepo maintainer handbook owns the local
generation commands because the generator is intentionally absent from the
standalone public package.

Multipart is excluded from production live claims until all five backend routes
are verified. A failed publication is fixed forward with a new version after the
entire candidate pipeline passes again.
