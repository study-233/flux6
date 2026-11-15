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
    for name, manifest_path in [('android', 'apps/android/pubspec.yaml'),
                                ('windows', 'apps/windows/flclash_ui/pubspec.yaml')]:
        if platform is not None and platform != name:
            continue
        match = re.search(r'^version:\s*(\S+)\s*$', (root / manifest_path).read_text(), re.M)
        if match is None or '+' not in match[1]:
            raise ValueError(f'{name} requires a version and build number')
        version, build = match[1].split('+', 1)
        data[name] = {'version': version, 'build': build}
    for platform, item in data.items():
        if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[\w.-]+)?', item['version']):
            raise ValueError(f'Invalid {platform} version')
        if item['build'] is not None and not re.fullmatch(r'[1-9]\d*', str(item['build'])):
            raise ValueError(f'Invalid {platform} build')
        item['tag'] = f"v{item['version']}"
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
