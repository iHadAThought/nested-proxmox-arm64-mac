# Results

Living summary of stability evidence. Append new runs at the top of each
section. Raw logs live in `artifacts/` (gitignored).

## Current classification

**Experimental nested lab — not production.**

Short-horizon evidence is green. Long-horizon / server-readiness testing is
**in progress**.

## Short-horizon

### 2026-08-05 — full short soak

- Host: Apple M4, macOS 26.5
- Runtime: Apple `container` 1.2.0
- Lab: Proxmox VE 9.2 ARM64 userspace, Linux 6.18.5 KVM kernel
- Command:
  `RESTART_ITERS=10 GUEST_ITERS=10 API_SOAK_SECS=1800 ./scripts/stability-test.sh all`
- Log: `artifacts/stability-20260805-134037.log`
- Duration: ~42 minutes
- Result: **22 passed, 0 failed**

| Suite | Detail |
|---|---|
| resources | 11 GiB lab RAM, ~1.5 GiB of 32 GiB volume used |
| restart ×10 | all verify-lab clean after restart |
| guest ×10 | all reached `10.44.0.162`, clean stop in 25–50s |
| api 1800s | 312 polls, 0 errors |

Notes:

- Guest ACPI `qm shutdown` frequently timed out; `qm stop` fallback succeeded.
- First soak attempt aborted due to stale bootstrap-marker race; fixed before
  this successful run.

## Long-horizon

### Status: ongoing

Harness: `scripts/long-term-stability.sh`

### 2026-08-05 — smoke (reduced sizes)

| Suite | Command knobs | Result | Log |
|---|---|---|---|
| `io` | `IO_MIB=128` | PASS | `artifacts/long-term-20260805-150848.log` |
| `durability` | `DURABILITY_MIB=64` | PASS (SHA-256 matched after restart) | `artifacts/long-term-20260805-150854.log` |

### 2026-08-05 — full long-horizon campaign (interrupted)

```bash
SKIP_SLEEP_WAKE=1 caffeinate -dims ./scripts/long-term-stability.sh all
```

The local run did not complete before host teardown preparation. Preserved
results from `artifacts/long-term-20260805-151011.log`:

| Suite | Result | Detail |
|---|---|---|
| `io` | PASS | 1024 MiB write/read; `verify-lab` remained clean |
| `durability` | PASS | 512 MiB random blob SHA-256 matched after lab restart |
| `concurrent` | FAIL | both clones started, but only one of two obtained DHCP/ping |
| `reboot` | PARTIAL PASS | iterations 1–4 recovered before the log ended |
| `sleep-wake` | NOT RUN | interactive test still required |
| `soak` | NOT RUN | 24-hour phase was never reached |

This makes concurrent guest networking the highest-priority unresolved issue.
Do not describe the lab as production-ready.

### Next campaign

1. Rebuild the lab after the Mac wipe using `README.md`.
2. Reproduce `./scripts/long-term-stability.sh concurrent`.
3. Check cloned VM MAC addresses, cloud-init instance IDs, dnsmasq leases, and
   bridge traffic for VM 9001 before changing network design.
4. Re-run `reboot`, then the interactive `sleep-wake` suite.
5. Only after those pass, run the 24-hour `soak`.

