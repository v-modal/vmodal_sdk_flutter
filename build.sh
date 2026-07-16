#!/usr/bin/env bash
help='
  Build and validate the VModal Flutter package.

  Examples:
    bash build.sh build
    bash build.sh test
    bash build.sh example_android
    bash build.sh package
'
set -euo pipefail
cd "$(dirname "$0")"
sdk_dir="$PWD"

sdk_flutter() {
  local help='
    ## Usage:
      sdk_flutter analyze
  '
  local bin
  bin="$(bash "$sdk_dir/install.sh" flutter_bin)"
  "$bin" "$@"
}

sdk_dart() {
  local help='
    ## Usage:
      sdk_dart format lib test
  '
  local bin
  bin="$(bash "$sdk_dir/install.sh" dart_bin)"
  "$bin" "$@"
}

sdk_pub_get() {
  local help='
    ## Usage:
      bash build.sh pub_get
  '
  bash install.sh check
  sdk_flutter pub get
  (cd example && sdk_flutter pub get)
}

sdk_format() {
  local help='
    ## Usage:
      bash build.sh format
  '
  sdk_dart format --output=none --set-exit-if-changed lib test tool example/lib example/test
}

sdk_analyze() {
  local help='
    ## Usage:
      bash build.sh analyze
  '
  sdk_flutter analyze
  (cd example && sdk_flutter analyze)
}

sdk_test() {
  local help='
    ## Usage:
      bash build.sh test
  '
  sdk_flutter test
  (cd example && sdk_flutter test)
}

sdk_example_android() {
  local help='
    ## Usage:
      bash build.sh example_android
  '
  (cd example && sdk_flutter build apk --debug)
}

sdk_example_ios() {
  local help='
    ## Usage:
      bash build.sh example_ios
  '
  [[ "$(uname -s)" == 'Darwin' ]] || { echo 'iOS builds require a configured macOS runner.' >&2; return 2; }
  (cd example && sdk_flutter build ios --simulator --debug --no-codesign)
}

sdk_package() {
  local help='
    ## Usage:
      bash build.sh package
  '
  local temp
  temp="$(mktemp -d "${TMPDIR:-/tmp}/vmodal-flutter-package.XXXXXX")"
  trap 'rm -rf "${temp:-}"' RETURN
  sdk_dart run tool/release_manifest.dart export "$temp"
  (cd "$temp" && sdk_dart pub publish --dry-run)
}

sdk_build() {
  local help='
    ## Usage:
      bash build.sh build
  '
  sdk_pub_get
  sdk_format
  sdk_analyze
  sdk_test
  sdk_package
  sdk_example_android
}

sdk_clean() {
  local help='
    ## Usage:
      bash build.sh clean
  '
  [[ "$PWD" == */uinterface/sdk_flutter ]] || { echo 'Refusing to clean outside sdk_flutter.' >&2; return 2; }
  sdk_flutter clean
  (cd example && sdk_flutter clean)
}

sdk_help() {
  local help='
    ## Usage:
      bash build.sh help
  '
  echo "$help"
}

case "${1:-help}" in
  build) sdk_build ;;
  pub_get) sdk_pub_get ;;
  format) sdk_format ;;
  analyze) sdk_analyze ;;
  test) sdk_test ;;
  example_android) sdk_example_android ;;
  example_ios) sdk_example_ios ;;
  package) sdk_package ;;
  clean) sdk_clean ;;
  help|-h|--help) sdk_help ;;
  *) echo "Unknown command: ${1:-}" >&2; echo "$help" >&2; exit 2 ;;
esac
