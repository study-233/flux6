#!/usr/bin/env python3
"""Offline packaging checks using synthetic bundle files; never execute binaries."""
import gzip
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

SPEC = importlib.util.spec_from_file_location('windows_source', Path(__file__).with_name('package-source.py'))
source = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(source)


class PackagingTest(unittest.TestCase):
    def test_filter_excludes_private_and_runtime_outputs(self):
        for name in ['apps/windows/flutter_ui/build/app.so', 'apps/windows/config.local.json',
                     'apps/windows/state/warp.json', 'apps/windows/src-tauri/target/app.exe',
                     'apps/windows/signing.pem', 'apps/windows/flutter_ui/.env', 'output/branding/orange.svg']:
            self.assertFalse(source.permitted(name), name)
        for name in ['apps/windows/flutter_ui/lib/live_main.dart', 'cmd/freev6-helper/main.go',
                     'apps/windows/flutter_ui/vendor/flclash/LICENSE', 'scripts/windows/build-flutter.ps1',
                     'scripts/branding/generate-cats.py', 'scripts/branding/export-icons.cjs']:
            self.assertTrue(source.permitted(name), name)

    def test_bundle_notices_archive_and_mutation_detection(self):
        with tempfile.TemporaryDirectory(prefix='freev6-package-test-') as directory:
            root = Path(directory)
            bundle = root / 'bundle'
            assets = bundle / 'data/flutter_assets'
            assets.mkdir(parents=True)
            with gzip.open(assets / 'NOTICES.Z', 'wb') as stream:
                stream.write(b'Synthetic Flutter notice fixture\n')
            manifest = root / 'source.json'
            snapshot = source.inventory()
            manifest.write_bytes(source.encoded(snapshot))
            source.prepare(bundle, manifest)
            archive = root / 'source.zip'
            source.archive(bundle, archive)
            with zipfile.ZipFile(archive) as package:
                names = package.namelist()
                self.assertIn('Flux6-source/apps/windows/flutter_ui/lib/live_main.dart', names)
                self.assertIn('Flux6-source/apps/windows/installer/flutter.nsi', names)
                self.assertIn('Flux6-source/scripts/branding/generate-cats.py', names)
                self.assertIn('Flux6-source/assets/branding/cats/cow.svg', names)
                self.assertEqual(json.loads(package.read('Flux6-source/windows-source-sha256.json')), snapshot)
                self.assertFalse(any('/state/' in name or name.endswith('.exe') for name in names))
            with patch.object(source, 'inventory', return_value={**snapshot, 'changed': 'hash'}):
                with self.assertRaisesRegex(ValueError, 'changed during build'):
                    source.prepare(bundle, manifest)
                with self.assertRaisesRegex(ValueError, 'no longer matches'):
                    source.archive(bundle, archive)


if __name__ == '__main__':
    unittest.main()
