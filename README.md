# Nested Proxmox VE ARM64 lab

Experimental **Proxmox VE 9.2 ARM64** running inside an Apple Containerization
micro-VM with nested KVM. Built to explore Proxmox on ARM64 and boot disposable
ARM64 guests on Apple Silicon—not to replace a bare-metal Proxmox host.

> **Status:** experimental / non-production.
> Short-horizon stability is green. **Long-horizon testing is ongoing.**
> See [docs/RESULTS.md](docs/RESULTS.md) and [docs/TESTING.md](docs/TESTING.md).
> The Forgejo repository is the authoritative post-wipe source; the GitHub
> mirror does not yet contain the final handoff commit.

## Why this exists

Apple's `container` runtime can expose nested virtualization on M3+ hardware.
That makes it possible to run Proxmox VE's ARM64 userspace and start KVM guests
inside a Linux micro-VM on a Mac. This repo packages that path as a
repeatable, isolated lab:

- pinned KVM-enabled kernel (Apple Containerization + Linux 6.18.5)
- pinned Proxmox VE 9.2 packages
- private NAT for guests (`10.44.0.0/24`)
- loopback-only management UI/SSH
- short- and long-horizon stability harnesses

It is **not** a supported Proxmox deployment. Official Proxmox ARM64 targets
UEFI/ACPI ARM servers (for example NVIDIA Grace/Vera), not Apple hardware.

## Current state (2026-08-05)

| Item | Value |
|---|---|
| Classification | Experimental nested lab |
| Host verified | Apple M4, macOS 26.5 |
| Runtime | Apple `container` 1.2.0 |
| Kernel | Linux 6.18.5 (`CONFIG_KVM=y`), Containerization 0.40.2 |
| Proxmox | VE 9.2 ARM64 userspace (`pve-manager` 9.2.9) |
| Lab resources | 6 vCPU, 12 GiB RAM, 32 GiB volume |
| Short-horizon soak | **22/22 PASS** (~42 min) |
| Long-horizon campaign | **In progress** |
| Production use | **No** |

### What works today

- Lab create/start/stop/restart
- Proxmox UI on `https://127.0.0.1:8006`
- Nested ARM64 Debian cloud guest (VM `9000`) with cloud-init DHCP
- Private guest NAT and dnsmasq
- Short-horizon restart / guest / API stability suite
- Volume durability checksum across lab restart (smoke)
- Host-side IO pressure smoke

### Soft quirks observed

- Guest ACPI shutdown (`qm shutdown`) often times out; `qm stop` succeeds
- Bootstrap ready-marker must not be trusted alone after restart (verify poll)
- `watchdog-mux.service` may show failed inside the lab (expected on this path)

### Explicitly out of scope

- Production workloads or availability claims
- Joining an existing Proxmox cluster
- Ceph, HA, ZFS, live migration, PCI/USB/GPU passthrough
- Bridging nested guests onto LAN VLANs or NAS mounts
- x86 guests

## Architecture

```text
macOS browser ──► 127.0.0.1:8006 ──► Proxmox VE (ARM64 userspace)
macOS ssh      ──► 127.0.0.1:2222 ──► sshd (after password set)

Nested guest(s)
  └─► vmbr0 10.44.0.0/24 ──► nftables MASQUERADE ──► Apple container net ──► Internet

Persistent disk: volume pve-arm64-data → /var/lib/vz (32 GiB)
```

## Host requirements

- Apple Silicon **M3 or newer** (nested virt; tested on M4)
- macOS **26** or newer
- ≥40 GiB free disk before first create
- ~24 GiB host RAM recommended
- Admin rights to install Apple's signed `container` package

## Security boundary

- UI: `https://127.0.0.1:8006` only
- SSH: `127.0.0.1:2222` only (disabled until a password is set)
- Guests: private `10.44.0.0/24`, NAT egress only
- No macOS home, SSH-agent, NAS, or production credential mounts
- Root password is never stored in this repository (Keychain optional)

## Quick start

```bash
./scripts/install-container.sh
./scripts/build-kernel.sh
./scripts/build-image.sh
./scripts/create-lab.sh
./scripts/set-password.sh --generate
./scripts/verify-lab.sh
./scripts/create-test-vm.sh
```

Kernel/image builds take several minutes and pin:

- Apple Containerization `0.40.2`
  (`5796abeaea5c25da3a0f32b6edee9219c7754c5b`)
- Linux `6.18.5`
  (SHA-256 `189d1f409cef8d0d234210e04595172df392f8cb297e14b447ed95720e2fd940`)

Sign in at <https://127.0.0.1:8006> as `root` / realm **Linux PAM**
(`root@pam`). Retrieve a generated password with:

```bash
security find-generic-password -w -s pve-arm64-lab -a root@pam
```

## Day-to-day operations

```bash
./scripts/labctl.sh status
./scripts/labctl.sh stop
./scripts/labctl.sh start
./scripts/labctl.sh restart
./scripts/labctl.sh logs
```

Optional SSH after password setup:

```bash
ssh -p 2222 root@127.0.0.1
```

Destroy (confirmation-gated; removes only this lab + its volume):

```bash
./scripts/labctl.sh destroy --destroy-data
```

## Stability testing

### Short horizon (completed)

```bash
RESTART_ITERS=10 GUEST_ITERS=10 API_SOAK_SECS=1800 ./scripts/stability-test.sh all
```

Result on 2026-08-05: **22 passed, 0 failed**. Details in
[docs/RESULTS.md](docs/RESULTS.md).

### Long horizon (ongoing)

```bash
# Recommended: prevent idle sleep while soaking
SKIP_SLEEP_WAKE=1 caffeinate -dims ./scripts/long-term-stability.sh all

# Interactive host sleep/wake (run separately when you can babysit):
./scripts/long-term-stability.sh sleep-wake
```

Suites: `io`, `durability`, `concurrent`, `reboot`, `sleep-wake`, `soak`.

Full methodology and pass criteria:
[docs/TESTING.md](docs/TESTING.md).

## Repository layout

```text
Containerfile                 Proxmox ARM64 lab image
config/                       network, nftables, dnsmasq, sshd
scripts/                      build, create, verify, stability harnesses
systemd/                      lab bootstrap unit
docs/                         BookStack runbook, testing, results
artifacts/                    local logs/kernels (gitignored)
```

## Documentation map

| Doc | Contents |
|---|---|
| [README.md](README.md) | Overview, setup, current state |
| [docs/TESTING.md](docs/TESTING.md) | How to run short- and long-horizon suites |
| [docs/RESULTS.md](docs/RESULTS.md) | Dated pass/fail evidence |
| [docs/HANDOFF.md](docs/HANDOFF.md) | Post-wipe rebuild context and next-agent priorities |
| [docs/bookstack-proxmox-arm64.md](docs/bookstack-proxmox-arm64.md) | BookStack-ready ops runbook |

Live BookStack book:
[Nested Proxmox ARM64 on Mac](https://bookstack.ghostnetwork.app/books/nested-proxmox-arm64-on-mac).

## Contributing results

When a long-horizon suite finishes, append a dated entry to
[`docs/RESULTS.md`](docs/RESULTS.md) with command, log path, and outcome.
Keep secrets out of git; logs under `artifacts/` are ignored by default.
