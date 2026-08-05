#!/bin/bash

set -Eeuo pipefail

source "$(dirname "$0")/common.sh"

require_container

action="${1:-status}"

case "$action" in
  start)
    container_exists || die "lab does not exist; run scripts/create-lab.sh"
    container start "$LAB_NAME"
    ;;
  stop)
    container_exists || die "lab does not exist"
    container stop --time 45 "$LAB_NAME"
    ;;
  restart)
    container_exists || die "lab does not exist"
    container stop --time 45 "$LAB_NAME"
    container start "$LAB_NAME"
    ;;
  status)
    container list --all
    if container_exists; then
      container exec "$LAB_NAME" systemctl --no-pager --failed || true
    fi
    ;;
  logs)
    container logs "$LAB_NAME"
    ;;
  destroy)
    [[ "${2:-}" == "--destroy-data" ]] ||
      die "destructive action requires: $0 destroy --destroy-data"
    printf 'Type %s to permanently remove the lab and its volume: ' "$LAB_NAME"
    read -r confirmation
    [[ "$confirmation" == "$LAB_NAME" ]] || die "confirmation did not match"
    if container_exists; then
      container stop --time 45 "$LAB_NAME" >/dev/null 2>&1 || true
      container delete "$LAB_NAME"
    fi
    if container volume inspect "$DATA_VOLUME" >/dev/null 2>&1; then
      container volume delete "$DATA_VOLUME"
    fi
    ;;
  *)
    die "usage: $0 {start|stop|restart|status|logs|destroy --destroy-data}"
    ;;
esac
