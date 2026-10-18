# AWC1 wire protocol v2 (backward compatible with v1)

One framing format for every transport: ADB-forwarded TCP (a dynamically allocated loopback port forwarding to phone port `27183`)
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
  receiver must apply to decoded frames. It is the total orientation:
  sensor/display/facing compensation plus manual Rotate taps (Android
  `CameraOrientation.totalTurns`). Sent before the first frame, on every
  format change, and whenever orientation or taps change it.
- **CONFIG2** (type `5`, new): `codec u8 | count u8 | (len u16 + bytes)* |
  width u16 | height u16 | fps u8 | rotation u8`.
  `codec`: `0`=AVC (sets are sps,pps), `1`=HEVC (sets are vps,sps,pps in
  that order). `rotation = 0` means frames arrive upright — via HAL
  rotate-and-crop or because the compensated total is already 0 — and the
  receiver forwards decoded frames untouched. Sent before legacy CONFIG on every format
  change; v1 receivers skip it as an unknown type via payload length.
- **CONTROL / HELLO**: UTF-8 `key=value;key=value`, e.g.
  `cmd=start;facing=back;width=1920;height=1080;fps=30`,
  `cmd=requestKeyframe`, `cmd=stop`, `cmd=ping;seq=7`.
  Quality-first keys (all optional, v1 peers ignore what they don't send):
  `cmd=start;quality=best|high|balanced;codec=auto|avc|hevc;bitrate=<bps>;
  gop=<sec>;codecs=avc,hevc;configV2=1`.
  Transport/latency keys (optional): `transport=usb|wifi` and
  `latency=low`. The Mac sends `transport=wifi;latency=low` on Wi-Fi
  starts; the phone then applies its Wi-Fi low-latency profile (same
  width/height/fps/codec, bitrate scaled to 75% of the tier, GOP 1 s;
  explicit `bitrate`/`gop` overrides still win). USB starts omit
  `latency`, and legacy phones ignore both keys.
  `cmd=hello;codecs=avc,hevc;configV2=1` is a capability announcement
  (Mac → phone on connect); it never starts streaming by itself.
  HELLO example:
  `model=SM-E236B;brand=samsung;sdk=34;cameras=back,front;uvc=unknown;codecs=avc,hevc;configV2=1`.

## Discovery (Bonjour / DNS-SD) — Wi-Fi only, AWC1 unchanged

The phone advertises itself on the local network so the Mac finds it with
no manual IP entry. Discovery is metadata only; the stream still uses the
AWC1 framing above on TCP port `27183`.

- Service type: `_wamc._tcp` (Android NSD registers `_wamc._tcp.`).
- Instance name: `WAMC-<model>-<shortId>`, e.g. `WAMC-SM-E236B-a1b2`,
  where `shortId` is the first 4 alphanumeric characters (lowercased) of
  the device `id`. The system may auto-rename on conflict; identity is
  the TXT `id`, never the instance name.
- Stable identity: a per-install UUID persisted on the phone, published
  as TXT `id` and echoed in HELLO as `id=<uuid>`. A Mac that connected
  via Bonjour drops the connection if HELLO `id` does not match TXT `id`.
- TXT record (plain ASCII `key=value`):
  `v=2`, `id=<uuid>`, `model=<model>`, `brand=<brand>`, `sdk=<int>`,
  `port=27183`, `caps=avc,hevc;configV2`.
- Optional TXT `emulator=0|1` identifies Android emulators. The Mac excludes
  emulator advertisements from phone rows, counts, endpoint maps, and automatic
  connections. Older advertisements fall back to known emulator model names.
  Physical phones remain distinct by stable ID, even when model names match.
- Mac browsing: `NWBrowser` for `_wamc._tcp`; connect with `NWConnection`
  to the Bonjour service endpoint (no IP/port handling in app code).
  Requires `NSBonjourServices` + `NSLocalNetworkUsageDescription` in the
  Mac app Info.plist.
- Trust: the Mac auto-connects over Wi-Fi only to previously trusted
  `id`s. First sight of an unknown `id` requires an explicit
  Trust & Connect (a manual connect counts as trust). USB (adb) needs
  no trust step — physical cable is the trust signal.
- HELLO example with identity:
  `model=SM-E236B;brand=samsung;sdk=34;cameras=back,front;uvc=unknown;codecs=avc,hevc;configV2=1;id=<uuid>`.
  Legacy peers ignore the unknown `id` key.
- Restart epoch: HELLO also carries `gen=<n>`, a monotonic counter the
  phone bumps on every pipeline rebuild (setting change, camera switch,
  rotation with a HAL mode change). It is informational — old Mac builds
  ignore unknown keys — and lets the receiver tell rejoins apart in logs
  and diagnostics.

## Rules

- Latest-wins: senders and receivers keep at most 2 queued frames; drop old
  frames instead of building latency. Never drop CONFIG or keyframes first.
- Receiver asks for a fresh keyframe with `cmd=requestKeyframe` after any
  decode error or (re)connect.

## Restart and rejoin

Any pipeline rebuild must rejoin without a freeze, on USB and Wi-Fi alike:

- Sender order per restart: flush queued VIDEO (keep CONFIG/CONTROL/HELLO),
  then HELLO, then CONFIG2 + legacy CONFIG, then VIDEO starting with an IDR.
  Pre-IDR P-frames are held on the phone, never sent.
- A `requestKeyframe` that arrives while the encoder is down is coalesced
  and applied to the next encoder; the opening IDR is always forced.
- Display rotation only resends CONFIG + keyframe when the compensated total
  changes; a HAL rotate-and-crop mode change restarts the pipeline instead.
- Receiver resets decoder session, frame queue, CONFIG dedup, and arrival
  tracking on every transport dial (not only manual disconnect), dedups
  CONFIG by `codec:WxH@fps:rotation`, and re-asks for a keyframe (throttled,
  capped) while still waiting after a CONFIG.
- The virtual camera publishes one fixed format (1920×1080): other sizes are
  letterboxed into it, and stalls publish the waiting slate with fresh
  timestamps instead of a frozen frame.
- Unknown frame types are skipped via payload length; bad magic resyncs by
  scanning for the next `AWC1`.

## Golden vector (asserted in Kotlin and Swift tests)

VIDEO, keyframe, pts=1000, payload `00 00 00 01 65 88`:

```text
41574331 01 01 0000 00000000000003e8 00000006 000000016588
```

## macOS connection and camera lifecycle

- USB and Wi-Fi connection attempts share a five-second deadline covering setup,
  socket connection, and a valid phone HELLO. Bonjour HELLO identity must match
  TXT identity before the connection becomes usable. A TCP connection alone does
  not enable camera controls. A failed attempt does not retry continuously while
  its target remains present; explicit Connect or a new arrival can retry.
- USB setup selects an authorized physical USB serial and allocates its own
  loopback forwarding port. Cancellation and teardown remove only that mapping.
- Manual transport selection takes priority over automatic USB preference.
  Stop sends `cmd=stop`, waits at most 500 ms for local send completion, and
  disconnects. Stop/Disconnect suppress automatic connection until explicit
  Connect or app relaunch. Start requires a validated connection.
- Quality changes reuse `cmd=start` with the selected profile, coalescing rapid
  selections. A running Android foreground stream can apply quality changes
  while its Activity is hidden; starting an idle camera retains Android's
  existing eligibility checks. HELLO `gen` distinguishes pipeline generations;
  CONFIG parameter sets participate in decoder deduplication. CONFIG2 takes
  precedence over its legacy CONFIG companion.
- Preview availability follows decoded frames, independently of socket state.
  Explicit teardown clears retained images immediately; one second without a
  decoded frame shows No feed. The registered virtual camera keeps its existing
  placeholder fallback. Closing the preview window does not stop bridge delivery.

### Unified macOS session controls

The macOS Start stream action owns connection and camera startup: select a source,
connect, validate HELLO, then send the existing Start command. Stop stream sends
Stop and disconnects. Source switching performs orderly Stop/teardown before
starting the new source. These UI changes add no protocol fields or frame types.
The five-second connection and 500 ms Stop-send limits still apply.
