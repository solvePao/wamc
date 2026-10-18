# ADB-free USB accessory streaming

WAMC's consumer USB transport uses Android Open Accessory (AOA), not ADB.
The AOA protocol itself does not require developer mode, USB debugging, root,
tethering, Platform Tools, or separate Mac USB drivers. Device firmware can
still prevent accessory activation; see the validation record below. Install WAMC on both devices,
connect a data cable, unlock Android, open WAMC, and approve camera/accessory
permissions. An unsupported or busy USB device offers Retry and Wi-Fi/hotspot
instructions rather than silently switching to ADB.

## Implementation

- The Mac discovers Samsung USB devices and existing Google AOA devices using
  the bundled libusb 1.0.30 Darwin backend. It never captures/detaches a driver
  or launches a privileged helper.
- AOA requests 51/52/53 identify `WAMC / Wired Android Mac Camera / 1.0`.
  USB bus/port topology correlates re-enumeration; only the accessory bulk
  interface is claimed, leaving any separate ADB interface alone.
- Setup has a 30-second deadline, including permission approval. Cancel and
  Stop invalidate the attempt; late callbacks cannot revive the old stream.
- TCP and accessory adapters share the AWC1 parser, codec negotiation, decoder,
  quality selection and virtual-camera pipeline. HELLO requires a valid stable
  phone ID; a changed ID on an established USB topology ends that connection.
- Android requests accessory permission and handles attach/detach/new intents.
  It accepts only the matching WAMC accessory. USB reads are buffered at the
  accessory transfer size so protocol header reads cannot discard USB data.
- Automatic selection prefers USB. On USB failure, an already trusted Wi-Fi
  phone can take over only with automatic streaming enabled. Explicit Stop or
  Cancel suppresses automatic restart, and network sources still require trust.

## Development ADB transport

Enable **Preferences → Developer tools → Use ADB transport**, then explicitly
select **ADB (development)** as the source. Developers install Platform Tools,
enable USB debugging, and authorize the Mac. Existing install/log/debug scripts
continue to use ADB. ADB is never a consumer fallback. The preference defaults
OFF; ordinary discovery/setup does not probe for or launch ADB.

## Tethering and native webcam alternatives

A compatible USB-tethering network can use Manual address with the existing
TCP stream. A tethering toggle alone does not establish compatibility: macOS
must expose a working network interface and reach WAMC on port 27183. Manual
network connections are labeled Network, not wired USB. No automatic tethering
subsystem, root-based mode switch, or RNDIS driver installation is included.

Phones with a manufacturer-provided USB Webcam option can be selected directly
in meeting apps. That path uses the phone's system webcam service, not WAMC's
camera controls. Wi-Fi/hotspot remains the fallback on unsupported USB devices.

## Packaging and release gate

The libusb implementation is built from the pinned sources in
`macos/Vendor/libusb`; users have no external runtime dependency. The app bundle
includes the LGPL license and source/rebuild instructions. Rebuildable WAMC and
library sources are supplied in this repository.

AOA GET_PROTOCOL version 2 was observed on Samsung SM-E236B during development.
This establishes protocol support, not complete release acceptance. Do not
advertise validated wired support until the following checks are recorded:

- Signed installed Mac app streams with ADB absent/stopped and Android USB
  debugging OFF; no root, privileged helper or separate driver is used.
- First permission approval, denial/retry, cable replug, app restart and Cancel
  during setup work without stale callbacks or a second active source.
- Moving video reaches a meeting app; camera switch, rotation and quality work.
- Trusted Wi-Fi fallback preserves Stop intent and rejects untrusted phones.
- Bundled library/license and normal launch's absence of ADB calls are verified.

No new tests are introduced by this change. Existing tests that assume
root/developer onboarding, anonymous accessories, or USB meaning ADB require
an explicitly authorized update. Hardware and signing validation remain
separate from unit-test results.

## Development validation record — 2026-10-19

- Built the Android APK and signed Mac bundle. Bundle/profile verification
  passed. `otool -L` confirms no Homebrew, external libusb, or Android SDK runtime
  library dependency; bundled library license and rebuild instructions exist.
- Observed a live decoded phone feed over the accessory interface before
  changing USB debugging. This proves the byte transport can carry video; it
  does not satisfy the debugging-disabled release gate.
- Disabled Android USB debugging and stopped the Mac ADB server. The Samsung
  then returned to its ordinary USB configuration. After a physical cable
  reconnect, AOA GET_PROTOCOL still reported 2 and requests 52/53 acknowledged,
  but an accessory interface was not observed within the setup deadline.
- The user also attempted a debugging-enabled comparison. That did not provide
  a repeatable fresh accessory activation result. Do not infer that debugging
  is a required workaround or advertise this firmware as supported.
- A libusb teardown/hotplug deadlock exposed by the settings change was fixed
  by using one process-wide context with independently retained device refs.
- A separate Android validation application was installed because the existing
  app's signing key differs from the local debug key. The original app/data was
  preserved. Coexisting copies can contend for the camera/TCP listener, so
  final end-to-end validation must use one app signed with the proper key.
- Existing focused checks passed: 20 Mac wire/network tests, 3 Mac Wi-Fi/session
  tests, and 26 Android wire/transport tests. The broad suites remain red:
  Android has five old onboarding/anonymous-accessory expectation failures;
  macOS includes legacy USB-as-ADB expectations and failures/crash in other
  concurrently edited setup/camera code. No tests were added or edited.
- Meeting-app output, complete permission denial/replug recovery, clean-machine
  operation with ADB absent, and installed-app virtual-camera readback remain
  unverified. USB release support is therefore **not approved by this record**.
