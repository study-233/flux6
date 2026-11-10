#!/usr/bin/env python3
"""Package Android sources with manifests, build scripts and corresponding licenses."""
import argparse
import hashlib
from pathlib import Path
import os
import runpy
import tarfile

ROOT = Path(__file__).resolve().parents[2]
OMIT_DIRS = {
    '.git', '.gradle', '.dart_tool', 'build', 'target', 'libclash', 'dist',
    '.idea', '.vscode', '.claude', '.github', '__pycache__', '.cxx', '.kotlin',
    '.symlinks', 'ephemeral', 'Pods', '.plugin_symlinks',
}
OMIT_FILES = {'local.properties', '.DS_Store', '.flutter-plugins-dependencies', '.packages', 'GeneratedPluginRegistrant.java'}


def sources():
    for name in ('go.mod', 'go.sum', 'LICENSE', 'THIRD-PARTY.txt', 'README.md', 'AGENTS.md', 'scripts/version.py'):
        yield ROOT / name
    for name in ('apps/android', 'mobileapi', 'internal', 'shared', 'scripts/android', 'assets/branding', 'scripts/branding'):
        for directory, dirs, files in os.walk(ROOT / name):
            dirs[:] = sorted(d for d in dirs if d not in OMIT_DIRS)
            for filename in sorted(files):
                path = Path(directory) / filename
                if (filename in OMIT_FILES or filename.startswith('.flutter-')
                        or path.suffix in {'.jks', '.keystore', '.p12', '.p8', '.log', '.dill', '.pyc'}):
                    continue
                if path.is_symlink():
                    raise RuntimeError(f'Unexpected source symlink: {path.relative_to(ROOT)}')
                yield path


def main():
    version = runpy.run_path(str(ROOT / 'scripts/version.py'))['versions'](platform='android')['android']
    destination = ROOT / 'dist/android' / f"{version['version']}-b{version['build']}"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, default=destination)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    output = args.output_dir / f"FreeV6-{version['version']}-b{version['build']}-preview-source.tar.gz"
    temporary = output.with_suffix('.tmp')
    count = 0
    try:
        with tarfile.open(temporary, 'w:gz') as archive:
            for path in sources():
                archive.add(path, arcname=Path('freev6-android-source') / path.relative_to(ROOT), recursive=False)
                count += 1
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    (args.output_dir / 'SOURCE-SHA256SUMS').write_text(f'{digest}  {output.name}\n')
    print(f'{output} ({count} source files)')


if __name__ == '__main__':
    main()
