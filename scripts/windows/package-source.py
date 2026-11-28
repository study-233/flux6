#!/usr/bin/env python3
"""Package tracked Windows/helper sources and bind them to the built bundle."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[2]
TREES = ('apps/windows/', 'scripts/windows/', 'scripts/branding/', 'cmd/', 'internal/', 'mobileapi/',
         'shared/', 'third_party/', 'assets/branding/', 'profiles/')
FILES = {'LICENSE', 'README.md', 'THIRD-PARTY.txt', 'go.mod', 'go.sum', 'notice.json',
         'docs/agreement.md', 'docs/privacy.md', 'docs/development/windows-flutter-refactor.md',
         'docs/development/windows-flutter-acceptance.md', 'docs/development/repository-maintenance.md',
         'docs/development/README.md', 'scripts/version.py', 'AGENTS.md', '.gitattributes', '.gitignore',
         '.github/workflows/windows-release.yml'}
FORBIDDEN = {'build', 'dist', '.dart_tool', 'ephemeral', 'target', 'state', 'runtime', '.git'}
PRIVATE = {'.key', '.pem', '.p12', '.p8', '.jks', '.keystore', '.exe', '.dll', '.syso'}

UNIFIED_TREES = ('apps/android/', 'apps/flux6/windows_client/', 'scripts/unified/')
UNIFIED_FILES = {'apps/flux6/README.md', 'apps/flux6/LICENSE', 'docs/development/unified-client.md'}


def permitted(name, unified=False):
    path = PurePosixPath(name)
    if path.is_absolute() or '..' in path.parts or '\\' in name or ':' in name:
        return False
    included = name in FILES or name.startswith(TREES)
    if unified:
        included = included or name in UNIFIED_FILES or name.startswith(UNIFIED_TREES)
    # FlClash's Riverpod state definitions are source files.
    forbidden = FORBIDDEN - {'state'} if path.parent == PurePosixPath('apps/android/lib/providers/state') and path.suffix == '.dart' else FORBIDDEN
    return included and not (
        forbidden.intersection(path.parts) or path.suffix.lower() in PRIVATE or
        path.name.startswith('.env') or path.name.endswith('.local.json'))


def tracked(unified=False):
    manifest = ROOT / 'windows-source-sha256.json'
    if not (ROOT / '.git').exists() and manifest.exists():
        return sorted(json.loads(manifest.read_text(encoding='utf-8')))
    try:
        raw = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT)
        return sorted(n for n in raw.decode().split('\0') if n and permitted(n, unified))
    except (subprocess.CalledProcessError, FileNotFoundError):
        # A corresponding-source archive is intentionally buildable without Git.
        if not manifest.exists():
            raise ValueError('Use a Git checkout or an intact corresponding-source archive')
        return sorted(json.loads(manifest.read_text(encoding='utf-8')))


def inventory(unified=False):
    result = {}
    for name in tracked(unified):
        path = ROOT / name
        if not permitted(name, unified) or path.is_symlink() or not path.is_file():
            raise ValueError(f'Unexpected source input: {name}')
        result[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    required = ['apps/windows/flutter_ui/lib/live_main.dart',
                'scripts/windows/build-flutter.ps1', 'apps/windows/installer/flutter.nsi']
    if unified:
        required += ['apps/android/pubspec.lock', 'apps/flux6/windows_client/lib/live_main.dart',
                     'apps/flux6/windows_client/flclash.patch', 'scripts/unified/prepare.py']
    for name in required:
        if name not in result:
            raise ValueError(f'Source is not tracked: {name}. Commit/add the migration sources before packaging.')
    return result


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + '\n').encode()


def prepare(bundle, manifest, unified=False):
    before = json.loads(manifest.read_bytes())
    if before != inventory(unified):
        raise ValueError('Sources changed during build. Rebuild before packaging.')
    notices = bundle / 'NOTICES'
    notices.mkdir(parents=True, exist_ok=True)
    vendor = ROOT / 'apps/windows/flutter_ui/vendor'
    for source, name in ((ROOT / 'LICENSE', 'Flux6-LICENSE.txt'),
                         (ROOT / 'THIRD-PARTY.txt', 'THIRD-PARTY.txt'),
                         (vendor / 'flclash/LICENSE', 'FlClash-GPLv3.txt'),
                         (vendor / 'prism_ui/LICENSE', 'PrismUI-LICENSE.txt'),
                         (vendor / 'prism_ui/NOTICE', 'PrismUI-NOTICE.txt'),
                         (vendor / 'Flutter-LICENSE', 'Flutter-LICENSE.txt'),
                         (vendor / 'UPSTREAM.json', 'UPSTREAM.json'),
                         (vendor / 'MACOS-SOURCE.json', 'MACOS-SOURCE.json'),
                         (vendor / 'WINDOWS-PATCHES.json', 'WINDOWS-PATCHES.json')):
        shutil.copyfile(source, notices / name)
    if unified:
        shutil.copyfile(ROOT / 'apps/android/FREEV6.md', notices / 'Unified-FlClash-sources.md')
        shutil.copyfile(ROOT / 'apps/flux6/LICENSE', notices / 'Unified-FlClash-LICENSE.txt')
    shutil.copytree(ROOT / 'third_party/licenses', notices / 'licenses', dirs_exist_ok=True)
    compressed = bundle / 'data/flutter_assets/NOTICES.Z'
    with gzip.open(compressed, 'rb') as source:
        (notices / 'Flutter-Package-Notices.txt').write_bytes(source.read())
    (notices / 'windows-source-sha256.json').write_bytes(encoded(before))
    flclash = 'a FlClash-derived GPLv3 application' if unified else 'FlClash-derived GPLv3 visual components'
    (notices / 'SOURCES.txt').write_text(
        f'This distribution contains {flclash}, Prism UI, Flutter and Go components.\n'
        'See the individual licenses in this directory. No single license replaces component terms.\n'
        'Distribute the matching Flux6 Windows corresponding-source ZIP alongside this binary.\n'
        'The ZIP contains complete local modifications, build scripts, dependency locks and source revisions.\n'
        'Source entry: https://github.com/study-233/flux6\n', encoding='utf-8')


def archive(bundle, output, unified=False):
    current = inventory(unified)
    if current != json.loads((bundle / 'NOTICES/windows-source-sha256.json').read_bytes()):
        raise ValueError('Source snapshot no longer matches this binary')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent) as staging:
        staged = Path(staging) / output.name
        with zipfile.ZipFile(staged, 'w', compression=zipfile.ZIP_DEFLATED) as dest:
            for name in ['windows-source-sha256.json', *current]:
                if name in current:
                    data = (ROOT / name).read_bytes()
                    if hashlib.sha256(data).hexdigest() != current[name]:
                        raise ValueError(f'Source changed while packaging: {name}')
                else:
                    data = encoded(current)
                info = zipfile.ZipInfo('Flux6-source/' + name)
                info.create_system = 3
                info.external_attr = 0o100644 << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                dest.writestr(info, data)
        staged.replace(output)
    print(f'Corresponding source: {len(current)} files; SHA256 {hashlib.sha256(output.read_bytes()).hexdigest()}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['snapshot', 'prepare', 'archive'])
    parser.add_argument('--unified', action='store_true')
    parser.add_argument('--manifest', type=Path)
    parser.add_argument('--bundle', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.command == 'snapshot':
        args.manifest.parent.mkdir(parents=True, exist_ok=True)
        args.manifest.write_bytes(encoded(inventory(args.unified)))
    elif args.command == 'prepare':
        prepare(args.bundle, args.manifest, args.unified)
    else:
        archive(args.bundle, args.output, args.unified)


if __name__ == '__main__':
    main()
