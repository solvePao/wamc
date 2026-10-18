#!/usr/bin/env python3
"""Verify release APK identity, version and permanent signing certificate."""
import os
from pathlib import Path
import re
import subprocess
import sys
from version import load_version


def verify(apk):
    version = load_version()
    sdk = Path(os.environ['ANDROID_HOME']) / 'build-tools/35.0.0'
    fingerprint = os.environ['ANDROID_SIGNING_SHA256'].replace(':', '').lower()
    if not re.fullmatch('[a-f0-9]{64}', fingerprint):
        raise ValueError('ANDROID_SIGNING_SHA256 must identify the permanent release certificate')
    signed = subprocess.check_output([str(sdk / 'apksigner'), 'verify', '--verbose', '--print-certs', str(apk)], text=True)
    certificates = re.findall(r'Signer #\d+ certificate SHA-256 digest: ([a-fA-F0-9]+)', signed)
    if [value.lower() for value in certificates] != [fingerprint]:
        raise ValueError('APK signer differs from configured permanent certificate')
    manifest = subprocess.check_output([str(sdk / 'aapt'), 'dump', 'badging', str(apk)], text=True)
    expected = f"package: name='com.androidwebcam.app' versionCode='{version['build']}' versionName='{version['version']}'"
    if not manifest.startswith(expected):
        raise ValueError('APK identifier or version differs from release.json')
    print('Verified APK package, version, and release signing certificate')


if __name__ == '__main__':
    verify(Path(sys.argv[1]))
