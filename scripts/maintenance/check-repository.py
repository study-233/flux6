#!/usr/bin/env python3
"""Check platform layout, version sources, component pins and documentation links."""
import ast
import hashlib
import json
from pathlib import Path
import re
import runpy
import subprocess
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[2]


def check():
    errors = []
    for name in ('macos', 'mobile', 'web', 'src-tauri'):
        if (ROOT / name).exists():
            errors.append(f'Obsolete root platform directory: {name}')
    for platform in ('macos', 'android', 'windows', 'ios', 'openwrt'):
        if not (ROOT / 'apps' / platform).is_dir():
            errors.append(f'Missing platform: {platform}')
    for platform in ('ios', 'openwrt'):
        paths = [p.name for p in (ROOT / 'apps' / platform).iterdir() if p.name != '.DS_Store']
        if paths != ['README.md']:
            errors.append(f'{platform} must remain a documentation-only placeholder')
    versions = runpy.run_path(str(ROOT / 'scripts/version.py'))['versions']()
    module = ROOT / 'apps/android/core/go.mod'
    match = re.search(r'^replace github.com/yourname/freev6 => (.+)$', module.read_text(), re.M)
    if not match or (module.parent / match[1]).resolve() != ROOT:
        errors.append('Android Go module does not resolve the shared root module')
    windows = ROOT / 'apps/windows/src-tauri'
    config = json.loads((windows / 'tauri.conf.json').read_text())
    for relative in [config['build']['frontendDist'], *config['bundle']['icon'], *config['bundle']['resources']]:
        if relative.endswith('GeoSite.dat'):
            continue
        if not (windows / relative).exists():
            errors.append(f'Missing Windows bundle input: {relative}')
    vendor = ROOT / 'apps/macos/flutter_ui/vendor'
    inventory = json.loads((vendor / 'UPSTREAM.json').read_text())['Prism UI']
    mobile = ROOT / 'apps/android/plugins/prism_ui'
    for name, expected in inventory['files'].items():
        original = mobile / name
        if not original.is_file():
            errors.append(f'Missing Android Prism source: {name}')
            continue
        data = original.read_bytes()
        blob = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
        if blob != expected:
            errors.append(f'Unrecorded Android Prism change: {name}')
    runpy.run_path(str(ROOT / 'scripts/macos/flutter-source-release.py'))['verify_components'](vendor)
    runpy.run_path(str(ROOT / 'scripts/windows/check-sources.py'))['check']()
    markdown = list((ROOT / 'docs').rglob('*.md')) + list((ROOT / 'shared').rglob('*.md'))
    markdown += [ROOT / name for name in (
        'README.md', 'apps/macos/README.md', 'apps/macos/DEVELOPMENT.md',
        'apps/macos/flutter_ui/README.md', 'apps/android/README.md', 'apps/android/FREEV6.md',
        'apps/windows/README.md', 'apps/windows/src-tauri/README.md',
        'apps/windows/flutter_ui/README.md', 'apps/windows/flutter_ui/DEVELOPMENT.md',
        'apps/ios/README.md', 'apps/openwrt/README.md',
    )]
    for path in markdown:
        if not path.is_file():
            errors.append(f'Missing guide: {path.relative_to(ROOT)}')
            continue
        for raw in re.findall(r'\]\(([^\n]+?)\)', path.read_text()):
            link = unquote(raw.strip('<>').split('#', 1)[0])
            if not link or '://' in link or link.startswith(('mailto:', '/')):
                continue
            target = (path.parent / link).resolve()
            if target.is_relative_to(ROOT / 'build') or target.is_relative_to(ROOT / 'dist'):
                continue
            if not target.exists():
                errors.append(f'{path.relative_to(ROOT)}: missing link {link}')
    for path in (ROOT / 'scripts').rglob('*.py'):
        ast.parse(path.read_text(), filename=str(path))
    for path in (ROOT / 'scripts').rglob('*.sh'):
        subprocess.run(['bash', '-n', path], check=True)
    if (ROOT / '.git').exists():
        tracked = set(subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0'))
        android_sources = runpy.run_path(str(ROOT / 'scripts/android/package-source.py'))['sources']()
        macos_sources = runpy.run_path(str(ROOT / 'scripts/macos/flutter-source-release.py'))['sources']()
        inputs = {str(path.relative_to(ROOT)) for path in android_sources} | set(macos_sources)
        for path in sorted(inputs - tracked):
            errors.append(f'Untracked build/source-package input: {path}')
    if errors:
        raise SystemExit('\n'.join(errors))
    print('Repository checks passed: ' + ', '.join(f'{p} {v["version"]}' for p, v in versions.items()))


if __name__ == '__main__':
    check()
