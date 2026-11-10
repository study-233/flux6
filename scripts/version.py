#!/usr/bin/env python3
"""Read platform release versions from their authoritative application manifests."""
import argparse
import json
from pathlib import Path
import plistlib
import re

ROOT = Path(__file__).resolve().parents[1]


def versions(root=ROOT, platform=None):
    data = {}
    if platform in (None, 'macos'):
        manifest = plistlib.loads((root / 'apps/macos/Resources/Info.plist').read_bytes())
        data['macos'] = {'version': manifest['CFBundleShortVersionString'], 'build': manifest['CFBundleVersion']}
    if platform in (None, 'android'):
        android = re.search(r'^version:\s*(\S+)\s*$', (root / 'apps/android/pubspec.yaml').read_text(), re.M)
        if android is None or '+' not in android[1]:
            raise ValueError('Android requires a version and build number')
        version, build = android[1].split('+', 1)
        data['android'] = {'version': version, 'build': build}
    if platform in (None, 'windows'):
        windows = json.loads((root / 'apps/windows/src-tauri/tauri.conf.json').read_text())['version']
        cargo = re.search(r'^version\s*=\s*"([^"]+)"', (root / 'apps/windows/src-tauri/Cargo.toml').read_text(), re.M)
        if cargo is None or cargo[1] != windows:
            raise ValueError('Windows Tauri and Cargo versions differ')
        data['windows'] = {'version': windows, 'build': None}
    for platform, item in data.items():
        if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[\w.-]+)?', item['version']):
            raise ValueError(f'Invalid {platform} version')
        if item['build'] is not None and not re.fullmatch(r'[1-9]\d*', str(item['build'])):
            raise ValueError(f'Invalid {platform} build')
        suffix = f"-b{item['build']}" if item['build'] is not None else ''
        item['tag'] = f"{platform}-v{item['version']}{suffix}"
    return data


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=('macos', 'android', 'windows'))
    parser.add_argument('--field', choices=('version', 'build', 'tag'))
    args = parser.parse_args()
    data = versions(platform=args.platform)
    if args.field and not args.platform:
        parser.error('--field requires --platform')
    selected = data[args.platform] if args.platform else data
    print(selected[args.field] if args.field else json.dumps(selected, ensure_ascii=False, indent=2))
