#!/usr/bin/env python3
"""List disposable outputs; pass --apply to remove the selected allowlisted paths."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
GROUPS = {
    'temporary': [
        'build/service-probes', 'build/installer-probes', 'build/native-update-probes',
        'build/update-probes', 'build/flutter-perf', 'build/p5-visual',
        'build/p6-release-validation', 'build/android-arm64-35.zip', 'build/mobile-jdk17.tar.gz',
    ],
    'compile': [
        'build/macos', 'build/macos-module-cache', 'build/macos-go-cache',
        'build/mobile-go-cache', 'build/macos-release-runner',
        'apps/android/build', 'apps/android/.dart_tool', 'apps/macos/flutter_ui/build', 'apps/macos/flutter_ui/.dart_tool',
    ],
    'toolchains': ['build/flutter-toolchain', 'build/mobile-sdk', 'build/go-toolchain', 'build/mobile-toolchain'],
}


def validate(root, relative):
    path = root / relative
    if relative not in {item for group in GROUPS.values() for item in group}:
        raise ValueError('Path is not allowlisted')
    if path.is_symlink() or path.resolve() != root.resolve() / relative:
        raise ValueError(f'Refusing symlink or redirected path: {relative}')
    if path.is_dir():
        for directory, dirs, files in os.walk(path, followlinks=False):
            for name in files:
                if name.endswith(('.jks', '.keystore', '.p12', '.p8', '.keychain-db')) or name == 'password':
                    raise ValueError(f'Signing material found in cleanup target: {relative}')
    return path


def open_files():
    command = shutil.which('lsof') or '/usr/sbin/lsof'
    result = subprocess.run([command, '-n', '-P', '-a', '-u', str(os.getuid()), '-Fn'],
                            capture_output=True, text=True)
    if result.returncode not in (0, 1) or result.stderr.strip():
        raise RuntimeError('Cannot reliably inspect open files; no outputs removed')
    return [line[1:] for line in result.stdout.splitlines() if line.startswith('n/')]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--group', choices=GROUPS, default='temporary')
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    targets = []
    for relative in GROUPS[args.group]:
        path = validate(ROOT, relative)
        if path.exists():
            size = int(subprocess.check_output(['du', '-sk', str(path)], text=True).split()[0])
            targets.append({'path': relative, 'kib': size})
    for target in targets:
        print(f"{target['kib'] / 1024:.1f} MiB\t{target['path']}")
    print(f"Total: {sum(item['kib'] for item in targets) / 1048576:.2f} GiB; apply={args.apply}")
    if args.apply:
        opened = open_files()
        for item in targets:
            prefix = str(ROOT / item['path'])
            if any(name == prefix or name.startswith(prefix + '/') for name in opened):
                raise RuntimeError(f"Target is in use: {item['path']}; no outputs removed")
        for item in targets:
            path = validate(ROOT, item['path'])
            if path.is_dir():
                shutil.rmtree(path)
            else:
                path.unlink()
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps({'group': args.group, 'applied': args.apply, 'targets': targets}, indent=2) + '\n')


if __name__ == '__main__':
    main()
