#!/bin/bash

set -euo pipefail

INTERVAL=45
PIDFILE="/var/run/zfs-keepawake.pid"
LOGFILE="/var/log/zfs-keepawake.log"

EXPECTED_POOLS=(
    "Archive-ZFS-8-Bay-2019-2026"
    "Archive-ZFS-8-Bay-2026"
    "Backup-Archive-ZFS-6-Bay-2024-Oct"
)

# Resolve this script to an absolute path before sudo/background launch.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "$0")"

#
# Re-run the whole script as root if necessary.
#
if [[ "${EUID}" -ne 0 ]]; then
    exec sudo "$SCRIPT_PATH" "$@"
fi

#
# Locate zpool.
#
ZPOOL="$(command -v zpool || true)"

if [[ -z "$ZPOOL" ]]; then
    echo "ERROR: zpool not found."
    exit 1
fi


#
# Return all physical disks that contain a ZFS partition.
#
# Example output:
#
#   /dev/disk6
#   /dev/disk7
#   ...
#
get_zfs_disks() {
    diskutil list physical | awk '
        /^\/dev\/disk[0-9]+ .*physical.*:/ {
            disk=$1
        }

        /^[[:space:]]+[0-9]+:.*[[:space:]]ZFS[[:space:]]/ {
            if (disk != "")
                print disk
        }
    ' | sort -u
}


#
# Keep every ZFS physical disk awake.
#
run_daemon() {
    trap 'rm -f "$PIDFILE"; exit 0' TERM INT EXIT

    echo "$$" > "$PIDFILE"

    echo "$(date): ZFS keep-awake daemon started."
    echo "$(date): interval = ${INTERVAL}s"

    while true; do

        disks="$(get_zfs_disks)"

        if [[ -z "$disks" ]]; then
            echo "$(date): WARNING: no physical ZFS disks found."
        else
            while IFS= read -r disk; do

                [[ -z "$disk" ]] && continue

                #
                # /dev/rdiskX is the raw character device.
                # This avoids relying on filesystem/ZFS ARC caching.
                #
                rawdisk="${disk/\/dev\/disk/\/dev\/rdisk}"

                if [[ -e "$rawdisk" ]]; then
                    dd \
                        if="$rawdisk" \
                        of=/dev/null \
                        bs=4096 \
                        count=1 \
                        2>/dev/null || \
                        echo "$(date): WARNING: read failed: $rawdisk"
                fi

            done <<< "$disks"
        fi

        sleep "$INTERVAL"
    done
}


#
# Internal daemon mode.
#
if [[ "${1:-}" == "--daemon" ]]; then
    run_daemon
    exit 0
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


#
# Make sure all expected pools were imported.
#
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


#
# Check that every vdev/pool entry in the config section is ONLINE.
#
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


#
# Stop stale keep-awake daemon if PID file exists.
#
if [[ -f "$PIDFILE" ]]; then

    OLD_PID="$(cat "$PIDFILE" 2>/dev/null || true)"

    if [[ "$OLD_PID" =~ ^[0-9]+$ ]] && kill -0 "$OLD_PID" 2>/dev/null; then
        echo
        echo "Keep-awake daemon already running (PID $OLD_PID)."
        exit 0
    fi

    rm -f "$PIDFILE"
fi


#
# Start daemon.
#
echo
echo "========================================"
echo " Starting disk keep-awake daemon"
echo "========================================"
echo

nohup "$SCRIPT_PATH" --daemon >> "$LOGFILE" 2>&1 &

DAEMON_PID=$!

echo "$DAEMON_PID" > "$PIDFILE"

sleep 1

if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
    echo "ERROR: keep-awake daemon failed to start."
    rm -f "$PIDFILE"
    exit 1
fi


echo "Keep-awake daemon started."
echo "PID:      $DAEMON_PID"
echo "Interval: ${INTERVAL}s"
echo "Log:      $LOGFILE"

echo
echo "Current ZFS physical disks:"
get_zfs_disks

echo
echo "========================================"
echo " ZFS READY"
echo "========================================"
