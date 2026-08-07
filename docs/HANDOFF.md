# Cursor handoff and rebuild context

Last updated: 2026-08-07, immediately before the local Mac is wiped.

## Project goal

Run an experimental Proxmox VE 9.2 ARM64 lab on Apple Silicon using Apple's
`container` runtime and nested KVM. This is a research/development environment,
not a normal or production Proxmox server.

## Canonical locations

- GitHub: <https://github.com/iHadAThought/nested-proxmox-arm64-mac>
- Forgejo: <https://git.ghostnetwork.app/Brendan/nested-proxmox-arm64-mac>
- BookStack: <https://bookstack.ghostnetwork.app/books/nested-proxmox-arm64-on-mac>
- Repository folder before wipe: `/Users/brendan/Projects/containers`
- Default branch: `master`

After the wipe, prefer Forgejo or GitHub as the source. Verify both remotes
point to the same commit before making new changes.

## Important technical decisions

- Host requirement: Apple Silicon M3 or newer; tested on an M4 MacBook Pro
  with 24 GiB RAM and macOS 26.5.
- Apple `container` version used: 1.2.0.
- Apple Containerization source pinned to `0.40.2`, commit
  `5796abeaea5c25da3a0f32b6edee9219c7754c5b`.
- Custom Linux kernel: 6.18.5 with `CONFIG_KVM=y`.
- Proxmox userspace: VE 9.2 ARM64; Apple’s custom kernel must boot instead of
  the Proxmox kernel.
- Lab allocation: 6 vCPU, 12 GiB RAM, 32 GiB persistent volume.
- Management is loopback-only:
  - UI: `https://127.0.0.1:8006`
  - SSH: `127.0.0.1:2222`
- Guest network is routed/NAT, not a real VLAN trunk:
  - bridge `vmbr0`: `10.44.0.1/24`
  - dnsmasq leases: `10.44.0.100–199`
  - nftables masquerades outbound traffic.
- VM 9000 is the Debian ARM64 smoke VM. It needs a cloud-init disk and
  `ipconfig0: ip=dhcp`.
- Proxmox guest firewall is disabled on the smoke VM because it interfered
  with initial DHCP testing; isolation is enforced by the outer private NAT.

## Security constraints

- Never store the Proxmox password in Git, BookStack, logs, or Cursor notes.
- `scripts/set-password.sh --generate` stores `root@pam` in macOS Keychain.
- Do not copy the old Keychain credential to the rebuilt Mac; generate a new
  password.
- Do not join this node to the production Proxmox cluster.
- Do not attach NAS credentials, production VLAN trunks, or production
  workloads.
- Do not expose ports 8006 or 22 beyond localhost without a separate security
  review.

## What was working

- Repeatable kernel and OCI image builds.
- Proxmox UI/API and core services.
- Nested KVM (`/dev/kvm`) and ARM64 UEFI guest boot.
- Private DHCP/NAT and outbound guest connectivity.
- Persistent `/var/lib/vz` volume.
- Ten lab restart/verify cycles.
- Ten VM 9000 boot → DHCP → ping → stop cycles.
- Thirty-minute API/control-plane soak with zero errors.
- Full-size 1024 MiB IO test.
- 512 MiB durability blob checksum across lab restart.

Short suite result: **22 passed, 0 failed** in approximately 42 minutes.

## Known issues and incomplete tests

1. **Concurrent cloned guests:** VM 9001 and VM 9002 both started, but only one
   obtained DHCP/ping. The long-term suite recorded a failure.
2. **Guest ACPI shutdown:** `qm shutdown` often times out; scripts fall back to
   `qm stop`. Treat this as a durability risk until fixed.
3. **Reboot storm:** iterations 1–4 recovered, then the local run ended before
   completion.
4. **Mac sleep/wake:** not tested.
5. **24-hour soak:** not reached.
6. `watchdog-mux.service` may appear failed; no watchdog device exists on this
   unsupported nested path.
7. At final handoff, `container list` returned an XPC connection-invalid error;
   the Apple container service was not running. The local runtime should be
   considered disposable because the Mac is being wiped.

## Rebuild sequence after wipe

```bash
git clone https://git.ghostnetwork.app/Brendan/nested-proxmox-arm64-mac.git
cd nested-proxmox-arm64-mac

./scripts/install-container.sh
./scripts/build-kernel.sh
./scripts/build-image.sh
./scripts/create-lab.sh
./scripts/set-password.sh --generate
./scripts/verify-lab.sh
./scripts/create-test-vm.sh
```

Then retrieve the newly generated password only when needed:

```bash
security find-generic-password -w -s pve-arm64-lab -a root@pam
```

Do not expect the old local `artifacts/` directory to return after cloning; it
is intentionally gitignored because it contains generated kernels and logs.
The meaningful test results are summarized in `docs/RESULTS.md` and BookStack.

## Next agent priorities

1. Confirm the repository commit and read `README.md`, `docs/TESTING.md`, and
   `docs/RESULTS.md` before changing scripts.
2. Rebuild and run `./scripts/verify-lab.sh`.
3. Recreate VM 9000.
4. Reproduce the concurrent failure:

   ```bash
   ./scripts/long-term-stability.sh concurrent
   ```

5. Compare VM 9001/9002 MACs and cloud-init data; clear stale dnsmasq leases;
   capture bridge/DHCP traffic for the failed clone.
6. Improve soft shutdown behavior before sustained write-heavy tests.
7. Run:

   ```bash
   ./scripts/long-term-stability.sh reboot
   ./scripts/long-term-stability.sh sleep-wake
   SKIP_SLEEP_WAKE=1 LONG_TERM_HOURS=24 \
     caffeinate -dims ./scripts/long-term-stability.sh soak
   ```

8. Update both `docs/RESULTS.md` and the BookStack testing page with evidence.
9. Push to Forgejo; update this project’s BookStack book whenever Forgejo is
   updated.

## VPN / VLAN discussion

The user asked about reaching multiple UniFi VLANs. The viable design is L3
routing through a WireGuard client on the nested Proxmox host to a UniFi
WireGuard server. This does **not** create real 802.1Q trunks or make nested
guests native VLAN peers. No VPN configuration was implemented. If resumed,
use split-tunnel `AllowedIPs`, narrowly scoped UniFi firewall rules, and keep
management loopback-only.

## Git attribution

For GitHub commits and pushes, author and committer must be:

- Name: `iHadAThought`
- Email: `140212683+iHadAThought@users.noreply.github.com`

Do not add Cursor co-author trailers. Forgejo may use the normal user identity
unless the user requests otherwise.
