#!/usr/bin/env sh
set -eu

TOP_DIR="/Volumes/Archive-ZFS-8-Bay-2019-2026/Archive-2024-Oct/Raw Videos/organized"

FX3_DIR="/Volumes/Archive-ZFS-8-Bay-2019-2026/Archive-2024-Oct/Raw Videos/fx3"
AX53_DIR="/Volumes/Archive-ZFS-8-Bay-2019-2026/Archive-2024-Oct/Raw Videos/ax53"
TENTACLE_DIR="/Volumes/Archive-ZFS-8-Bay-2019-2026/Archive-2024-Oct/Raw Videos/tentacle track e"
LARK_MAX_DIR="/Volumes/Archive-ZFS-8-Bay-2019-2026/Archive-2024-Oct/Raw Videos/lark max"
GOPRO_DIR="/Volumes/Archive-ZFS-8-Bay-2019-2026/Archive-2024-Oct/Raw Videos/gopro"

# label is only used for logging; link names come from subfolder names (fx3-tangerine, etc.)
DEVICE_DIRS="
FX3:$FX3_DIR
AX53:$AX53_DIR
TENTACLE:$TENTACLE_DIR
LARK_MAX:$LARK_MAX_DIR
GOPRO:$GOPRO_DIR
"

DRY_RUN="${DRY_RUN:-0}"

log() { printf '%s\n' "$*"; }

for org in "$TOP_DIR"/*; do
  [ -d "$org" ] || continue

  base=$(basename "$org")
  key=${base%% *}          # first word before first space
  [ -n "$key" ] || continue

  echo "$DEVICE_DIRS" | while IFS=: read -r label devroot; do
    [ -n "$devroot" ] || continue

    daydir="$devroot/$key"
    [ -d "$daydir" ] || continue

    # Iterate subfolders under device daydir
    found_any=0
    for sub in "$daydir"/*; do
      [ -d "$sub" ] || continue
      found_any=1

      subname=$(basename "$sub")
      link="$org/$subname"

      # If link already exists, skip
      if [ -L "$link" ] || [ -e "$link" ]; then
        #log "EXISTS: $link"
        continue
      fi

      if [ "$DRY_RUN" = "1" ]; then
        log "LINK: $link -> $sub"
      else
        ln -s "$sub" "$link"
        log "LINKED: $link -> $sub"
      fi
    done

    # If you also want a link to the day folder itself when it has no subfolders:
    # if [ "$found_any" = "0" ]; then
    #   link="$org/${label,,}"
    #   [ -e "$link" ] || ln -s "$daydir" "$link"
    # fi
  done
done
