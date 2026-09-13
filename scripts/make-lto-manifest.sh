#!/bin/bash

set -euo pipefail

# Usage:
#
#   ./make-lto-manifest.sh SOURCE_ROOT OUTPUT_ROOT TAPE_NAME SERIAL [PATH ...]
#
# Whole SOURCE_ROOT:
#
#   ./make-lto-manifest.sh \
#     "/Volumes/Archive-ZFS-8-Bay-2019-2026/Archive-2019-2023" \
#     "$HOME/LTO-Manifests" \
#     "ARCH-CN0001" \
#     "QKR083"
#
# Selected folders/files:
#
#   ./make-lto-manifest.sh \
#     "/Volumes/Archive-ZFS-8-Bay-2019-2026/Archive-2019-2023" \
#     "$HOME/LTO-Manifests" \
#     "ARCH-CN0001" \
#     "QKR083" \
#     "Raw Videos/2019" \
#     "Raw Videos/2020" \
#     "Audio/2019"

if [ "$#" -lt 4 ]; then
    echo "Usage: $0 SOURCE_ROOT OUTPUT_ROOT TAPE_NAME SERIAL [PATH ...]"
    exit 1
fi

SOURCE_ROOT="${1%/}"
OUTPUT_ROOT="${2%/}"
TAPE_NAME="$3"
SERIAL="$4"

shift 4

OUTPUT_DIR="$OUTPUT_ROOT/$TAPE_NAME"

mkdir -p "$OUTPUT_DIR"

MANIFEST_TSV="$OUTPUT_DIR/manifest.tsv"
MANIFEST_TXT="$OUTPUT_DIR/manifest.txt"
CHECKSUM="$OUTPUT_DIR/sha256.txt"
SUMMARY="$OUTPUT_DIR/summary.txt"

if [ ! -d "$SOURCE_ROOT" ]; then
    echo "ERROR: Source does not exist:"
    echo "$SOURCE_ROOT"
    exit 1
fi

cd "$SOURCE_ROOT"

#
# Start fresh
#

printf "size_bytes\tmtime\tpath\n" > "$MANIFEST_TSV"

printf "%12s  %-24s  %s\n" \
    "size" "mtime" "path" > "$MANIFEST_TXT"

: > "$CHECKSUM"


human_size() {
    local bytes="$1"

    awk -v b="$bytes" '
        function fmt(x, unit) {
            if (x >= 100)
                return sprintf("%.0f %s", x, unit)
            else if (x >= 10)
                return sprintf("%.1f %s", x, unit)
            else
                return sprintf("%.2f %s", x, unit)
        }

        BEGIN {
            if (b >= 1000000000000)
                print fmt(b / 1000000000000, "TB")
            else if (b >= 1000000000)
                print fmt(b / 1000000000, "GB")
            else if (b >= 1000000)
                print fmt(b / 1000000, "MB")
            else if (b >= 1000)
                print fmt(b / 1000, "KB")
            else
                printf "%d B\n", b
        }
    '
}


format_time() {
    local seconds="$1"

    if [ "$seconds" -lt 0 ]; then
        seconds=0
    fi

    local days=$((seconds / 86400))
    local hours=$(((seconds % 86400) / 3600))
    local minutes=$(((seconds % 3600) / 60))

    if [ "$days" -gt 0 ]; then
        printf "%dd %dh %dm" "$days" "$hours" "$minutes"
    elif [ "$hours" -gt 0 ]; then
        printf "%dh %dm" "$hours" "$minutes"
    else
        printf "%dm" "$minutes"
    fi
}


