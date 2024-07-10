#!/usr/bin/env sh
#
FX3_DIR="/Volumes/Archive-ZFS-8-Bay/Archive-2023/Raw Videos/fx3"
AX53_DIR="/Volumes/Archive-ZFS-8-Bay/Archive-2023/Raw Videos/ax53"
TENTACLE_DIR="/Volumes/Archive-ZFS-8-Bay/Archive-2023/Raw Videos/tentacle track e"

echo "Sync ${TENTACLE_DIR}"

for dir in $(ls "${TENTACLE_DIR}"); do
    cd "${FX3_DIR}"
    if [ -d "${dir}" ] && [ 'template-dir' != "${dir}" ] && [ ! -d "${FX3_DIR}/${dir}/tentacle sync" ]; then
        echo "Creating symlink for ${dir}"
        ln -s "${TENTACLE_DIR}/${dir}" "${FX3_DIR}/${dir}/tentacle sync"
    fi
done

echo "Sync ${AX53_DIR}"

for dir in $(ls "${AX53_DIR}"); do
    cd "${FX3_DIR}"
    if [ -d "${dir}" ] && [ 'template-dir' != "${dir}" ] && [ ! -d "${FX3_DIR}/${dir}/ax53" ]; then
        echo "Creating symlink for ${dir}"
        ln -s "${AX53_DIR}/${dir}" "${FX3_DIR}/${dir}/ax53"
    fi
done
