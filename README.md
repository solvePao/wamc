# WAMC — Wired Android Mac Camera

Turns a Samsung Android phone into a wired Mac webcam (Zoom, Meet, Teams,
FaceTime, OBS). USB only, no internet. Implements `plan.md` in full:
Phase 1 streaming → Phase 2 virtual camera → Phase 3 AOA/UVC → Phase 4 polish.

**Test matrix for now: Samsung phones + macOS only** (verified device:
SM-E236B, Android 14). Decisions: [docs/DECISIONS.md](docs/DECISIONS.md).

## Layout

- `android/` — Kotlin app: Camera2 → MediaCodec H.264 → ADB-TCP / AOA (`Transport` interface)
- `macos/` — SwiftPM app: receiver → VideoToolbox → preview + menu bar; `CameraExtension/` holds the CoreMediaIO virtual-camera sources (Xcode target)
- `shared/protocol/PROTOCOL.md` — AWC1 wire format, golden-vector tested both sides
- `AI_AGENT_GUIDE.md` — Operations runbook for AI agents: clean, build APK, build macOS DMG, and install both sides

## Build and test

Android (JDK 17, SDK 35 — see `ANDROID_SETUP.md`):

```bash
cd android
export JAVA_HOME=$(/usr/libexec/java_home -v 17)
./gradlew testDebugUnitTest assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

macOS:

```bash
cd macos
xcrun swift test   # use Xcode's toolchain; the swiftly `swift` mismatches Xcode 27
xcrun swift build
.build/debug/WAMC
```

Virtual camera: follow `macos/CameraExtension/README.md` once in Xcode
(signing + system-extension approval required).

## Use

1. Plug the Samsung phone in by USB, open the Android app, tap **Start Streaming**.
2. On the Mac app: **Connect**, then **Start camera**. Pick Best (HEVC when negotiated, else max-rate AVC), 1080p high, or 720p balanced.
3. In your meeting app select **WAMC Camera** (after extension setup);
   until then, verify the feed in the Mac preview window.

Unplugging keeps the virtual camera registered on a placeholder slate;
reconnect resumes automatically (backoff 0.5s → 8s). Diagnostics (FPS,
bitrate, drops) show in the app window and menu bar. No audio by design.


muse resume 01a14af5-9330-7831-97c2-dc69ffca9917