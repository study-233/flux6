#!/usr/bin/env python3
"""Locate the private Android signing directory and migrate the existing identity."""
import argparse
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
FILES = ('preview.jks', 'password')


def private_file(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise RuntimeError(f'Expected a private user-owned signing file: {path.name}')


def prepare(destination):
    destination = destination.expanduser().absolute()
    if destination.is_symlink() or destination.resolve().is_relative_to(ROOT):
        raise RuntimeError('Signing directory must be outside the repository and not a symlink')
    legacy = ROOT / 'build/mobile-signing'
    present = [name for name in FILES if (legacy / name).exists()]
    if present and len(present) != len(FILES):
        raise RuntimeError('Incomplete legacy signing identity; refusing to rotate it')
    for name in present:
        private_file(legacy / name)
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not destination.exists():
        with tempfile.TemporaryDirectory(prefix='.android-signing-', dir=destination.parent) as tmp:
            stage = Path(tmp) / 'identity'
            stage.mkdir(mode=0o700)
            for name in present:
                shutil.copy2(legacy / name, stage / name)
                os.chmod(stage / name, 0o600)
            stage.rename(destination)
    info = destination.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise RuntimeError('Signing directory must be private and user-owned')
    saved = [name for name in FILES if (destination / name).exists()]
    if saved and len(saved) != len(FILES):
        raise RuntimeError('Incomplete signing identity; refusing to generate a replacement')
    for name in saved:
        private_file(destination / name)
    for name in present:
        if (legacy / name).read_bytes() != (destination / name).read_bytes():
            raise RuntimeError('Existing signing identity differs from the legacy identity')
    return destination


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    data = Path.home() / 'Library/Application Support' if sys.platform == 'darwin' else Path(os.environ.get('XDG_DATA_HOME', Path.home() / '.local/share'))
    default = data / 'FreeV6/Development/android-signing'
    parser.add_argument('--directory', type=Path, default=Path(os.environ.get('FREEV6_SIGNING_DIR', default)))
    print(prepare(parser.parse_args().directory))
