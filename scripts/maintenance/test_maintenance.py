import importlib.util
import os
from pathlib import Path
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
