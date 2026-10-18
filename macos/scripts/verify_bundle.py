#!/usr/bin/env python3
"""Reject incorrectly signed WAMC bundles before installation or DMG publication."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

from find_signing_profile import profile_matches

APP_ID = "com.androidwebcam.app"
EXTENSION_ID = APP_ID + ".CameraExtension"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify(app):
    with tempfile.TemporaryDirectory(prefix="wamc-verify-") as temporary:
        directory = Path(temporary)

        def capture(arguments):
            output, error = directory / "stdout", directory / "stderr"
            with output.open("wb") as stdout, error.open("wb") as stderr:
                result = subprocess.run(arguments, stdout=stdout, stderr=stderr, check=False)
            require(result.returncode == 0, f"{arguments[0]} failed: {error.read_text(errors='replace').strip()}")
            return output.read_bytes(), error.read_text(errors="replace")

        def signature(bundle):
            capture(["codesign", "--verify", "--deep", "--strict", str(bundle)])
            data, _ = capture(["codesign", "-d", "--entitlements", ":-", str(bundle)])
            entitlements = plistlib.loads(data)
            _, details = capture(["codesign", "-dvv", str(bundle)])
            match = re.search(r"^TeamIdentifier=(.+)$", details, re.MULTILINE)
            require(match is not None, "Missing actual signing TeamIdentifier")
            return entitlements, match.group(1)

        host_info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        require(host_info.get("CFBundleIdentifier") == APP_ID, "Unexpected host bundle identifier")
        require(host_info.get("NSCameraUsageDescription"), "Missing camera permission explanation")
        require(host_info.get("NSLocalNetworkUsageDescription"), "Missing local-network permission explanation")
        require(host_info.get("NSSystemExtensionUsageDescription"), "Missing extension permission explanation")
        require("_wamc._tcp" in host_info.get("NSBonjourServices", []), "Missing WAMC Bonjour service")
        require(host_info.get("WAMCSetupVersion", 0) >= 1, "Bundle predates the required setup workflow")
        host_entitlements, team = signature(app)
        require(host_entitlements.get("com.apple.developer.system-extension.install") is True,
                "Missing system-extension.install entitlement")
        require(host_entitlements.get("com.apple.developer.team-identifier") == team,
                "Host's entitlement Team ID differs from its actual signer")
        require(host_entitlements.get("com.apple.application-identifier") == f"{team}.{APP_ID}",
                "Host's application identifier differs from its signer/bundle")

        profile_path = app / "Contents/embedded.provisionprofile"
        require(profile_path.is_file(), "Missing embedded provisioning profile")
        data, _ = capture(["security", "cms", "-D", "-i", str(profile_path)])
        profile = plistlib.loads(data)
        require(profile_matches(profile, team), "Profile is expired or does not authorize this host, platform, team, or extension entitlement")
        certificate_prefix = directory / "signer"
        capture(["codesign", "-d", f"--extract-certificates={certificate_prefix}", str(app)])
        certificate = Path(str(certificate_prefix) + "0").read_bytes()
        require(certificate in profile.get("DeveloperCertificates", []), "Host signing certificate is not authorized by its profile")
        if os.environ.get("WAMC_DISTRIBUTION") == "true":
            _, details = capture(["codesign", "-dvv", str(app)])
            require("Authority=Developer ID Application:" in details,
                    "Distribution requires a Developer ID Application certificate")
            require(profile.get("ProvisionsAllDevices") is True,
                    "Distribution profile must authorize all devices")
            require(not profile.get("Entitlements", {}).get("get-task-allow", False),
                    "Distribution profile must not enable debugging")
        if not profile.get("ProvisionsAllDevices", False):
            data, _ = capture(["system_profiler", "SPHardwareDataType", "-json"])
            hardware = json.loads(data)["SPHardwareDataType"][0]
            device = hardware.get("provisioning_UDID") or hardware.get("platform_UUID")
            require(device and device in profile.get("ProvisionedDevices", []), "This Mac is not registered in the development profile")

        extension = app / f"Contents/Library/SystemExtensions/{EXTENSION_ID}.systemextension"
        extension_info = plistlib.loads((extension / "Contents/Info.plist").read_bytes())
        require(extension_info.get("CFBundleIdentifier") == EXTENSION_ID, "Unexpected extension identifier")
        entitlements, extension_team = signature(extension)
        require(extension_team == team, "Host and camera extension are signed by different teams")
        require(entitlements.get("com.apple.security.app-sandbox") is True, "Camera extension must be sandboxed")
        require(f"{team}.{APP_ID}" in entitlements.get("com.apple.security.application-groups", []),
                "Camera extension's app group uses the wrong Team ID")
        require(extension_info.get("CMIOExtension", {}).get("CMIOExtensionMachServiceName") == f"{team}.{EXTENSION_ID}",
                "Camera extension's Mach service uses the wrong Team ID")
        print(f"PASS: WAMC bundle {host_info['CFBundleVersion']}, team {team}, signed host + extension, profile valid through {profile['ExpirationDate'].date()}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    try:
        verify(args.app.resolve())
    except (ValueError, OSError, plistlib.InvalidFileException) as error:
        parser.exit(1, f"WAMC bundle validation failed: {error}\n")
