# Testing

This project has two stability harnesses:

| Script | Purpose | Typical duration |
|---|---|---|
| [`scripts/stability-test.sh`](../scripts/stability-test.sh) | Short-horizon soak (restart, guest cycle, API) | minutes–tens of minutes |
| [`scripts/long-term-stability.sh`](../scripts/long-term-stability.sh) | Longer-horizon server-readiness checks | hours–days |

Neither suite claims production readiness. They measure whether the nested lab
holds together under controlled stress.

## Short-horizon suite

```bash
./scripts/stability-test.sh all
./scripts/stability-test.sh restart
./scripts/stability-test.sh guest
./scripts/stability-test.sh api
./scripts/stability-test.sh resources
```

Tunables: `RESTART_ITERS`, `GUEST_ITERS`, `API_SOAK_SECS`,
`API_POLL_INTERVAL`, `GUEST_VM_ID`, `BOOTSTRAP_TIMEOUT`,
`GUEST_LEASE_TIMEOUT`.

### Completed short-horizon results (2026-08-05)

Command:

```bash
RESTART_ITERS=10 GUEST_ITERS=10 API_SOAK_SECS=1800 ./scripts/stability-test.sh all
```

Log: `artifacts/stability-20260805-134037.log`

| Check | Result |
|---|---|
| Idle resources | PASS |
| Restart + verify ×10 | PASS |
| Guest start → DHCP → ping → stop ×10 | PASS (25–50s each) |
| API soak 30 minutes | PASS (312 polls, 0 errors) |
| **Total** | **22 passed, 0 failed** (~42 minutes) |

Observed soft quirks (not hard failures):

- Guest ACPI shutdown often timed out; the harness fell back to `qm stop`.
- An earlier attempt failed because verify raced a stale bootstrap marker; the
  waiter was fixed to poll `verify-lab` until healthy.

## Long-horizon suite

```bash
# Prevent idle sleep while soaking (recommended on a laptop):
caffeinate -dims ./scripts/long-term-stability.sh all

# Or run individual suites:
./scripts/long-term-stability.sh io
./scripts/long-term-stability.sh durability
./scripts/long-term-stability.sh concurrent
./scripts/long-term-stability.sh reboot
./scripts/long-term-stability.sh sleep-wake   # interactive host sleep/wake
./scripts/long-term-stability.sh soak        # multi-hour heartbeat soak
```

| Suite | What it measures |
|---|---|
| `io` | Sustained `dd` write/read on the lab volume, then `verify-lab` |
| `durability` | Random blob + SHA-256, lab restart, checksum must match |
| `concurrent` | Full-clone VMs 9001/9002, boot together, DHCP + ping both |
| `reboot` | Guest reboot/reset storm with lease recovery |
| `sleep-wake` | Manual Mac sleep/wake, then lab + guest recovery |
| `soak` | Multi-hour heartbeat: verify-lab, resources, periodic guest smoke |

Tunables: `LONG_TERM_HOURS` (default 24), `HEARTBEAT_SECS` (default 300),
`GUEST_REBOOT_ITERS`, `CONCURRENT_VM_IDS`, `DURABILITY_MIB`, `IO_MIB`,
`SKIP_SLEEP_WAKE=1`.

### Long-horizon status

**Further testing is ongoing.** Record results under `artifacts/long-term-*.log`
and summarize them in [`RESULTS.md`](RESULTS.md) when a suite completes.

Suggested first long-horizon campaign:

```bash
# Non-interactive portion (skip laptop sleep/wake):
SKIP_SLEEP_WAKE=1 caffeinate -dims ./scripts/long-term-stability.sh all

# Separately, when you can babysit the laptop:
./scripts/long-term-stability.sh sleep-wake
```

## Pass criteria for “server-ish”

The lab remains **unsupported and non-production** even if these pass. Treat
the following as a minimum for calling it a durable homelab/dev hypervisor on
this Mac—not a replacement for bare-metal Proxmox:

1. Short-horizon suite green at 10/10/30min (already done).
2. Durability checksum survives lab restart.
3. Two concurrent guests stay reachable under light host IO.
4. Guest reboot storm recovers leases for all iterations.
5. Host sleep/wake recovers lab + at least one guest.
6. Multi-hour soak (≥24h) with zero verify-lab heartbeats failing.

Anything short of that stays classified as an experimental nested lab.
