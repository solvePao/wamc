# AI Agent Operations Guide: Clean, Build & Deploy WAMC

This document provides complete, deterministic instructions for AI agents (and human operators) to clean, build, package, and install **WAMC (Wired Android Mac Camera)** on both Android and macOS, as well as instructions for managing virtual camera extensions and cleaning OBS.

---

## Quick Reference Table

| Target | Clean Command | Build Command | Install Command |
| :--- | :--- | :--- | :--- |
| **Android** | `adb uninstall com.androidwebcam.app` | `cd android && ./gradlew assembleDebug` | `./android/scripts/install_and_configure.sh` |
| **macOS** | `rm -rf /Applications/WAMC.app` | `./macos/scripts/build_and_install.sh` | `./macos/scripts/build_and_install.sh` |
| **macOS DMG** | `rm -f WAMC.dmg` | `hdiutil create -volname "WAMC" -srcfolder /Applications/WAMC.app -ov -format UDZO WAMC.dmg` | Mount & copy to `/Applications` |

---

## 0. Parallel Execution Plan (default)

Run the Android and macOS tracks in **two parallel agents**. The tracks are
independent: Android touches `android/` + the ADB-attached device, macOS touches
`macos/.build` + `/Applications/WAMC.app` + codesigning. They share no build
state and must run concurrently, not sequentially.

### 0.1 Track ownership

| | Agent-Android | Agent-macOS |
| :--- | :--- | :--- |
| Sections | §1 Android env + §2 only | §1 macOS env + §3 + §4 + §5 |
| Owns paths | `android/`, `WAMC.apk`, ADB device | `macos/`, `/Applications/WAMC.app`, `WAMC.dmg` |
| Never touches | `/Applications/WAMC.app`, `macos/`, `WAMC.dmg` | `android/`, `WAMC.apk`, `adb` |
| Finishes with | §6.1 Android checks | §6.2 macOS checks + §6.3 DMG check |

DMG (§5) belongs to Agent-macOS and runs **after** its §4 build, never in parallel
with it and never in Agent-Android.

### 0.2 Concurrency rules (both agents must follow)

1. Use a **private shell** per agent. Never assume a shared working directory.
2. Run repo commands from the repo root with track-local paths, e.g.
   `(cd android && ./gradlew assembleDebug)` — never `cd android` in one step
   and `cd ..` in a later step and expect it to persist for the other agent.
3. Do not run the other track's clean/build/install commands, even to "help".
4. Root-level artifacts are namespaced: only Agent-Android writes `WAMC.apk`,
   only Agent-macOS writes `WAMC.dmg`. Never `git add` / commit the other's file.
5. `adb` is owned by Agent-Android. Agent-macOS must not run `adb forward`,
   `adb reverse`, or USB-config commands.
6. Each agent reports its own §6 track checks. The coordinator (not the agents)
   runs the §6 merge verification after **both** agents finish.

### 0.3 Agent start prompts

Coordinator: launch both prompts in the same parallel batch.

**Agent-Android prompt:**

```text
Follow AI_AGENT_GUIDE.md, Android track only (§1 Android env, §2.1 → §2.2 → §2.3).
Do not touch macOS paths (/Applications/WAMC.app, macos/, WAMC.dmg) or run
macOS sections (§3–§5). Use a private shell from the repo root. Finish by
running the §6.1 Android checks and reporting pass/fail per check.
```

**Agent-macOS prompt:**

```text
Follow AI_AGENT_GUIDE.md, macOS track only (§1 macOS env, §3.1 → §4 → §5).
Do not touch Android paths (android/, WAMC.apk) and do not run adb or §2.
Use a private shell from the repo root. Build the DMG (§5) only after your §4
install succeeds. Finish by running the §6.2 + §6.3 checks and reporting
pass/fail per check.
```

### 0.4 Merge

When both agents report done, the coordinator runs the §6 merge verification
(Android installed + running, Mac bundle present + running, DMG present). If one
track fails, keep the other track's result and retry only the failed track —
never re-run both.

---

## 1. Prerequisites & Environment Setup

### Android Environment
- **Java**: JDK 17 is required (Temurin/OpenJDK 17).
  ```bash
  export JAVA_HOME=$(/usr/libexec/java_home -v 17)
  ```
- **Android SDK**: `~/Library/Android/sdk` with platform tools (`adb`), build-tools 35, and target SDK 35.
- **Physical Device**: Device must have USB debugging enabled and be listed under `adb devices`.

