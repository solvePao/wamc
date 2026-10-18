#!/usr/bin/env python3
"""Copy Sparkle's release framework and sign nested updater executables first."""
import argparse
import os
from pathlib import Path
import subprocess

MACOS = Path(__file__).resolve().parents[1]


def embed(app):
    frameworks = list((MACOS / '.build/artifacts').glob('**/Sparkle.xcframework/macos-*/Sparkle.framework'))
    if len(frameworks) != 1:
        raise ValueError(f'Expected one resolved Sparkle macOS framework, found {len(frameworks)}')
    destination = app / 'Contents/Frameworks/Sparkle.framework'
    destination.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['ditto', str(frameworks[0]), str(destination)], check=True)
    # Sign real versioned paths only; framework symlinks must remain untouched.
    nested = [path for path in destination.rglob('*')
              if not path.is_symlink() and (path.suffix in ('.xpc', '.app') or path.name == 'Autoupdate')]
    for path in sorted(nested, key=lambda path: len(path.parts), reverse=True) + [destination]:
        subprocess.run(['codesign', '--force', '--sign', os.environ['SIGN_IDENTITY'],
                        '--options', 'runtime', '--timestamp', '--preserve-metadata=entitlements', str(path)], check=True)



if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    embed(parser.parse_args().app)
