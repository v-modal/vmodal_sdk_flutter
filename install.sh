#!/usr/bin/env bash
help='
  Install or locate the pinned Flutter SDK in a user-owned cache.

  Examples:
    bash install.sh install
    bash install.sh check
    bash install.sh flutter_bin
    bash install.sh dart_bin
'
set -euo pipefail
cd "$(dirname "$0")"

sdk_os_arch() {
  local help='
    ## Usage:
      bash install.sh os_arch
  '
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os:$arch" in
    Darwin:x86_64) echo 'macos-x64' ;;
    Darwin:arm64) echo 'macos-arm64' ;;
    Linux:x86_64) echo 'linux-x64' ;;
    *) echo "Unsupported Flutter host: $os $arch" >&2; return 2 ;;
  esac
}

sdk_check_sha256() {
  local help='
    ## Usage:
      sdk_check_sha256 FILE EXPECTED_SHA256
  '
  local file="${1:?file required}" expected="${2:?checksum required}" got
  if command -v shasum >/dev/null 2>&1; then
    got="$(shasum -a 256 "$file" | awk '{print $1}')"
  elif command -v sha256sum >/dev/null 2>&1; then
    got="$(sha256sum "$file" | awk '{print $1}')"
  else
    echo 'A SHA-256 utility is required (shasum or sha256sum).' >&2
    return 2
  fi
  [[ "$got" == "$expected" ]] || { echo 'Flutter archive checksum mismatch.' >&2; return 3; }
}

sdk_flutter_version() {
  local help='
    ## Usage:
      sdk_flutter_version
  '
  tr -d '[:space:]' < .flutter-version
}

sdk_cache_root() {
  local help='
    ## Usage:
      sdk_cache_root
  '
  echo "${VMODAL_FLUTTER_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/vmodal/flutter}"
}

sdk_binary_version() {
  local help='
    ## Usage:
      sdk_binary_version /path/to/flutter
  '
  "${1:?flutter executable required}" --version --machine 2>/dev/null |
    sed -n 's/.*"frameworkVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
    head -n 1
}

sdk_flutter_home() {
  local help='
    ## Usage:
      bash install.sh flutter_home
  '
  local version system cached
  version="$(sdk_flutter_version)"
  if command -v flutter >/dev/null 2>&1; then
    system="$(command -v flutter)"
    if [[ "$(sdk_binary_version "$system")" == "$version" ]]; then
      cd "$(dirname "$system")/.." && pwd
      return
    fi
  fi
  cached="$(sdk_cache_root)/$version/flutter"
  if [[ -x "$cached/bin/flutter" ]] && [[ "$(sdk_binary_version "$cached/bin/flutter")" == "$version" ]]; then
    echo "$cached"
    return
  fi
  echo "Pinned Flutter $version is not installed. Run: bash install.sh install" >&2
  return 1
}

sdk_flutter_bin() {
  local help='
    ## Usage:
      bash install.sh flutter_bin
  '
  echo "$(sdk_flutter_home)/bin/flutter"
}

sdk_dart_bin() {
  local help='
    ## Usage:
      bash install.sh dart_bin
  '
  echo "$(sdk_flutter_home)/bin/dart"
}

sdk_install_flutter() {
  local help='
    ## Usage:
      bash install.sh install_flutter
  '
  local version platform row archive checksum cache final temp bundle url
  version="$(sdk_flutter_version)"
  platform="$(sdk_os_arch)"
  row="$(awk -v v="$version" -v p="$platform" '$1 == v && $2 == p {print $0}' tool/flutter_checksums.txt)"
  [[ -n "$row" ]] || { echo "No reviewed Flutter artifact for $version $platform" >&2; return 2; }
  archive="$(awk '{print $3}' <<<"$row")"
  checksum="$(awk '{print $4}' <<<"$row")"
  cache="$(sdk_cache_root)"
  final="$cache/$version"
  if [[ -x "$final/flutter/bin/flutter" ]] && [[ "$(sdk_binary_version "$final/flutter/bin/flutter")" == "$version" ]]; then
    return
  fi
  command -v curl >/dev/null 2>&1 || { echo 'curl is required.' >&2; return 2; }
  mkdir -p "$cache"
  temp="$(mktemp -d "$cache/.flutter-${version}.XXXXXX")"
  bundle="$temp/$(basename "$archive")"
  trap 'rm -rf "${temp:-}"' RETURN
  url="https://storage.googleapis.com/flutter_infra_release/releases/$archive"
  curl --fail --location --retry 3 --retry-delay 2 --output "$bundle" "$url"
  sdk_check_sha256 "$bundle" "$checksum"
  case "$archive" in
    *.zip) command -v unzip >/dev/null 2>&1; unzip -q "$bundle" -d "$temp/extract" ;;
    *.tar.xz) command -v tar >/dev/null 2>&1; mkdir -p "$temp/extract"; tar -xJf "$bundle" -C "$temp/extract" ;;
    *) echo 'Unsupported Flutter archive format.' >&2; return 2 ;;
  esac
  [[ "$(sdk_binary_version "$temp/extract/flutter/bin/flutter")" == "$version" ]] || {
    echo 'Extracted Flutter version does not match the pin.' >&2
    return 3
  }
  rm -rf "$temp/stage"
  mv "$temp/extract" "$temp/stage"
  rm -rf "$final.partial"
  mv "$temp/stage" "$final.partial"
  rm -rf "$final"
  mv "$final.partial" "$final"
  "$final/flutter/bin/flutter" config --no-analytics >/dev/null
}

sdk_check_tools() {
  local help='
    ## Usage:
      bash install.sh check
  '
  local flutter_bin dart_bin version
  flutter_bin="$(sdk_flutter_bin)"
  dart_bin="$(sdk_dart_bin)"
  version="$(sdk_flutter_version)"
  [[ "$(sdk_binary_version "$flutter_bin")" == "$version" ]] || { echo 'Flutter version mismatch.' >&2; return 3; }
  "$dart_bin" --version
  "$flutter_bin" pub get
}

sdk_install() {
  local help='
    ## Usage:
      bash install.sh install
  '
  sdk_install_flutter
  sdk_check_tools
}

sdk_help() {
  local help='
    ## Usage:
      bash install.sh help
  '
  echo "$help"
}

case "${1:-help}" in
  install) sdk_install ;;
  install_flutter) sdk_install_flutter ;;
  check) sdk_check_tools ;;
  flutter_home) sdk_flutter_home ;;
  flutter_bin) sdk_flutter_bin ;;
  dart_bin) sdk_dart_bin ;;
  os_arch) sdk_os_arch ;;
  help|-h|--help) sdk_help ;;
  *) echo "Unknown command: ${1:-}" >&2; echo "$help" >&2; exit 2 ;;
esac
