#!/usr/bin/env bash
help='
  Run the deterministic SDK simulation or the example on one chosen device.

  Examples:
    bash run.sh sim
    bash run.sh example --device emulator-5554
'
set -euo pipefail
cd "$(dirname "$0")"
sdk_dir="$PWD"

sdk_dart() {
  local help='
    ## Usage:
      sdk_dart run tool/sim.dart
  '
  local bin
  bin="$(bash "$sdk_dir/install.sh" dart_bin)"
  "$bin" "$@"
}

sdk_flutter() {
  local help='
    ## Usage:
      sdk_flutter devices
  '
  local bin
  bin="$(bash "$sdk_dir/install.sh" flutter_bin)"
  "$bin" "$@"
}

sdk_run_sim() {
  local help='
    ## Usage:
      bash run.sh sim
  '
  sdk_dart run tool/sim.dart
}

sdk_run_example() {
  local help='
    ## Usage:
      bash run.sh example --device DEVICE_ID
  '
  shift || true
  local device=''
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --device) device="${2:-}"; shift 2 ;;
      *) echo "Unknown example argument: $1" >&2; return 2 ;;
    esac
  done
  [[ -n "$device" ]] || { echo '--device DEVICE_ID is required.' >&2; return 2; }
  (cd example && sdk_flutter run --device-id "$device")
}

sdk_help() {
  local help='
    ## Usage:
      bash run.sh help
  '
  echo "$help"
}

case "${1:-sim}" in
  sim) sdk_run_sim ;;
  example) sdk_run_example "$@" ;;
  help|-h|--help) sdk_help ;;
  *) echo "Unknown command: ${1:-}" >&2; echo "$help" >&2; exit 2 ;;
esac
