# Decisions — Draft (awaiting your acceptance to become Final)

Settled with the owner on 2026-10-17. Source plan: `plan.md`.

| # | Decision | Choice |
| --- | --- | --- |
| 1 | Scope | **Plan C — full Phases 1–4** (streaming, virtual camera, AOA, polish) |
| 2 | Test matrix for now | **Samsung phone + owner's Mac only.** Verified device: Samsung SM-E236B, Android 14 (API 34), USB. Pixel/OnePlus/other makers deferred. |
| 3 | Transports | ADB-forwarded TCP first (working path); AOA included for Phase 3; native UVC phones detected and used directly. |
| 4 | Video | Quality-first: HEVC (VPS/SPS/PPS) when both ends negotiate it, else AVC; Best 30/25 Mbps VBR, High 12 Mbps, Balanced 8 Mbps; 1080p/720p @ 30 FPS, no B-frames, GOP 2 s, latest-wins queues (latency over backlog). Legacy 6 Mbps CBR AVC kept as the old-app fallback path. |
| 5 | Virtual camera | CoreMediaIO Camera Extension, sink+source streams, stays registered with a placeholder when the phone is unplugged. |
| 6 | Audio | Out of scope (video only), per `plan.md` §8. |
| 7 | Wire protocol | AWC1 v2 framing in `shared/protocol/PROTOCOL.md` (CONFIG2 type 5 + codec/quality negotiation, v1-compatible), golden-vector tested in Kotlin + Swift. |
| 8 | Product name | **WAMC — Wired Android Mac Camera** (both apps; virtual camera is “Android Camera”). Package/bundle IDs unchanged. |
| 9 | Android UI | Single-screen dark dashboard with charcoal surfaces and teal accents; square preview adapts around visible controls, compact camera/quality selectors and three switch rows, pinned 56dp Start/Stop action. Landscape uses preview + controls columns; scrolling remains available for small windows, USB guidance and enlarged text, with preview actions moving into the control group when space is tight. Native XML/Kotlin views, 48dp minimum touch targets, no new dependencies. |
| 10 | Rotation | Total = sensor/display/facing compensation + manual taps; HAL rotate-and-crop does it on-device when supported (CONFIG rotation 0, Mac forwards untouched), else the total travels in CONFIG and the Mac renders it. TextureView applies a separate residual transform because it already compensates for sensor orientation. Android updates preview and CONFIG together; Mac frames retain their decoder orientation and generation. Back sensor is 90° on SM-E236B. |
| 11 | Auto flow | Phone auto-starts (front camera) on open/grant, survives UI death as a sticky foreground listener; Mac auto-connects on plug and auto-starts unless stopped. Both default ON and both switchable in-app (Android Auto-start switch + Mac Auto-connect/Auto-start toggles). |
| 12 | Default camera | Front camera by default (fresh installs); an explicit saved choice always wins. |

| 13 | Wi-Fi discovery | **Bonjour/DNS-SD `_wamc._tcp`**: Android `NsdManager` publishes a stable per-install UUID (`id`) in TXT + HELLO; Mac browses with `NWBrowser` and connects to the Bonjour endpoint (no manual IP). Wi-Fi auto-connect only for trusted `id`s (first-connect Trust & Connect); HELLO `id` must match TXT `id`. USB stays preferred; one active transport. AWC1 wire format unchanged. |
| 14 | Mac app form | **Menu-bar agent**: `LSUIElement` (no Dock icon/window by default), launch-at-login via `SMAppService.mainApp` default ON with persisted opt-out, full controls/status in the menu bar, window on demand. |
| 15 | Wi-Fi latency | **Wi-Fi low-latency profile**: same resolution/fps/codec, bitrate at 75% of the USB tier, GOP 1 s (Mac sends `transport=wifi;latency=low`; phone owns the scaling in `QualitySelector`). Plus no-cost fixes: Wi-Fi queue cap 1 + 128 KB send buffer, TCP no-delay both ends, FAST HAL enhancement on Wi-Fi, immediate decode→bridge feed on the Mac, 1 ms extension sink re-arm. Quality budget is bitrate-only. Live A/B (2026-10-18, `docs/QUALITY.md`): 75% profile confirmed (−25% bitrate/frame size, GOP 1, fps unchanged), but Wi-Fi arrival p95 (≈97 ms) did not improve vs 100% — stalls are link-layer, not size-bound — so the gated 720p fallback stays **off** by decision; the next lever would be Wi-Fi link behaviour, not resolution. |

| 16 | Mac installation readiness | First-run Setup & Diagnostics, automatic extension activation from Applications, explicit OS approval actions, real enabled-state and own-sink checks, preserved user opt-outs, and complete-bundle installation. Local development signing uses actual team `HU27CJ3DK6`, not the certificate-name suffix `FJ696ZCQ56`. Build/DMG gates validate profile, signer, registered Mac, identifiers, sandbox, and mounted artifacts before replacing working outputs. |

