#!/usr/bin/env bash

set -e

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 INSTALL_DIR"
  echo "Example: $0 /usr/local/bin"
  exit 2
fi

INSTALL_DIR="${1%/}"
SCRIPT_DIR="$(cd "$(dirname "$0")/scripts" && pwd)"

mkdir -p "$INSTALL_DIR"

for src in "$SCRIPT_DIR"/*; do
  [[ -e "$src" ]] || continue

  name="$(basename "$src")"
  dst="$INSTALL_DIR/$name"

  chmod +x "$src"

  echo "$dst -> $src"
  ln -sfn "$src" "$dst"
done

echo
echo "Installed to: $INSTALL_DIR"
