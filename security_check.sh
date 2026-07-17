#!/usr/bin/env bash
help='
  Validate Flutter SDK release workflow, toolchain, metadata, package, and secret policy.

  Examples:
    bash security_check.sh workflow
    bash security_check.sh all
'
set -euo pipefail
cd "$(dirname "$0")"

sdk_security_workflow() {
  local help='
    ## Usage:
      bash security_check.sh workflow
  '
  local internal='../../.github/workflows/sdk_flutter_test_release.yml'
  local public='release/public_publish.yml'
  [[ -f "$internal" && -f "$public" ]] || { echo 'Flutter release workflow is missing.' >&2; return 2; }
  ! grep -Eiq 'maven|gradle publication|github packages|\bosv\b|\bsbom\b|security_policy' "$internal" "$public"
  ! grep -Eq 'uses:[[:space:]]+[^[:space:]]+@(v[0-9]|main|master|latest)' "$internal" "$public"
  grep -Eq 'permissions:[[:space:]]*$' "$internal"
  grep -Eq 'id-token:[[:space:]]+write' "$public"
  grep -Eq 'needs:[[:space:]]+verify_tagged_source' "$public"
  grep -Eq 'environment:[[:space:]]+pub\.dev' "$public"
  grep -Eq 'environment:[[:space:]]+sdk-flutter-production' "$internal"
  grep -Eq 'persist-credentials:[[:space:]]+false' "$internal" "$public"
  grep -Fq -- '--source "$WORKDIR"' "$internal"
  ! grep -Fq -- '--log-opts=' "$internal"
  grep -Fq 'RELEASE_TOKEN: ${{ secrets.GH_TOKEN }}' "$internal"
  ! grep -Fq 'FLUTTER_SDK_APP_' "$internal"
  ! grep -Eq 'git merge|git push[^\n]*--force|--skip-validation' "$internal" "$public"
  if grep -E 'uses:[[:space:]]+' "$internal" "$public" |
      grep -Ev 'uses:[[:space:]]+[^[:space:]]+@[0-9a-f]{40}([[:space:]]|$)' >/dev/null; then
    echo 'Every action must use a full commit SHA.' >&2
    return 3
  fi
}

sdk_security_toolchain() {
  local help='
    ## Usage:
      bash security_check.sh toolchain
  '
  local version rows
  version="$(tr -d '[:space:]' < .flutter-version)"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid Flutter version pin.' >&2; return 3; }
  rows="$(awk -v v="$version" '$1 == v {count++} END {print count + 0}' tool/flutter_checksums.txt)"
  [[ "$rows" == 3 ]] || { echo 'All three reviewed Flutter artifacts must be pinned.' >&2; return 3; }
  awk -v v="$version" '$1 == v && $4 !~ /^[0-9a-f]{64}$/ {exit 1}' tool/flutter_checksums.txt
}

sdk_security_version() {
  local help='
    ## Usage:
      bash security_check.sh version
  '
  "$(bash install.sh dart_bin)" run tool/release_manifest.dart check
}

sdk_security_license() {
  local help='
    ## Usage:
      bash security_check.sh license
  '
  [[ -s LICENSE ]] || { echo 'LICENSE is missing or empty.' >&2; return 3; }
  grep -q 'MIT License' LICENSE
  grep -q '^license: MIT$' pubspec.yaml
}

sdk_security_package() {
  local help='
    ## Usage:
      bash security_check.sh package
  '
  local listing
  listing="$(bash build.sh package 2>&1)"
  printf '%s\n' "$listing"
  ! grep -Eiq '(^|/)(\.env|ztmp|\.dart_tool|build|checkpoints?)(/|$)|private[_-]?key|presigned' <<<"$listing"
}

sdk_security_secrets() {
  local help='
    ## Usage:
      bash security_check.sh secrets
  '
  local detector_version='8.30.1'
  local platform detector_sha
  local cache="${XDG_CACHE_HOME:-$HOME/.cache}/vmodal/gitleaks/$detector_version"
  local archive="$cache/gitleaks.tar.gz" bin="$cache/gitleaks"
  case "$(uname -s):$(uname -m)" in
    Darwin:arm64) platform='darwin_arm64'; detector_sha='b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5' ;;
    Darwin:x86_64) platform='darwin_x64'; detector_sha='dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709' ;;
    Linux:x86_64) platform='linux_x64'; detector_sha='551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb' ;;
    *) echo 'No reviewed gitleaks artifact for this host.' >&2; return 2 ;;
  esac
  mkdir -p "$cache"
  if [[ ! -x "$bin" ]]; then
    curl --fail --location --retry 3 --output "$archive" \
      "https://github.com/gitleaks/gitleaks/releases/download/v${detector_version}/gitleaks_${detector_version}_${platform}.tar.gz"
    sdk_security_sha256 "$archive" "$detector_sha"
    tar -xzf "$archive" -C "$cache" gitleaks
    chmod 755 "$bin"
  fi
  "$bin" detect --source . --config .gitleaks.toml --no-banner --redact --no-git
}

sdk_security_sha256() {
  local help='
    ## Usage:
      sdk_security_sha256 FILE EXPECTED
  '
  local file="${1:?file required}" expected="${2:?checksum required}" got
  if command -v shasum >/dev/null 2>&1; then
    got="$(shasum -a 256 "$file" | awk '{print $1}')"
  else
    got="$(sha256sum "$file" | awk '{print $1}')"
  fi
  [[ "$got" == "$expected" ]] || { echo 'Security tool checksum mismatch.' >&2; return 3; }
}

sdk_security_all() {
  local help='
    ## Usage:
      bash security_check.sh all
  '
  sdk_security_workflow
  sdk_security_toolchain
  sdk_security_version
  sdk_security_license
  sdk_security_package
  sdk_security_secrets
}

sdk_security_help() {
  local help='
    ## Usage:
      bash security_check.sh help
  '
  echo "$help"
}

case "${1:-help}" in
  workflow) sdk_security_workflow ;;
  toolchain) sdk_security_toolchain ;;
  version) sdk_security_version ;;
  license) sdk_security_license ;;
  package) sdk_security_package ;;
  secrets) sdk_security_secrets ;;
  all) sdk_security_all ;;
  help|-h|--help) sdk_security_help ;;
  *) echo "Unknown command: ${1:-}" >&2; echo "$help" >&2; exit 2 ;;
esac
