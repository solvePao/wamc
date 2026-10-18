# Video quality — measured ceiling and modes (SM-E236B, Android 14)

Probed 2026-10-18 via `adb shell dumpsys media.player` on the connected
SM-E236B (`RZCT40TFK9D`). This is the evidence behind the quality-first
defaults; re-probe on other phones before raising ceilings.

## Encoder ceiling (hardware, Qualcomm)

| Encoder | Bitrate range | Size range | 1080p measured fps | Perf points | Bitrate modes |
| --- | --- | --- | --- | --- | --- |
| OMX.qcom.video.encoder.avc | 1–100 Mbps | 128×128–4096×2176 | 35–76 | 1080p120, 4K30, 4096×2304@24 | (default path) |
| OMX.qcom.video.encoder.hevc | 1–100 Mbps | (same class) | 31–67 | 1080p120, 4K30 | VBR, CBR |
| OMX.qcom.video.encoder.hevc.cq | — | — | — | 512×512 class | CQ |
| c2.android.hevc.encoder | 1–10 Mbps | — | — | — | VBR, CBR, CQ |

Frame-rate range for both HW encoders: 1–240 fps.

## Modes shipped

| Mode | Codec | Bitrate | GOP | Notes |
| --- | --- | --- | --- | --- |
| Best · auto (default) | HEVC if phone + Mac both announce it, else AVC | 30 Mbps HEVC / 25 Mbps AVC, VBR | 2 s | Near-transparency at 1080p30; ~4–5× the old 6 Mbps CBR |
| 1080p · high | negotiated codec | 12 Mbps VBR | 2 s | 2× the old clamp |
| 720p · balanced | negotiated codec | 8 Mbps VBR | 2 s | Old 6 Mbps CBR path retired; kept as explicit overrides via CONTROL |

No B-frames and zero-latency flags stay on in every mode (latency over
backlog). The transport keeps latest-wins queues (cap 3 per USB peer,
cap 1 per Wi-Fi peer, CONFIG and keyframes never silently dropped) and
`requestKeyframe` recovery.

## Wi-Fi low-latency profile

Wi-Fi starts (`transport=wifi;latency=low` from the Mac) keep the same
resolution, fps, and negotiated codec, with bitrate scaled to 75% of the
USB tier and GOP shortened from 2 s to 1 s:

| Mode | USB bitrate | Wi-Fi low-latency bitrate | GOP (USB → Wi-Fi) |
| --- | --- | --- | --- |
| Best · HEVC | 30 Mbps | 22.5 Mbps | 2 s → 1 s |
| Best · AVC | 25 Mbps | 18.75 Mbps | 2 s → 1 s |
| High | 12 Mbps | 9 Mbps | 2 s → 1 s |
| Balanced | 8 Mbps | 6 Mbps | 2 s → 1 s |

Supporting changes: the encoder requests realtime priority/operating
rate on the Wi-Fi path (`KEY_PRIORITY=0`, `KEY_OPERATING_RATE=fps`,
best-effort hints; output format is logged), HAL edge/noise prefers
`FAST` over `HIGH_QUALITY` on Wi-Fi, Wi-Fi peers get a queue cap of 1
and a 128 KB send buffer (loopback/USB peers are unchanged), both
sockets run with TCP no-delay, the Mac feeds the virtual-camera bridge
immediately on decode instead of waiting for its 60 Hz pump, and the
extension sink re-arms in 1 ms instead of 10 ms.

Latency instrumentation: the phone hub logs offered/dropped/written
plus queue-wait and write ms per peer; the Mac reports
arrival→decode→bridge processing p50/p95 (`StreamStats`) in its
diagnostics (`proc p95 … ms`). A reusable capture probe for the network
leg (frame sizes, keyframe sizes, inter-arrival jitter over Wi-Fi) is
kept out of tree at `/tmp/wifi_capture.py` — run it against the phone's
Wi-Fi address for 30 s windows before/after profile changes.

### Measured 2026-10-18, Wi-Fi latency A/B (SM-E236B, same SSID)

