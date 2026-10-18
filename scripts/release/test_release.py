import json
from pathlib import Path
import plistlib
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

import metadata
import publish
from version import load_version, stamp


class ReleaseToolTests(unittest.TestCase):
    def test_version_rejects_invalid_tag_build_and_semver(self):
        with TemporaryDirectory() as temporary:
            path = Path(temporary) / 'release.json'
            for value in [{'version': '01.2.0', 'build': 4}, {'version': '0.2.0', 'build': True},
                          {'version': '0.2.0', 'build': 3}]:
                path.write_text(json.dumps(value))
                with self.assertRaises(ValueError):
                    load_version(path)
            path.write_text(json.dumps({'version': '0.2.0', 'build': 4}))
            with self.assertRaises(ValueError):
                load_version(path, 'v0.3.0')
            self.assertEqual(load_version(path, 'v0.2.0')['build'], 4)

    def test_stamp_updates_host_and_extension_together(self):
        with TemporaryDirectory() as temporary:
            app = Path(temporary) / 'WAMC.app'
            paths = [app / 'Contents/Info.plist', app / 'Contents/Library/SystemExtensions/camera.systemextension/Contents/Info.plist']
            for path in paths:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(plistlib.dumps({'CFBundleIdentifier': path.parent.name}))
            stamp(app, {'version': '1.2.3', 'build': 100})
            for path in paths:
                info = plistlib.loads(path.read_bytes())
                self.assertEqual(info['CFBundleVersion'], '100')
                self.assertEqual(info['CFBundleShortVersionString'], '1.2.3')

    def test_metadata_requires_both_platforms_and_valid_signature(self):
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            with self.assertRaises(ValueError):
                metadata.generate(directory, 'A' * 86 + '==')
            version = load_version()['version']
            (directory / f'WAMC-{version}.apk').write_bytes(b'apk')
            (directory / f'WAMC-{version}-arm64.dmg').write_bytes(b'dmg')
            with self.assertRaises(ValueError):
                metadata.generate(directory, 'invalid')

    def test_metadata_binds_same_version_and_exact_asset_checksums(self):
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            version = load_version()['version']
            apk = directory / f'WAMC-{version}.apk'
            dmg = directory / f'WAMC-{version}-arm64.dmg'
            apk.write_bytes(b'apk')
            dmg.write_bytes(b'dmg')
            metadata.generate(directory, 'A' * 86 + '==')
            android = json.loads((directory / 'android-update.json').read_text())
            self.assertEqual(android['sha256'], metadata.digest(apk))
            self.assertEqual(android['size'], 3)
            enclosure = ET.parse(directory / 'appcast.xml').find('.//enclosure')
            self.assertIn(f'/releases/download/v{version}/', enclosure.attrib['url'])
            self.assertEqual(enclosure.attrib['length'], '3')
            self.assertEqual(len((directory / 'SHA256SUMS').read_text().splitlines()), 4)

    def test_publishing_missing_artifacts_does_not_contact_github(self):
        with TemporaryDirectory() as temporary, patch.object(publish.subprocess, 'run') as run:
            with self.assertRaises(ValueError):
                publish.publish(Path(temporary))
            run.assert_not_called()

    def test_published_version_is_immutable(self):
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            version = load_version()['version']
            for name in [f'WAMC-{version}.apk', f'WAMC-{version}-arm64.dmg',
                         'android-update.json', 'appcast.xml', 'SHA256SUMS']:
                (directory / name).write_text('existing')
            result = type('Result', (), {'returncode': 0, 'stdout': '{"draft":false}', 'stderr': ''})()
            with patch.object(publish.subprocess, 'run', return_value=result) as run:
                with self.assertRaisesRegex(ValueError, 'already published'):
                    publish.publish(directory)
                self.assertEqual(run.call_count, 1)


if __name__ == '__main__':
    unittest.main()
