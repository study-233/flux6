"""Assemble an isolated FlClash candidate from the shared tracked application sources."""
import argparse
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

from source_inputs import files

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'apps/android'
CANDIDATE = ROOT / 'apps/flux6'


def copy_tracked(source_dir, output, exclude=()):
    for name in files(source_dir.relative_to(ROOT).as_posix()):
        source = ROOT / name
        relative = source.relative_to(source_dir)
        if relative.parts[0] in {'.agents', 'AGENTS.md', *exclude}:
            continue
        destination = output / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)


def prepare(target):
    build = ROOT / 'build'
    build.mkdir(exist_ok=True)
    # core/go.mod imports the root Go module via ../../.. on all three targets.
    prefix = f'unified-{target}-'
    output = Path(tempfile.mkdtemp(prefix=prefix, dir=build))
    try:
        copy_tracked(APP, output)
        gradle = output / 'android/app/build.gradle.kts'
        original = gradle.read_text()
        production_id = 'applicationId = "dev.freev6.mobile"'
        if original.count(production_id) != 1:
            raise ValueError('Android application ID changed; check preview isolation')
        package = 'dev.flux6.unified.preview' if target == 'preview' else 'dev.flux6.unified.client'
        if target != 'upgrade-client':
            gradle.write_text(original.replace(production_id, f'applicationId = "{package}"'))
        if target == 'preview':
            add_preview(output)
        elif target in {'client', 'upgrade-client'}:
            add_client(output)
        elif target == 'windows-client':
            add_windows_client(output)
    except BaseException:
        shutil.rmtree(output)
        raise
    return output


def add_client(output):
    host = ROOT / 'apps/macos/flutter_ui'
    copy_tracked(host / 'macos', output / 'macos')
    copy_tracked(host / 'lib', output / 'lib/mac_host', exclude=('preview', 'main.dart'))
    shutil.copy2(host / 'analysis_options.yaml', output / 'lib/mac_host/analysis_options.yaml')
    copy_tracked(host / 'assets', output / 'assets')
    # Apply the recorded Mac accessibility label fix to the common Prism sidebar.
    shutil.copy2(host / 'vendor/prism_ui/lib/sidebar.dart', output / 'plugins/prism_ui/lib/sidebar.dart')
    project = output / 'macos/Runner.xcodeproj/project.pbxproj'
    content = project.read_text()
    package = 'relativePath = "../..";'
    if content.count(package) != 1:
        raise ValueError('Cannot locate the native Flux6 Swift package')
    project.write_text(content.replace(package, 'relativePath = "../../../apps/macos";'))
    manifest = output / 'pubspec.yaml'
    content = manifest.read_text()
    assets = 'flutter:\n  assets:\n'
    if content.count(assets) != 1:
        raise ValueError('Cannot locate Flutter assets')
    manifest.write_text(content.replace(assets, 'flutter:\n  uses-material-design: true\n  assets:\n    - assets/branding/cats/\n'))
    (output / 'lib/main.dart').rename(output / 'lib/android_main.dart')
    for name in ('main.dart', 'mac_navigation.dart'):
        shutil.copy2(CANDIDATE / 'client' / name, output / 'lib' / name)
    shutil.copy2(CANDIDATE / 'client/mac_navigation_test.dart', output / 'test/unified_mac_navigation_test.dart')


def add_windows_client(output):
    integration = CANDIDATE / 'windows_client'
    copy_tracked(ROOT / 'apps/windows/flutter_ui/windows', output / 'windows')
    subprocess.run(['git', 'apply', '--ignore-space-change', '--whitespace=nowarn',
                    '--directory=' + output.relative_to(ROOT).as_posix(),
                    integration / 'flclash.patch'], cwd=ROOT, check=True)
    for directory in ('lib', 'test'):
        shutil.copytree(integration / directory, output / directory, dirs_exist_ok=True)
    # The normal Windows entry always negotiates the live native host.
    shutil.copy2(integration / 'lib/live_main.dart', output / 'lib/main.dart')
    legal = output / 'assets/legal'
    legal.mkdir(exist_ok=True)
    shutil.copy2(ROOT / 'LICENSE', legal / 'FreeV6-LICENSE.txt')
    for arb in (output / 'arb').glob('intl_*.arb'):
        source = integration / 'arb' / ('intl_zh_CN.arb' if arb.stem == 'intl_zh_CN' else 'intl_en.arb')
        strings = json.loads(arb.read_text(encoding='utf-8'))
        additions = json.loads(source.read_text(encoding='utf-8'))
        for key, value in additions.items():
            if key in strings and strings[key] != value:
                raise ValueError(f'Conflicting translation in {arb.name}: {key}')
            strings[key] = value
        arb.write_text(json.dumps(strings, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def add_preview(output):
    for platform in ('macos', 'windows'):
        shutil.copytree(CANDIDATE / platform, output / platform)
    shutil.copy2(CANDIDATE / 'preview/main.dart', output / 'lib/main.dart')
    shutil.copy2(CANDIDATE / 'preview/node_groups_test.dart', output / 'test/unified_node_groups_test.dart')
    shutil.copy2(CANDIDATE / 'preview/desktop_profile_test.dart', output / 'test/unified_desktop_profile_test.dart')
    config = json.loads((ROOT / 'shared/fixtures/warp-business-configuration.json').read_text())
    groups = [{'name': group['name'], 'proxies': group['proxies']}
              for group in config['proxy-groups']]
    (output / 'assets/data/preview-groups.json').write_text(json.dumps(groups, ensure_ascii=False), encoding='utf-8')
    manifests = output / 'android/app/src'
    shutil.copy2(CANDIDATE / 'preview/android/AndroidManifest.xml', manifests / 'main/AndroidManifest.xml')
    (manifests / 'debug/AndroidManifest.xml').unlink()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--android-client', dest='target', action='store_const', const='android-client',
                       help='assemble the Android-only compatibility candidate')
    modes.add_argument('--windows-client', dest='target', action='store_const', const='windows-client',
                       help='assemble the full Windows client with the native host')
    modes.add_argument('--client', dest='target', action='store_const', const='client',
                       help='assemble one Flutter application with Android and macOS hosts')
    modes.add_argument('--upgrade-client', dest='target', action='store_const', const='upgrade-client',
                       help='assemble the same client using the existing Android application ID')
    parser.set_defaults(target='preview')
    print(prepare(parser.parse_args().target))
