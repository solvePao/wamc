#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "==> Building and installing WAMC on Android device..."
cd "$ANDROID_DIR"
./gradlew installDebug

echo "==> Setting default USB configuration to MTP (Transferring files / Android Auto)..."
adb shell svc usb setScreenUnlockedFunctions mtp || true
adb shell svc usb setFunctions mtp || true

echo "==> Launching WAMC on Android device..."
adb shell am start -n com.androidwebcam.app/.ui.MainActivity || true

echo "==> Done! Default USB configuration set to Transferring files / Android Auto."

