#!/bin/bash
set -euo pipefail

# Ensure we operate from project root
cd "$(dirname "$0")/.."

# MacNTFS DMG Packaging Script
APP_NAME="MacNTFS"
VERSION="${1:-0.1.0}"
BUILD_DIR=".build/release"
STAGING_DIR="build/dmg-staging"
DMG_NAME="${APP_NAME}-${VERSION}-arm64.dmg"
OUTPUT_DIR="build/dist"

echo "==> Building ${APP_NAME} in release configuration..."
swift build -c release

echo "==> Preparing DMG staging area..."
rm -rf "${STAGING_DIR}" "${OUTPUT_DIR}"
mkdir -p "${STAGING_DIR}" "${OUTPUT_DIR}"

# Copy executable and resources
cp "${BUILD_DIR}/macntfs" "${STAGING_DIR}/"
cp "README.md" "${STAGING_DIR}/"
cp "LICENSE" "${STAGING_DIR}/"

# Create a symlink to Applications or local bin if app bundle, or provide README
cat << 'EOF' > "${STAGING_DIR}/INSTALL.txt"
MacNTFS Installation:

1. Copy 'macntfs' to /usr/local/bin or ~/.local/bin:
   sudo cp macntfs /usr/local/bin/

2. Verify installation:
   macntfs --help

For documentation and updates:
https://github.com/darkspike1988/MacNTFS
EOF

echo "==> Creating DMG image: ${DMG_NAME}..."
hdiutil create \
  -volname "${APP_NAME} ${VERSION}" \
  -srcfolder "${STAGING_DIR}" \
  -ov \
  -format UDZO \
  "${OUTPUT_DIR}/${DMG_NAME}"

echo "==> DMG successfully created at: ${OUTPUT_DIR}/${DMG_NAME}"
ls -lh "${OUTPUT_DIR}/${DMG_NAME}"
