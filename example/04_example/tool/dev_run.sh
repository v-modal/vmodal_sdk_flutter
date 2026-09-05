#!/usr/bin/env bash
# Build, install and launch a debug build on the booted iOS simulator.
#
#   tool/dev_run.sh
#   FLUTTER=/path/to/flutter tool/dev_run.sh
#
# The API key is never passed here. Paste it into the app once; a debug build
# remembers it between launches so a demo run does not need it again.
set -euo pipefail

BUNDLE_ID="com.brpetrov.sightline"
FLUTTER="${FLUTTER:-flutter}"

"$FLUTTER" build ios --simulator --debug
xcrun simctl terminate booted "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install booted build/ios/iphonesimulator/Runner.app
xcrun simctl launch booted "$BUNDLE_ID"
