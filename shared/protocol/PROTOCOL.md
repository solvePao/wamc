# AWC1 wire protocol v2 (backward compatible with v1)

One framing format for every transport: ADB-forwarded TCP (`127.0.0.1:27183`)
and Android Open Accessory bulk streams. All integers are big-endian.

## Frame layout (20-byte header + payload)

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 4 | Magic `AWC1` (`41 57 43 31`) |
| 4 | 1 | Type: `1`=VIDEO, `2`=CONFIG, `3`=CONTROL, `4`=HELLO, `5`=CONFIG2 |
| 5 | 1 | Flags: bit0 = keyframe; other bits 0 |
| 6 | 2 | Reserved, 0 |
| 8 | 8 | `ptsUs` int64: device monotonic timestamp (µs); 0 for non-video |
| 16 | 4 | Payload length uint32 (max 8 MiB) |

## Payloads

- **VIDEO**: one Annex-B access unit (start codes included, no B-frames).
  Codec is AVC unless the latest CONFIG2 says HEVC.
- **CONFIG** (v1, unchanged): `spsLen u16 | sps | ppsLen u16 | pps |
  width u16 | height u16 | fps u8 | rotation u8`.
  `rotation` is quarter-turns clockwise (0=0°, 1=90°, 2=180°, 3=270°) the
  receiver must apply to decoded frames. Sent before the first frame, on
  every format change, and whenever the user taps Rotate on the phone.
- **CONFIG2** (type `5`, new): `codec u8 | count u8 | (len u16 + bytes)* |
  width u16 | height u16 | fps u8 | rotation u8`.
  `codec`: `0`=AVC (sets are sps,pps), `1`=HEVC (sets are vps,sps,pps in
  that order). `rotation = 0` means frames arrive upright — the phone
  rotated in hardware (HAL rotate-and-crop) and the receiver forwards
  decoded frames untouched. Sent before legacy CONFIG on every format
  change; v1 receivers skip it as an unknown type via payload length.
- **CONTROL / HELLO**: UTF-8 `key=value;key=value`, e.g.
  `cmd=start;facing=back;width=1920;height=1080;fps=30`,
  `cmd=requestKeyframe`, `cmd=stop`, `cmd=ping;seq=7`.
  Quality-first keys (all optional, v1 peers ignore what they don't send):
  `cmd=start;quality=best|high|balanced;codec=auto|avc|hevc;bitrate=<bps>;
  gop=<sec>;codecs=avc,hevc;configV2=1`.
  `cmd=hello;codecs=avc,hevc;configV2=1` is a capability announcement
  (Mac → phone on connect); it never starts streaming by itself.
  HELLO example:
  `model=SM-E236B;brand=samsung;sdk=34;cameras=back,front;uvc=unknown;codecs=avc,hevc;configV2=1`.

## Rules

- Latest-wins: senders and receivers keep at most 2 queued frames; drop old
  frames instead of building latency. Never drop CONFIG or keyframes first.
- Receiver asks for a fresh keyframe with `cmd=requestKeyframe` after any
  decode error or (re)connect.
- Unknown frame types are skipped via payload length; bad magic resyncs by
  scanning for the next `AWC1`.

## Golden vector (asserted in Kotlin and Swift tests)

VIDEO, keyframe, pts=1000, payload `00 00 00 01 65 88`:

```text
41574331 01 01 0000 00000000000003e8 00000006 000000016588
```