process_file() {
    local FILE="$1"

    local REL="${FILE#./}"

    local SIZE
    SIZE=$(stat -f '%z' "$FILE")

    local MTIME
    MTIME=$(stat -f '%Sm' \
        -t '%Y-%m-%dT%H:%M:%S%z' \
        "$FILE")

    #
    # Machine-readable TSV
    #

    printf '%s\t%s\t%s\n' \
        "$SIZE" \
        "$MTIME" \
        "$REL" >> "$MANIFEST_TSV"

    #
    # Human-readable TXT
    #

    local HUMAN_SIZE
    HUMAN_SIZE=$(human_size "$SIZE")

    printf "%12s  %-24s  %s\n" \
        "$HUMAN_SIZE" \
        "$MTIME" \
        "$REL" >> "$MANIFEST_TXT"

    #
    # SHA-256
    #

    local HASH
    HASH=$(shasum -a 256 "$FILE")
    HASH="${HASH%% *}"

    printf '%s  %s\n' \
        "$HASH" \
        "$REL" >> "$CHECKSUM"

    #
    # Progress
    #

    TOTAL_FILES=$((TOTAL_FILES + 1))
    TOTAL_BYTES=$((TOTAL_BYTES + SIZE))

    local NOW
    NOW=$(date +%s)

    local ELAPSED=$((NOW - START_TIME))

    local HASHED_TB
    HASHED_TB=$(awk "BEGIN {
        printf \"%.3f\", $TOTAL_BYTES / 1000000000000
    }")

    local PERCENT
    PERCENT=$(awk "BEGIN {
        if ($TOTAL_SOURCE_BYTES > 0) {
            p = ($TOTAL_BYTES / $TOTAL_SOURCE_BYTES) * 100
            if (p > 100)
                p = 100
            printf \"%.2f\", p
        } else {
            printf \"100.00\"
        }
    }")

    local SPEED_MB
    local ETA

    if [ "$ELAPSED" -gt 0 ] && [ "$TOTAL_BYTES" -gt 0 ]; then

        local SPEED_BPS
        SPEED_BPS=$(awk "BEGIN {
            printf \"%.0f\", $TOTAL_BYTES / $ELAPSED
        }")

        SPEED_MB=$(awk "BEGIN {
            printf \"%.1f\", $SPEED_BPS / 1000000
        }")

        local REMAINING_BYTES=$((TOTAL_SOURCE_BYTES - TOTAL_BYTES))

        if [ "$REMAINING_BYTES" -lt 0 ]; then
            REMAINING_BYTES=0
        fi

        local ETA_SECONDS
        ETA_SECONDS=$(awk "BEGIN {
            if ($SPEED_BPS > 0)
                printf \"%.0f\", $REMAINING_BYTES / $SPEED_BPS
            else
                printf \"0\"
        }")

        ETA=$(format_time "$ETA_SECONDS")

    else

        SPEED_MB="0.0"
        ETA="calculating..."

    fi

    printf '\r\033[KFiles: %d   Data hashed: %s / ~%s TB   %s%%   %s MB/s   ETA %s' \
        "$TOTAL_FILES" \
        "$HASHED_TB" \
        "$TOTAL_SOURCE_TB" \
        "$PERCENT" \
        "$SPEED_MB" \
        "$ETA"
}


#
# Determine selected paths
#

if [ "$#" -eq 0 ]; then
    PATHS=(".")
else
    PATHS=("$@")
fi


#
# Validate paths
#

for ITEM in "${PATHS[@]}"; do
    if [ ! -e "$ITEM" ]; then
        echo "ERROR: Path does not exist:"
        echo "$ITEM"
        exit 1
    fi
done


#
# Approximate source size
#

echo "Getting source size..."

TOTAL_SOURCE_KIB=0

for ITEM in "${PATHS[@]}"; do

    if [ -f "$ITEM" ]; then

        FILE_BYTES=$(stat -f '%z' "$ITEM")

        FILE_KIB=$(
            awk "BEGIN {
                printf \"%.0f\", ($FILE_BYTES + 1023) / 1024
            }"
        )

        TOTAL_SOURCE_KIB=$((TOTAL_SOURCE_KIB + FILE_KIB))

    else

        ITEM_KIB=$(du -sk "$ITEM" | awk '{print $1}')

        TOTAL_SOURCE_KIB=$((TOTAL_SOURCE_KIB + ITEM_KIB))

    fi

