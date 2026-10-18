#!/usr/bin/env python3
"""Prepare an unpublished version from the commit whose build passed."""
import os
from pathlib import Path
import subprocess

from publish import find_release, run
from version import load_version


class ReleasePreparation:
    def __init__(self):
        self.repository = os.environ['GITHUB_REPOSITORY']
        self.commit = subprocess.check_output(
            ['git', 'rev-parse', 'HEAD'], text=True).strip()
        self.version = load_version()
        self.tag = 'v' + self.version['version']

    def prepare(self):
        if os.environ['GITHUB_EVENT_NAME'] == 'push':
            load_version(tag=os.environ['GITHUB_REF_NAME'])
        existing = find_release(self.tag, self.repository)
        if existing is not None and not existing['draft']:
            print(f'{self.tag} is already published; no release needed.')
            return False

        # A new version must not silently reuse a tag pointing at older code.
        result = subprocess.run(['git', 'rev-parse', '--verify', f'refs/tags/{self.tag}^{{commit}}'],
                                text=True, capture_output=True)
        if result.returncode == 0:
            if result.stdout.strip() != self.commit:
                raise ValueError(f'{self.tag} points at another commit; increase the release version')
        else:
            run('api', '--method', 'POST', f'repos/{self.repository}/git/refs',
                '-f', f'ref=refs/tags/{self.tag}', '-f', f'sha={self.commit}')
        print(f'Preparing {self.tag} from {self.commit}')
        return True

    def write_outputs(self):
        release = self.prepare()
        with Path(os.environ['GITHUB_OUTPUT']).open('a') as output:
            output.write(f'release={str(release).lower()}\ntag={self.tag}\ncommit={self.commit}\n')


if __name__ == '__main__':
    ReleasePreparation().write_outputs()
