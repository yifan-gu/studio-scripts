#!/usr/bin/env sh

set -e
set -o pipefail  # Exit if any command in a pipeline fails

FX3_DIR="/Volumes/Archive-ZFS-8-Bay/Archive-2024-Oct/Raw Videos/fx3"
AX53_DIR="/Volumes/Archive-ZFS-8-Bay/Archive-2024-Oct/Raw Videos/ax53"
TENTACLE_DIR="/Volumes/Archive-ZFS-8-Bay/Archive-2024-Oct/Raw Videos/tentacle track e"
LARKMAX_DIR="/Volumes/Archive-ZFS-8-Bay/Archive-2024-Oct/Raw Videos/lark max"

VIDEO_DATA_PATH="/Volumes/Untitled/PRIVATE/M4ROOT/CLIP"
AUDIO_DATA_PATH="/Volumes/NO NAME"

if [ $# -ne 2 ]; then
    echo "usage: $0 DEVICE_NAME DATE"
    exit 1
fi

DEVICE_NAME="$1"
DATE="$2"

#sudo zpool import -a
#set -o xtrace

case "${DEVICE_NAME}" in
    "tangerine" | "ultramarine" | "vanilla" )
        mkdir -p "${FX3_DIR}/${DATE}/fx3-${DEVICE_NAME}"
        rsync --info=progress2 -avrhb  "${VIDEO_DATA_PATH}"/* "${FX3_DIR}/${DATE}/fx3-${DEVICE_NAME}/"
        echo "Checking for video rotation..."
        fix-rotation.sh -r "${FX3_DIR}/${DATE}/fx3-${DEVICE_NAME}"
        ;;
    "amber" | "emerald" | "ivory" | "lavender")
        mkdir -p "${TENTACLE_DIR}/${DATE}/tentacle-${DEVICE_NAME}"
        rsync --info=progress2 -avrhb  "${AUDIO_DATA_PATH}"/* "${TENTACLE_DIR}/${DATE}/tentacle-${DEVICE_NAME}/"
        ;;
    "ax53")
        mkdir -p "${AX53_DIR}/${DATE}"
        rsync --info=progress2 -avrhb  "${VIDEO_DATA_PATH}"/* "${AX53_DIR}/${DATE}/"
        ;;
    "lark1")
        mkdir -p "${LARKMAX_DIR}/MIC 1"
        rsync --info=progress2 -avrhb  "${AUDIO_DATA_PATH}"/* "${LARKMAX_DIR}/MIC 1/"
        ;;
    "lark2")
        mkdir -p "${LARKMAX_DIR}/MIC 2"
        rsync --info=progress2 -avrhb  "${AUDIO_DATA_PATH}"/* "${LARKMAX_DIR}/MIC 2/"
        ;;
    *)
        echo "Wrong name given"
        exit 1
        ;;
esac
