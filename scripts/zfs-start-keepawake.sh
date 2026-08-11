#!/bin/bash

set -euo pipefail

INTERVAL=45
PIDFILE="/var/run/zfs-keepawake.pid"
LOGFILE="/var/log/zfs-keepawake.log"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "$0")"

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo "$SCRIPT_PATH" "$@"
fi

ZPOOL="$(command -v zpool || true)"

if [[ -z "$ZPOOL" ]]; then
  echo "ERROR: zpool not found."
  exit 1
fi

#
# Return media-* vdev IDs for one pool.
#
get_pool_media_ids() {
  local pool="$1"

  "$ZPOOL" status "$pool" | awk '
    /^config:/ {
      in_config=1
      next
    }

    /^errors:/ {
      in_config=0
    }

    in_config && $1 ~ /^media-/ {
      print $1
    }
  '
}

#
# Resolve:
#
#   media-XXXXXXXX
#     -> /dev/disk22s1
#     -> /dev/disk22
#
get_physical_disk_for_media_id() {
  local media_id="$1"
  local link
  local target
  local name

  link="/var/run/disk/by-id/$media_id"

  target="$(readlink "$link" 2>/dev/null || true)"

  if [[ -z "$target" ]]; then
    return 1
  fi

  name="$(basename "$target")"

  #
  # disk22s1 -> disk22
  #
  name="${name%%s[0-9]*}"

  if [[ ! "$name" =~ ^disk[0-9]+$ ]]; then
    return 1
  fi

  echo "/dev/$name"
}

run_daemon() {
  trap 'rm -f "$PIDFILE"; exit 0' TERM INT EXIT

  echo "$$" > "$PIDFILE"

  echo "$(date): ZFS keep-awake daemon started."
  echo "$(date): interval = ${INTERVAL}s"

  while true; do
    pools="$("$ZPOOL" list -H -o name 2>/dev/null || true)"

    if [[ -z "$pools" ]]; then
      echo "$(date): WARNING: no imported ZFS pools found."
      echo
      sleep "$INTERVAL"
      continue
    fi

    echo "$(date): refreshing ZFS disks in parallel:"

    pids=()

    while IFS= read -r pool; do
      [[ -z "$pool" ]] && continue

      media_ids="$(get_pool_media_ids "$pool")"

      if [[ -z "$media_ids" ]]; then
        echo "  WARNING: $pool: no media-* ZFS devices found."
        continue
      fi

      while IFS= read -r media_id; do
        [[ -z "$media_id" ]] && continue

        disk="$(get_physical_disk_for_media_id "$media_id" || true)"

        if [[ -z "$disk" ]]; then
          echo "  FAILED: $pool: could not resolve $media_id"
          continue
        fi

        rawdisk="/dev/r$(basename "$disk")"

        #
        # Touch this disk in parallel with all the others.
        #
        (
          if dd \
            if="$rawdisk" \
            of=/dev/null \
            bs=4096 \
            count=1 \
            2>/dev/null
          then
            echo "  OK: $pool | $disk ($rawdisk) $media_id"
          else
            echo "  FAILED: $pool | $disk ($rawdisk) $media_id"
          fi
        ) &

        pids+=("$!")

      done <<< "$media_ids"

    done <<< "$pools"

    #
    # Wait for every disk touch to finish.
    #
    set +e
    for pid in "${pids[@]}"; do
      wait "$pid"
    done
    set -e

    echo
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

#
# Check whether daemon is already running.
#
if [[ -f "$PIDFILE" ]]; then
  OLD_PID="$(cat "$PIDFILE" 2>/dev/null || true)"

  if [[ "$OLD_PID" =~ ^[0-9]+$ ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "Keep-awake daemon already running."
    echo "PID: $OLD_PID"
    exit 0
  fi

  rm -f "$PIDFILE"
fi

#
# Start daemon.
#
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
echo "Current ZFS disks by pool:"

pools="$("$ZPOOL" list -H -o name 2>/dev/null || true)"

while IFS= read -r pool; do
  [[ -z "$pool" ]] && continue

  echo
  echo "$pool"

  media_ids="$(get_pool_media_ids "$pool")"

  if [[ -z "$media_ids" ]]; then
    echo "  No media-* ZFS devices found."
    continue
  fi

  while IFS= read -r media_id; do
    [[ -z "$media_id" ]] && continue

    disk="$(get_physical_disk_for_media_id "$media_id" || true)"

    if [[ -z "$disk" ]]; then
      echo "  UNKNOWN  $media_id"
      continue
    fi

    echo "  $disk  $media_id"

  done <<< "$media_ids"

done <<< "$pools"
