#!/bin/bash

set -Eeuo pipefail

source "$(dirname "$0")/common.sh"

require_container
require_command openssl

mode="${1:-prompt}"
password=""

if [[ "$mode" == "--generate" ]]; then
  require_command security
  password="$(openssl rand -base64 30 | tr -d '\n')"
elif [[ "$mode" == "prompt" ]]; then
  read -r -s -p "New root@pam password: " password
  printf '\n'
  read -r -s -p "Confirm password: " confirmation
  printf '\n'
  [[ "$password" == "$confirmation" ]] || die "passwords do not match"
  unset confirmation
else
  die "usage: $0 [--generate]"
fi

(( ${#password} >= 16 )) || die "password must contain at least 16 characters"
[[ "$password" =~ [[:upper:]] ]] || die "password must contain an uppercase letter"
[[ "$password" =~ [[:lower:]] ]] || die "password must contain a lowercase letter"
[[ "$password" =~ [[:digit:]] ]] || die "password must contain a digit"
[[ "$password" =~ [^[:alnum:]] ]] || die "password must contain a symbol"

printf 'root:%s\n' "$password" |
  container exec --interactive "$LAB_NAME" /usr/sbin/chpasswd
container exec "$LAB_NAME" systemctl enable --now ssh.service >/dev/null

if [[ "$mode" == "--generate" ]]; then
  security delete-generic-password \
    -a root@pam -s "$LAB_NAME" >/dev/null 2>&1 || true
  security add-generic-password \
    -a root@pam -s "$LAB_NAME" -w "$password" >/dev/null
  printf 'Generated password stored in macOS Keychain service %s (account root@pam).\n' \
    "$LAB_NAME"
else
  printf 'Updated root@pam password; it was not stored by this script.\n'
fi

unset password
