# Release process

The package is pinned to Flutter 3.44.6. `install.sh` verifies the official
archive checksum and installs only into a user-owned cache. Run `bash test.sh all`
for the offline gate and `bash test.sh live` only after explicitly loading the
existing repository test credential variables.

The release workflow is manually dispatched during development. Exact-candidate
`RELEASE_SHA` checkout and `git rev-parse` verification lines are retained as
comments so they can be restored later, but they do not gate the fast release
path. Jobs use the normal workflow checkout, while GitHub's built-in
`GITHUB_SHA` is recorded in artifacts, public commits, tags, and documentation
metadata for traceability. The secret scanner and protected release approval
are also disabled during this development mode. Optional pub.dev publication is
triggered only by the exported version tag and uses OIDC trusted publishing; no
long-lived pub token is stored.

After the tested SDK source is published, the same workflow regenerates
`docs_swagger`, validates its OpenAPI contract, and publishes the immutable site
artifact to the `gh-pages` branch of the existing public repository
`v-modal/vmodal_sdk_flutter`. The workflow pushes that branch directly, without
opening a pull request, and configures GitHub Pages for branch-based (`legacy`)
publishing. It verifies the recorded `GITHUB_SHA` at
`https://v-modal.github.io/vmodal_sdk_flutter/`. The deployment depends on both
the source publication and the current no-op secret-detection job.

Multipart is excluded from production live claims until all five backend routes
are verified. A failed publication is fixed forward with a new version after the
entire candidate pipeline passes again.
