#!/bin/bash

set -Eeuo pipefail

source "$(dirname "$0")/common.sh"

require_container

if [[ ! -f "$KERNEL_PATH" ]]; then
  "${PROJECT_ROOT}/scripts/build-kernel.sh"
fi

container build \
  --platform linux/arm64 \
  --cpus 6 \
  --memory 10G \
  --pull \
  --tag "$IMAGE_NAME" \
  --file "${PROJECT_ROOT}/Containerfile" \
  "$PROJECT_ROOT"

container image inspect "$IMAGE_NAME" >/dev/null
printf 'Built image %s.\n' "$IMAGE_NAME"
