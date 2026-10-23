#!/bin/bash
set -euo pipefail
# Embed after building the host app, before signing its outer bundle.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?Usage: build_fskit_extension.sh /path/to/MacNTFS.app [debug|release]}"
CONFIGURATION="${2:-release}"
IDENTITY="${MACNTFS_SIGNING_IDENTITY:--}"
PROFILE="${MACNTFS_FSKIT_PROFILE:-}"
cd "$ROOT"
swift build -c "$CONFIGURATION" --product MacNTFSFileSystemExtension
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
EXTENSION="$APP/Contents/Extensions/MacNTFSFileSystemExtension.appex"
mkdir -p "$EXTENSION/Contents/MacOS"
cp "$BIN_DIR/MacNTFSFileSystemExtension" "$EXTENSION/Contents/MacOS/"
cp Config/MacNTFSFileSystemExtension-Info.plist "$EXTENSION/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" "$EXTENSION/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")" "$EXTENSION/Contents/Info.plist"
ENTITLEMENTS="$(mktemp -t macntfs-entitlements)"
DECODED_PROFILE="$(mktemp -t macntfs-profile)"
trap 'rm -f "$ENTITLEMENTS" "$DECODED_PROFILE"' EXIT
cp Config/MacNTFSFileSystemExtension.entitlements "$ENTITLEMENTS"
if [ -n "$PROFILE" ]; then
    if [ "$IDENTITY" = "-" ]; then
        echo "A provisioned extension requires an Apple-issued signing identity." >&2
        exit 1
    fi
    security cms -D -i "$PROFILE" > "$DECODED_PROFILE"
    python3 - "$DECODED_PROFILE" "$ENTITLEMENTS" "$EXTENSION/Contents/Info.plist" <<'PY'
import datetime
import plistlib
import sys
from pathlib import Path
profile = plistlib.loads(Path(sys.argv[1]).read_bytes())
provided = profile.get('Entitlements', {})
info = plistlib.loads(Path(sys.argv[3]).read_bytes())
identifier = info['CFBundleIdentifier']
app_id = provided.get('com.apple.application-identifier', '')
team = provided.get('com.apple.developer.team-identifier', '')
if not team or app_id != team + '.' + identifier:
    raise SystemExit('FSKit profile must authorize this exact extension bundle identifier and team.')
if provided.get('com.apple.developer.fskit.fsmodule') is not True:
    raise SystemExit('FSKit profile does not authorize com.apple.developer.fskit.fsmodule.')
expires = profile.get('ExpirationDate')
if not expires or expires.replace(tzinfo=datetime.timezone.utc) <= datetime.datetime.now(datetime.timezone.utc):
    raise SystemExit('FSKit provisioning profile is expired or has no expiration date.')
entitlements_path = Path(sys.argv[2])
entitlements = plistlib.loads(entitlements_path.read_bytes())
entitlements['com.apple.application-identifier'] = app_id
entitlements['com.apple.developer.team-identifier'] = team
entitlements_path.write_bytes(plistlib.dumps(entitlements))
PY
    cp "$PROFILE" "$EXTENSION/Contents/embedded.provisionprofile"
else
    rm -f "$EXTENSION/Contents/embedded.provisionprofile"
    echo "WARNING: No FSKit provisioning profile; this development bundle can register but is not ready for mounting." >&2
fi
codesign --force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" "$EXTENSION"
codesign --verify --strict "$EXTENSION"
printf 'Embedded FSKit extension: %s\n' "$EXTENSION"
