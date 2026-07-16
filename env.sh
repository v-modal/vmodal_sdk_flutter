#!/usr/bin/env bash
help='
  Derive Flutter SDK live/release variable aliases without storing values.

  Examples:
    source env.sh && sdk_env_live
    bash env.sh live
    bash env.sh release
'

sdk_env_live() {
  local help='
    ## Usage:
      source env.sh && sdk_env_live
  '
  export VMODAL_API_KEY="${VMODAL_API_KEY:-${TEST_CLIENT_CLERK_USER_API_TOKEN:-}}"
  export VMODAL_BASE_URL="${VMODAL_BASE_URL:-${TEST_CLIENT_SERVER_API_URL:-}}"
  export VMODAL_USER_ID="${VMODAL_USER_ID:-${TEST_CLIENT_USER_ID:-}}"
  export VMODAL_ENV="${VMODAL_ENV:-prd}"
}

sdk_env_release() {
  local help='
    ## Usage:
      source env.sh && sdk_env_release
  '
  export GH_TOKEN="${GH_TOKEN:-}"
}

sdk_env_help() {
  local help='
    ## Usage:
      bash env.sh help
  '
  echo "$help"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  cd "$(dirname "$0")"
  case "${1:-help}" in
    live) sdk_env_live ;;
    release) sdk_env_release ;;
    help|-h|--help) sdk_env_help ;;
    *) echo "Unknown command: ${1:-}" >&2; echo "$help" >&2; exit 2 ;;
  esac
fi
