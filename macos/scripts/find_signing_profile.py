#!/usr/bin/env python3
"""Find a valid Mac development profile for the WAMC system-extension host."""

import datetime
import fnmatch
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile


def profile_matches(profile, team, now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    entitlements = profile.get("Entitlements", {})
    expiration = profile.get("ExpirationDate", datetime.datetime.min)
    identifier = entitlements.get("com.apple.application-identifier", "")
    return (team in profile.get("TeamIdentifier", [])
            and "OSX" in profile.get("Platform", [])
            and expiration > now
            and bool(identifier)
            and fnmatch.fnmatchcase(f"{team}.com.androidwebcam.app", identifier)
            and entitlements.get("com.apple.developer.system-extension.install") is True)


def main():
    team = os.environ.get("DEVELOPMENT_TEAM", "HU27CJ3DK6")
    override = os.environ.get("WAMC_PROVISIONING_PROFILE")
    directories = [
        Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles",
        Path.home() / "Library/MobileDevice/Provisioning Profiles",
    ]
    candidates = [Path(override)] if override else [
        profile for directory in directories for profile in directory.glob("*.provisionprofile")
    ]
    matches = []
    with tempfile.TemporaryDirectory(prefix="wamc-profile-") as temporary:
        decoded = Path(temporary) / "profile.plist"
        errors = Path(temporary) / "decode.log"
        for candidate in candidates:
            with decoded.open("wb") as output, errors.open("wb") as error:
                result = subprocess.run(
                    ["security", "cms", "-D", "-i", str(candidate)],
                    stdout=output, stderr=error, check=False,
                )
            if result.returncode:
                continue
            try:
                profile = plistlib.loads(decoded.read_bytes())
            except (ValueError, plistlib.InvalidFileException):
                continue
            if profile_matches(profile, team):
                matches.append((profile["ExpirationDate"], candidate))
    if not matches:
        sys.exit(
            f"No valid WAMC provisioning profile for team {team}. In Xcode, enable "
            "System Extensions for com.androidwebcam.app and use automatic signing, "
            "or set WAMC_PROVISIONING_PROFILE to the downloaded Mac development profile. "
            "The installed app has not been changed."
        )
    print(max(matches, key=lambda match: match[0])[1])


if __name__ == "__main__":
    main()
