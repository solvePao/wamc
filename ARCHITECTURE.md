# WAMC Architecture — Wired Android Mac Camera

Turns a Samsung Android phone into a wired Mac webcam over USB (no internet,
no audio). This file is split in two self-contained halves: **Part A (macOS)**
and **Part B (Android)**. The only shared contract is the **AWC1 wire
protocol** (`shared/protocol/PROTOCOL.md`), described once in §0.

System context:

```text
[Samsung phone: Android app] --USB--> [Mac: WAMC app] --> [WAMC Camera virtual cam]
   Camera2 -> MediaCodec            adb forward TCP        CoreMediaIO sys-ext
   AWC1 encode                   127.0.0.1:27183           sink + source streams
   (ADB transport,                     |                   meeting apps read
    AOA behind same iface)      VideoToolbox decode        source @30fps
                                SwiftUI preview
```

Test matrix: Samsung phones + owner's Mac only (verified SM-E236B, Android 14).
See `docs/DECISIONS.md`. Quality ceilings: `docs/QUALITY.md`. AOA/UVC status:
`docs/ACCESSORY.md`. Ops runbook: `iterative-testing.md`.

## 0. Shared contract — AWC1 (both sides implement it)

Spec: `shared/protocol/PROTOCOL.md`. One framing for every transport
(ADB-forwarded TCP and AOA bulk). All integers big-endian.

- Frame: 20-byte header (`AWC1` magic + type + flags + reserved + `ptsUs`
  int64 + payload length uint32, max 8 MiB) + payload.
- Types: `1`=VIDEO (one Annex-B access unit, no B-frames), `2`=CONFIG (v1:
  `spsLen+sps+ppsLen+pps+width+height+fps+rotation`), `3`=CONTROL,
  `4`=HELLO, `5`=CONFIG2 (v2: `codec+count+(len+bytes)*+width+height+fps+
  rotation`; AVC carries sps,pps; HEVC carries vps,sps,pps in order).
- CONTROL/HELLO payloads are UTF-8 `key=value;...`: `cmd=start`
  (`quality/codec/bitrate/gop/codecs/configV2/...`), `cmd=requestKeyframe`,
  `cmd=stop`, `cmd=ping`, `cmd=hello;codecs=avc,hevc;configV2=1` (capability
  announcement, never starts streaming), phone HELLO
  (`model/brand/sdk/cameras/uvc/codecs/configV2`).
- Rules: latest-wins queues (cap ~2 frames; never silently drop CONFIG or
  keyframes); receiver sends `requestKeyframe` after decode errors or
  (re)connects; unknown types skipped via length; bad magic resyncs by
  scanning for next `AWC1`.
- Golden vector (asserted in Kotlin + Swift tests): VIDEO keyframe pts=1000
  payload `00 00 00 01 65 88` →
  `41574331 01 01 0000 00000000000003e8 00000006 000000016588`.
- Rotation encoding: quarter-turns clockwise 0–3, carrying the total
  orientation (sensor/display/facing compensation + manual taps). `0`
  means frames arrive upright — via HAL rotate-and-crop or an already-zero
  total; otherwise the Mac renders the total.

# Part A — macOS (`macos/`)

SwiftPM package (`macos/Package.swift`, tools 5.9, macOS 14+): three targets
plus an Xcode-only system extension that SwiftPM never builds.

| Module | Sources | Role |
|---|---|---|
| `AndroidWebcamProtocol` | `Sources/AndroidWebcamProtocol/WireProtocol.swift` | AWC1 encode/decode + incremental `FrameParser` (resync on bad magic) |
| `AndroidWebcamCore` | `Sources/AndroidWebcamCore/FrameQueue.swift`, `FrameRotation.swift`, `H264.swift`, `AutoStartPolicy.swift` | Latest-wins queue, reconnect backoff, stats; CoreImage rotation; Annex-B to AVCC + NAL-type helpers; pure auto-connect/start state machine |
| `AndroidWebcamApp` (executable `WAMC`) | `Sources/AndroidWebcamApp/*.swift` | Receiver to decode to preview + virtual-cam bridge + UI |
| `CameraExtension` (Xcode sys-ext, NOT a SwiftPM target) | `CameraExtension/ExtensionMain.swift`, `ProviderSource.swift`, `DeviceSource.swift`, `StreamSources.swift` + `project.yml`, Info.plist, entitlements | CoreMediaIO "WAMC Camera": sink (ingest) + source (publish at 30fps, placeholder when unplugged) |