### macOS Environment
- **Xcode Command Line Tools / Toolchain**: Swift 5.10+ / macOS 14.0+ SDK (`xcrun swift`, `xcrun swiftc`).
- **Codesigning Identity**:
  A valid Apple Development certificate is required for System Extension signing. Find it via:
  ```bash
  security find-identity -v -p codesigning
  # Active identity in this workspace:
  # "Apple Development: Arush Yadav (FJ696ZCQ56)"
  ```

---

## 2. Android Lifecycle

### 2.1 Complete Uninstall & Clean
Run these commands to terminate any running process, remove ADB port forwards, and uninstall the package:
```bash
# 1. Force stop the application
adb shell am force-stop com.androidwebcam.app || true

# 2. Clear any active ADB TCP port forwardings
adb forward --remove tcp:27183 2>/dev/null || true
adb forward --remove-all 2>/dev/null || true
adb reverse --remove-all 2>/dev/null || true

# 3. Uninstall the app package completely
adb uninstall com.androidwebcam.app

# 4. Clean Gradle build artifacts
cd android && ./gradlew clean && cd ..

# 5. Verify uninstallation (should output empty)
adb shell pm list packages | grep com.androidwebcam.app
```

### 2.2 Build APK
```bash
export JAVA_HOME=$(/usr/libexec/java_home -v 17)
cd android
./gradlew testDebugUnitTest assembleDebug
cd ..
# Output APK: android/app/build/outputs/apk/debug/app-debug.apk
# Root-level copy (optional): cp android/app/build/outputs/apk/debug/app-debug.apk WAMC.apk
```

### 2.3 Install & Launch on Device
Use the automated installation script:
```bash
./android/scripts/install_and_configure.sh
```

Or execute manually:
```bash
# 1. Install APK to attached device
adb install -r android/app/build/outputs/apk/debug/app-debug.apk

# 2. Configure USB mode to MTP (Transferring files / Android Auto)
adb shell svc usb setScreenUnlockedFunctions mtp || true
adb shell svc usb setFunctions mtp || true

# 3. Launch main activity
adb shell am start -n com.androidwebcam.app/.ui.MainActivity
```

---

## 3. macOS Lifecycle

### 3.1 Complete Uninstall & Clean (WAMC)
```bash
# 1. Terminate running WAMC process
pkill -x WAMC || true
sleep 1

# 2. Delete application bundle from /Applications
rm -rf /Applications/WAMC.app

# 3. Remove user preferences & caches
rm -f "$HOME/Library/Preferences/com.androidwebcam.app.plist"
rm -rf "$HOME/Library/Caches/com.androidwebcam.app"
rm -rf "$HOME/Library/Saved Application State/com.androidwebcam.app.savedState"

# 4. Remove crash & diagnostic reports
rm -f "$HOME"/Library/Logs/DiagnosticReports/WAMC*
rm -f "$HOME"/Library/Application\ Support/CrashReporter/WAMC*

# 5. Clean Swift build directory
rm -rf macos/.build

# 6. Verify removal
ls -ld /Applications/WAMC.app 2>&1
pgrep -il WAMC || echo "WAMC is not running"
```

### 3.2 Complete Uninstall & Clean (OBS Studio & Virtual Cam)
When cleaning OBS or resolving virtual camera conflicts:
```bash
# 1. Terminate OBS
pkill -f /Applications/OBS.app 2>/dev/null || true
sleep 1

# 2. Remove application bundle
rm -rf /Applications/OBS.app

# 3. Remove user configurations, profiles, and caches
bash -c 'shopt -s nullglob; rm -rf "$HOME/Library/Application Support/obs-studio" "$HOME"/Library/Preferences/com.obsproject* "$HOME"/Library/Saved\ Application\ State/com.obsproject* "$HOME"/Library/Caches/com.obsproject*'

# 4. Check system extension status
systemextensionsctl list
```
> [!NOTE]
> When `/Applications/OBS.app` is removed, macOS marks the `com.obsproject.obs-studio.mac-camera-extension` system extension as `[terminated waiting to uninstall on reboot]`. A system reboot finalizes the uninstallation.

---

## 4. macOS Build, Sign, and Install

### 4.1 Automated Build & Install (`build_and_install.sh`)
The recommended way to build, package into `/Applications/WAMC.app`, sign the extension, and launch is:
```bash
./macos/scripts/build_and_install.sh
```

### 4.2 Manual Step-by-Step Build & Codesign
If you need to execute each step individually:

