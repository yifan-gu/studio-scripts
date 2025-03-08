#!/bin/bash
# Enable extended globbing to safely handle patterns with no matches
shopt -s nullglob

# Set the root directory (adjust the path if needed)
ROOT="lark max"

# Change to the root directory
cd "$ROOT" || { echo "Directory $ROOT not found"; exit 1; }

# Loop over each MIC folder in the root directory
for mic in MIC*; do
    if [ -d "$mic" ]; then
        # Loop over each hl- folder within the MIC folder
        for hl in "$mic"/hl-*; do
            if [ -d "$hl" ]; then
                # Extract the base name (e.g. "hl-2024-05-06")
                base=$(basename "$hl")
                # Extract the date part (YYYY-MM-DD) and remove hyphens to create YYYYMMDD
                date_part=${base#hl-}       # "2024-05-06"
                new_date=${date_part//-/}    # "20240506"
                
                # Create the destination directory: ROOT/YYYYMMDD/MIC X/hl-YYYY-MM-DD
                dest="$PWD/$new_date/$mic/$base"
                mkdir -p "$dest"
                
                # Move all files from the hl- folder to the destination hl- folder
                mv "$hl"/* "$dest"/
                
                # Remove the now-empty hl- folder
                rmdir "$hl"
            fi
        done
        # Remove the original MIC folder (if empty)
        rmdir "$mic"
    fi
done

echo "Reorganization complete!"