## A.1 Runtime data flow

```text
adb forward tcp:27183 --TCP--> USBReceiver --AWC1 frames--> AppModel --annexB--> H264Decoder
   (DeviceDiscovery)   (NWConnection,       (CONFIG dedup,  (VideoToolbox
    port 27183)         auto-reconnect)      stats, 60Hz     VTDecompressionSession,
                                            pump)           AVC+HEVC, Annex-B to AVCC)
                                                                              |
                                                              LatestFrameQueue (cap 2, drop-oldest)
                                                                              |
                                              +-------------------------------+------------------+
                                              |                                                  |
                                     PreviewRenderer                                ExtensionBridge
                              (AVSampleBufferDisplayLayer,                    (CMIO sink stream
                               SwiftUI PreviewView)                            buffer queue; no-op
                                                                              until ext approved)
                                                                              |
                                                              CameraExtension.SinkStreamSource
                                                              -> SharedFrame ->
                                                              SourceStreamSource -> Zoom/Meet/Teams
```

Key classes and behaviors:

- `USBReceiver.swift` — `NWConnection` TCP client to `127.0.0.1:27183`;
  `FrameParser.feed` to `dispatch` to `onVideo/onConfig/onConfigV2/onHello/
  onConnectionChange`; `sendControl` for `hello/requestKeyframe/start/stop/
  setFacing/rotate`. Reconnect via `ReconnectPolicy` (0.5s doubling, 8s cap).
  AOA arrives on the same socket path once host-side negotiation presents it.
- `H264Decoder.swift` — `configure(with:)` (AVC sps/pps) and
  `configure(withV2:)` (AVC/HEVC param sets) build `CMVideoFormatDescription`
  then a real-time `VTDecompressionSession` (BGRA output). `decode(annexB:
  ptsUs:isKeyframe:)` drops non-keyframes until the next keyframe after an
  error; any failure sets `needsKeyframe` and fires `onError`.
- `AppModel.swift` (`@MainActor`, `ObservableObject`) — owns receiver,
  decoder, `LatestFrameQueue`, `ExtensionBridge`, `PreviewRenderer`,
  `CameraExtensionManager`, `AutoStartPolicy`, 60Hz display timer + 2.5s
  plug watchdog. `facingBack` defaults `false` (mirrors the phone's front
  default); `autoConnect`/`autoStart` persist via `UserDefaults`, default
  ON, switched by the "Auto-connect on plug" / "Auto-start camera" toggles.
  On connect sends `cmd=hello
  (codecs=avc,hevc;configV2=1)` + `requestKeyframe`, then `sendStart` when
  `shouldAutoStart`; `sendStart` sends `cmd=start` with
  quality/width/height/fps/codec-auto; CONFIG dedup by `WxH@fps:rotation`
  string; rotation non-zero goes through `FrameRotation.rotate`, rotation 0
  forwards untouched (fast path). The display pump wraps once via
  `makeImageSampleBuffer` and shares the sample with renderer and bridge.
  `pollDevices` auto-connects on arrival (`shouldConnect`) and clears the
  Stop latch on serial swap; `sendStart`/`sendStop`/`disconnect` update the
  latch (`didSendStart`/`didSendStop`/`manualDisconnect`), while a transient
  drop only resets `streamCommanded` so reconnect re-asks. Decode errors
  increment `stats.decodeErrors` and request a keyframe.
- `PreviewAndBridge.swift` — `PreviewRenderer` and `ExtensionBridge`
  both take an already-wrapped `CMSampleBuffer` (caller wraps once per
  frame and shares it). Renderer: display layer, flush on `.failed`.
  Bridge: discovers CMIO sink stream by name, copies its `CMSimpleQueue`,
  enqueues samples, re-discovers every 2s while unavailable.
  `PlaceholderFrame` (dark 1920x1080 slate).
