#!/usr/bin/env python3
"""Validate the single release version and stamp staged macOS bundles."""
import argparse
import json
from pathlib import Path
import plistlib
import re

ROOT = Path(__file__).resolve().parents[2]


def load_version(path=ROOT / 'release.json', tag=None):
    value = json.loads(path.read_text())
    if not re.fullmatch(r'(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)', value['version']):
        raise ValueError('Release version must be MAJOR.MINOR.PATCH')
    if type(value['build']) is not int or not 4 <= value['build'] <= 2100000000:
        raise ValueError('Release build must be an integer between 4 and 2100000000')
    if tag is not None and tag != 'v' + value['version']:
        raise ValueError('Tag does not match release.json')
    return value


def stamp(app, value):
    for path in [app / 'Contents/Info.plist', *app.glob('Contents/Library/SystemExtensions/*/Contents/Info.plist')]:
        data = plistlib.loads(path.read_bytes())
        data.update(CFBundleShortVersionString=value['version'], CFBundleVersion=str(value['build']))
        path.write_bytes(plistlib.dumps(data))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag')
    parser.add_argument('--app', type=Path)
    args = parser.parse_args()
    value = load_version(tag=args.tag)
    if args.app:
        stamp(args.app, value)
    print(json.dumps(value))


if __name__ == '__main__':
    main()
