# Virtual camera extension (Phase 2)

Registers **Android Camera** (provided by WAMC) in macOS so Zoom, Meet, Teams, FaceTime and OBS
can select it. Requires macOS 12.3+ (project targets macOS 14), Xcode, and
an Apple Developer signing identity — a Camera Extension system extension
cannot be validated from `swift build` alone.

## Build and signing

Run `./macos/scripts/build_and_install.sh` from the repository root. It checks
provisioning before changing the installed app, stages the complete bundle,
signs both components, then installs and launches `/Applications/WAMC.app`.

The host requires `com.apple.developer.system-extension.install` **and a Mac
development provisioning profile authorizing that entitlement** for
`com.androidwebcam.app`. A successful `codesign` verification alone does not
prove that macOS will allow the app to launch. Create the profile using Xcode
automatic signing with the System Extensions capability, or download it from
the Apple Developer account. The build script finds matching profiles in
Xcode's profile folders; `WAMC_PROVISIONING_PROFILE` can specify another path.
Profiles remain local and must not be committed.

The current certificate is `Apple Development: Arush Yadav (FJ696ZCQ56)`;
its actual **Team ID is `HU27CJ3DK6`**, as recorded in the certificate's OU
and the signature's TeamIdentifier. The parenthesized certificate suffix is
not the Team ID. Both the extension's application group and its Mach service
must use the real Team ID. `SIGN_IDENTITY` and `DEVELOPMENT_TEAM` can override
the build defaults together.

After the first installation, enable **WAMC → Android Camera** in System
Settings → General → Login Items & Extensions → Camera Extensions. Select
**Android Camera** in FaceTime's Video menu and Photo Booth's Camera menu.
OBS Virtual Camera's crossed-out logo means that OBS is selected.

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

All buffers crossing the extension boundary, including normalized portrait
frames and the waiting placeholder, must have IOSurface backing. Source
sample timestamps and `hostTimeInNanoseconds` use the host clock advertised
by the stream. Frame-duration properties use CMTime dictionaries, not boxed
Swift structs. The host reconnects when an extension replacement leaves its
old sink queue full for more than a second.

## Samsung + Mac test checklist

- [x] “Android Camera” appears in FaceTime and Photo Booth and shows the phone feed (2026-10-18, SM-E236B over USB).
- [ ] Same in Chrome (Google Meet), Zoom, and OBS.
- [ ] Unplug USB: meeting apps keep the camera, showing the placeholder.
- [ ] Replug: feed resumes without restarting the meeting app.