| 17 | Mac interface | Large aspect-fit preview plus a 320 pt scrolling control panel (1040×680 default; 820×560 minimum). Native Liquid Glass actions and expandable headers on macOS 26+, material/bordered fallback on macOS 14–15. Two aligned equal-width camera-action rows; full-row animated disclosure headers honor Reduce Motion. Disconnect removes the preview view and clears its retained image. Live statistics use a separate display-only publisher observed by preview/setup; camera controls and native menus also compare value snapshots so statistics cannot invalidate open pickers. Bridge readiness still publishes only on availability changes. Preserve every setup/trust action and background virtual-camera delivery. |

Open for later: public Developer ID distribution/notarization, 60 FPS/4K, other OEMs.

## Connection and camera controls — 2026-10-18

- One `ConnectionController` owns the macOS transport lifecycle, target identity,
  cancellation, and five-second connection deadline. USB and Wi-Fi expose the same
  connection actions. USB commands run off the main thread and select a physical
  USB serial with an independently allocated loopback forwarding port.
- Start camera requires a validated connection. Stop camera sends Stop then
  disconnects, with at most 500 ms allowed for send completion. Explicit Stop or
  Disconnect suppresses automatic reconnection until Connect or app relaunch.
  This supersedes device-list changes clearing the user's stop intent.
- Manual Wi-Fi selection remains selected with USB attached. USB preference
  applies to automatic transport selection. Failed targets are not retried until
  explicit Connect or disappearance and reappearance.
- Feed state follows decoded current-generation frames. Stop/disconnect clears
  preview immediately; one second without frames shows No feed. Background
  virtual-camera delivery and its placeholder behavior remain independent.
- Quality selection applies through the existing Start command, coalesces rapid
  changes, and waits for fresh output. Existing orientation contexts continue to
  reject late decoder output. No new wire frame types are introduced.
- Discovery excludes emulators using optional TXT metadata with a legacy model
  fallback. Phone identity and trust continue to use the per-install stable ID.
- The toolbar Refresh arrow is removed; automatic and menu-based discovery remain.

## Unified streaming session — 2026-10-18

- The macOS sidebar has one session action: Start stream, Stop stream, Cancel,
  Retry stream, or a brief disabled Stopping state. Separate camera Start/Stop
  and transport Connect/Disconnect buttons are removed from window and menu.
- Source rows select USB or a physical Wi-Fi phone. Selecting while stopped does
  not connect. Selecting while streaming stops the old phone, tears down its
  connection, then connects and starts the selected source. Latest selection
  wins; Cancel invalidates pending switching. Unknown Wi-Fi sources require trust.
- SessionModel owns selected source and streaming intent; ConnectionController
  retains transport lifecycle ownership. Camera decoding and generation guards
  remain in AppModel. Source selection survives Stop for the current app session.
- Start streaming automatically replaces the independent Auto-connect/Auto-start
  preferences. Migration enables it only when both legacy values were enabled;
  missing legacy values keep their previous true defaults. Existing opt-outs and
  launch-at-login settings are preserved. Explicit Stop/Cancel suppress auto-start.
- Initial source preference is authorized physical USB, then trusted Wi-Fi. A
  user's explicit source selection overrides subsequent discovery preference.
  Manual address uses the same session flow. Transport deadlines stay five
  seconds; sending Stop remains bounded to 500 ms.

## GitHub distribution and updates — 2026-10-18

- Host source publicly in `solvePao/wamc` so the current GitHub plan supports protected `main`; publish paired artifacts and update metadata in `solvePao/wamc-releases`. Main requires pull requests and passing Android/Mac checks, including for administrators. No store submission.
- Tag releases with `vMAJOR.MINOR.PATCH`; `release.json` supplies semantic version and increasing build number for both apps and camera extension.
- Android uses a permanent release key and native installer approval. Mac uses arm64 Developer ID signing, notarization, and Sparkle signed updates.
- Check once per process launch, prompt before download, and defer installation during streaming. Manual update checks remain available.
- Retain 90% coverage gates; focused updater tests were explicitly authorized.


## ADB-free consumer transport — 2026-10-19

- Consumer USB uses Android Open Accessory with bundled libusb 1.0.30 and the
  existing AWC1 stream. Samsung/Mac remains the initial hardware scope; wired
  release support requires real debugging-disabled and signed-app validation.
- ADB remains available only through explicit Developer tools opt-in and source
  selection. It is not installed, probed or launched by ordinary consumer setup.
- AOA setup is bounded to 30 seconds; network connection deadlines and Stop
  behavior remain separate. No privileged USB helper or driver is introduced.
- USB failure can select currently trusted Wi-Fi only when automatic streaming
  remains enabled. Explicit Stop/Cancel suppress restart. Manual addresses may
  use compatible tethering; automatic tether discovery is deferred.
- Accessory permission, matching identity, detach/reattach and buffered USB reads
  are Android transport responsibilities. Camera and codec behavior are shared.