```bash
cd macos

# Step 1: Build Swift host app in Release mode
xcrun swift build -c release

APP_DIR="/Applications/WAMC.app"
SYSEXT_DIR="$APP_DIR/Contents/Library/SystemExtensions/com.androidwebcam.app.CameraExtension.systemextension"

# Step 2: Prepare bundle structure
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$SYSEXT_DIR/Contents/MacOS"

# Step 3: Copy binary & Info.plist
cp ".build/release/WAMC" "$APP_DIR/Contents/MacOS/WAMC"
cp "WAMC-Info.plist" "$APP_DIR/Contents/Info.plist"

# Step 4: Compile CameraExtension
xcrun swiftc -target arm64-apple-macos14.0 -O \
    -framework Foundation -framework CoreMediaIO -framework CoreVideo \
    "CameraExtension/ExtensionMain.swift" \
    "CameraExtension/ProviderSource.swift" \
    "CameraExtension/DeviceSource.swift" \
    "CameraExtension/StreamSources.swift" \
    -o "$SYSEXT_DIR/Contents/MacOS/CameraExtension"

cp "CameraExtension/CameraExtension-Info.plist" "$SYSEXT_DIR/Contents/Info.plist"

# Step 5: Codesign with developer certificate
SIGN_IDENTITY="Apple Development: Arush Yadav (FJ696ZCQ56)"

codesign -s "$SIGN_IDENTITY" -f \
    --entitlements "CameraExtension/CameraExtension.entitlements" \
    --options runtime \
    "$SYSEXT_DIR"

codesign -s "$SIGN_IDENTITY" -f \
    --entitlements "WAMC.entitlements" \
    --options runtime \
    "$APP_DIR"

# Step 6: Validate signatures
codesign -vvv "$SYSEXT_DIR"
codesign -vvv "$APP_DIR"

# Step 7: Launch app
open -a "$APP_DIR"
```

---

## 5. Building & Installing macOS DMG

### 5.1 Create DMG from Built Application
Once `/Applications/WAMC.app` has been built and signed:
```bash
# Generate compressed UDZO DMG at project root
hdiutil create -volname "WAMC" -srcfolder "/Applications/WAMC.app" -ov -format UDZO WAMC.dmg
```

### 5.2 Install from DMG
To test or perform installation directly from the disk image:
```bash
# 1. Mount disk image without browsing
hdiutil attach -nobrowse WAMC.dmg

# 2. Copy application into /Applications (overwrites previous)
cp -R "/Volumes/WAMC/WAMC.app" /Applications/

# 3. Unmount disk image
hdiutil detach /Volumes/WAMC

# 4. Launch app
open -a /Applications/WAMC.app
```

---

## 6. Verification Checklist

Each agent runs its own track checks; the coordinator runs the merge check
after **both** agents finish.

### 6.1 Android checks (Agent-Android)

```bash
bash -c '
echo "=== Android Verification ==="
adb shell pm list packages | grep com.androidwebcam && echo "Android App: Installed" || echo "Android App: Not Installed"
adb shell pidof com.androidwebcam.app >/dev/null && echo "Android Process: Running" || echo "Android Process: Stopped"
'
```

### 6.2 macOS checks (Agent-macOS)

```bash
bash -c '
echo "=== macOS Verification ==="
[ -d "/Applications/WAMC.app" ] && echo "Mac App Bundle: Present (/Applications/WAMC.app)" || echo "Mac App Bundle: Not Present"
pgrep -il WAMC >/dev/null && echo "Mac Process: Running" || echo "Mac Process: Stopped"
'
```

### 6.3 DMG check (Agent-macOS, after §5)

```bash
bash -c '[ -f "WAMC.dmg" ] && echo "Mac DMG: Present ($(ls -lh WAMC.dmg | awk '\''{print $5}'\''))" || echo "Mac DMG: Not Present"'
```

### 6.4 Merge verification (coordinator, after both agents finish)

```bash
bash -c '
echo "=== Android Verification ==="
adb shell pm list packages | grep com.androidwebcam && echo "Android App: Installed" || echo "Android App: Not Installed"
adb shell pidof com.androidwebcam.app >/dev/null && echo "Android Process: Running" || echo "Android Process: Stopped"

echo "=== macOS Verification ==="
[ -d "/Applications/WAMC.app" ] && echo "Mac App Bundle: Present (/Applications/WAMC.app)" || echo "Mac App Bundle: Not Present"
pgrep -il WAMC >/dev/null && echo "Mac Process: Running" || echo "Mac Process: Stopped"
[ -f "WAMC.dmg" ] && echo "Mac DMG: Present ($(ls -lh WAMC.dmg | awk '\''{print $5}'\''))" || echo "Mac DMG: Not Present"
'
```

