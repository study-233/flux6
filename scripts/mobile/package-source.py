#!/usr/bin/env python3
"""Package the APK's corresponding source without caches or signing material."""
from pathlib import Path
import os
import tarfile

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / 'dist/android/FreeV6-0.1.2-preview-source.tar.gz'
OMIT_DIRS = {
    '.git', '.gradle', '.dart_tool', 'build', 'target', 'libclash', 'dist',
    '.idea', '.vscode', '.claude', '.agents', '.github', '__pycache__', '.cxx',
    '.symlinks', 'ephemeral', 'Pods', '.plugin_symlinks',
}
OMIT_FILES = {'local.properties', '.DS_Store', '.flutter-plugins-dependencies', '.packages'}


def sources():
    for name in ('go.mod', 'go.sum', 'LICENSE', 'THIRD-PARTY.txt'):
        yield ROOT / name
    for name in ('mobile', 'mobileapi', 'internal', 'shared', 'scripts/mobile'):
        for directory, dirs, files in os.walk(ROOT / name):
            dirs[:] = sorted(d for d in dirs if d not in OMIT_DIRS)
            for filename in sorted(files):
                path = Path(directory) / filename
                if (filename in OMIT_FILES or filename.startswith('.flutter-')
                        or path.suffix in {'.jks', '.keystore', '.log', '.dill', '.pyc'}):
                    continue
                if path.is_symlink():
                    raise RuntimeError(f'Unexpected source symlink: {path.relative_to(ROOT)}')
                yield path


OUTPUT.parent.mkdir(parents=True, exist_ok=True)
count = 0
with tarfile.open(OUTPUT, 'w:gz') as archive:
    for path in sources():
        archive.add(path, arcname=Path('freev6-android-source') / path.relative_to(ROOT))
        count += 1
print(f'{OUTPUT} ({count} source files)')
