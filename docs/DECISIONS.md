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
| 8 | Product name | **WAMC — Wired Android Mac Camera** (both apps; virtual camera is “WAMC Camera”). Package/bundle IDs unchanged. |
| 9 | Android UI | Preview always square (1:1, fits smaller screen dimension); large modern buttons (68dp primary, 64dp secondary, rounded, dark theme). |
| 10 | Rotation | Total = sensor/display/facing compensation + manual taps; HAL rotate-and-crop does it on-device when supported (CONFIG rotation 0, Mac forwards untouched), else the total travels in CONFIG and the Mac renders it. Preview applies the same total. Back sensor is 90° on SM-E236B. |
| 11 | Auto flow | Phone auto-starts (front camera) on open/grant, survives UI death as a sticky foreground listener; Mac auto-connects on plug and auto-starts unless stopped. Both default ON and both switchable in-app (Android Auto-start switch + Mac Auto-connect/Auto-start toggles). |
| 12 | Default camera | Front camera by default (fresh installs); an explicit saved choice always wins. |

Open for later: Apple signing/notarization identity, 60 FPS/4K, other OEMs.