done

TOTAL_SOURCE_BYTES=$((TOTAL_SOURCE_KIB * 1024))

TOTAL_SOURCE_TB=$(awk "BEGIN {
    printf \"%.3f\", $TOTAL_SOURCE_BYTES / 1000000000000
}")


TOTAL_FILES=0
TOTAL_BYTES=0

START_TIME=$(date +%s)


echo
echo "Tape name: $TAPE_NAME"
echo "Serial:    $SERIAL"
echo "Source:    $SOURCE_ROOT"
echo "Output:    $OUTPUT_DIR"

echo
echo "Paths:"

for ITEM in "${PATHS[@]}"; do
    echo "  $ITEM"
done

echo
echo "Approximate source size: $TOTAL_SOURCE_TB TB"
echo
echo "Generating manifests + SHA-256..."
echo


#
# Process selected paths
#

for ITEM in "${PATHS[@]}"; do

    if [ -f "$ITEM" ]; then

        process_file "$ITEM"

    elif [ -d "$ITEM" ]; then

        while IFS= read -r -d '' FILE; do
            process_file "$FILE"
        done < <(find "$ITEM" -type f -print0)

    fi

done


echo
echo


#
# Final statistics
#

END_TIME=$(date +%s)
TOTAL_ELAPSED=$((END_TIME - START_TIME))

TOTAL_TB=$(awk "BEGIN {
    printf \"%.3f\", $TOTAL_BYTES / 1000000000000
}")

AVG_SPEED_MB=$(awk "BEGIN {
    if ($TOTAL_ELAPSED > 0)
        printf \"%.1f\", ($TOTAL_BYTES / $TOTAL_ELAPSED) / 1000000
    else
        printf \"0.0\"
}")

TOTAL_TIME=$(format_time "$TOTAL_ELAPSED")


#
# Summary
#

{
    echo "LTO ARCHIVE MANIFEST"
    echo
    echo "Tape Name:"
    echo "$TAPE_NAME"
    echo
    echo "Tape Serial:"
    echo "$SERIAL"
    echo
    echo "Source:"
    echo "$SOURCE_ROOT"
    echo
    echo "Paths:"

    for ITEM in "${PATHS[@]}"; do
        echo "$ITEM"
    done

    echo
    echo "Created:"
    date '+%Y-%m-%d %H:%M:%S %z'
    echo
    echo "Files:"
    echo "$TOTAL_FILES"
    echo
    echo "Total bytes:"
    echo "$TOTAL_BYTES"
    echo
    echo "Total TB:"
    echo "$TOTAL_TB"
    echo
    echo "Checksum:"
    echo "SHA-256"
    echo
    echo "Hashing time:"
    echo "$TOTAL_TIME"
    echo
    echo "Average speed:"
    echo "$AVG_SPEED_MB MB/s"
    echo
    echo "Machine-readable manifest:"
    echo "$(basename "$MANIFEST_TSV")"
    echo
    echo "Human-readable manifest:"
    echo "$(basename "$MANIFEST_TXT")"
    echo
    echo "Checksum file:"
    echo "$(basename "$CHECKSUM")"

} > "$SUMMARY"


echo "Done."
echo
echo "Tape name:     $TAPE_NAME"
echo "Serial:        $SERIAL"
echo "Files:         $TOTAL_FILES"
echo "Size:          $TOTAL_TB TB"
echo "Time:          $TOTAL_TIME"
echo "Average speed: $AVG_SPEED_MB MB/s"
echo
echo "Output folder: $OUTPUT_DIR"
echo "TSV manifest:  $MANIFEST_TSV"
echo "TXT manifest:  $MANIFEST_TXT"
echo "SHA-256:       $CHECKSUM"
echo "Summary:       $SUMMARY"
