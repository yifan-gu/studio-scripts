#!/bin/bash

set -euo pipefail

PIDFILE="/var/run/zfs-keepawake.pid"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "$0")"

#
# Run as root.
#
if [[ "${EUID}" -ne 0 ]]; then
    exec sudo "$SCRIPT_PATH" "$@"
fi


ZPOOL="$(command -v zpool || true)"

if [[ -z "$ZPOOL" ]]; then
    echo "ERROR: zpool not found."
    exit 1
fi


echo
echo "========================================"
echo " Stopping ZFS keep-awake daemon"
echo "========================================"
echo

if [[ -f "$PIDFILE" ]]; then

    PID="$(cat "$PIDFILE" 2>/dev/null || true)"

    if [[ "$PID" =~ ^[0-9]+$ ]] && kill -0 "$PID" 2>/dev/null; then

        echo "Stopping daemon PID $PID..."

        kill "$PID"

        #
        # Give it a few seconds to terminate.
        #
        for _ in {1..10}; do
            if ! kill -0 "$PID" 2>/dev/null; then
                break
            fi

            sleep 0.5
        done

        #
        # Should normally never be necessary.
        #
        if kill -0 "$PID" 2>/dev/null; then
            echo "Daemon did not terminate normally; killing it."
            kill -KILL "$PID" 2>/dev/null || true
        fi

    else
        echo "No running daemon found."
    fi

    rm -f "$PIDFILE"

else
    echo "Keep-awake daemon is not running."
fi


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
