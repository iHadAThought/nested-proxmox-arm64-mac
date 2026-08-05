#!/bin/bash

set -Eeuo pipefail

source "$(dirname "$0")/common.sh"

require_container
container_exists || die "lab does not exist; run scripts/create-lab.sh"

checks='
set -Eeuo pipefail

test "$(uname -m)" = "aarch64"
test -c /dev/kvm
test -r /dev/kvm
test -w /dev/kvm
grep -qx "1" /proc/sys/net/ipv4/ip_forward
ip -brief address show vmbr0 | grep -q "10.44.0.1/24"
nft list table inet pve_lab_filter >/dev/null
nft list table ip pve_lab_nat >/dev/null
systemctl is-active --quiet pve-cluster
systemctl is-active --quiet pvedaemon
systemctl is-active --quiet pveproxy
systemctl is-active --quiet pvestatd
systemctl is-active --quiet dnsmasq
pvesm status | grep -Eq "^local[[:space:]]+dir[[:space:]]+active"
pveversion | grep -q "^pve-manager/9\.2\."
qm list >/dev/null
curl --fail --silent --show-error --insecure https://127.0.0.1:8006/ >/dev/null
'

container exec "$LAB_NAME" /bin/bash -c "$checks"
curl --fail --silent --show-error --insecure \
  "https://127.0.0.1:${PVE_UI_PORT}/" >/dev/null

printf 'Lab verification passed: KVM, services, storage, NAT, and API are healthy.\n'
