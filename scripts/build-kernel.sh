#!/bin/bash

set -Eeuo pipefail

source "$(dirname "$0")/common.sh"

readonly CONTAINERIZATION_TAG="0.40.2"
readonly CONTAINERIZATION_COMMIT="5796abeaea5c25da3a0f32b6edee9219c7754c5b"
readonly LINUX_VERSION="6.18.5"
readonly LINUX_SHA256="189d1f409cef8d0d234210e04595172df392f8cb297e14b447ed95720e2fd940"
readonly WORK_DIR="${PROJECT_ROOT}/.cache/containerization-${CONTAINERIZATION_TAG}"
readonly SOURCE_ARCHIVE="${WORK_DIR}/kernel/source.tar.xz"

require_container
require_command git
require_command curl
require_command shasum

if [[ -d "$WORK_DIR/.git" ]]; then
  actual_commit="$(git -C "$WORK_DIR" rev-parse HEAD)"
  [[ "$actual_commit" == "$CONTAINERIZATION_COMMIT" ]] ||
    die "cached containerization checkout has unexpected commit: $actual_commit"
else
  mkdir -p "${PROJECT_ROOT}/.cache"
  git clone --depth 1 --branch "$CONTAINERIZATION_TAG" \
    https://github.com/apple/containerization.git "$WORK_DIR"
fi

actual_commit="$(git -C "$WORK_DIR" rev-parse HEAD)"
[[ "$actual_commit" == "$CONTAINERIZATION_COMMIT" ]] ||
  die "containerization tag resolved to unexpected commit: $actual_commit"

if [[ ! -f "$SOURCE_ARCHIVE" ]]; then
  curl --fail --location --proto '=https' \
    "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${LINUX_VERSION}.tar.xz" \
    --output "$SOURCE_ARCHIVE"
fi

actual_sha="$(shasum -a 256 "$SOURCE_ARCHIVE" | awk '{print $1}')"
[[ "$actual_sha" == "$LINUX_SHA256" ]] ||
  die "Linux source checksum mismatch: $actual_sha"

grep -qx 'CONFIG_KVM=y' "${WORK_DIR}/kernel/config-arm64" ||
  die "pinned Apple kernel configuration does not enable KVM"
grep -qx 'CONFIG_TUN=y' "${WORK_DIR}/kernel/config-arm64" ||
  die "pinned Apple kernel configuration does not enable TUN"
grep -qx 'CONFIG_BRIDGE=y' "${WORK_DIR}/kernel/config-arm64" ||
  die "pinned Apple kernel configuration does not enable bridge networking"

make -C "${WORK_DIR}/kernel" TARGET_ARCH=arm64
install -m 0644 "${WORK_DIR}/bin/vmlinux-arm64" "$KERNEL_PATH"

printf 'Built %s using containerization %s (%s).\n' \
  "$KERNEL_PATH" "$CONTAINERIZATION_TAG" "$CONTAINERIZATION_COMMIT"
