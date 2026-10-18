# Virtual camera extension (Phase 2)

Registers **WAMC Camera** in macOS so Zoom, Meet, Teams, FaceTime and OBS
can select it. Requires macOS 12.3+ (project targets macOS 14), Xcode, and
an Apple Developer signing identity — a Camera Extension system extension
cannot be validated from `swift build` alone.

## One-time Xcode setup

1. Open `macos/Package.swift` in Xcode. Add a new target:
   File → New → Target → **Camera Extension** (name it `CameraExtension`),
   embedded in the app target so the app can install/activate it.
   Alternatively run `xcodegen generate` with `project.yml` in this folder.
2. Replace the template sources with the files in this folder
   (`ExtensionMain.swift`, `ProviderSource.swift`, `DeviceSource.swift`,
   `StreamSources.swift`). If the template generated its own main, keep the
   template main and delete `ExtensionMain.swift`.
3. Set the extension target's Info.plist to `CameraExtension-Info.plist`
   values (Mach service name = the extension bundle ID) and apply
   `CameraExtension.entitlements`. Sign app + extension with the same team.
4. Build and run the app once. Approve the system extension when macOS asks
   (System Settings → Privacy & Security), then quit/reopen the meeting app.

## How frames flow

`AndroidWebcamApp` decodes H.264/HEVC → `ExtensionBridge` enqueues CMSampleBuffers
into the extension's **sink** stream → `SinkStreamSource` stores the latest
pixel buffer → `SourceStreamSource` publishes it at 30 FPS (dark placeholder
while no phone is connected, so the camera never disappears mid-call).

## Samsung + Mac test checklist

- [ ] “WAMC Camera” appears in FaceTime camera menu and shows the phone feed.
- [ ] Same in Chrome (Google Meet), Zoom, and OBS.
- [ ] Unplug USB: meeting apps keep the camera, showing the placeholder.
- [ ] Replug: feed resumes without restarting the meeting app.
