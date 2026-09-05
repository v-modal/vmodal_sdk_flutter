#!/usr/bin/env bash
# Captures framed screenshots while an integration test drives the app, and
# keeps the device fixtures in place while it runs.
#
# The test writes a flag file into the app's Documents folder at each screenshot
# point and waits for it to disappear. This watches for those flags, captures
# the device screen, frames it, and deletes the flag so the test carries on.
#
# It re-resolves the container every pass, because installing the app moves it,
# and it plants the API key there so a driven run can connect without the key
# ever appearing in the test, the repo or a command.
#
#   tool/shoot.sh &
#   flutter drive --driver test_driver/integration_test.dart --target <test>
set -uo pipefail

BUNDLE_ID="com.brpetrov.sightline"
OUT="${OUT:-../screenshots}"
BORDER="${BORDER:-26}"
KEY_FILE="${KEY_FILE:-../../../secrets.md}"
DEADLINE=$(( $(date +%s) + 900 ))

mkdir -p "$OUT"
key=$(grep -o 'ak_[A-Za-z0-9]\{20,\}' "$KEY_FILE" 2>/dev/null | head -1)
[ -n "$key" ] && echo "key found for planting" || echo "no key file at $KEY_FILE"

while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  docs="$(xcrun simctl get_app_container booted "$BUNDLE_ID" data 2>/dev/null)/Documents"
  if [ -d "$docs" ]; then
    # A key for the driven run to type into the sheet. The app never reads
    # this file; only the walkthrough does, which keeps the key out of the repo
    # and still shows setup happening on screen.
    if [ -n "$key" ] && [ ! -s "$docs/.demo_key" ]; then
      printf '%s' "$key" > "$docs/.demo_key"
      echo "planted a key for the walkthrough to type"
    fi
    # PLANT_SETTINGS reproduces "the key was saved on a previous run", which a
    # clean install would otherwise wipe between two driven runs.
    if [ -n "${PLANT_SETTINGS:-}" ] && [ -n "$key" ] && \
       [ ! -s "$docs/sightline.json" ]; then
      printf '{"apiKey":"%s","collections":{"traffic":"%s"},"remember":true}' \
        "$key" "${TRAFFIC_COLLECTION:-traffic_camera}" > "$docs/sightline.json"
      echo "planted saved settings"
    fi
    flag=$(ls -a "$docs" 2>/dev/null | grep '^\.shot_' | head -1)
    if [ -n "$flag" ]; then
      name="${flag#.shot_}"
      raw="/tmp/shot_raw_$$.png"
      xcrun simctl io booted screenshot --mask=black "$raw" >/dev/null 2>&1
      ffmpeg -v error -y -i "$raw" \
        -filter_complex "pad=iw+${BORDER}*2:ih+${BORDER}*2:${BORDER}:${BORDER}:black" \
        "$OUT/$name.png"
      rm -f "$raw" "$docs/$flag"
      echo "captured $OUT/$name.png"
    fi
  fi
  sleep 0.3
done