- `DeviceDiscovery.swift` — shells out to
  `~/Library/Android/sdk/platform-tools/adb`: `devices -l` parse,
  `forward tcp:27183`, `forward --remove`, `svc usb setFunctions mtp`
  default-mode config; `nativeUVCWebcams()` via AVFoundation `.external`
  discovery (Android 14+ firmware webcam mode needs no app).
- `CameraExtensionManager.swift` — `OSSystemExtensionRequest`
  activate/deactivate for `com.androidwebcam.app.CameraExtension`; statuses
  unknown/notInstalled/requiresApproval/active/failed.
- `AndroidWebcamApp.swift` — SwiftUI `WAMCApp`: main window (connection dot,
  preview, status, diagnostics `codec - FPS - Mbps`, quality picker
  Best/1080p-high/720p-balanced, Connect/Start/Stop/switch-camera/Rotate/
  Refresh, auto-connect/auto-start toggles, virtual-cam status) + `MenuBarExtra` with the same controls.
- Core: `LatestFrameQueue` (cap 2, `dequeueLatest` drops all but newest),
  `StreamStats` (rolling FPS, Mbps since connect), `FrameRotation`
  (CoreImage centre-rotate + translate, swaps axes on odd turns),
  `H264.annexBToAVCC` + `isSyncAccessUnit` (AVC IDR=5; HEVC 19/20/21).

## A.2 Virtual camera (`CameraExtension/`, Xcode only)

One-time Xcode setup per `CameraExtension/README.md`: open `Package.swift` in
Xcode, add a Camera Extension target, swap in these four files, apply
`CameraExtension-Info.plist` + `CameraExtension.entitlements`, sign app and
extension with the same team, approve in System Settings.

- `ExtensionMain.swift` — `@main`, starts `CMIOExtensionProvider`, runs the
  runloop.
- `ProviderSource.swift` — provider "Android Camera Provider" + one device
  ("Android Camera", fixed UUID) with `SharedFrame` (NSLock-guarded latest
  `CVPixelBuffer`) shared between streams.
- `DeviceSource.swift` — two streams: source "Android Camera Video" +
  sink "Android Camera Sink" (fixed UUIDs, host-time clock).
- `StreamSources.swift` — `SourceStreamSource` publishes at 30fps
  (`DispatchSourceTimer` 33ms): latest sink frame or cached dark
  placeholder, so the camera never disappears mid-call on unplug;
  `SinkStreamSource` consumes app sample buffers into `SharedFrame`
  (queue size 30, 1 buffer for startup). Format: 1920x1080 BGRA.

## A.3 Build, install, verify

- Automated: `./macos/scripts/build_and_install.sh` — `xcrun swift build
  -c release`, stage `/Applications/WAMC.app` (binary + `WAMC-Info.plist`),
  compile the extension with `xcrun swiftc -target arm64-apple-macos14.0`
  (Foundation/CoreMediaIO/CoreVideo), copy extension Info.plist, `codesign`
  both with `Apple Development: Arush Yadav (FJ696ZCQ56)` + per-target
  entitlements (`WAMC.entitlements` = camera device; extension = app-sandbox
  + app-group), validate, `open` the app. DMG:
  `hdiutil create -volname WAMC -srcfolder /Applications/WAMC.app -ov
  -format UDZO WAMC.dmg`.
- Manual SwiftPM: `cd macos && xcrun swift test` (19 tests) then
  `xcrun swift build` and run `.build/debug/WAMC`. Note: use Xcode's
  toolchain (`xcrun`); a separately installed `swift` may mismatch Xcode 27.
- Tests: `Tests/AndroidWebcamTests/WireProtocolTests.swift` (framing,
  CONFIG/CONFIG2 round-trips, golden vector) and `CoreTests.swift`
  (Annex-B/AVCC, rotation, queue, backoff, stats, `AutoStartPolicyTests`
  plug/latch/reconnect table).

