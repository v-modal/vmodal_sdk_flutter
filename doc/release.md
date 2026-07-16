# Release process

The package is pinned to Flutter 3.44.6. `install.sh` verifies the official
archive checksum and installs only into a user-owned cache. Run `bash test.sh all`
for the offline gate and `bash test.sh live` only after explicitly loading the
existing repository test credential variables.

The internal workflow checks out one immutable candidate SHA, runs secret
detection only on the current `uinterface/sdk_flutter` tree and that path's Git
history, then runs offline tests, Android/iOS example builds, the live
signed-upload lifecycle, and package dry-run. It exports one checksummed source
artifact to the public repository. Optional pub.dev publication is triggered
only by the exported version tag and uses OIDC trusted publishing; no long-lived
pub token is stored.

Multipart is excluded from production live claims until all five backend routes
are verified. A failed publication is fixed forward with a new version after the
entire candidate pipeline passes again.
