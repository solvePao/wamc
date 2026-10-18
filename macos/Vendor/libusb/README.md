# libusb 1.0.30

Vendored, unmodified libusb implementation from the official 1.0.30 release:
https://github.com/libusb/libusb/releases/tag/v1.0.30

Only the Darwin/POSIX backend and required common sources are included.
`config.h` selects macOS with pipe2 disabled for the macOS 14 minimum.
The public header is copied into include/ for SwiftPM.

License: LGPL-2.1-or-later; see COPYING and source file notices.
WAMC links this source into the executable. The complete WAMC and libusb
sources and SwiftPM build instructions are supplied in this repository,
allowing rebuilding and relinking with a modified libusb.
Run `cd macos && xcrun swift build -c release` to rebuild.
No system libusb, Homebrew, driver, or privileged helper is used.
