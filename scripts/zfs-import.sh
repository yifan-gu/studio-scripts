#!/bin/bash

set -euo pipefail

EXPECTED_POOLS=(
  "Archive-ZFS-8-Bay-2019-2026"
  "Archive-ZFS-8-Bay-2026"
  "Backup-Archive-ZFS-6-Bay-2024-Oct"
)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "$0")"
KEEP_AWAKE_SCRIPT="${SCRIPT_DIR}/zfs-start-keepawake.sh"

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo "$SCRIPT_PATH" "$@"
fi

ZPOOL="$(command -v zpool || true)"

if [[ -z "$ZPOOL" ]]; then
  echo "ERROR: zpool not found."
  exit 1
fi

if [[ ! -x "$KEEP_AWAKE_SCRIPT" ]]; then
  echo "ERROR: keep-awake script not found or not executable:"
  echo "  $KEEP_AWAKE_SCRIPT"
  exit 1
fi

echo
echo "========================================"
echo " Importing ZFS pools"
echo "========================================"
echo

"$ZPOOL" import -a -l

echo
echo "Imported pools:"
"$ZPOOL" list
echo

echo "========================================"
echo " Verifying expected pools"
echo "========================================"
echo

for pool in "${EXPECTED_POOLS[@]}"; do
  if ! "$ZPOOL" list -H -o name | grep -Fxq "$pool"; then
    echo "ERROR: pool was not imported:"
    echo "  $pool"
    exit 1
  fi

  echo "OK: $pool"
done

echo
echo "========================================"
echo " Verifying all ZFS devices are ONLINE"
echo "========================================"
echo

FAILED=0

for pool in "${EXPECTED_POOLS[@]}"; do
  echo "Checking: $pool"

  if ! "$ZPOOL" status "$pool" | awk '
    /^config:/ {
      in_config=1
      next
    }

    /^errors:/ {
      in_config=0
    }

    in_config && $1 == "NAME" {
      next
    }

    in_config && NF >= 2 &&
    $2 ~ /^(ONLINE|DEGRADED|FAULTED|OFFLINE|UNAVAIL|REMOVED)$/ {
      if ($2 != "ONLINE") {
        print "  NOT ONLINE: " $0 > "/dev/stderr"
        bad=1
      }
    }

    END {
      exit bad
    }
  '; then
    FAILED=1
  fi
done

if [[ "$FAILED" -ne 0 ]]; then
  echo
  echo "ERROR: One or more ZFS devices are not ONLINE."
  echo "Keep-awake daemon was NOT started."
  echo
  "$ZPOOL" status
  exit 1
fi

echo
echo "All pools and vdevs are ONLINE."

echo
echo "========================================"
echo " Starting disk keep-awake daemon"
echo "========================================"
echo

"$KEEP_AWAKE_SCRIPT"

echo
echo "========================================"
echo " ZFS READY"
echo "========================================"
