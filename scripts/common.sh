#!/bin/bash

set -Eeuo pipefail

readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly LAB_NAME="${LAB_NAME:-pve-arm64-lab}"
readonly IMAGE_NAME="${IMAGE_NAME:-local/pve-arm64-lab:9.2}"
readonly DATA_VOLUME="${DATA_VOLUME:-pve-arm64-data}"
readonly KERNEL_PATH="${KERNEL_PATH:-${PROJECT_ROOT}/artifacts/vmlinux-arm64}"
readonly PVE_UI_PORT="${PVE_UI_PORT:-8006}"
readonly PVE_SSH_PORT="${PVE_SSH_PORT:-2222}"
readonly LAB_CPUS="${LAB_CPUS:-6}"
readonly LAB_MEMORY="${LAB_MEMORY:-12G}"
readonly DATA_VOLUME_SIZE="${DATA_VOLUME_SIZE:-32G}"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_container() {
  require_command container
  container system status >/dev/null 2>&1 ||
    die "Apple container system is not running; run: container system start"
}

container_exists() {
  container inspect "$LAB_NAME" >/dev/null 2>&1
}

container_running() {
  container list --format json 2>/dev/null |
    /usr/bin/python3 -c '
import json, sys
name = sys.argv[1]
try:
    rows = json.load(sys.stdin)
except json.JSONDecodeError:
    raise SystemExit(1)
raise SystemExit(0 if any(
    row.get("configuration", {}).get("id") == name
    or row.get("id") == name
    for row in rows
) else 1)
' "$LAB_NAME"
}
