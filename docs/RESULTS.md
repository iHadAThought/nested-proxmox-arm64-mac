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

### Campaign in flight / next

Started 2026-08-05 (local):

```bash
SKIP_SLEEP_WAKE=1 caffeinate -dims ./scripts/long-term-stability.sh all
```

This runs `io` → `durability` → `concurrent` → `reboot` → skipped sleep-wake →
24h `soak`. Update this section when the process exits; sleep-wake still needs
a separate interactive run.

