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

- HAL `SCALER_ROTATE_AND_CROP` (API 33+, queried per camera) rotates
  on-device when supported; CONFIG(2) then reports rotation 0 and the Mac
  forwards decoded buffers untouched (no CoreImage render).
- Unsupported cameras keep metadata rotation; the Mac renders it as before.
- HAL rotation center-crops to the stream aspect — framing tightens
  slightly when rotation is active. Default (0°) streams are unaffected.

## Live validation checklist

1. `./gradlew testDebugUnitTest` (Android, 39 tests) and
   `xcrun swift test` (macOS, 14 tests) green.
2. Install debug APK, tap Best quality → Start Streaming.
3. Mac shows `HEVC · 30 FPS · ~25–30 Mbps` in diagnostics on first connect
   (falls back to `H.264` against old builds by design).
4. Tap Rotate on the phone: CONFIG rotation returns to 0 with HAL support
   (framing crops slightly), else Mac preview turns as before.
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
