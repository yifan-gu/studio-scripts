#!/usr/bin/env sh
#
TOP_DIR="/Volumes/Archive-ZFS-8-Bay/Archive-2024-Oct/Raw Videos/organized"
FX3_DIR="/Volumes/Archive-ZFS-8-Bay/Archive-2024-Oct/Raw Videos/fx3"
AX53_DIR="/Volumes/Archive-ZFS-8-Bay/Archive-2024-Oct/Raw Videos/ax53"
TENTACLE_DIR="/Volumes/Archive-ZFS-8-Bay/Archive-2024-Oct/Raw Videos/tentacle track e"
LARK_MAX_DIR="/Volumes/Archive-ZFS-8-Bay/Archive-2024-Oct/Raw Videos/lark max"
GOPRO_DIR="/Volumes/Archive-ZFS-8-Bay/Archive-2024-Oct/Raw Videos/gopro"

echo "=== Running reorg-script.sh ==="

for SRC in "${FX3_DIR}" "${AX53_DIR}" "${TENTACLE_DIR}" "${LARK_MAX_DIR}" "${GOPRO_DIR}"; do
    echo "Sync ${SRC}"

    for dir in $(ls "${SRC}"); do
        cd "${TOP_DIR}"
        target_dir=$(find . -type d -name "${dir}*")
        if [ -d "${target_dir}" ]; then
            for d in $(ls "${SRC}/${dir}"); do
                base=$(basename "$d")
                if [ ! -L "${TOP_DIR}/${target_dir}/${base}" ]; then
                    echo "Creating symlink for ${target_dir}"
                    relative=$(basename "$SRC")
                    ln -s "../../${relative}/${dir}/${base}" "${TOP_DIR}/${target_dir}/${base}"
                fi
            done
        fi
    done
done
