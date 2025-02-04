#!/usr/bin/env sh
#
FX3_DIR="/Volumes/Archive-ZFS-8-Bay/Archive-2024-Oct/Raw Videos/fx3"
AX53_DIR="/Volumes/Archive-ZFS-8-Bay/Archive-2024-Oct/Raw Videos/ax53"
TENTACLE_DIR="/Volumes/Archive-ZFS-8-Bay/Archive-2024-Oct/Raw Videos/tentacle track e"
LARK_MAX_DIR="/Volumes/Archive-ZFS-8-Bay/Archive-2024-Oct/Raw Videos/lark max"

echo "=== Running reorg-script.sh ==="

echo "Sync ${TENTACLE_DIR}"

for dir in $(ls "${TENTACLE_DIR}"); do
    cd "${FX3_DIR}"
    target_dir=$(find . -type d -name "${dir}*")
    if [ -d "${target_dir}" ] && [ ! -d "${FX3_DIR}/${target_dir}/tentacle sync" ]; then
        echo "Creating symlink for ${target_dir}"
        ln -s "../../tentacle track e/${dir}" "${FX3_DIR}/${target_dir}/tentacle sync"
    fi
done

echo "Sync ${AX53_DIR}"

for dir in $(ls "${AX53_DIR}"); do
    cd "${FX3_DIR}"
    target_dir=$(find . -type d -name "${dir}*")
    if [ -d "${target_dir}" ] && [ ! -d "${FX3_DIR}/${target_dir}/ax53" ]; then
        echo "Creating symlink for ${target_dir}"
        ln -s "../../ax53/${dir}" "${FX3_DIR}/${target_dir}/ax53"
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
        target_dir=$(find . -type d -name "${dir}*")
        if [ -d "${target_dir}" ] && [ ! -d "${FX3_DIR}/${target_dir}/lark max ${mic}" ]; then
            echo "Creating symlink for ${target_dir}/lark max/${mic}"
            ln -s "../../lark max/${mic}/${lark_dir}" "${FX3_DIR}/${target_dir}/lark max ${mic}"
        fi
    done
done
