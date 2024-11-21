#!/usr/bin/env sh

set -e

# Ensure arguments are not more than 2
if [ $# -lt 1 ] || [ $# -gt 3 ]; then
    echo "Usage: $0 [-r] [-q] <TARGET>"
    echo "<TARGET> can be a file or a directory. If it's a directory, all files will be checked."
    echo "-r: Rotate recursively (applies only to directories)."
    echo "-q: Quiet mode. Suppress output for skipped files."
    exit 1
fi

RECURSIVE=false
QUIET=false

# Parse options
while [ "$1" ]; do
    case "$1" in
        -r)
            RECURSIVE=true
            shift
            ;;
        -q)
            QUIET=true
            shift
            ;;
        *)
            TARGET="$1"
            shift
            ;;
    esac
done

# Function to check if a file has a .MP4 extension (case-insensitive)
is_mp4_file() {
    local file="$1"
    case "${file##*.}" in
        [Mm][Pp]4) return 0 ;; # It is an MP4 file
        *) return 1 ;;         # Not an MP4 file
    esac
}

rotate_file() {
    local file="$1"
    if is_mp4_file "$file"; then
        rotation=$(exiftool -rotation "$file" | awk -F " " '{print $3}')
        if [ "$rotation" -ne 0 ]; then
            exiftool -rotation=0 "$file"
            trash "${file}_original"
            echo "$file rotated. Original file moved to trash."
        else
            echo "$file does not need rotation."
        fi
    else
        if [ "$QUIET" = false ]; then
            echo "Skipping $file: not an MP4 file."
        fi
    fi
}

process_target() {
    local target="$1"
    if [ -f "$target" ]; then
        rotate_file "$target"
    elif [ -d "$target" ]; then
        if [ "$RECURSIVE" = true ]; then
            find "$target" -type f | while read -r file; do
                rotate_file "$file"
            done
        else
            for file in "$target"/*; do
                [ -f "$file" ] && rotate_file "$file"
            done
        fi
    else
        echo "Error: $target is neither a file nor a directory."
        exit 1
    fi
}

process_target "$TARGET"
