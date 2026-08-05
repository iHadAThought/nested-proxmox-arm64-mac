#!/bin/bash

set -Eeuo pipefail

source "$(dirname "$0")/common.sh"

# Long-horizon suites for deciding whether the nested lab is "server-ish".
# Defaults are conservative so a full run is measurable in hours, not days,
# unless LONG_TERM_HOURS is raised explicitly.

readonly BASE_VM_ID="${BASE_VM_ID:-9000}"
readonly CONCURRENT_VM_IDS="${CONCURRENT_VM_IDS:-9001 9002}"
readonly GUEST_REBOOT_ITERS="${GUEST_REBOOT_ITERS:-10}"
readonly LONG_TERM_HOURS="${LONG_TERM_HOURS:-24}"
readonly HEARTBEAT_SECS="${HEARTBEAT_SECS:-300}"
readonly BOOTSTRAP_TIMEOUT="${BOOTSTRAP_TIMEOUT:-180}"
readonly GUEST_LEASE_TIMEOUT="${GUEST_LEASE_TIMEOUT:-180}"
readonly DURABILITY_MIB="${DURABILITY_MIB:-512}"
readonly IO_MIB="${IO_MIB:-1024}"
readonly SKIP_SLEEP_WAKE="${SKIP_SLEEP_WAKE:-0}"

readonly LOG_DIR="${PROJECT_ROOT}/artifacts"
readonly LOG_FILE="${LOG_DIR}/long-term-$(date +%Y%m%d-%H%M%S).log"
readonly STATE_DIR="${LOG_DIR}/long-term-state"

PASS_COUNT=0
FAIL_COUNT=0
declare -a RESULTS=()

log() {
  printf '%s %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$*" | tee -a "$LOG_FILE"
}

