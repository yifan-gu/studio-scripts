#!/usr/bin/env sh

set -e
set -o pipefail  # Exit if any command in a pipeline fails

ARCHIVE_DIR="/Volumes/Archive-ZFS-8-Bay-2026/Archive-2026-Mar"
BACKUP_ARCHIVE_DIR="/Volumes/Backup-Archive-ZFS-6-Bay-2024-Oct/Archive-2026-Mar"
TOP_DIR="${ARCHIVE_DIR}/Raw Videos/organized"
FX3_DIR="${ARCHIVE_DIR}/Raw Videos/fx3"
AX53_DIR="${ARCHIVE_DIR}/Raw Videos/ax53"
TENTACLE_DIR="${ARCHIVE_DIR}/Raw Videos/tentacle track e"
LARKMAX_DIR="${ARCHIVE_DIR}/Raw Videos/lark max"
GOPRO_DIR="${ARCHIVE_DIR}/Raw Videos/gopro"
SONY_TRV_DIR="${ARCHIVE_DIR}/Raw Videos/sony trv"

VIDEO_DATA_PATH="/Volumes/Untitled/PRIVATE/M4ROOT/CLIP"
AUDIO_DATA_PATH="/Volumes/NO NAME"
GOPRO_DATA_PATH="/Volumes/Untitled/DCIM/100GOPRO"
TRV_DATA_PATH="/Volumes/VIDEO/VIDEO/HVR"

TEMP_DIR="/tmp/trv-import"
TEMP_MOV_DIR="${TEMP_DIR}/mov"


if [ $# -lt 2 ]; then
    echo "usage: $0 DEVICE_NAME DATE [SUMMARY]"
    exit 1
fi

echo "=== Running Backup-data.sh ==="

DEVICE_NAME="$1"
DATE="$2"
shift 2
SUMMARY="$*"  # Capture the remaining arguments as the summary

FULL_NAME="${DATE} ${SUMMARY}"
COMBINED_NAME="${DATE}"

mkdir -p "${TOP_DIR}/${FULL_NAME}"

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
        TARGET_DIR="${AX53_DIR}/${COMBINED_NAME}/ax53-blk"
        mkdir -p "${TARGET_DIR}"
        rsync --info=progress2 -avrhb "${VIDEO_DATA_PATH}"/* "${TARGET_DIR}/"
        ;;
     lark-*)
        TARGET_DIR="${LARKMAX_DIR}/${COMBINED_NAME}/${DEVICE_NAME}"
        mkdir -p "${TARGET_DIR}"
        rsync --info=progress2 -avrhb "${AUDIO_DATA_PATH}"/* "${TARGET_DIR}/"
        ;;
     gopro-*)
        TARGET_DIR="${GOPRO_DIR}/${COMBINED_NAME}/${DEVICE_NAME}"
        mkdir -p "${TARGET_DIR}"
        rsync --info=progress2 -avrhb "${GOPRO_DATA_PATH}"/* "${TARGET_DIR}/"
        ;;
     trv-*)
        TARGET_DIR="${SONY_TRV_DIR}/${COMBINED_NAME}/${DEVICE_NAME}"
        mkdir -p "${TARGET_DIR}"
        mkdir -p "${TEMP_DIR}"
        mkdir -p "${TEMP_MOV_DIR}"

        rsync --info=progress2 -avrhb "${TRV_DATA_PATH}"/* "${TEMP_DIR}/"

        for file in "${TEMP_DIR}"/*.AVI; do
            [ -e "${file}" ] || continue

            base="$(basename "${file}")"
            name="${base%.*}"

            echo "Converting: ${file}"
            ffmpeg -y -i "${file}" -c copy "${TEMP_MOV_DIR}/${name}.mov"
        done

        rsync --info=progress2 -avrhb "${TEMP_MOV_DIR}/"*.mov "${TARGET_DIR}/"

        rm -rf ${TEMP_DIR}
        ;;
    *)
        echo "Wrong name given"
        exit 1
        ;;
esac

reorg-script.sh

echo
echo "!!! Please run rsync to backup the whole drive !!!"
