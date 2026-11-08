#!/usr/bin/env bash
# settime.sh - send the current time to a Trezor running the clock firmware.
# Usage: ./settime.sh [--emulator]    (TZ_NAME defaults to Africa/Nairobi)
set -euo pipefail
REPO="${REPO:-$HOME/trezor-firmware}"
TZ_NAME="${TZ_NAME:-Africa/Nairobi}"
PORT=()
[ "${1:-}" = "--emulator" ] && PORT=(-p udp)

UTC=$(date -u +%s)
Z=$(TZ="$TZ_NAME" date +%z)
SIGN=${Z:0:1}; H=${Z:1:2}; M=${Z:3:2}
OFF=$(( 10#$H * 3600 + 10#$M * 60 ))
[ "$SIGN" = "-" ] && OFF=$(( -OFF ))

cd "$REPO/legacy"
uv run trezorctl "${PORT[@]}" ping "SETTIME $UTC $OFF"
echo "sent: SETTIME $UTC $OFF  ($TZ_NAME)"
