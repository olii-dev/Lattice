#!/bin/bash
#
# Generate or update the Sparkle appcast from archived builds.
#
# Usage:
#   ./scripts/generate-appcast.sh [updates-dir]
#
# Arguments:
#   updates-dir  Directory containing exported .zip/.dmg archives
#                (default: ~/Desktop/AgentSwiftUpdates)
#
# Prerequisites:
#   - Sparkle SPM package resolved in Xcode (provides generate_appcast binary)
#   - EdDSA private key in Keychain (created via generate_keys)
#   - Exported archive(s) in the updates directory
#

set -euo pipefail

# Extract version from Xcode project
VERSION=$(sed -n 's/.*MARKETING_VERSION = \([^;]*\);/\1/p' AgentSwift.xcodeproj/project.pbxproj | head -n 1 | tr -d ' ')
if [ -z "$VERSION" ]; then
    echo "Error: Could not extract MARKETING_VERSION from project.pbxproj"
    exit 1
fi

DOWNLOAD_URL_PREFIX="https://github.com:hpennington/agentswift/"
DEFAULT_UPDATES_DIR="$HOME/Desktop/AgentSwiftUpdates"
UPDATES_DIR="${1:-$DEFAULT_UPDATES_DIR}"

# Zip the app bundle
APP_PATH="$UPDATES_DIR/AgentSwift.app"
ZIP_NAME="AgentSwift-${VERSION}.zip"
if [ ! -d "$APP_PATH" ]; then
    echo "Error: AgentSwift.app not found in $UPDATES_DIR"
    exit 1
fi
echo "Zipping $APP_PATH -> $UPDATES_DIR/$ZIP_NAME"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$UPDATES_DIR/$ZIP_NAME"

# Find the Sparkle bin directory from DerivedData
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData -path "*/sparkle/Sparkle/bin/generate_appcast" -type f 2>/dev/null | head -n 1)

if [ -z "$SPARKLE_BIN" ]; then
    echo "Error: generate_appcast not found in DerivedData."
    echo "Make sure the Sparkle SPM package is resolved in Xcode (build the project first)."
    exit 1
fi

SPARKLE_DIR=$(dirname "$SPARKLE_BIN")

if [ ! -d "$UPDATES_DIR" ]; then
    echo "Error: Updates directory not found: $UPDATES_DIR"
    echo "Usage: $0 [updates-dir]"
    exit 1
fi

# Check that there are archives to process
ARCHIVE_COUNT=$(find "$UPDATES_DIR" -maxdepth 1 \( -name "*.zip" -o -name "*.dmg" -o -name "*.tar.gz" -o -name "*.tar.bz2" \) | wc -l | tr -d ' ')
if [ "$ARCHIVE_COUNT" -eq 0 ]; then
    echo "Error: No archives (.zip, .dmg, .tar.gz) found in $UPDATES_DIR"
    exit 1
fi

echo "Generating appcast..."
echo "  Updates dir: $UPDATES_DIR"
echo "  Download URL prefix: $DOWNLOAD_URL_PREFIX"
echo "  Archives found: $ARCHIVE_COUNT"
echo ""

"$SPARKLE_BIN" "$UPDATES_DIR" --download-url-prefix "$DOWNLOAD_URL_PREFIX"

echo ""
echo "Done! Appcast written to: $UPDATES_DIR/appcast.xml"
echo ""
echo "Next steps:"
echo "  1. Upload the archives and appcast.xml to $DOWNLOAD_URL_PREFIX"
echo "  2. Verify the appcast is accessible at ${DOWNLOAD_URL_PREFIX}appcast.xml"
