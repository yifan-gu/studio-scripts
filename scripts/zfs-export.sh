#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "$0")"
STOP_KEEP_AWAKE_SCRIPT="${SCRIPT_DIR}/zfs-stop-keepawake.sh"

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo "$SCRIPT_PATH" "$@"
fi

ZPOOL="$(command -v zpool || true)"

if [[ -z "$ZPOOL" ]]; then
  echo "ERROR: zpool not found."
  exit 1
fi

if [[ ! -x "$STOP_KEEP_AWAKE_SCRIPT" ]]; then
  echo "ERROR: stop keep-awake script not found or not executable:"
  echo "  $STOP_KEEP_AWAKE_SCRIPT"
  exit 1
fi

"$STOP_KEEP_AWAKE_SCRIPT"

echo
echo "========================================"
echo " Exporting all ZFS pools"
echo "========================================"
echo

"$ZPOOL" export -a

echo
echo "========================================"
echo " Verifying export"
echo "========================================"
echo

REMAINING="$("$ZPOOL" list -H -o name 2>/dev/null || true)"

if [[ -n "$REMAINING" ]]; then
  echo "ERROR: Some pools are still imported:"
  echo "$REMAINING"
  exit 1
fi

echo "All ZFS pools successfully exported."

echo
echo "========================================"
echo " SAFE TO DISCONNECT"
echo "========================================"
