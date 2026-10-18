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
backlog). The transport keeps latest-wins queues (cap 3 per peer, CONFIG
and keyframes never silently dropped) and `requestKeyframe` recovery.

## Why not uncompressed

Raw 1080p30 is ~750 Mbps (YUV420) to ~2 Gbps (BGRA) before framing —
far above reliable `adb forward` TCP throughput — and it would break the
zero-copy Camera2 → encoder-surface path. VBR at the ceilings above is
the practical "no visible compression" point.

## Rotation placement

- Total orientation = `CameraOrientation.totalTurns` (sensor ± display +
  manual taps: back = sensor−device, front = sensor+device). The encoder
  and preview surfaces receive sensor-order buffers, so the stream needs
  rotating by the total for an upright picture.
- HAL `SCALER_ROTATE_AND_CROP` (API 33+, queried per camera) is applied to
  that total when supported; CONFIG(2) then reports rotation 0 and the Mac
  forwards decoded buffers untouched (no CoreImage render).
- Otherwise the total travels in CONFIG(2) and the Mac renders it; the
  Android preview applies the same total cosmetically (`previewTurns()`).
- HAL rotation center-crops to the stream aspect — framing tightens
  slightly when rotation is active. Upright totals are unaffected.

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
