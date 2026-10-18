#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Development: Arush Yadav (FJ696ZCQ56)}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-HU27CJ3DK6}"
export DEVELOPMENT_TEAM SIGN_IDENTITY

# Restricted entitlements require a provisioning profile, even when codesign
# reports that the signature itself is valid. Check before changing the app.
HOST_PROFILE="$(python3 "$SCRIPT_DIR/find_signing_profile.py")"

echo "==> Building Swift packages (Release)..."
cd "$MACOS_DIR"
if [[ "${WAMC_RUN_TESTS:-true}" == true && "${WAMC_COVERAGE_VERIFIED:-false}" != true ]]; then
    python3 "$SCRIPT_DIR/check_macos_coverage.py"
fi
xcrun swift build -c release

STAGING_DIR="$(mktemp -d "$MACOS_DIR/.build/wamc-package.XXXXXX")"
INSTALL_STAGING=""
cleanup() {
    if [[ -n "$INSTALL_STAGING" ]]; then
        if [[ ! -d /Applications/WAMC.app && -d "$INSTALL_STAGING/Previous.app" ]]; then
            mv "$INSTALL_STAGING/Previous.app" /Applications/WAMC.app
        fi
        rm -rf "$INSTALL_STAGING"
    fi
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT
APP_DIR="$STAGING_DIR/WAMC.app"
OUTPUT="${WAMC_APP_OUTPUT:-$MACOS_DIR/../release-dist/WAMC.app}"
if [[ -e "$OUTPUT" ]]; then echo "Output already exists: $OUTPUT" >&2; exit 1; fi
SYSEXT_DIR="$APP_DIR/Contents/Library/SystemExtensions/com.androidwebcam.app.CameraExtension.systemextension"

echo "==> Creating application structure in $APP_DIR..."
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$SYSEXT_DIR/Contents/MacOS"

echo "==> Copying host app binary and Info.plist..."
BINARY_DIR="$(xcrun swift build -c release --show-bin-path)"
cp "$BINARY_DIR/WAMC" "$APP_DIR/Contents/MacOS/WAMC"
cp "$MACOS_DIR/WAMC-Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$HOST_PROFILE" "$APP_DIR/Contents/embedded.provisionprofile"
if [[ -n "${WAMC_EXTENSION_PROFILE:-}" ]]; then
    cp "$WAMC_EXTENSION_PROFILE" "$SYSEXT_DIR/Contents/embedded.provisionprofile"
fi

echo "==> Compiling CameraExtension..."
xcrun swiftc -target arm64-apple-macos14.0 -O \
    -framework Foundation -framework CoreMediaIO -framework CoreVideo \
    "$MACOS_DIR/Sources/AndroidWebcamCore/CameraHealthSnapshot.swift" \
    "$MACOS_DIR/CameraExtension/ExtensionMain.swift" \
    "$MACOS_DIR/CameraExtension/ExtensionLogger.swift" \
    "$MACOS_DIR/CameraExtension/CameraStreamTimer.swift" \
    "$MACOS_DIR/CameraExtension/CameraMediaFactory.swift" \
    "$MACOS_DIR/CameraExtension/ProviderSource.swift" \
    "$MACOS_DIR/CameraExtension/DeviceSource.swift" \
    "$MACOS_DIR/CameraExtension/StreamSources.swift" \
    -o "$SYSEXT_DIR/Contents/MacOS/CameraExtension"

cp "$MACOS_DIR/CameraExtension/CameraExtension-Info.plist" "$SYSEXT_DIR/Contents/Info.plist"

cp "$MACOS_DIR/WAMC.entitlements" "$STAGING_DIR/Host.entitlements"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $DEVELOPMENT_TEAM.com.androidwebcam.app" "$STAGING_DIR/Host.entitlements"
/usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $DEVELOPMENT_TEAM" "$STAGING_DIR/Host.entitlements"
cp "$MACOS_DIR/CameraExtension/CameraExtension.entitlements" "$STAGING_DIR/Extension.entitlements"
/usr/libexec/PlistBuddy -c "Set :com.apple.security.application-groups:0 $DEVELOPMENT_TEAM.com.androidwebcam.app" "$STAGING_DIR/Extension.entitlements"
/usr/libexec/PlistBuddy -c "Set :CMIOExtension:CMIOExtensionMachServiceName $DEVELOPMENT_TEAM.com.androidwebcam.app.CameraExtension" "$SYSEXT_DIR/Contents/Info.plist"

python3 "$MACOS_DIR/../scripts/release/version.py" --app "$APP_DIR"

echo "==> Embedding Sparkle..."
python3 "$SCRIPT_DIR/embed_sparkle.py" "$APP_DIR"

if [[ "${WAMC_DISTRIBUTION:-false}" == true ]]; then
    : "${SPARKLE_PUBLIC_KEY:?Missing Sparkle update public key}"
fi
if [[ -n "${SPARKLE_PUBLIC_KEY:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_KEY" "$APP_DIR/Contents/Info.plist"
fi

echo "==> Signing System Extension with identity: $SIGN_IDENTITY..."
codesign -s "$SIGN_IDENTITY" -f \
    --entitlements "$STAGING_DIR/Extension.entitlements" \
    --options runtime --timestamp \
    "$SYSEXT_DIR"

echo "==> Signing Container App with identity: $SIGN_IDENTITY..."
codesign -s "$SIGN_IDENTITY" -f \
    --entitlements "$STAGING_DIR/Host.entitlements" \
    --options runtime --timestamp \
    "$APP_DIR"

echo "==> Validating signatures..."
codesign -vvv "$SYSEXT_DIR"
codesign -vvv "$APP_DIR"

# A valid signature alone does not authorize extension activation. Fail the
# deployment if the host was signed without the System Extensions capability.
SIGNED_ENTITLEMENTS="$STAGING_DIR/Signed.entitlements"
codesign -d --entitlements :- "$APP_DIR" > "$SIGNED_ENTITLEMENTS" 2>/dev/null
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.system-extension.install' "$SIGNED_ENTITLEMENTS")" != "true" ]]; then
    echo "WAMC is missing the entitlement required to install its camera extension." >&2
    exit 1
fi
python3 "$SCRIPT_DIR/verify_bundle.py" "$APP_DIR"


mkdir -p "$(dirname "$OUTPUT")"
mv "$APP_DIR" "$OUTPUT"
echo "Validated app bundle: $OUTPUT"
