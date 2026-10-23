#!/bin/bash
set -euo pipefail

# Ensure we operate from project root
cd "$(dirname "$0")/.."

# MacNTFS DMG Packaging Script
APP_NAME="MacNTFS"
VERSION="${1:-0.1.5}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; then
    echo "Invalid version: use a numeric semantic version with an optional development suffix." >&2
    exit 1
fi
IDENTITY="${MACNTFS_SIGNING_IDENTITY:--}"
OUTPUT_DIR="build/dist"
STAGING_DIR="build/dmg-staging"
APP_BUNDLE="${STAGING_DIR}/${APP_NAME}.app"

echo "==> Building ${APP_NAME} in release configuration..."
swift build -c release
BUILD_DIR="$(swift build -c release --show-bin-path)"
ARCHITECTURES="$(lipo -archs "${BUILD_DIR}/MacNTFSApp")"
case "$ARCHITECTURES" in
    arm64|x86_64) ARTIFACT_ARCH="$ARCHITECTURES" ;;
    "arm64 x86_64"|"x86_64 arm64") ARTIFACT_ARCH="universal" ;;
    *) echo "Unsupported artifact architectures: $ARCHITECTURES" >&2; exit 1 ;;
esac
DMG_NAME="${APP_NAME}-${VERSION}-${ARTIFACT_ARCH}.dmg"

echo "==> Preparing DMG staging area..."
rm -rf "${STAGING_DIR}" "${OUTPUT_DIR}"
mkdir -p "${STAGING_DIR}" "${OUTPUT_DIR}"

echo "==> Creating macOS App Bundle: ${APP_BUNDLE}..."
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# Copy binary to App bundle
cp "${BUILD_DIR}/MacNTFSApp" "${APP_BUNDLE}/Contents/MacOS/"
chmod +x "${APP_BUNDLE}/Contents/MacOS/MacNTFSApp"

# Ship the matching helper version with the app, ahead of user-installed helpers.
cp "${BUILD_DIR}/macntfs" "${APP_BUNDLE}/Contents/MacOS/"
chmod +x "${APP_BUNDLE}/Contents/MacOS/macntfs"

# Bundle.module checks Bundle.main.resourceURL for app resources.
for resource_bundle in "${BUILD_DIR}"/*.bundle; do
    if [ -d "${resource_bundle}" ]; then
        cp -R "${resource_bundle}" "${APP_BUNDLE}/Contents/Resources/"
    fi
done

# Copy App Icon if available
if [ -f "Sources/MacNTFSApp/Resources/AppIcon.icns" ]; then
    cp "Sources/MacNTFSApp/Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/"
fi

# Create Info.plist
cat << EOF > "${APP_BUNDLE}/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MacNTFSApp</string>
    <key>CFBundleIdentifier</key>
    <string>org.macntfs.MacNTFS</string>
    <key>CFBundleName</key>
    <string>MacNTFS</string>
    <key>CFBundleDisplayName</key>
    <string>MacNTFS</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
</dict>
</plist>
EOF

# Create PkgInfo
echo -n "APPL????" > "${APP_BUNDLE}/Contents/PkgInfo"

# Create classic Apple drag-and-drop Applications symlink
ln -s /Applications "${STAGING_DIR}/Applications"

# Also include CLI tool and docs in DMG
mkdir -p "${STAGING_DIR}/Command-Line Tools"
cp "${BUILD_DIR}/macntfs" "${STAGING_DIR}/Command-Line Tools/"
cp "README.md" "${STAGING_DIR}/"
cp "LICENSE" "${STAGING_DIR}/"

# Sign nested executables first, then the extension, and finally its host.
codesign --force --sign "$IDENTITY" "${APP_BUNDLE}/Contents/MacOS/macntfs"
codesign --force --sign "$IDENTITY" "${STAGING_DIR}/Command-Line Tools/macntfs"
./scripts/build_fskit_extension.sh "$APP_BUNDLE" release
codesign --force --sign "$IDENTITY" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

echo "==> Creating Apple DMG image: ${DMG_NAME}..."
hdiutil create \
  -volname "${APP_NAME}" \
  -srcfolder "${STAGING_DIR}" \
  -ov \
  -format UDZO \
  "${OUTPUT_DIR}/${DMG_NAME}"

echo "==> DMG successfully created at: ${OUTPUT_DIR}/${DMG_NAME}"
ls -lh "${OUTPUT_DIR}/${DMG_NAME}"
(cd "$OUTPUT_DIR" && shasum -a 256 "$DMG_NAME" > SHA256SUMS)
