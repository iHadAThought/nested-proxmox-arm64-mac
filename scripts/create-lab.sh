#!/bin/bash

set -Eeuo pipefail

source "$(dirname "$0")/common.sh"

require_container

[[ -f "$KERNEL_PATH" ]] || die "kernel not found; run scripts/build-kernel.sh"
container image inspect "$IMAGE_NAME" >/dev/null 2>&1 ||
  die "image not found; run scripts/build-image.sh"

available_kb="$(df -Pk "$PROJECT_ROOT" | awk 'NR == 2 {print $4}')"
(( available_kb >= 40 * 1024 * 1024 )) ||
  die "at least 40 GiB free space is required before creating the lab"

if container_exists; then
  printf 'Container %s already exists; leaving it unchanged.\n' "$LAB_NAME"
  exit 0
fi

if ! container volume inspect "$DATA_VOLUME" >/dev/null 2>&1; then
  container volume create --opt "size=${DATA_VOLUME_SIZE}" "$DATA_VOLUME"
fi

container run \
  --detach \
  --name "$LAB_NAME" \
  --cpus "$LAB_CPUS" \
  --memory "$LAB_MEMORY" \
  --virtualization \
  --kernel "$KERNEL_PATH" \
  --cap-add ALL \
  --publish "127.0.0.1:${PVE_UI_PORT}:8006/tcp" \
  --publish "127.0.0.1:${PVE_SSH_PORT}:22/tcp" \
  --volume "${DATA_VOLUME}:/var/lib/vz" \
  "$IMAGE_NAME"

printf 'Waiting for the Proxmox lab bootstrap'
for _ in {1..90}; do
  if container exec "$LAB_NAME" \
    test -f /var/lib/pve-lab-bootstrap.complete >/dev/null 2>&1; then
    printf '\nLab bootstrap completed.\n'
    exit 0
  fi
  printf '.'
  sleep 2
done

printf '\n' >&2
container logs "$LAB_NAME" >&2 || true
die "lab did not complete bootstrap within three minutes"
