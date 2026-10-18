#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ANDROID_DIR="$REPO_DIR/android"
MACOS_DIR="$REPO_DIR/macos"
PACKAGE_NAME="com.androidwebcam.app"
SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Development: Arush Yadav (FJ696ZCQ56)}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-HU27CJ3DK6}"
export DEVELOPMENT_TEAM

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Run this script on the Mac that has the Android device and signing profile." >&2
    exit 1
fi

if [[ ! -x "$ANDROID_DIR/gradlew" || ! -x "$ANDROID_DIR/scripts/install_and_configure.sh" ]]; then
    echo "The Android Gradle wrapper or install script is missing from $REPO_DIR." >&2
    exit 1
fi

if [[ ! -x "$MACOS_DIR/scripts/build_and_install.sh" || ! -x "$MACOS_DIR/scripts/build_dmg.sh" ]]; then
    echo "The macOS build/install or DMG script is missing from $REPO_DIR." >&2
    exit 1
fi

TMP_ROOT="${TMPDIR:-/tmp}"
LOG_DIR="$(mktemp -d "${TMP_ROOT%/}/wamc-clean-build-install.XXXXXX")"

run_logged() {
    local stage="$1"
    local log_file="$2"
    shift 2

    echo "==> $stage"
    if "$@" > "$log_file" 2>&1; then
        echo "    Passed (log: $log_file)"
    else
        local status=$?
        echo "    Failed with exit code $status. Log: $log_file" >&2
        tail -n 40 "$log_file" >&2 || true
        exit "$status"
    fi
}

# Complete every prerequisite check before removing an app or build artifact.
if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required to validate the Mac provisioning profile." >&2
    exit 1
fi

if [[ ! -x /usr/libexec/java_home ]]; then
    echo "Install a JDK 17 before running this script." >&2
    exit 1
fi
JAVA_HOME="$(/usr/libexec/java_home -v 17 2>/dev/null || true)"
if [[ -z "$JAVA_HOME" || ! -x "$JAVA_HOME/bin/java" ]]; then
    echo "JDK 17 was not found. Install it before running this script." >&2
    exit 1
fi
export JAVA_HOME

ANDROID_SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
if [[ ! -d "$ANDROID_SDK/platform-tools" || ! -d "$ANDROID_SDK/platforms/android-35" ]]; then
    echo "Android SDK platform-tools and platforms/android-35 are required at $ANDROID_SDK." >&2
    exit 1
fi
export ANDROID_HOME="$ANDROID_SDK"
export ANDROID_SDK_ROOT="$ANDROID_SDK"
export PATH="$ANDROID_SDK/platform-tools:$PATH"

if ! command -v adb >/dev/null 2>&1; then
    echo "adb was not found in the Android SDK platform-tools." >&2
    exit 1
fi

run_logged "Check Android Gradle wrapper" "$LOG_DIR/gradle_preflight.log" \
    bash -c 'cd "$1" && ./gradlew --version' _ "$ANDROID_DIR"

if ! command -v xcrun >/dev/null 2>&1 || ! command -v codesign >/dev/null 2>&1; then
    echo "Xcode command-line tools are required for the macOS build." >&2
    exit 1
fi

if ! xcode-select -p >/dev/null 2>&1; then
    echo "Select or install Xcode command-line tools before running this script." >&2
    exit 1
fi

IDENTITY_LOG="$LOG_DIR/signing_identity_preflight.log"
if ! security find-identity -v -p codesigning > "$IDENTITY_LOG" 2>&1; then
    echo "Could not inspect available code-signing identities. Log: $IDENTITY_LOG" >&2
    tail -n 40 "$IDENTITY_LOG" >&2 || true
    exit 1
fi
if ! grep -F -- "$SIGN_IDENTITY" "$IDENTITY_LOG" >/dev/null; then
    echo "Signing identity '$SIGN_IDENTITY' is unavailable. Log: $IDENTITY_LOG" >&2
    tail -n 40 "$IDENTITY_LOG" >&2 || true
    exit 1
fi

PROFILE_LOG="$LOG_DIR/signing_profile_preflight.log"
if ! python3 "$MACOS_DIR/scripts/find_signing_profile.py" > "$PROFILE_LOG" 2>&1; then
    echo "A valid WAMC provisioning profile was not found. Log: $PROFILE_LOG" >&2
    tail -n 40 "$PROFILE_LOG" >&2 || true
    exit 1
fi

DEVICE_OUTPUT="$LOG_DIR/android_devices_preflight.log"
if ! adb devices -l > "$DEVICE_OUTPUT" 2>&1; then
    echo "Could not query Android devices. Log: $DEVICE_OUTPUT" >&2
    tail -n 40 "$DEVICE_OUTPUT" >&2 || true
    exit 1
fi

if [[ -n "${ANDROID_SERIAL:-}" ]]; then
    DEVICE_STATE="$(adb -s "$ANDROID_SERIAL" get-state 2>/dev/null || true)"
    if [[ "$DEVICE_STATE" != "device" ]]; then
        echo "ANDROID_SERIAL '$ANDROID_SERIAL' is not an authorized, connected device." >&2
        cat "$DEVICE_OUTPUT" >&2
        exit 1
    fi
