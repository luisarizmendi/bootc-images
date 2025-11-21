#!/bin/bash

# Script to generate a cloud-init ISO from user-data and meta-data files
# Usage: ./create-cloudinit-iso.sh <source_directory> <destination_directory>

set -e

# Check if correct number of arguments provided
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <source_directory> <destination_directory>"
    echo "  source_directory: Directory containing user-data and meta-data files"
    echo "  destination_directory: Directory where the ISO file will be created"
    exit 1
fi

SOURCE_DIR="${1%/}"  # Remove trailing slash if present
DEST_DIR="${2%/}"    # Remove trailing slash if present

# Get the base name of the source directory for the ISO name
SOURCE_DIRNAME=$(basename "$SOURCE_DIR")
ISO_NAME="${SOURCE_DIRNAME}.iso"

# Full output path
OUTPUT_ISO="$DEST_DIR/$ISO_NAME"

# Check if source directory exists
if [ ! -d "$SOURCE_DIR" ]; then
    echo "Error: Source directory '$SOURCE_DIR' does not exist"
    exit 1
fi

# Check if destination directory exists
if [ ! -d "$DEST_DIR" ]; then
    echo "Error: Destination directory '$DEST_DIR' does not exist"
    exit 1
fi

# Check if user-data file exists
if [ ! -f "$SOURCE_DIR/user-data" ]; then
    echo "Error: user-data file not found in '$SOURCE_DIR'"
    exit 1
fi

# Check if meta-data file exists
if [ ! -f "$SOURCE_DIR/meta-data" ]; then
    echo "Error: meta-data file not found in '$SOURCE_DIR'"
    exit 1
fi

# Check if genisoimage is installed
if ! command -v genisoimage &> /dev/null; then
    echo "Error: genisoimage is not installed"
    echo "Install it with: sudo dnf install genisoimage (RHEL/Fedora) or sudo apt install genisoimage (Debian/Ubuntu)"
    exit 1
fi

# Create the ISO
echo "Creating cloud-init ISO..."
echo "Source directory: $SOURCE_DIR"
echo "ISO name: $ISO_NAME"
echo "Output path: $OUTPUT_ISO"

genisoimage -output "$OUTPUT_ISO" -volid cidata -joliet -rock "$SOURCE_DIR/user-data" "$SOURCE_DIR/meta-data"

if [ $? -eq 0 ]; then
    echo "Success! Cloud-init ISO created at: $OUTPUT_ISO"
else
    echo "Error: Failed to create ISO"
    exit 1
fi