Back-to-back 30 s captures with `/tmp/wifi_capture.py` (AWC1 over the
phone's Wi-Fi address; USB leg via `adb forward` to the same listener),
two runs each for the Wi-Fi rows, phone hub logs alongside:

| Leg | Bitrate | FPS | Frame KB avg / p95 | Keyframe KB avg | Arrival p95 | Gaps >66 ms |
| --- | --- | --- | --- | --- | --- | --- |
| USB (100% profile) | 29.7 Mbps | 29.7 | 122 / 166 | 281 | 50 ms | 1 |
| Wi-Fi 100% (30 Mbps, GOP 2) | 28.7 Mbps | 29.2 | 120 / 171 | 288 | 99 ms | ~60 |
| Wi-Fi 75% (22.5 Mbps, GOP 1) | 21.6 Mbps | 29.4 | 90 / 99 | 210 | 97 ms | ~60 |

Findings:

- The profile does exactly what it says: bitrate −25%, average frame
  −25%, frame p95 −42%, keyframe average −27%, keyframes doubled
  (GOP 1), fps unchanged. Phone pipeline log confirms
  `22Mbps gop=1s latency=wifi-low` and the encoder output format
  reports `bitrate=22500000`.
- Phone-side queueing is not the bottleneck: hub logs show
  `qWaitLast 0–1 ms`, `writeLast 0–3 ms` (one 66 ms write stall in a
  100% run), drops ≈1–2%, on both Wi-Fi profiles.
- The ≥30% arrival-latency target is **not met**: Wi-Fi inter-arrival
  p95 stays ≈97–99 ms at both bitrates (vs 50 ms on USB with the same
  encoder), with a steady ~2 stalls/sec >66 ms either way. The stalls
  are bitrate-independent and keyframe-independent (GOP 1 doubled the
  keyframes, stall count did not move), which points at Wi-Fi
  link-layer burstiness (power-save/aggregation on this network), not
  at frame size, encoder, or socket queues.
- Mac `proc p95` (arrival→decode→bridge) is instrumented and shown in
  the app's diagnostics, but was not read out in this run: the agent
  window is closed by design in the background and programmatic UI
  access is denied on this machine, so that leg remains
  owner-readable in the menu bar rather than captured here.

Decision (Step 6 gate): the 720p fallback stays **off**. The data says
smaller frames are not what is stalling, so spending resolution would
buy little; the next real lever for the remaining ≈50 ms Wi-Fi arrival
penalty is link behaviour (e.g. a trialled `WIFI_MODE_FULL_LOW_LATENCY`
lock, or a different network), which needs its own decision. The 75%
profile is kept: it cuts airtime and burst size by a quarter at the
agreed quality budget with no fps or stall regression.

## Why not uncompressed

Raw 1080p30 is ~750 Mbps (YUV420) to ~2 Gbps (BGRA) before framing —
far above reliable `adb forward` TCP throughput — and it would break the
zero-copy Camera2 → encoder-surface path. VBR at the ceilings above is
the practical "no visible compression" point.

## Rotation placement

- `CameraOrientation.totalTurns` supplies clockwise stream compensation:
  back = sensor−display, front = sensor+display, plus manual Rotate taps.
  `StreamOrientation` records camera ID, pipeline generation, HAL mode,
  stream turns, and the separate preview transform.
- `TextureView` already compensates for sensor orientation and mirrors the
  front camera. Its matrix applies −display + manual turns, minus the HAL
  rotation as seen in that preview (reversed by front-camera mirroring).
  The orientation label describes the total, not that residual matrix angle.
- HAL `SCALER_ROTATE_AND_CROP` is queried from API 31. Supported physical
  rotation leaves CONFIG(2) rotation 0; metadata rotation explicitly requests
  HAL NONE when available. Rejected physical rotation rebuilds using metadata.
  If NONE is ignored, capture stops with a visible error rather than publishing
  incorrectly described pixels. HAL rotation can tighten framing through cropping.
- Display events retain a trailing update within 500 ms. Manual Rotate applies
  immediately. Both update preview state and CONFIG together; HAL-mode changes
  rebuild capture. All control/encoder callbacks run on the service's main thread,
  and obsolete encoder generations cannot publish CONFIG or VIDEO.
- The Mac binds connection/configuration identity and rotation to each decoder
  session. It rejects delayed output/status from replaced configurations, rotates
  accepted pixels once, and shares them with preview and virtual-camera output.
  The latest-frame queue retains frame identity through delivery.
- Mac controls prevent redundant Start during a live feed; reconnects invalidate
  its frame context. AWC1 CONFIG/CONFIG2 and Rotate stay compatible.

### Rotation repair verification (2026-10-18)

- Final Android unit suite: 75 tests, zero failures; debug APK assembled and
  updated on SM-E236B with `adb install -r`, preserving preferences. Root
  `WAMC.apk` refreshed from that build.
- Final Swift suite: 46 tests, zero failures. Pixel-content tests check all four
  clockwise rotations; context tests check delayed output, reconnects, and queues.
  Signed release host and extension bundle validated and installed in Applications.
- Visually inspected the updated Android front preview and Mac preview: both
  upright in landscape. Mac USB delivery measured approximately 29–30 FPS,
  27–29 Mbps HEVC; Wi-Fi delivery approximately 30 FPS, 20.7 Mbps HEVC.
  Four manual Rotate taps completed a full turn and returned to upright.
- Visual inspection exposed a stale Mac orientation label after metadata changes;
  it now refreshes when CONFIG changes during a live feed. Final Swift tests and
  signed bundle installation repeated after this correction.
- USB reconnected after the final app update. Virtual-camera bridge reported ready.
  A transient Wi-Fi reconnect deadline occurred around the app replacement; USB
  recovered. Physical portrait/reverse-landscape stress and meeting-app output
  were not fully validated in this shortened pass.

## Live validation checklist

1. `./gradlew testDebugUnitTest` (Android, 48 tests) and
   `xcrun swift test` (macOS, 19 tests) green.
2. Install debug APK — streaming auto-starts on the front camera at Best
   quality (manual path: Auto-start switch off → tap Start Streaming).
3. Mac shows `HEVC · 30 FPS · ~25–30 Mbps` in diagnostics on first connect
   (falls back to `H.264` against old builds by design).
4. Tap Rotate on the phone: CONFIG(2) carries the compensated total —
   returns to 0 with HAL support (framing crops slightly), else the Mac
   preview turns by the total while the stream continues uninterrupted.
5. 5-minute soak per mode: no decode-error storms, reconnect resumes,
   meeting app holds the virtual camera.

## Measured 2026-10-18 (adb-forwarded TCP, SM-E236B)

- Best/HEVC 1080p30: **28.2 Mbps @ 28.1 fps** sustained 12 s, keyframes
  every ~2 s (GOP 2), CONFIG2 `hevc + vps/sps/pps [23,39,11 B]`, NALs only
  IDR_W_RADL + TRAIL. Captured bytes decode in VideoToolbox to 1920×1080
  (checked with a throwaway `VideoToolbox` script, same calls as the app).
- Legacy v1 start (no negotiation keys): **AVC 23.7 Mbps @ 28.5 fps**,
  CONFIG2 + legacy CONFIG both sent — old Mac builds keep working.
- Rotate on this camera: HAL rotate-and-crop unsupported → metadata
  rotation (`rot=1` in CONFIG2), Mac renders it; stream uninterrupted.
- Hardening found live: uncaught camera-thread exceptions used to kill the
  process mid-stream (abandoned Surface); now contained and surfaced as
  status. Capture is halted before encoder surfaces are released on both
  restart and stop paths (no more HAL buffer-error storms on transitions).
- Known load behavior: at maxed-out 30 Mbps HEVC the HAL occasionally
  drops input frames (~3% in one window); the stream continues and
  latest-wins queues absorb it. Thermal was fine (37 °C).
- Idle listener cost: with the camera off, the sticky service holds only a
  TCP accept thread and the AOA hooks — no capture, no encoder. The Mac
  watchdog spawns `adb devices` every 2.5 s; no polling happens on the
  phone.

## Measured 2026-10-18, auto flow + orientation (SM-E236B)

- Sensors: back 90°, front 270° (`dumpsys media.camera`).
- Cleared-data launch: streaming starts with zero taps (front camera,
  HEVC Best); selector shows the front camera, status `Streaming to Mac`.
- Forced portrait + front: CONFIG2 `rot=3` = (270+0)/90 exactly per the
  front formula; landscape + front returns to `rot=0`. Stream uninterrupted.
- HOME-backgrounded stream keeps delivering (26.4 Mbps, 25.9 fps HEVC).
- Process survives camera-thread errors (no more mid-stream deaths);
  capture halts before surfaces release on restart/stop.
- Mac watchdog + latch: 5 policy unit tests green; live plug-transition
  (physical replug → auto-connect → auto-start, Stop-holds-till-replug)
  needs the Mac GUI run — unit-covered, owner to confirm on device.

## Camera-start and reconnect repair (2026-10-18)

- A Mac `start` received while the Android Activity is backgrounded is queued
  and reports “Open WAMC on the phone to start the camera.” Resuming the app
  consumes the request; an active stream remains in the foreground service
  when the Activity pauses.
- Camera2 session callbacks are generation-checked so a late `onConfigured`
  from a closed camera cannot create a request on a dead device and crash the
  camera thread. Camera-open, capture/encoder, and service-start failures now
  surface distinct status text.
- A Mac socket disconnect clears the decoder, latest-frame queue, frame timing,
  keyframe watchdog, and rolling stats. Receiver generations reject callbacks
  from replaced sockets, and the Mac ignores queued frame/stat tasks from a
  closed transport. The keyframe watchdog reports a timeout after its recovery
  window and clears it when an IDR arrives.
- The app bundle script stages and validates the embedded Camera Extension
  before replacing the installed app. It checks the host/extension team and
  CMIO Mach-service identity and requires a valid matching signing identity.
- The host app entitlements now include Apple's
  `com.apple.developer.system-extension.install` capability, which the
  activation request requires. A clean release app and Camera Extension were
  built and signed, but macOS rejected the host app at launch because no
  provisioning profile authorized that restricted entitlement. The prior app
  bundle was restored. The installer now requires and validates separate host
  and extension profiles, then embeds them before signing and swapping bundles.
  Neither profile is present on this Mac yet, so FaceTime/Photo Booth still
  cannot use WAMC until the matching profiles are supplied and the extension
  is approved in Camera Extensions settings.
- Unit verification: Android `testDebugUnitTest` and macOS `swift test` pass;
  the Camera2 fix was installed on the attached SM-E236B. The stream emitted
  data and HEVC CONFIG, but the Mac still showed 0 FPS on its pre-rebuild app.
  Repeat the live check after a signed app bundle is available.
- Remaining device checks: approve the signed Camera Extension in System
  Settings, verify FaceTime/Photo Booth, complete wired control/soak checks,
  then unplug the cable to validate trusted Wi-Fi fallback and its soak test.
