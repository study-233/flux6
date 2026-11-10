import importlib.util
import json
import os
from pathlib import Path
import plistlib
import tempfile
import unittest


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


HERE = Path(__file__).resolve().parent
clean = module('clean', HERE / 'clean.py')
signing = module('signing', HERE.parent / 'android/prepare-signing.py')
versions = module('versions', HERE.parent / 'version.py')
channel = module('channel', HERE.parent / 'macos/github_channel.py')


class ReleaseLayoutTests(unittest.TestCase):
    def test_platforms_share_a_release_tag_and_keep_their_build_numbers(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            mac = root / 'apps/macos/Resources/Info.plist'
            android = root / 'apps/android/pubspec.yaml'
            windows = root / 'apps/windows/src-tauri'
            mac.parent.mkdir(parents=True)
            android.parent.mkdir(parents=True)
            windows.mkdir(parents=True)
            mac.write_bytes(plistlib.dumps({'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '9'}))
            android.write_text('version: 0.1.0+2026111005\n')
            (windows / 'tauri.conf.json').write_text(json.dumps({'version': '0.1.0'}))
            (windows / 'Cargo.toml').write_text('version = "0.1.0"\n')
            result = versions.versions(root)
            self.assertEqual({value['tag'] for value in result.values()}, {'v0.1.0'})
            self.assertEqual(result['macos']['build'], '9')
            self.assertEqual(result['android']['build'], '2026111005')
            self.assertIsNone(result['windows']['build'])

    def test_update_download_uses_the_shared_version_release(self):
        self.assertEqual(channel.download_base('0.1.0'),
                         'https://github.com/study-233/free-v6/releases/download/v0.1.0')


class MaintenanceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.root = self.base / 'repo'
        self.root.mkdir()
        self.destination = self.base / 'private/android'
        signing.ROOT = self.root

    def legacy(self):
        path = self.root / 'build/mobile-signing'
        path.mkdir(parents=True)
        for name in signing.FILES:
            (path / name).write_bytes(name.encode())
            os.chmod(path / name, 0o600)
        return path

    def test_signing_migration_is_identical_and_repeatable(self):
        source = self.legacy()
        signing.prepare(self.destination)
        signing.prepare(self.destination)
        for name in signing.FILES:
            self.assertEqual((source / name).read_bytes(), (self.destination / name).read_bytes())
            self.assertEqual((self.destination / name).stat().st_mode & 0o777, 0o600)

    def test_signing_mismatch_is_not_overwritten(self):
        self.legacy()
        signing.prepare(self.destination)
        (self.destination / 'password').write_bytes(b'different')
        with self.assertRaises(RuntimeError):
            signing.prepare(self.destination)
        self.assertEqual((self.destination / 'password').read_bytes(), b'different')

    def test_incomplete_identity_is_not_rotated(self):
        source = self.legacy()
        (source / 'password').unlink()
        with self.assertRaises(RuntimeError):
            signing.prepare(self.destination)

    def test_signing_cannot_live_in_repository(self):
        with self.assertRaises(RuntimeError):
            signing.prepare(self.root / 'signing')

    def test_cleanup_rejects_unlisted_path(self):
        with self.assertRaises(ValueError):
            clean.validate(self.root, 'build/mobile-signing')

    def test_cleanup_rejects_redirected_parent(self):
        outside = self.base / 'outside'
        outside.mkdir()
        (self.root / 'build').symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            clean.validate(self.root, 'build/service-probes')

    def test_cleanup_rejects_signing_material(self):
        target = self.root / 'build/service-probes'
        target.mkdir(parents=True)
        (target / 'preview.jks').write_bytes(b'identity')
        with self.assertRaises(ValueError):
            clean.validate(self.root, 'build/service-probes')


if __name__ == '__main__':
    unittest.main()