record() {
  local name="$1" status="$2" detail="${3:-}"
  if [[ "$status" == "pass" ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
    RESULTS+=("PASS  ${name}${detail:+ — $detail}")
    log "PASS  ${name}${detail:+ — $detail}"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    RESULTS+=("FAIL  ${name}${detail:+ — $detail}")
    log "FAIL  ${name}${detail:+ — $detail}"
  fi
}

wait_for_lab_ready() {
  local deadline=$((SECONDS + BOOTSTRAP_TIMEOUT))
  sleep 3
  while (( SECONDS < deadline )); do
    if "${PROJECT_ROOT}/scripts/verify-lab.sh" >>"$LOG_FILE" 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

ensure_base_vm() {
  container exec "$LAB_NAME" qm status "$BASE_VM_ID" >/dev/null 2>&1 ||
    die "base VM ${BASE_VM_ID} missing; run scripts/create-test-vm.sh first"
}

guest_ip_for() {
  local vm_id="$1"
  container exec --interactive "$LAB_NAME" \
    env VM_ID="$vm_id" LEASE_TIMEOUT="$GUEST_LEASE_TIMEOUT" \
    /bin/bash -s <<'REMOTE'
set -Eeuo pipefail
mac="$(qm config "$VM_ID" | sed -n 's/^net0: virtio=\([^,]*\).*/\1/p' | tr '[:upper:]' '[:lower:]')"
[ -n "$mac" ] || exit 1
deadline=$(( SECONDS + LEASE_TIMEOUT ))
while (( SECONDS < deadline )); do
  ip="$(awk -v mac="$mac" 'tolower($2) == mac {print $3; exit}' \
    /var/lib/misc/dnsmasq.leases 2>/dev/null || true)"
  if [ -n "$ip" ] && ping -c1 -W2 "$ip" >/dev/null 2>&1; then
    echo "$ip"
    exit 0
  fi
  sleep 2
done
exit 1
REMOTE
}

stop_vm() {
  local vm_id="$1"
  container exec "$LAB_NAME" /bin/bash -c \
    "qm shutdown ${vm_id} --timeout 30 >/dev/null 2>&1 || qm stop ${vm_id} >/dev/null 2>&1 || true"
}

# --- Suites -----------------------------------------------------------------

test_concurrent_guests() {
  log "=== Concurrent guests (${CONCURRENT_VM_IDS}) ==="
  ensure_base_vm

  # Ensure clones exist (full clone so they can run independently).
  local vm_id
  for vm_id in $CONCURRENT_VM_IDS; do
    if ! container exec "$LAB_NAME" qm status "$vm_id" >/dev/null 2>&1; then
      log "Cloning ${BASE_VM_ID} -> ${vm_id}"
      if ! container exec "$LAB_NAME" /bin/bash -c \
        "qm clone ${BASE_VM_ID} ${vm_id} --full 1 --name concurrent-${vm_id} >>/tmp/clone-${vm_id}.log 2>&1"; then
        record "concurrent-clone[${vm_id}]" fail "qm clone failed"
        return
      fi
      container exec "$LAB_NAME" qm set "$vm_id" --ipconfig0 ip=dhcp >/dev/null
    fi
  done

  # Stop any already-running clones, then start all together.
  for vm_id in $CONCURRENT_VM_IDS; do
    stop_vm "$vm_id"
  done
  container exec "$LAB_NAME" qm stop "$BASE_VM_ID" >/dev/null 2>&1 || true

  local started=0
  for vm_id in $CONCURRENT_VM_IDS; do
    if container exec "$LAB_NAME" qm start "$vm_id" >>"$LOG_FILE" 2>&1; then
      started=$((started + 1))
    else
      record "concurrent-start[${vm_id}]" fail "qm start failed"
    fi
  done

  local reachable=0
  local ips=""
  for vm_id in $CONCURRENT_VM_IDS; do
    local ip
    if ip="$(guest_ip_for "$vm_id")"; then
      reachable=$((reachable + 1))
      ips="${ips:+$ips, }${vm_id}=${ip}"
    else
      record "concurrent-lease[${vm_id}]" fail "no DHCP/ping"
    fi
  done

  # Light concurrent IO pressure from the Proxmox host against guest disks.
  container exec "$LAB_NAME" /bin/bash -c '
    set -e
    for d in /var/lib/vz/images/9001 /var/lib/vz/images/9002; do
      [ -d "$d" ] || continue
      dd if=/dev/zero of="$d/.io-pressure" bs=1M count=64 oflag=direct status=none || true
      rm -f "$d/.io-pressure"
    done
  ' >>"$LOG_FILE" 2>&1 || true

  for vm_id in $CONCURRENT_VM_IDS; do
    stop_vm "$vm_id"
  done

  local expected
  expected="$(wc -w <<<"$CONCURRENT_VM_IDS" | tr -d ' ')"
  if (( reachable == expected && started == expected )); then
    record "concurrent-guests" pass "${reachable}/${expected} reachable (${ips})"
  else
    record "concurrent-guests" fail "reachable ${reachable}/${expected}, started ${started}/${expected}"
  fi
}

test_guest_reboot_storm() {
  log "=== Guest reboot storm (VM ${BASE_VM_ID}, ${GUEST_REBOOT_ITERS} iters) ==="
  ensure_base_vm
  stop_vm "$BASE_VM_ID"

  if ! container exec "$LAB_NAME" qm start "$BASE_VM_ID" >>"$LOG_FILE" 2>&1; then
    record "reboot-storm" fail "initial qm start failed"
    return
  fi
  if ! guest_ip_for "$BASE_VM_ID" >/dev/null; then
    stop_vm "$BASE_VM_ID"
    record "reboot-storm" fail "initial lease failed"
    return
  fi

  local i ok=0
  for (( i = 1; i <= GUEST_REBOOT_ITERS; i++ )); do
    if ! container exec "$LAB_NAME" qm reboot "$BASE_VM_ID" --timeout 60 >>"$LOG_FILE" 2>&1; then
      # Soft reboot often times out on this nested path; fall back to reset.
      log "qm reboot timed out on iter ${i}; using qm reset"
      container exec "$LAB_NAME" qm reset "$BASE_VM_ID" >>"$LOG_FILE" 2>&1 || true
    fi
    if guest_ip_for "$BASE_VM_ID" >/dev/null; then
      ok=$((ok + 1))
      log "reboot[${i}] recovered"
    else
      record "reboot[${i}]" fail "no lease after reboot"
    fi
  done

  stop_vm "$BASE_VM_ID"
  if (( ok == GUEST_REBOOT_ITERS )); then
    record "reboot-storm" pass "${ok}/${GUEST_REBOOT_ITERS} recoveries"
  else
    record "reboot-storm" fail "${ok}/${GUEST_REBOOT_ITERS} recoveries"
  fi
}

test_volume_durability() {
  log "=== Volume durability (${DURABILITY_MIB} MiB checksum across restart) ==="
  mkdir -p "$STATE_DIR"
  local marker="/var/lib/vz/long-term-durability.bin"
  local sum_file="${STATE_DIR}/durability.sha256"

  if ! container exec "$LAB_NAME" /bin/bash -c "
    set -e
    dd if=/dev/urandom of='${marker}' bs=1M count=${DURABILITY_MIB} status=none
    sync
    sha256sum '${marker}'
  " >"$sum_file" 2>>"$LOG_FILE"; then
    record "durability-write" fail "could not write durability blob"
    return
  fi

  local expected
  expected="$(awk '{print $1}' "$sum_file")"
  log "Wrote durability blob sha256=${expected}"

  if ! "${PROJECT_ROOT}/scripts/labctl.sh" restart >>"$LOG_FILE" 2>&1; then
    record "durability-restart" fail "labctl restart failed"
    return
  fi
  if ! wait_for_lab_ready; then
    record "durability-restart" fail "lab unhealthy after restart"
    return
  fi

  local actual
  if ! actual="$(container exec "$LAB_NAME" sha256sum "$marker" | awk '{print $1}')"; then
    record "durability-verify" fail "blob missing after restart"
    return
  fi

  if [[ "$actual" == "$expected" ]]; then
    record "durability" pass "sha256 matched after lab restart"
  else
    record "durability" fail "sha256 mismatch (expected ${expected}, got ${actual})"
  fi

  container exec "$LAB_NAME" rm -f "$marker" >/dev/null 2>&1 || true
}

test_host_io_pressure() {
  log "=== Host-side IO pressure on lab volume (${IO_MIB} MiB) ==="
  if container exec "$LAB_NAME" /bin/bash -c "
    set -e
    path=/var/lib/vz/long-term-io.bin
    dd if=/dev/zero of=\"\$path\" bs=1M count=${IO_MIB} oflag=direct status=none
    dd if=\"\$path\" of=/dev/null bs=1M iflag=direct status=none
    rm -f \"\$path\"
    sync
  " >>"$LOG_FILE" 2>&1; then
    if "${PROJECT_ROOT}/scripts/verify-lab.sh" >>"$LOG_FILE" 2>&1; then
      record "host-io" pass "write/read ${IO_MIB} MiB, verify-lab clean"
    else
      record "host-io" fail "IO completed but verify-lab failed"
    fi
  else
    record "host-io" fail "dd write/read failed"
  fi
}

test_sleep_wake() {
  log "=== Host sleep/wake recovery ==="
  if [[ "$SKIP_SLEEP_WAKE" == "1" ]]; then
    record "sleep-wake" pass "skipped (SKIP_SLEEP_WAKE=1)"
    return
  fi
  if [[ ! -t 0 ]]; then
    record "sleep-wake" fail "non-interactive TTY; re-run with a terminal or SKIP_SLEEP_WAKE=1"
    return
  fi

  if ! wait_for_lab_ready; then
    record "sleep-wake" fail "lab unhealthy before sleep"
    return
  fi

  cat <<EOF

---------------------------------------------------------------------------
Sleep/wake is a host-level test and cannot be automated safely.

1. Leave this terminal open.
2. Put the Mac to sleep now (Apple menu → Sleep, or close the lid briefly).
3. Wake the Mac.
4. Return here and press Enter.
---------------------------------------------------------------------------
EOF
  read -r -p "Press Enter after the Mac has woken: " _

  # Give Apple Containerization time to recover networking / VM state.
  sleep 15
  if wait_for_lab_ready; then
    if ensure_base_vm && container exec "$LAB_NAME" qm start "$BASE_VM_ID" >>"$LOG_FILE" 2>&1 \
      && guest_ip_for "$BASE_VM_ID" >/dev/null; then
      stop_vm "$BASE_VM_ID"
      record "sleep-wake" pass "lab + guest recovered after host wake"
    else
      stop_vm "$BASE_VM_ID"
      record "sleep-wake" fail "lab up but guest did not recover"
    fi
  else
    record "sleep-wake" fail "lab did not become healthy after wake"
  fi
}

test_multi_day_soak() {
  local total_secs=$(( LONG_TERM_HOURS * 3600 ))
  log "=== Multi-hour soak (${LONG_TERM_HOURS}h, heartbeat every ${HEARTBEAT_SECS}s) ==="
  log "Start this under caffeinate if you want to prevent idle sleep:"
  log "  caffeinate -dims ./scripts/long-term-stability.sh soak"

  local deadline=$((SECONDS + total_secs))
  local beats=0 errors=0
  local next_guest_check=$((SECONDS + HEARTBEAT_SECS * 3))

  while (( SECONDS < deadline )); do
    beats=$((beats + 1))
    local remaining=$((deadline - SECONDS))
    log "heartbeat[${beats}] remaining≈${remaining}s"

    if ! container_exists; then
      errors=$((errors + 1))
      log "heartbeat[${beats}] lab container missing"
    elif ! "${PROJECT_ROOT}/scripts/verify-lab.sh" >>"$LOG_FILE" 2>&1; then
      errors=$((errors + 1))
      log "heartbeat[${beats}] verify-lab failed"
    else
      container exec "$LAB_NAME" /bin/bash -c \
        'echo "uptime=$(uptime)"; free -h | sed -n "2p"; df -h /var/lib/vz | sed -n "2p"' \
        >>"$LOG_FILE" 2>&1 || true
    fi

    # Periodic guest smoke without stopping the soak.
    if (( SECONDS >= next_guest_check )); then
      next_guest_check=$((SECONDS + HEARTBEAT_SECS * 3))
      if container exec "$LAB_NAME" qm status "$BASE_VM_ID" >/dev/null 2>&1; then
        stop_vm "$BASE_VM_ID"
        if container exec "$LAB_NAME" qm start "$BASE_VM_ID" >>"$LOG_FILE" 2>&1 \
          && guest_ip_for "$BASE_VM_ID" >/dev/null; then
          log "heartbeat[${beats}] guest smoke ok"
        else
          errors=$((errors + 1))
          log "heartbeat[${beats}] guest smoke failed"
        fi
        stop_vm "$BASE_VM_ID"
      fi
    fi

    sleep "$HEARTBEAT_SECS"
  done

  if (( errors == 0 )); then
    record "multi-hour-soak" pass "${beats} heartbeats over ${LONG_TERM_HOURS}h, 0 errors"
  else
    record "multi-hour-soak" fail "${errors} errors across ${beats} heartbeats"
  fi
}

print_summary() {
  log "=== Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed ==="
  log "Log file: ${LOG_FILE}"
  local line
  for line in "${RESULTS[@]}"; do
    printf '  %s\n' "$line"
  done
  (( FAIL_COUNT == 0 )) || exit 1
}

usage() {
  cat <<EOF
usage: $0 {all|concurrent|reboot|durability|io|sleep-wake|soak}

Environment knobs:
  LONG_TERM_HOURS      soak duration in hours (default: 24)
  HEARTBEAT_SECS       soak verify interval (default: 300)
  GUEST_REBOOT_ITERS   reboot-storm iterations (default: 10)
  CONCURRENT_VM_IDS    space-separated clone IDs (default: "9001 9002")
  DURABILITY_MIB       checksum blob size (default: 512)
  IO_MIB               host IO pressure size (default: 1024)
  SKIP_SLEEP_WAKE=1    skip interactive sleep/wake suite
EOF
  exit 1
}

main() {
  require_container
  container_exists || die "lab does not exist; run scripts/create-lab.sh"
  mkdir -p "$LOG_DIR" "$STATE_DIR"

  local suite="${1:-}"
  [[ -n "$suite" ]] || usage

  log "Long-term stability start (suite=${suite}, log=${LOG_FILE})"
  if ! wait_for_lab_ready; then
    die "lab is not healthy; run scripts/verify-lab.sh"
  fi

  case "$suite" in
    concurrent) test_concurrent_guests ;;
    reboot)     test_guest_reboot_storm ;;
    durability) test_volume_durability ;;
    io)         test_host_io_pressure ;;
    sleep-wake) test_sleep_wake ;;
    soak)       test_multi_day_soak ;;
    all)
      test_host_io_pressure
      test_volume_durability
      test_concurrent_guests
      test_guest_reboot_storm
      test_sleep_wake
      test_multi_day_soak
      ;;
    *)
      usage
      ;;
  esac

  print_summary
}

main "$@"
