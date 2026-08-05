#!/bin/bash

set -Eeuo pipefail

source "$(dirname "$0")/common.sh"

require_container
container_exists || die "lab does not exist; run scripts/create-lab.sh"

container exec --interactive "$LAB_NAME" /bin/bash -s <<'REMOTE'
set -Eeuo pipefail

readonly VM_ID=9000
readonly VM_NAME="debian-arm64-smoke"
readonly IMAGE_DIR="/var/lib/vz/template/qcow"
readonly IMAGE_NAME="debian-13-genericcloud-arm64.qcow2"
readonly IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/latest/${IMAGE_NAME}"
readonly SUMS_URL="https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS"

if qm status "$VM_ID" >/dev/null 2>&1; then
  echo "VM ${VM_ID} already exists; refusing to replace it." >&2
  exit 1
fi

install -d -m 0755 "$IMAGE_DIR"
cd "$IMAGE_DIR"

curl --fail --location --proto '=https' "$SUMS_URL" --output SHA512SUMS
curl --fail --location --proto '=https' "$IMAGE_URL" --output "$IMAGE_NAME"
grep " \*\\?${IMAGE_NAME}$" SHA512SUMS | sha512sum --check --strict

qm create "$VM_ID" \
  --name "$VM_NAME" \
  --description "Disposable ARM64 nested-KVM smoke test" \
  --memory 2048 \
  --cores 2 \
  --cpu host \
  --machine virt \
  --bios ovmf \
  --ostype l26 \
  --scsihw virtio-scsi-single \
  --net0 virtio,bridge=vmbr0,firewall=0 \
  --serial0 socket \
  --vga serial0

qm set "$VM_ID" --efidisk0 local:0,efitype=4m,pre-enrolled-keys=1
qm set "$VM_ID" \
  --scsi0 "local:0,import-from=${IMAGE_DIR}/${IMAGE_NAME},discard=on,ssd=1"
qm set "$VM_ID" \
  --scsi1 local:cloudinit \
  --ciuser pvelab \
  --ipconfig0 ip=dhcp
qm set "$VM_ID" --boot order=scsi0

qm start "$VM_ID"

mac_address="$(
  qm config "$VM_ID" |
    sed -n 's/^net0: virtio=\([^,]*\).*/\1/p' |
    tr '[:upper:]' '[:lower:]'
)"
[[ -n "$mac_address" ]]

guest_ip=""
for _ in {1..90}; do
  guest_ip="$(
    awk -v mac="$mac_address" 'tolower($2) == mac {print $3; exit}' \
      /var/lib/misc/dnsmasq.leases 2>/dev/null || true
  )"
  if [[ -n "$guest_ip" ]] && ping -c 1 -W 2 "$guest_ip" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if [[ -z "$guest_ip" ]]; then
  qm stop "$VM_ID" --skiplock 1 || true
  echo "VM booted but did not obtain a DHCP lease" >&2
  exit 1
fi

qm status "$VM_ID" | grep -q 'status: running'
echo "Nested ARM64 VM reached ${guest_ip}; stopping the smoke-test VM."
qm shutdown "$VM_ID" --timeout 30 || qm stop "$VM_ID"
qm status "$VM_ID" | grep -q 'status: stopped'
REMOTE

printf 'Nested ARM64 KVM smoke test passed; VM 9000 is stopped.\n'
