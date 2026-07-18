#!/usr/bin/env bash
help='
  Run VModal Flutter offline, regression, package, security, or explicit live gates.

  Examples:
    bash test.sh test
    bash test.sh regression S16
    bash test.sh all
    bash test.sh live
'
set -euo pipefail
cd "$(dirname "$0")"

sdk_test() {
  local help='
    ## Usage:
      bash test.sh test
  '
  bash install.sh check
  bash build.sh test
}

sdk_regression() {
  local help='
    ## Usage:
      bash test.sh regression S16
  '
  local step="${1:-}" flutter
  case "$step" in
    S04|S05|S06|S07|S08|S09|S10|S11_1|S11_2|S11_3|S11_4|S11_5|S11_6|S11|S12|S13|S14|S15|S16|S17|S18|S19) ;;
    *) echo "Unknown regression step: $step" >&2; return 2 ;;
  esac
  bash build.sh format
  bash build.sh analyze
  flutter="$(bash install.sh flutter_bin)"
  "$flutter" test test/config_routes_test.dart
  [[ "$step" == 'S04' ]] || "$flutter" test test/fakes_test.dart test/auth_http_test.dart
  case "$step" in
    S04|S05|S06|S07|S08) ;;
    *) "$flutter" test test/transport_test.dart ;;
  esac
  case "$step" in
    S04|S05|S06|S07|S08|S09|S10) ;;
    *) "$flutter" test test/resources_models_test.dart ;;
  esac
  case "$step" in
    S12|S13|S14|S15|S16|S17|S18|S19) "$flutter" test test/upload_test.dart ;;
  esac
  case "$step" in
    S15|S16|S17|S18|S19) "$flutter" test test/multipart_upload_test.dart ;;
  esac
  case "$step" in
    S16|S17|S18|S19) "$flutter" test test/adaptive_upload_test.dart ;;
  esac
  case "$step" in
    S11|S12|S13|S14|S15|S16|S17|S18|S19) "$flutter" test ;;
  esac
  "$(bash install.sh dart_bin)" run tool/check_route_sync.dart
  case "$step" in
    S17|S18|S19) bash build.sh package; bash build.sh example_android ;;
  esac
  case "$step" in
    S18|S19) bash security_check.sh all; sdk_live ;;
  esac
}

sdk_sim() {
  local help='
    ## Usage:
      bash test.sh sim
  '
  bash run.sh sim
}

sdk_security() {
  local help='
    ## Usage:
      bash test.sh security
  '
  bash security_check.sh all
}

sdk_package() {
  local help='
    ## Usage:
      bash test.sh package
  '
  bash build.sh package
}

sdk_live_lancedb_version() {
  local help='
    ## Usage:
      sdk_live_lancedb_version

    Upload a video, create its index, read the advertised LanceDB version,
    and verify that search sends that version successfully.
  '
  echo 'Live gate: collection metadata -> version_lancedb search'
  "$(bash install.sh dart_bin)" run tool/live_test.dart
}

sdk_live() {
  local help='
    ## Usage:
      source ../../ztmp/env_gitignore.sh
      bash test.sh live
  '
  source env.sh
  sdk_env_live
  [[ -n "${VMODAL_API_KEY:-}" ]] || { echo 'Live API credential is required.' >&2; return 2; }
  sdk_live_lancedb_version
}

sdk_all() {
  local help='
    ## Usage:
      bash test.sh all
  '
  sdk_test
  sdk_security
  sdk_package
  sdk_sim
}

sdk_clean() {
  local help='
    ## Usage:
      bash test.sh clean
  '
  bash build.sh clean
}

sdk_help() {
  local help='
    ## Usage:
      bash test.sh help
  '
  echo "$help"
}

case "${1:-test}" in
  test) sdk_test ;;
  regression) shift; sdk_regression "${1:-}" ;;
  sim) sdk_sim ;;
  security) sdk_security ;;
  package) sdk_package ;;
  live) sdk_live ;;
  all) sdk_all ;;
  clean) sdk_clean ;;
  help|-h|--help) sdk_help ;;
  *) echo "Unknown command: ${1:-}" >&2; echo "$help" >&2; exit 2 ;;
esac
