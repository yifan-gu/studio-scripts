#!/usr/bin/env sh

set -e
set -o pipefail  # Exit if any command in a pipeline fails

ARCHIVE_DIR="/Volumes/Archive-ZFS-8-Bay/Archive-2024-Oct"
BACKUP_ARCHIVE_DIR="/Volumes/Backup-Archive-ZFS-6-Bay-2024-Oct/Archive-2024-Oct"
FX3_DIR="${ARCHIVE_DIR}/Raw Videos/fx3"
AX53_DIR="${ARCHIVE_DIR}/Raw Videos/ax53"
TENTACLE_DIR="${ARCHIVE_DIR}/Raw Videos/tentacle track e"
LARKMAX_DIR="${ARCHIVE_DIR}/Raw Videos/lark max"

VIDEO_DATA_PATH="/Volumes/Untitled/PRIVATE/M4ROOT/CLIP"
AUDIO_DATA_PATH="/Volumes/NO NAME"

if [ $# -lt 2 ]; then
    echo "usage: $0 DEVICE_NAME DATE [SUMMARY]"
    exit 1
fi

echo "=== Running Backup-data.sh ==="

DEVICE_NAME="$1"
DATE="$2"
shift 2
SUMMARY="$*"  # Capture the remaining arguments as the summary

# Combine DATE and SUMMARY into a single folder name
if [ -n "${SUMMARY}" ]; then
    COMBINED_NAME="${DATE} ${SUMMARY}"
else
    COMBINED_NAME="${DATE}"
fi

case "${DEVICE_NAME}" in
    "tangerine" | "ultramarine" | "vanilla" )
        TARGET_DIR="${FX3_DIR}/${COMBINED_NAME}/fx3-${DEVICE_NAME}"
        mkdir -p "${TARGET_DIR}"
        rsync --info=progress2 -avrhb "${VIDEO_DATA_PATH}"/* "${TARGET_DIR}/"
        echo "Checking for video rotation..."
        fix-rotation.sh -r "${TARGET_DIR}"
        ;;
    "amber" | "emerald" | "ivory" | "lavender")
        TARGET_DIR="${TENTACLE_DIR}/${COMBINED_NAME}/tentacle-${DEVICE_NAME}"
        mkdir -p "${TARGET_DIR}"
        rsync --info=progress2 -avrhb "${AUDIO_DATA_PATH}"/* "${TARGET_DIR}/"
        ;;
    "ax53")
        TARGET_DIR="${AX53_DIR}/${COMBINED_NAME}"
        mkdir -p "${TARGET_DIR}"
        rsync --info=progress2 -avrhb "${VIDEO_DATA_PATH}"/* "${TARGET_DIR}/"
        ;;
    "lark1")
        TARGET_DIR="${LARKMAX_DIR}/${COMBINED_NAME}/MIC 1"
        mkdir -p "${TARGET_DIR}"
        rsync --info=progress2 -avrhb "${AUDIO_DATA_PATH}"/* "${TARGET_DIR}/"
        ;;
    "lark2")
        TARGET_DIR="${LARKMAX_DIR}/${COMBINED_NAME}/MIC 2"
        mkdir -p "${TARGET_DIR}"
        rsync --info=progress2 -avrhb "${AUDIO_DATA_PATH}"/* "${TARGET_DIR}/"
        ;;
    *)
        echo "Wrong name given"
        exit 1
        ;;
esac

reorg-script.sh

echo
echo "!!! Please run rsync to backup the whole drive !!!"
