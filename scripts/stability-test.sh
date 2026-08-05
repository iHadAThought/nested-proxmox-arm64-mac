#!/bin/bash

set -Eeuo pipefail

source "$(dirname "$0")/common.sh"

readonly GUEST_VM_ID="${GUEST_VM_ID:-9000}"
readonly RESTART_ITERS="${RESTART_ITERS:-5}"
readonly GUEST_ITERS="${GUEST_ITERS:-5}"
readonly API_SOAK_SECS="${API_SOAK_SECS:-120}"
readonly API_POLL_INTERVAL="${API_POLL_INTERVAL:-5}"
readonly BOOTSTRAP_TIMEOUT="${BOOTSTRAP_TIMEOUT:-180}"
readonly GUEST_LEASE_TIMEOUT="${GUEST_LEASE_TIMEOUT:-120}"

readonly LOG_DIR="${PROJECT_ROOT}/artifacts"
readonly LOG_FILE="${LOG_DIR}/stability-$(date +%Y%m%d-%H%M%S).log"

PASS_COUNT=0
FAIL_COUNT=0
declare -a RESULTS=()

log() {
  printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG_FILE"
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
  # After restart, poll verify-lab until services are actually healthy.
  # A previous bootstrap marker alone is not a reliable ready signal.
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

test_restart_loop() {
  log "=== Restart + verify loop (${RESTART_ITERS} iterations) ==="
  local i
  for (( i = 1; i <= RESTART_ITERS; i++ )); do
    if ! "${PROJECT_ROOT}/scripts/labctl.sh" restart >>"$LOG_FILE" 2>&1; then
      record "restart[$i]" fail "labctl restart returned non-zero"
      continue
    fi
    if wait_for_lab_ready; then
      record "restart[$i]" pass "verify-lab clean"
    else
      record "restart[$i]" fail "lab not healthy within ${BOOTSTRAP_TIMEOUT}s"
    fi
  done
}

test_guest_cycle() {
  log "=== Guest cold start/stop cycle (VM ${GUEST_VM_ID}, ${GUEST_ITERS} iterations) ==="

  if ! container exec "$LAB_NAME" qm status "$GUEST_VM_ID" >/dev/null 2>&1; then
    record "guest-cycle" fail "VM ${GUEST_VM_ID} does not exist; run scripts/create-test-vm.sh"
    return
  fi

  local i
  for (( i = 1; i <= GUEST_ITERS; i++ )); do
    local start_ns end_ns secs ip
    start_ns="$(date +%s)"
    ip="$(
      container exec --interactive "$LAB_NAME" \
        env VM_ID="$GUEST_VM_ID" LEASE_TIMEOUT="$GUEST_LEASE_TIMEOUT" \
        /bin/bash -s <<'REMOTE'
set -Eeuo pipefail
mac="$(qm config "$VM_ID" | sed -n 's/^net0: virtio=\([^,]*\).*/\1/p' | tr '[:upper:]' '[:lower:]')"
[ -n "$mac" ] || { echo "no-mac" >&2; exit 1; }
qm start "$VM_ID" >&2
deadline=$(( SECONDS + LEASE_TIMEOUT ))
while (( SECONDS < deadline )); do
  ip="$(awk -v mac="$mac" 'tolower($2) == mac {print $3; exit}' \
    /var/lib/misc/dnsmasq.leases 2>/dev/null || true)"
  if [ -n "$ip" ] && ping -c1 -W2 "$ip" >/dev/null 2>&1; then
    echo "$ip"
    qm shutdown "$VM_ID" --timeout 30 >&2 2>&1 || qm stop "$VM_ID" >&2 2>&1 || true
    exit 0
  fi
  sleep 2
done
qm stop "$VM_ID" >&2 2>&1 || true
exit 1
REMOTE
    )" || { record "guest-cycle[$i]" fail "no DHCP lease / no ping within ${GUEST_LEASE_TIMEOUT}s"; continue; }

    end_ns="$(date +%s)"
    secs=$((end_ns - start_ns))

    if container exec "$LAB_NAME" \
      /bin/bash -c "qm status $GUEST_VM_ID | grep -q 'status: stopped'"; then
      record "guest-cycle[$i]" pass "reached ${ip}, clean stop in ${secs}s"
    else
      record "guest-cycle[$i]" fail "reached ${ip} but VM did not stop"
    fi
  done
}

test_api_soak() {
  log "=== API/control-plane soak (${API_SOAK_SECS}s) ==="
  local deadline=$((SECONDS + API_SOAK_SECS))
  local polls=0 errors=0
  while (( SECONDS < deadline )); do
    polls=$((polls + 1))
    if ! curl --fail --silent --show-error --insecure \
      "https://127.0.0.1:${PVE_UI_PORT}/" >/dev/null 2>>"$LOG_FILE"; then
      errors=$((errors + 1))
    fi
    if ! container exec "$LAB_NAME" /bin/bash -c \
      'qm list >/dev/null 2>&1 && pvesm status >/dev/null 2>&1'; then
      errors=$((errors + 1))
    fi
    sleep "$API_POLL_INTERVAL"
  done
  if (( errors == 0 )); then
    record "api-soak" pass "${polls} polls, 0 errors"
  else
    record "api-soak" fail "${errors} errors across ${polls} polls"
  fi
}

test_idle_resources() {
  log "=== Idle resource snapshot ==="
  if container exec "$LAB_NAME" /bin/bash -c \
    'echo "uptime: $(uptime)"; free -h; df -h /var/lib/vz' \
    >>"$LOG_FILE" 2>&1; then
    record "idle-resources" pass "snapshot captured in log"
  else
    record "idle-resources" fail "could not capture resource snapshot"
  fi
}

main() {
  require_container
  container_exists || die "lab does not exist; run scripts/create-lab.sh"
  mkdir -p "$LOG_DIR"

  local suite="${1:-all}"
  log "Stability run start (suite=${suite}, log=${LOG_FILE})"

  case "$suite" in
    restart)   test_restart_loop ;;
    guest)     test_guest_cycle ;;
    api)       test_api_soak ;;
    resources) test_idle_resources ;;
    all)
      test_idle_resources
      test_restart_loop
      test_guest_cycle
      test_api_soak
      ;;
    *)
      die "usage: $0 {all|restart|guest|api|resources}"
      ;;
  esac

  log "=== Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed ==="
  local line
  for line in "${RESULTS[@]}"; do
    printf '  %s\n' "$line"
  done

  (( FAIL_COUNT == 0 )) || exit 1
}

main "$@"
