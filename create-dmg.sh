#!/bin/bash

# DMG Creation Script
# Requires sudo permissions to run

set -e

# Check for root/sudo permissions
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run with sudo"
    echo "Usage: sudo $0"
    exit 1
fi

# Configuration
APP_NAME="Unplug Alarm"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DMG="${SCRIPT_DIR}/${APP_NAME}.dmg"
SOURCE_APP="${SCRIPT_DIR}/${APP_NAME}.app"

# Verify source app exists
if [[ ! -d "$SOURCE_APP" ]]; then
    echo "Error: Source app not found at: $SOURCE_APP"
    exit 1
fi

# Remove existing DMG if it exists
if [[ -f "$OUTPUT_DMG" ]]; then
    echo "Removing existing DMG: $OUTPUT_DMG"
    rm -f "$OUTPUT_DMG"
fi

echo "Creating DMG for: $APP_NAME"

# Run create-dmg
create-dmg \
    --volname "$APP_NAME" \
    --window-size 820 520 \
    --window-pos 200 120 \
    --icon-size 128 \
    --icon "${APP_NAME}.app" 200 260 \
    --app-drop-link 600 260 \
    --hide-extension "${APP_NAME}.app" \
    --format UDZO \
    "$OUTPUT_DMG" \
    "$SOURCE_APP"

echo ""
echo "DMG created successfully: $OUTPUT_DMG"
