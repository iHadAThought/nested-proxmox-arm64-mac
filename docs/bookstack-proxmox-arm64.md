# Proxmox VE 9.2 ARM64 nested lab on Apple Containerization

## Purpose and support status

This page documents the disposable Proxmox VE 9.2 ARM64 lab running on an
Apple M4 Mac. The lab exists to test Proxmox ARM64 and small ARM64 KVM guests.

**Support classification:** experimental and non-production.

Do not add this node to the production Proxmox cluster. Do not attach the NAS,
production VLANs, backup credentials, or production workloads.

## Architecture

| Component | Configuration |
|---|---|
| Host | Apple M4, macOS 26+ |
| Runtime | Apple `container` 1.2.0 |
| Containerization source | 0.40.2 |
| Nested kernel | Linux 6.18.5, `CONFIG_KVM=y` |
| Proxmox | VE 9.2 ARM64 userspace |
| Resources | 6 vCPU, 12 GiB RAM |
| Persistent storage | `pve-arm64-data`, 32 GiB |
| Management UI | `https://127.0.0.1:8006` |
| SSH | `127.0.0.1:2222` |
| Guest network | `10.44.0.0/24`, NAT |
| Proxmox node name | `pve-arm64-lab` |

Traffic flows from nested guests through `vmbr0`, nftables masquerading, the
Apple container network, and then the Mac's normal egress. No guest MAC address
is exposed to the physical LAN.

## Initial deployment

From `/Users/brendan/Projects/containers`:

```bash
./scripts/install-container.sh
./scripts/build-kernel.sh
./scripts/build-image.sh
./scripts/create-lab.sh
./scripts/set-password.sh --generate
./scripts/verify-lab.sh
./scripts/create-test-vm.sh
```

The generated `root@pam` password is stored in the user's macOS Keychain:

```bash
security find-generic-password -w -s pve-arm64-lab -a root@pam
```

Never paste this password into BookStack, Git, shell scripts, or tickets.

## Routine operations

```bash
./scripts/labctl.sh status
./scripts/labctl.sh start
./scripts/labctl.sh stop
./scripts/labctl.sh restart
./scripts/labctl.sh logs
```

After startup, validate before using the lab:

```bash
./scripts/verify-lab.sh
```

Open <https://127.0.0.1:8006> and sign in as `root@pam`. A self-signed
certificate warning is expected because the service is not exposed beyond
loopback.

## Network configuration

`vmbr0` is an internal bridge with address `10.44.0.1/24`. Dnsmasq provides
leases from `10.44.0.100` through `10.44.0.199`. nftables permits guest
forwarding only from the private bridge and masquerades outbound IPv4 traffic.

Do not change `vmbr0` to bridge the Apple container's external interface. The
outer network does not provide a supported production bridge for multiple
nested guest MAC addresses.

## Verification evidence

The verification scripts check:

- ARM64 architecture and readable/writable `/dev/kvm`
- IPv4 forwarding, `vmbr0`, nftables filtering, and NAT
- `pve-cluster`, `pvedaemon`, `pveproxy`, and `pvestatd`
- Active local Proxmox storage
- Proxmox VE 9.2 API on both container loopback and macOS loopback
- An ARM64 UEFI guest can start, receive DHCP, respond to ping, and stop

Smoke-test VM `9000` is deliberately left stopped after validation.

## Credential rotation

Run:

```bash
./scripts/set-password.sh
```

The interactive mode requires at least 16 characters with uppercase,
lowercase, numeric, and symbol characters. It does not store the replacement
password.

If a generated Keychain credential is rotated manually, remove the obsolete
entry:

```bash
security delete-generic-password -s pve-arm64-lab -a root@pam
```

## Recovery

1. Check `./scripts/labctl.sh status`.
2. Inspect `./scripts/labctl.sh logs`.
3. Restart with `./scripts/labctl.sh restart`.
4. Run `./scripts/verify-lab.sh`.
5. If only VM `9000` failed, inspect its task log and serial console in
   Proxmox; do not delete other resources automatically.

If the custom kernel no longer boots after an Apple runtime update, rebuild it
from the pinned source with `./scripts/build-kernel.sh`, rebuild the image, and
repeat validation in a newly created lab.

## Stability testing

Short-horizon suite (completed 2026-08-05: 22/22 PASS):

```bash
RESTART_ITERS=10 GUEST_ITERS=10 API_SOAK_SECS=1800 ./scripts/stability-test.sh all
```

Long-horizon suite (ongoing — not a production gate):

```bash
SKIP_SLEEP_WAKE=1 caffeinate -dims ./scripts/long-term-stability.sh all
./scripts/long-term-stability.sh sleep-wake   # interactive, separate
```

Canonical write-ups for GitHub:

- `docs/TESTING.md` — methodology and pass criteria
- `docs/RESULTS.md` — dated evidence
- `README.md` — current state and setup

## Destruction

```bash
./scripts/labctl.sh destroy --destroy-data
```

The command asks for the exact name `pve-arm64-lab` before deleting the
container and 32 GiB data volume. It does not delete kernel build artifacts or
the source cache.

## Explicitly unsupported

- Production workloads or availability claims
- Joining an existing Proxmox cluster
- Ceph, HA, ZFS, migration, PCI, USB, or GPU passthrough
- Direct production VLAN or NAS access
- x86 guests
- Relying on this environment for backups
