#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
APP_DIR="${WAMC_APP_DIR:-/Applications/WAMC.app}"
OUTPUT="${1:-$REPO_DIR/WAMC.dmg}"

if [[ "${WAMC_COVERAGE_VERIFIED:-false}" != true ]]; then
    python3 "$SCRIPT_DIR/check_macos_coverage.py"
fi
python3 "$SCRIPT_DIR/verify_bundle.py" "$APP_DIR"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/wamc-dmg.XXXXXX")"
MOUNT="$STAGING/mounted"
MOUNTED=false
cleanup() {
    if $MOUNTED; then hdiutil detach "$MOUNT" || true; fi
    rm -rf "$STAGING"
}
trap cleanup EXIT
mkdir -p "$STAGING/contents" "$MOUNT"
ditto "$APP_DIR" "$STAGING/contents/WAMC.app"
ln -s /Applications "$STAGING/contents/Applications"
cp "$SCRIPT_DIR/../INSTALL.txt" "$STAGING/contents/START HERE.txt"
hdiutil create -volname WAMC -srcfolder "$STAGING/contents" -format UDZO "$STAGING/WAMC.dmg"
hdiutil verify "$STAGING/WAMC.dmg"
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT" "$STAGING/WAMC.dmg"
MOUNTED=true
python3 "$SCRIPT_DIR/verify_bundle.py" "$MOUNT/WAMC.app"
cmp "$APP_DIR/Contents/MacOS/WAMC" "$MOUNT/WAMC.app/Contents/MacOS/WAMC"
cmp "$APP_DIR/Contents/Library/SystemExtensions/com.androidwebcam.app.CameraExtension.systemextension/Contents/MacOS/CameraExtension" \
    "$MOUNT/WAMC.app/Contents/Library/SystemExtensions/com.androidwebcam.app.CameraExtension.systemextension/Contents/MacOS/CameraExtension"
hdiutil detach "$MOUNT"
MOUNTED=false
mv -f "$STAGING/WAMC.dmg" "$OUTPUT"
echo "Validated DMG: $OUTPUT"
