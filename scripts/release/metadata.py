#!/usr/bin/env python3
"""Generate paired GitHub release assets and signed Sparkle enclosure metadata."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET
from version import load_version

REPOSITORY = 'solvePao/wamc-releases'
SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', SPARKLE)


def digest(path):
    with path.open('rb') as source:
        checksum = hashlib.sha256()
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            checksum.update(chunk)
        return checksum.hexdigest()


def generate(directory, signature):
    value = load_version()
    version, build = value['version'], value['build']
    apk = directory / f'WAMC-{version}.apk'
    dmg = directory / f'WAMC-{version}-arm64.dmg'
    if not apk.is_file() or not dmg.is_file() or not apk.stat().st_size or not dmg.stat().st_size:
        raise ValueError('Both nonempty APK and DMG are required')
    if not re.fullmatch(r'[A-Za-z0-9+/]{86}==', signature):
        raise ValueError('Expected base64 Ed25519 Sparkle signature')
    android = dict(value, minAndroid=26, asset=apk.name, size=apk.stat().st_size, sha256=digest(apk))
    (directory / 'android-update.json').write_text(json.dumps(android, indent=2) + '\n')
    rss = ET.Element('rss', version='2.0')
    channel = ET.SubElement(rss, 'channel')
    ET.SubElement(channel, 'title').text = 'WAMC updates'
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = f'WAMC {version}'
    for key, text in [('version', str(build)), ('shortVersionString', version),
                      ('minimumSystemVersion', '14.0.0'), ('hardwareRequirements', 'arm64')]:
        ET.SubElement(item, f'{{{SPARKLE}}}{key}').text = text
    ET.SubElement(item, 'enclosure', {
        'url': f'https://github.com/{REPOSITORY}/releases/download/v{version}/{dmg.name}',
        'length': str(dmg.stat().st_size), 'type': 'application/octet-stream',
        f'{{{SPARKLE}}}edSignature': signature,
    })
    ET.indent(rss)
    ET.ElementTree(rss).write(directory / 'appcast.xml', encoding='utf-8', xml_declaration=True)
    assets = [apk, dmg, directory / 'android-update.json', directory / 'appcast.xml']
    (directory / 'SHA256SUMS').write_text(''.join(f'{digest(path)}  {path.name}\n' for path in assets))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--signature-file', type=Path, required=True)
    args = parser.parse_args()
    generate(args.directory, args.signature_file.read_text().strip())
