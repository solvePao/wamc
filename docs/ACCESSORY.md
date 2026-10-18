# Android Open Accessory (Phase 3) notes

Goal: stream without USB debugging. Android side is implemented
(`UsbAccessoryTransport` + accessory intent filter for
`WAMC / Wired Android Mac Camera`).

## How AOA negotiation works

1. Mac (USB host) sends the AOA control requests to the phone:
   `GET_PROTOCOL`, `SET_STRING` (manufacturer/model/version matching
   `android/app/src/main/res/xml/accessory_filter.xml`),
   then `START` to switch the phone into accessory mode.
2. The phone re-enumerates; Android broadcasts
   `USB_ACCESSORY_ATTACHED` and the app opens bulk endpoints via
   `UsbManager.openAccessory`. The same AWC1 framing then flows.

## macOS host status

IOKit USB control transfers for step 1 need a small host helper plus USB
entitlements, and Samsung accessory behaviour varies by firmware. Until that
helper is validated on the Samsung test phone, the supported no-debug path
on this machine is: keep using the ADB transport, **or** use the phone's
native UVC webcam mode if its USB menu offers one (Android 14+; the Mac
app lists such cameras under “Native USB webcam found”). The ADB path is
the tested default; AOA stays behind the same `Transport` interface so no
camera/encoder code changes when the host helper lands.

## Test checklist (Samsung + Mac)

- [ ] With USB debugging OFF, attaching the cable triggers accessory attach.
- [ ] Stream starts over AOA and survives a cable replug.
- [ ] If AOA fails, the app falls back to guidance instead of a black screen.
