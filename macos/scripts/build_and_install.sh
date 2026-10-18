#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "==> Building Swift packages (Release)..."
cd "$MACOS_DIR"
xcrun swift build -c release

APP_DIR="/Applications/WAMC.app"
SYSEXT_DIR="$APP_DIR/Contents/Library/SystemExtensions/com.androidwebcam.app.CameraExtension.systemextension"

echo "==> Quitting any running WAMC instance..."
pkill -x WAMC || true
sleep 1

echo "==> Creating application structure in $APP_DIR..."
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$SYSEXT_DIR/Contents/MacOS"

echo "==> Copying host app binary and Info.plist..."
cp "$MACOS_DIR/.build/release/WAMC" "$APP_DIR/Contents/MacOS/WAMC"
cp "$MACOS_DIR/WAMC-Info.plist" "$APP_DIR/Contents/Info.plist"

echo "==> Compiling CameraExtension..."
xcrun swiftc -target arm64-apple-macos14.0 -O \
    -framework Foundation -framework CoreMediaIO -framework CoreVideo \
    "$MACOS_DIR/CameraExtension/ExtensionMain.swift" \
    "$MACOS_DIR/CameraExtension/ProviderSource.swift" \
    "$MACOS_DIR/CameraExtension/DeviceSource.swift" \
    "$MACOS_DIR/CameraExtension/StreamSources.swift" \
    -o "$SYSEXT_DIR/Contents/MacOS/CameraExtension"

cp "$MACOS_DIR/CameraExtension/CameraExtension-Info.plist" "$SYSEXT_DIR/Contents/Info.plist"

SIGN_IDENTITY="Apple Development: Arush Yadav (FJ696ZCQ56)"

echo "==> Signing System Extension with identity: $SIGN_IDENTITY..."
codesign -s "$SIGN_IDENTITY" -f \
    --entitlements "$MACOS_DIR/CameraExtension/CameraExtension.entitlements" \
    --options runtime \
    "$SYSEXT_DIR"

echo "==> Signing Container App with identity: $SIGN_IDENTITY..."
codesign -s "$SIGN_IDENTITY" -f \
    --entitlements "$MACOS_DIR/WAMC.entitlements" \
    --options runtime \
    "$APP_DIR"

echo "==> Validating signatures..."
codesign -vvv "$SYSEXT_DIR"
codesign -vvv "$APP_DIR"

echo "==> Launching updated WAMC..."
open -a "$APP_DIR"

echo "==> Build and deployment completed successfully!"

