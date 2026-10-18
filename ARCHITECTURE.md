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
`docs/ACCESSORY.md`. Ops runbook: `AI_AGENT_GUIDE.md`.

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
- Rotation encoding: quarter-turns clockwise 0–3. `0` means frames arrive
  upright (phone rotated in hardware); otherwise the Mac renders it.

---