---

# Part B — Android (`android/`)

Kotlin app (`namespace com.androidwebcam.app`, `compileSdk/targetSdk 35`,
`minSdk 26`, Java/Kotlin 17, no third-party deps — only `junit` for tests).
Package `com.androidwebcam.app`; launcher `ui.MainActivity`, streaming in a
camera-type foreground service.

| Package | Files | Role |
|---|---|---|
| `camera` | `CameraStreamingService.kt`, `CameraController.kt`, `VideoEncoder.kt`, `CodecConfig.kt`, `StreamProfile.kt`, `CameraInfo.kt`, `CameraOrientation.kt` | Capture + encode + quality/rotation policy + sensor/display orientation math |
| `transport` | `Transport.kt` (`Transport` + `TransportHub`), `AdbSocketTransport.kt`, `UsbAccessoryTransport.kt`, `NativeUvcSupport.kt` | AWC1 fan-out over ADB-TCP / AOA; UVC guidance text |
| `protocol` | `protocol/WireProtocol.kt` | AWC1 framing, CONFIG/CONFIG2, CONTROL/HELLO codecs |
| `ui` | `ui/MainActivity.kt`, `ui/SquareTextureView.kt`, `res/layout/activity_main.xml` (+land), drawables, `values/strings.xml` | Dark-theme UI, square preview, quality/camera/rotate controls |
| `util` | `util/UsbConfigHelper.kt` | Dev-options/root USB-mode setup card prefs |
| manifest | `src/main/AndroidManifest.xml`, `res/xml/accessory_filter.xml` | Permissions, foreground-service type, AOA intent filter |

## B.1 Runtime data flow

```text
MainActivity --bind--> CameraStreamingService (foreground, notification)
   Start(1920x1080/BEST)   restartPipelineUnsafe:
   preview Surface      CameraController.open(preview, encoderSurface, w, h, halRotateMode)
                           Camera2 TEMPLATE_RECORD (AF continuous-video, AE on,
                            edge/noise per EnhancementModes, optional SCALER_ROTATE_AND_CROP)
                                |
                         VideoEncoder (MediaCodec AVC/HEVC, input Surface)
                          csd/CODEC_CONFIG -> CodecConfig.splitAnnexB/orderParamSets
                                |-> onConfigSets -> CONFIG2 (+legacy CONFIG on AVC)
                                |-> onFrame (Annex-B AU, key flag, pts)
                                v
                         TransportHub --latest-wins--> AdbSocketTransport (:27183) + UsbAccessoryTransport
                                ^  HELLO + CONFIG resend + requestKeyframe on peer attach
                                |  CONTROL in: hello/start/stop/requestKeyframe/setFacing/setCamera/rotate/ping
```

Key classes and behaviors:

- `CameraStreamingService.kt` — foreground service, sticky idle listener
  (`onStartCommand` → `START_STICKY` + `showIdleNotification`; idle claims
  no camera service type, streaming upgrades to type `camera` on API 34+).
  Owns `CameraController?`, `VideoEncoder?`, `TransportHub`, both
  transports; `stopStreaming` falls back to the idle notification instead of
  leaving the foreground. `currentCameraId` resolves via
  `DefaultCamera.pickId` (saved → front → main back → first).
  `restartPipeline` order is load-bearing: `closeCapture()` before
  `encoder.stop()` so the camera never targets a released surface (kills
  HAL buffer-error storms). Rotation goes through `rotationSetup()`:
  `CameraOrientation.totalTurns` (sensor/display/facing + manual taps) fed
  to `RotationPlanner`; the HAL mode (if any) opens the camera while
  `macRotation` travels in CONFIG(2) and `previewTurns` drives the preview.
  Sends CONFIG2 first then legacy CONFIG on AVC (dedup by
  sets+size+rotation+codec); `handleControl` implements negotiation:
  `hello` restarts only if the picked codec would actually change; `start`
  applies quality/codec/bitrate/gop/peer-codecs then `startStreaming`;
  camera-thread exceptions are caught and surfaced as status, never process
  death. Prefs: camera id, enhance flag, quality.
