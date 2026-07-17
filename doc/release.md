# Release process

The package is pinned to Flutter 3.44.6. `install.sh` verifies the official
archive checksum and installs only into a user-owned cache. Run `bash test.sh all`
for the offline gate and `bash test.sh live` only after explicitly loading the
existing repository test credential variables.

Push and pull-request CI run the offline suite and Android/iOS example builds
without requiring the secret scanner or production API credential. A manual
publication checks out one immutable candidate SHA, scans the current
`uinterface/sdk_flutter` tree without scanning historical commits, runs the
credentialed live lifecycle, and exports one checksummed source artifact to the
public repository. These release-only jobs remain mandatory before source or
pub.dev publication. Optional pub.dev publication is triggered only by the
exported version tag and uses OIDC trusted publishing; no long-lived pub token is
stored.

Multipart is excluded from production live claims until all five backend routes
are verified. A failed publication is fixed forward with a new version after the
entire candidate pipeline passes again.
