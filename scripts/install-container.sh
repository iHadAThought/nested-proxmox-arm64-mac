#!/bin/bash

set -Eeuo pipefail

readonly CONTAINER_VERSION="1.2.0"
readonly PACKAGE_NAME="container-${CONTAINER_VERSION}-installer-signed.pkg"
readonly PACKAGE_SHA256="d140d4076ff0593d6b4f7c58722717b2abe87d75452cfe0a203792ba7f48f07c"
readonly PACKAGE_PATH="/tmp/${PACKAGE_NAME}"
readonly PACKAGE_URL="https://github.com/apple/container/releases/download/${CONTAINER_VERSION}/${PACKAGE_NAME}"

[[ "$(uname -m)" == "arm64" ]] ||
  { echo "Apple Silicon is required." >&2; exit 1; }

macos_major="$(sw_vers -productVersion | cut -d. -f1)"
(( macos_major >= 26 )) ||
  { echo "macOS 26 or newer is required." >&2; exit 1; }

chip="$(system_profiler SPHardwareDataType | awk -F': ' '/Chip:/ {print $2; exit}')"
[[ "$chip" =~ ^Apple[[:space:]]M([3-9]|[1-9][0-9]) ]] ||
  { echo "Nested virtualization requires M3 or newer; found ${chip}." >&2; exit 1; }

if ! command -v container >/dev/null 2>&1; then
  curl --fail --location --proto '=https' "$PACKAGE_URL" --output "$PACKAGE_PATH"
  echo "${PACKAGE_SHA256}  ${PACKAGE_PATH}" | shasum -a 256 --check --strict
  pkgutil --check-signature "$PACKAGE_PATH" |
    grep -q "signed by a developer certificate issued by Apple"
  sudo /usr/sbin/installer -pkg "$PACKAGE_PATH" -target /
fi

if ! container system status >/dev/null 2>&1; then
  printf 'y\n' | container system start
fi

container --version
container system status
