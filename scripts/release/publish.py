#!/usr/bin/env python3
"""Publish a complete paired release; never mutate a published version."""
import argparse
import json
from pathlib import Path
import subprocess
import time
from version import load_version

REPOSITORY = 'solvePao/wamc'


def run(*args):
    try:
        return subprocess.run(['gh', *args], check=True, text=True, capture_output=True).stdout
    except subprocess.CalledProcessError as error:
        raise RuntimeError(error.stderr.strip() or 'GitHub release command failed') from error


def validate_previous(version, repository=REPOSITORY):
    try:
        latest = json.loads(run('api', f'repos/{repository}/releases/latest'))
    except RuntimeError as error:
        if isinstance(error.__cause__, subprocess.CalledProcessError) and 'HTTP 404' in error.__cause__.stderr:
            return
        raise
    previous = json.loads(run('release', 'download', latest['tag_name'], '--repo', repository,
                              '--pattern', 'android-update.json', '--output', '-'))
    current_tuple = tuple(map(int, version['version'].split('.')))
    previous_tuple = tuple(map(int, previous['version'].split('.')))
    if current_tuple <= previous_tuple or version['build'] <= previous['build']:
        raise ValueError('Version and build must both increase beyond the latest published release')


def find_release(tag, repository=REPOSITORY):
    # GitHub's tag endpoint cannot resolve a draft before its tag exists.
    pages = json.loads(run('api', '--paginate', '--slurp',
                           f'repos/{repository}/releases?per_page=100'))
    matches = [release for page in pages for release in page if release['tag_name'] == tag]
    if len(matches) > 1:
        raise ValueError('Multiple releases use this tag; resolve duplicate drafts before publishing')
    return matches[0] if matches else None


def publish(directory, repository=REPOSITORY):
    version = load_version()
    tag = 'v' + version['version']
    expected = [f"WAMC-{version['version']}.apk", f"WAMC-{version['version']}-arm64.dmg",
                'android-update.json', 'appcast.xml', 'SHA256SUMS']
    for name in expected:
        if not (directory / name).is_file():
            raise ValueError(f'Missing release asset: {name}')
    existing = find_release(tag, repository)
    if existing is not None and not existing['draft']:
        raise ValueError('This version is already published; published assets are immutable')
    validate_previous(version, repository)
    if existing is None:
        run('release', 'create', tag, '--repo', repository, '--draft', '--title', f'WAMC {version["version"]}',
            '--notes', 'Signed Android APK and notarized Apple silicon macOS DMG. Source: https://github.com/solvePao/wamc.')
        existing = find_release(tag, repository)
        # Newly created drafts can briefly be absent from GitHub's release list.
        for _ in range(3):
            if existing is not None:
                break
            time.sleep(2)
            existing = find_release(tag, repository)
        if existing is None or not existing['draft']:
            raise ValueError('Expected the newly created draft release')
    run('release', 'upload', tag, '--repo', repository, '--clobber',
        *(str(directory / name) for name in expected))
    actual = json.loads(run('api', f'repos/{repository}/releases/{existing["id"]}'))
    if not actual['draft'] or actual['tag_name'] != tag:
        raise ValueError('Release is no longer the expected draft')
    if {asset['name'] for asset in actual['assets']} != set(expected):
        raise ValueError('Draft asset set differs from the expected paired release')
    run('release', 'edit', tag, '--repo', repository, '--draft=false', '--latest')
    print(f'https://github.com/{repository}/releases/tag/{tag}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--repository', default=REPOSITORY,
                        choices=[REPOSITORY])
    arguments = parser.parse_args()
    publish(arguments.directory, arguments.repository)
