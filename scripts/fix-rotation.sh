#!/usr/bin/env sh

set -e
set -o pipefail  # Exit if any command in a pipeline fails


# Ensure arguments are valid
if [ $# -lt 1 ] || [ $# -gt 3 ]; then
    echo "Usage: $0 [-r] [-v] <TARGET>"
    echo "<TARGET> can be a file or a directory. If it's a directory, all files will be checked."
    echo "-r: Rotate recursively (applies only to directories)."
    echo "-v: Verbose mode. Print output for skipped files and detailed exiftool logs."
    exit 1
fi

RECURSIVE=false
QUIET=true  # Default to quiet mode

# Parse options
while [ "$1" ]; do
    case "$1" in
        -r)
            RECURSIVE=true
            shift
            ;;
        -v)
            QUIET=false  # Enable verbose mode
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
        rotation=$(exiftool -rotation "$file" | awk -F " " '{print $3}' 2>/dev/null)
        if [ "$rotation" -ne 0 ]; then
            echo "Rotating $file..."
            if [ "$QUIET" = true ]; then
                exiftool -rotation=0 "$file" >/dev/null 2>&1
            else
                exiftool -rotation=0 "$file"
            fi
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
