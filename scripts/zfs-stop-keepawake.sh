#!/bin/bash

set -euo pipefail

PIDFILE="/var/run/zfs-keepawake.pid"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "$0")"

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo "$SCRIPT_PATH" "$@"
fi

echo
echo "========================================"
echo " Stopping ZFS keep-awake daemon"
echo "========================================"
echo

if [[ ! -f "$PIDFILE" ]]; then
  echo "Keep-awake daemon is not running."
  exit 0
fi

PID="$(cat "$PIDFILE" 2>/dev/null || true)"

if [[ "$PID" =~ ^[0-9]+$ ]] && kill -0 "$PID" 2>/dev/null; then
  echo "Stopping daemon PID $PID..."

  kill -TERM "$PID"

  for _ in {1..10}; do
    if ! kill -0 "$PID" 2>/dev/null; then
      break
    fi

    sleep 0.5
  done

  if kill -0 "$PID" 2>/dev/null; then
    echo "Daemon did not terminate normally; killing it."
    kill -KILL "$PID" 2>/dev/null || true
  fi
else
  echo "No running daemon found."
fi

rm -f "$PIDFILE"

echo
echo "Keep-awake daemon stopped."
