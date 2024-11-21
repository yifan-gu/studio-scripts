#!/usr/bin/env sh
#
FX3_DIR="/Volumes/Archive-ZFS-8-Bay/Archive-2024-Oct/Raw Videos/fx3"
AX53_DIR="/Volumes/Archive-ZFS-8-Bay/Archive-2024-Oct/Raw Videos/ax53"
TENTACLE_DIR="/Volumes/Archive-ZFS-8-Bay/Archive-2024-Oct/Raw Videos/tentacle track e"
LARK_MAX_DIR="/Volumes/Archive-ZFS-8-Bay/Archive-2024-Oct/Raw Videos/lark max"

echo "Sync ${TENTACLE_DIR}"

for dir in $(ls "${TENTACLE_DIR}"); do
    cd "${FX3_DIR}"
    if [ -d "${dir}" ] && [ ! -d "${FX3_DIR}/${dir}/tentacle sync" ]; then
        echo "Creating symlink for ${dir}"
        ln -s "${TENTACLE_DIR}/${dir}" "${FX3_DIR}/${dir}/tentacle sync"
    fi
done

echo "Sync ${AX53_DIR}"

for dir in $(ls "${AX53_DIR}"); do
    cd "${FX3_DIR}"
    if [ -d "${dir}" ] && [ ! -d "${FX3_DIR}/${dir}/ax53" ]; then
        echo "Creating symlink for ${dir}"
        ln -s "${AX53_DIR}/${dir}" "${FX3_DIR}/${dir}/ax53"
    fi
done

echo "Sync ${LARK_MAX_DIR}"

for mic in "MIC 1" "MIC 2"; do
    for lark_dir in $(ls "${LARK_MAX_DIR}/${mic}"); do
        dir_year=$(echo ${lark_dir} | awk -F "-" {'print $2'})
        dir_month=$(echo ${lark_dir} | awk -F "-" {'print $3'})
        dir_day=$(echo ${lark_dir} | awk -F "-" {'print $4'})
        dir="${dir_year}${dir_month}${dir_day}"
        cd "${FX3_DIR}"
        if [ -d "${dir}" ] && [ ! -d "${FX3_DIR}/${dir}/lark max ${mic}" ]; then
            echo "Creating symlink for ${dir}/lark max/${mic}"
            ln -s "${LARK_MAX_DIR}/${mic}/${lark_dir}" "${FX3_DIR}/${dir}/lark max ${mic}"
        fi
    done
done