else
    DEVICE_COUNT=0
    SELECTED_DEVICE=""
    while IFS= read -r DEVICE_SERIAL; do
        [[ -n "$DEVICE_SERIAL" ]] || continue
        DEVICE_COUNT=$((DEVICE_COUNT + 1))
        SELECTED_DEVICE="$DEVICE_SERIAL"
    done < <(awk 'NR > 1 && $2 == "device" { print $1 }' "$DEVICE_OUTPUT")

    if [[ "$DEVICE_COUNT" -ne 1 ]]; then
        echo "Connect exactly one authorized Android device, or set ANDROID_SERIAL when several are connected." >&2
        cat "$DEVICE_OUTPUT" >&2
        exit 1
    fi
    ANDROID_SERIAL="$SELECTED_DEVICE"
    export ANDROID_SERIAL
fi

echo "Android target: $ANDROID_SERIAL"
echo "Build logs: $LOG_DIR"

# Android clean install. Uninstalling this package clears only WAMC device data.
if adb -s "$ANDROID_SERIAL" shell pm list packages "$PACKAGE_NAME" 2>/dev/null \
    | grep -Fx "package:$PACKAGE_NAME" >/dev/null; then
    run_logged "Stop Android WAMC" "$LOG_DIR/android_stop.log" \
        adb -s "$ANDROID_SERIAL" shell am force-stop "$PACKAGE_NAME"
    run_logged "Uninstall Android WAMC and clear its data" "$LOG_DIR/android_uninstall.log" \
        adb -s "$ANDROID_SERIAL" uninstall "$PACKAGE_NAME"
fi

run_logged "Clean Android Gradle outputs" "$LOG_DIR/android_gradle_clean.log" \
    bash -c 'cd "$1" && ./gradlew clean' _ "$ANDROID_DIR"
rm -rf "$ANDROID_DIR/.gradle" "$ANDROID_DIR/app/build"
rm -f "$REPO_DIR/WAMC.apk"

run_logged "Build and install Android WAMC" "$LOG_DIR/android_install.log" \
    "$ANDROID_DIR/scripts/install_and_configure.sh"

ANDROID_APK="$ANDROID_DIR/app/build/outputs/apk/debug/app-debug.apk"
if [[ ! -s "$ANDROID_APK" ]]; then
    echo "Android install completed without producing $ANDROID_APK." >&2
    exit 1
fi
cp "$ANDROID_APK" "$REPO_DIR/WAMC.apk"

run_logged "Verify Android package is installed" "$LOG_DIR/android_verify_install.log" \
    adb -s "$ANDROID_SERIAL" shell pm path "$PACKAGE_NAME"
if ! adb -s "$ANDROID_SERIAL" shell pm path "$PACKAGE_NAME" 2>/dev/null \
    | grep -q 'package:'; then
    echo "Android package $PACKAGE_NAME is not installed on $ANDROID_SERIAL." >&2
    exit 1
fi
run_logged "Launch Android WAMC" "$LOG_DIR/android_launch.log" \
    adb -s "$ANDROID_SERIAL" shell am start -W -n "$PACKAGE_NAME/.ui.MainActivity"

# Reset only WAMC's Mac preferences, cache, and saved window state. Keep the
# system extension registration and its existing macOS approval intact.
run_logged "Stop Mac WAMC" "$LOG_DIR/macos_stop.log" \
    bash -c 'pkill -x WAMC; status=$?; [[ $status -eq 0 || $status -eq 1 ]]'
for _ in 1 2 3 4 5; do
    pgrep -x WAMC >/dev/null 2>&1 || break
    sleep 1
done
if pgrep -x WAMC >/dev/null 2>&1; then
    echo "WAMC is still running; Mac preferences and caches were not removed." >&2
    exit 1
fi

defaults delete com.androidwebcam.app >/dev/null 2>&1 || true
rm -f "$HOME/Library/Preferences/com.androidwebcam.app.plist"
rm -rf "$HOME/Library/Caches/com.androidwebcam.app"
rm -rf "$HOME/Library/Saved Application State/com.androidwebcam.app.savedState"
rm -rf "$MACOS_DIR/.build"

run_logged "Build, sign, install, and launch Mac WAMC" "$LOG_DIR/macos_install.log" \
    "$MACOS_DIR/scripts/build_and_install.sh"

run_logged "Build and validate WAMC.dmg" "$LOG_DIR/macos_dmg.log" \
    "$MACOS_DIR/scripts/build_dmg.sh" "$REPO_DIR/WAMC.dmg"

if [[ ! -s "$REPO_DIR/WAMC.apk" || ! -s "$REPO_DIR/WAMC.dmg" ]]; then
    echo "Expected APK and DMG artifacts were not both produced." >&2
    exit 1
fi

echo "Clean build and installation completed."
echo "Android device: $ANDROID_SERIAL"
echo "Android package: $PACKAGE_NAME (launched)"
echo "Android APK: $REPO_DIR/WAMC.apk"
echo "Mac app: /Applications/WAMC.app (launched)"
echo "Mac DMG: $REPO_DIR/WAMC.dmg"
echo "Logs: $LOG_DIR"
echo "If macOS requests camera-extension approval, complete it in System Settings or WAMC Setup & Diagnostics."