- `CameraController.kt` — Camera2 on a dedicated `camera` HandlerThread.
  Default via `DefaultCamera.pickId` (saved → front → main back → first).
  `chooseSize` =
  largest MediaCodec output size fitting the request (else 1280x720).
  `rotateAndCropModes` queries `SCALER_AVAILABLE_ROTATE_AND_CROP_MODES`
  (API 33+). `configureSession`: preview + encoder surfaces, AF/AE,
  edge/noise modes, optional `SCALER_ROTATE_AND_CROP`. `closeCapture` stops
  session+device; `close` also quits the thread.
- `VideoEncoder.kt` — `MediaCodec` hardware encoder fed by Camera2 input
  Surface (zero-copy). `MediaFormat`: surface color, bitrate, fps,
  I-frame interval, bitrate mode, `max-bframes=0`, latency 0. Callbacks:
  `BUFFER_FLAG_CODEC_CONFIG` buffers and `onOutputFormatChanged` csd-0/1/2
  go through `CodecConfig` (never forwarded as video); frames forward with
  key flag + pts. Legacy constructor keeps the old 6 Mbps CBR AVC path.
- `StreamProfile.kt` — `StreamQuality` BEST/HIGH/BALANCED;
  `QualitySelector.profileFor`: BEST 30 Mbps HEVC / 25 Mbps AVC VBR,
  HIGH 12 Mbps VBR, BALANCED 8 Mbps VBR, all GOP 2s, with bitrate/gop
  overrides. `pickCodec`: explicit `hevc/avc` wins if the phone has it;
  legacy/unknown peers stay AVC; else HEVC iff both sides list it.
  `RotationPlanner.plan`: HAL mode when supported (CONFIG rotation 0),
  else metadata rotation (CONFIG echoes turns). `EncoderCaps` probes
  `MediaCodecList` for AVC/HEVC (device-only, never in unit tests).
- `CodecConfig.kt` — pure Annex-B split + NAL-type reads (AVC 5-bit,
  HEVC 6-bit) + ordering (AVC sps=7/pps=8; HEVC vps=32/sps=33/pps=34).
- `CameraInfo.kt` — `CameraClassifier` maps Camera2 characteristics to
  MAIN/ULTRA_WIDE/TELEPHOTO/FRONT/EXTERNAL via 35mm-equivalent focal length
  (fallback: focal-length spread, else id "0" = MAIN); display names feed
  the camera spinner. `DefaultCamera.pickId` (same file): saved choice
  wins, else front, then main back, then anything — pure data in/out.
- `CameraOrientation.kt` — pure sensor/display math, no Android APIs:
  `totalTurns(sensorDeg, deviceDeg, facingFront, userTurns)`; back =
  (sensor−device), front = (sensor+device), plus taps, mod 360 → quarter
  turns. Mirroring intentionally excluded (stream stays true-to-sensor).
- `Transport.kt` — `Transport` iface (`name/start/close`); `TransportHub`
  fans out to all peers: per-peer queue cap 3, non-video bypasses the cap,
  video evicts oldest but re-queues dropped CONFIG/keyframes. Reader thread
  decodes CONTROL frames; writer thread per peer; `peerCount` drives the
  "waiting for Mac" status.
- `AdbSocketTransport.kt` — `ServerSocket(27183)` accept loop
  (`tcpNoDelay`), each socket attached to the hub. This is the tested
  default path (needs USB debugging + `adb forward`).
- `UsbAccessoryTransport.kt` — AOA bulk streams via
  `UsbManager.openAccessory` (needs host-side GET_PROTOCOL/SET_STRING/START
  first — Mac helper still pending, see `docs/ACCESSORY.md`); `start`
  attaches only if permission already granted; `connectAccessory` re-runs it
  on `USB_ACCESSORY_ATTACHED`.
- `NativeUvcSupport.kt` — guidance strings only: an app cannot enable UVC
  gadget mode; on Android 14+ firmware it is a phone USB-menu option the Mac
  sees via AVFoundation with no app.
