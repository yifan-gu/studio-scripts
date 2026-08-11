#!/usr/bin/env sh
set -eu

ARCHIVE_DIR="/Volumes/Archive-ZFS-8-Bay-2026/Archive-2026-Mar"
TOP_DIR="${ARCHIVE_DIR}/Raw Videos/organized"

FX3_DIR="${ARCHIVE_DIR}/Raw Videos/fx3"
AX53_DIR="${ARCHIVE_DIR}/Raw Videos/ax53"
TENTACLE_DIR="${ARCHIVE_DIR}/Raw Videos/tentacle track e"
LARK_MAX_DIR="${ARCHIVE_DIR}/Raw Videos/lark max"
GOPRO_DIR="${ARCHIVE_DIR}/Raw Videos/gopro"
SONY_TRV_DIR="${ARCHIVE_DIR}/Raw Videos/sony trv"

# label only for logging; devroot is absolute scan root; devrel is sibling folder name under Raw Videos
DEVICE_DIRS="
FX3:$FX3_DIR:fx3
AX53:$AX53_DIR:ax53
TENTACLE:$TENTACLE_DIR:tentacle track e
LARK_MAX:$LARK_MAX_DIR:lark max
GOPRO:$GOPRO_DIR:gopro
TRV:$SONY_TRV_DIR:sony trv
"

DRY_RUN="${DRY_RUN:-0}"

log() { printf '%s\n' "$*"; }

for org in "$TOP_DIR"/*; do
  [ -d "$org" ] || continue

  base=$(basename "$org")
  key=${base%% *}          # first word before first space
  [ -n "$key" ] || continue

  echo "$DEVICE_DIRS" | while IFS=: read -r label devroot devrel; do
    [ -n "$devroot" ] || continue
    [ -n "$devrel" ] || continue

    daydir="$devroot/$key"
    [ -d "$daydir" ] || continue

    for sub in "$daydir"/*; do
      [ -d "$sub" ] || continue

      subname=$(basename "$sub")
      link="$org/$subname"

      # If link already exists, skip
      if [ -L "$link" ] || [ -e "$link" ]; then
        continue
      fi

      # Make the link target relative to "$org" (organized/<orgname>/)
      # sibling folders live at ../../<devrel>/<key>/<subname>
      rel="../../$devrel/$key/$subname"

      if [ "$DRY_RUN" = "1" ]; then
        log "LINK: $link -> $rel"
      else
        ln -s "$rel" "$link"
        log "LINKED: $link -> $rel"
      fi
    done
  done
done
