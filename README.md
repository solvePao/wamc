# WAMC — Wired Android Mac Camera

Turns a Samsung Android phone into a Mac webcam (Zoom, Meet, Teams,
FaceTime, OBS) over USB or the same Wi-Fi network — no internet, no cloud.
Implements `plan.md` in full:
Phase 1 streaming → Phase 2 virtual camera → Phase 3 AOA/UVC → Phase 4 polish,
plus Wi-Fi auto-discovery (Bonjour) and a menu-bar background Mac app.

**Test matrix for now: Samsung phones + macOS only** (verified device:
SM-E236B, Android 14). Decisions: [docs/DECISIONS.md](docs/DECISIONS.md).

## Layout

- `android/` — Kotlin app: Camera2 → MediaCodec H.264 → socket / AOA (`Transport` interface); Bonjour (`NsdManager`, `_wamc._tcp`) advertiser for Wi-Fi discovery
- `macos/` — SwiftPM menu-bar agent app (`LSUIElement`, launch-at-login): Bonjour browser → receiver → VideoToolbox → preview + virtual camera; `CameraExtension/` holds the CoreMediaIO virtual-camera sources (Xcode target)
- `shared/protocol/PROTOCOL.md` — AWC1 wire format, golden-vector tested both sides
- `iterative-testing.md` — Build, signing, first-run setup, DMG validation, and live-camera test runbook

## Build and test

Android (JDK 17, SDK 35 — see `iterative-testing.md` for the full runbook):

```bash
cd android
export JAVA_HOME=$(/usr/libexec/java_home -v 17)
./gradlew testDebugUnitTest assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

macOS:

```bash
(cd macos && xcrun swift test) > /tmp/wamc-swift-tests.log 2>&1
./macos/scripts/build_and_install.sh > /tmp/wamc-build.log 2>&1
./macos/scripts/build_dmg.sh > /tmp/wamc-dmg.log 2>&1
```

Read the saved logs. The signed app requires a matching Mac development
profile; see [camera signing](macos/CameraExtension/README.md). A raw SwiftPM
executable is not an installed virtual-camera host.

The DMG contains an Applications shortcut and installation instructions.
The first launch shows **Setup & Diagnostics**, with **Install & Relaunch**
when needed, automatic extension activation, permission/settings links,
phone/USB/Wi-Fi checks, and optional recommended startup defaults. Enable
**WAMC → Android Camera** when macOS requests camera-extension approval.
The current DMG is a development build for registered Macs.

## Use

**Android dashboard:** All camera controls stay on one screen: camera and quality selectors, Enhance image, Auto-start, Wi-Fi discovery, and a pinned Start/Stop button. Switch camera and Rotate sit on the square preview, moving into the control group when space is tight. Landscape places the preview beside the controls; compact windows and large text can scroll the control area while Start/Stop remains visible. Quality changes apply the next time streaming starts.

**USB (preferred):**

1. Plug the Samsung phone in by USB and open the Android app — it starts streaming the front camera on its own (toggle **Auto-start** off to go manual).
2. On the Mac app: it connects on plug and starts the camera by itself. Pick Best (HEVC when negotiated, else max-rate AVC), 1080p high, or 720p balanced. **Stop** stays stopped until replug.

**Wi-Fi (automatic, no IP to type):**

1. Put the phone and Mac on the same Wi-Fi network. Open WAMC on the phone (keep **Wi-Fi discovery** on) — the phone advertises itself via Bonjour (`_wamc._tcp`) with a stable device ID.
2. The Mac finds it automatically in the menu bar / window. The first time, click **Trust & Connect** (Bonjour alone can be spoofed on a LAN, so an unknown device is never auto-connected). After that it auto-connects on sight. Plugging USB in takes over; unplugging falls back to trusted Wi-Fi.
3. If your router blocks discovery (AP isolation), use the manual address field in the window as a fallback.

**Mac background app:** After setup, WAMC runs in the menu bar with no Dock icon or window. It registers for launch-at-login by default (toggle **Launch at login** in Preferences in the menu/window; approve in System Settings → Login Items if asked). The menu bar shows connection and virtual-camera readiness, with Start/Stop and grouped camera, connection, preference, and troubleshooting controls. **Open WAMC** opens the preview window on demand, including live codec/FPS/bitrate diagnostics; closing it returns to background (the virtual camera keeps receiving frames).

**Preview window:** Open WAMC from the menu bar for a large camera preview with a compact control panel. Camera actions and quality are at the top; Connections contains USB and trusted Wi-Fi phones. Expand Manual address for a direct connection, Preferences for automatic behavior, and Diagnostics beneath the preview for stream details. Setup remains available from the toolbar and menu bar. The window follows macOS light/dark appearance, and closing it keeps virtual-camera delivery running. On macOS 26 and later, camera actions and expandable headers use Liquid Glass; macOS 14–15 use native materials and bordered controls. Start/Stop and camera-switch/rotate actions form two aligned rows. Click anywhere on an expandable header to open it with a short animation (or immediately with Reduce Motion). Disconnected previews detach and clear the last video image. Live statistics publish through a separate display-only store; quality and menu-bar controls also compare value snapshots so open menus keep tracking clicks.

In your meeting app select **Android Camera** (after extension setup).
Confirm moving video in FaceTime or Photo Booth; the Mac preview alone
only verifies phone transport and decoding.

Unplugging keeps the virtual camera registered on a placeholder slate;
reconnect resumes automatically (backoff 0.5s → 8s). Diagnostics (FPS,
bitrate, drops) show in the app window and menu bar. No audio by design.

## Releases and updates

GitHub-only signed APK and notarized Apple silicon DMG releases are built together. See [release setup](docs/RELEASING.md) for credentials, versioning, release workflows, and bootstrap installation. Both apps check once per launch and ask before downloading; installation waits until streaming stops.