- `MainActivity.kt` — `startForegroundService` (sticky listener survives
  the activity) + binds the service; square `SquareTextureView` preview
  (Matrix rotation is cosmetic only — the stream keeps sensor order +
  CONFIG rotation, preview follows `previewTurns()`). Auto-start switch
  (persisted `auto_start`, default ON) + `maybeAutoStart` on connect,
  permission grant, and re-enable; `startStreamingFromUi` is the shared tap
  path (spinner → BEST/HIGH/BALANCED → `startStreaming`). Start/Stop
  (camera permission gated), switch-camera, rotate, enhance toggle, camera
  spinner, USB-setup card (`UsbConfigHelper`: root `svc usb` attempt, else
  deep-links to dev options / about phone, dismissible). Reacts to
  `USB_ACCESSORY_ATTACHED` by calling `connectAccessory`.
- Manifest: CAMERA + FOREGROUND_SERVICE(_CAMERA) + POST_NOTIFICATIONS +
  INTERNET; `foregroundServiceType="camera"`; AOA intent filter + metadata
  `@xml/accessory_filter` (`manufacturer=WAMC model="Wired Android Mac
  Camera" version=1.0`); `configChanges=orientation|screenSize` with
  portrait/landscape layouts kept in parity (`LayoutParityTest`).

## B.2 Build, install, verify

- Prereqs: JDK 17 (`export JAVA_HOME=$(/usr/libexec/java_home -v 17)`),
  SDK 35 + platform-tools, phone with USB debugging in `adb devices`.
- `./gradlew testDebugUnitTest assembleDebug` (48 unit tests), then
  `./android/scripts/install_and_configure.sh` (`installDebug`, `svc usb`
  MTP defaults, launch `com.androidwebcam.app/.ui.MainActivity`) or manual
  `adb install -r app/build/outputs/apk/debug/app-debug.apk`.
- Tests (`app/src/test/...`): `WireProtocolTest` (framing, CONFIG/CONFIG2,
  golden vector), `QualitySelectorTest`, `CameraClassificationTest`,
  `EnhancementModeTest`, `NativeUvcSupportTest`, `UsbConfigHelperTest`,
  `LayoutParityTest`, `OrientationTest` (`CameraOrientationTest` rule table
  + `DefaultCameraTest` pick order).

---

## Cross-cutting notes

- Codec negotiation: Mac announces `cmd=hello;codecs=avc,hevc;configV2=1` on
  every connect; phone picks via `QualitySelector.pickCodec` and describes
  the stream in CONFIG2; legacy Mac builds ignore type 5 and use CONFIG.
- Rotation placement: `CameraOrientation.totalTurns` (sensor ± display +
  manual taps) feeds `RotationPlanner`; HAL `SCALER_ROTATE_AND_CROP` when
  the camera supports it (CONFIG rotation 0, Mac fast path), else the total
  travels in CONFIG(2) and `FrameRotation` renders it on the Mac. Measured:
  SM-E236B test camera lacks HAL rotate-and-crop, so rotation travels as
  metadata (`docs/QUALITY.md`).
- Auto flow: Android sticky idle-listener service + `maybeAutoStart`
  (switchable); Mac 2.5 s plug watchdog + `AutoStartPolicy` Stop-latch;
  front camera default on both sides; explicit Stop/Disconnect pauses auto
  until replug or manual Start/Connect (`docs/DECISIONS.md` 11–12).
- Latency over backlog everywhere: encoder `max-bframes=0`/latency 0, hub
  queues cap 3, Mac queue cap 2, GOP 2s, `requestKeyframe` recovery.
- Out of scope by design: audio (`docs/DECISIONS.md` #6), 60fps/4K + other
  OEMs (open for later), Mac AOA host helper (pending validation —
  ADB transport is the supported path).
- Repo map (non-source, for orientation): `WAMC.apk` / `WAMC.dmg` are built
  artifacts at root; `error-mac.log` is a past diagnostic capture;
  `macos/.build/` is SwiftPM output; `shared/` holds only the protocol spec.

---
