"""Assemble an isolated FlClash candidate from the shared tracked application sources."""
import argparse
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'apps/android'
CANDIDATE = ROOT / 'apps/flux6'


def prepare(android_client=False):
    build = ROOT / 'build'
    build.mkdir(exist_ok=True)
    # core/go.mod imports the root Go module via ../../.. on all three targets.
    prefix = 'unified-android-client-' if android_client else 'unified-preview-'
    output = Path(tempfile.mkdtemp(prefix=prefix, dir=build))
    try:
        tracked = subprocess.check_output(
            ['git', 'ls-files', '-z', '--', 'apps/android'], cwd=ROOT
        ).decode().split('\0')
        for name in filter(None, tracked):
            source = ROOT / name
            relative = source.relative_to(APP)
            if relative.parts[0] in {'.agents', 'AGENTS.md'}:
                continue
            target = output / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        gradle = output / 'android/app/build.gradle.kts'
        original = gradle.read_text()
        production_id = 'applicationId = "dev.freev6.mobile"'
        if original.count(production_id) != 1:
            raise ValueError('Android application ID changed; check preview isolation')
        package = 'dev.flux6.unified.client' if android_client else 'dev.flux6.unified.preview'
        gradle.write_text(original.replace(production_id, f'applicationId = "{package}"'))
        if not android_client:
            add_preview(output)
    except BaseException:
        shutil.rmtree(output)
        raise
    return output


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
    parser.add_argument('--android-client', action='store_true',
                        help='assemble the full Flutter app with Android VPN and isolated app ID')
    print(prepare(parser.parse_args().android_client))
