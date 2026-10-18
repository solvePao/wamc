#!/usr/bin/env python3
"""Publish a complete paired release; never mutate a published version."""
import argparse
import json
from pathlib import Path
import subprocess
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from version import load_version

REPOSITORY = 'solvePao/wamc-releases'


def run(*args):
    return subprocess.run(['gh', *args], check=True, text=True, capture_output=True).stdout


def validate_previous(version):
    try:
        with urlopen(Request(f'https://api.github.com/repos/{REPOSITORY}/releases/latest',
                             headers={'Accept': 'application/vnd.github+json'}), timeout=30) as response:
            latest = json.load(response)
    except HTTPError as error:
        if error.code == 404:
            return
        raise
    metadata = next(asset for asset in latest['assets'] if asset['name'] == 'android-update.json')
    with urlopen(metadata['browser_download_url'], timeout=30) as response:
        previous = json.load(response)
    current_tuple = tuple(map(int, version['version'].split('.')))
    previous_tuple = tuple(map(int, previous['version'].split('.')))
    if current_tuple <= previous_tuple or version['build'] <= previous['build']:
        raise ValueError('Version and build must both increase beyond the latest published release')


def publish(directory):
    version = load_version()
    tag = 'v' + version['version']
    expected = [f"WAMC-{version['version']}.apk", f"WAMC-{version['version']}-arm64.dmg",
                'android-update.json', 'appcast.xml', 'SHA256SUMS']
    for name in expected:
        if not (directory / name).is_file():
            raise ValueError(f'Missing release asset: {name}')
    # A missing release is the only recoverable lookup failure.
    lookup = subprocess.run(['gh', 'api', f'repos/{REPOSITORY}/releases/tags/{tag}'],
                            capture_output=True, text=True)
    if lookup.returncode:
        if '(HTTP 404)' not in lookup.stderr:
            raise RuntimeError(lookup.stderr)
        validate_previous(version)
        run('release', 'create', tag, '--repo', REPOSITORY, '--draft', '--title', f'WAMC {version["version"]}',
            '--notes', 'Signed Android APK and notarized Apple silicon macOS DMG. Source remains private.')
    else:
        existing = json.loads(lookup.stdout)
        if not existing['draft']:
            raise ValueError('This version is already published; published assets are immutable')
        validate_previous(version)
    run('release', 'upload', tag, '--repo', REPOSITORY, '--clobber',
        *(str(directory / name) for name in expected))
    actual = json.loads(run('api', f'repos/{REPOSITORY}/releases/tags/{tag}'))
    if {asset['name'] for asset in actual['assets']} != set(expected):
        raise ValueError('Draft asset set differs from the expected paired release')
    run('release', 'edit', tag, '--repo', REPOSITORY, '--draft=false', '--latest')
    print(f'https://github.com/{REPOSITORY}/releases/tag/{tag}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    publish(parser.parse_args().directory)
