#!/usr/bin/env python3
"""Verify the pinned FlClash export, local patches and offline entry boundary."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'apps/windows/flclash_ui'


def read(name):
    return (APP / name).read_text(encoding='utf-8-sig')


def check():
    upstream = json.loads(read('vendor/UPSTREAM.json'))
    patches = json.loads(read('vendor/FREEV6-PATCHES.json'))
    assert upstream['revision'] == 'be84736605527034689c95bf27828ff27d912c5e'
    assert upstream['prismRevision'] == '63450c0ac0e8e1b2c0f3ed4ad7926dc94e083185'
    assert patches['revision'] == upstream['revision']
    assert set(patches['files']) <= set(upstream['files'])
    for name, original in upstream['files'].items():
        file = APP / name
        assert file.is_file(), f'Missing upstream source: {name}'
        expected = patches['files'].get(name, {}).get('sha256', original)
        actual = hashlib.sha256(file.read_bytes()).hexdigest()
        assert actual == expected, f'Unrecorded source change: {name}'
        if name in patches['files']:
            assert actual != original, f'Redundant patch: {name}'
            assert patches['files'][name]['reason'], f'Missing patch reason: {name}'

    entry = read('lib/freev6/offline_main.dart')
    assert "bool.fromEnvironment('FREEV6_OFFLINE') || !safeModeBuild" in entry
    assert 'HttpOverrides.global = OfflineHttpGuard()' in entry
    assert "throw StateError('This offline preview cannot create an HTTP client')" in entry
    assert 'FreeV6Session(OfflineFreeV6Model())' in entry
    for forbidden in ('bootstrap.init', 'RustLib.init', 'CoreManager(', 'TrayManager(',
                      'HotkeyManager(', 'ProxyManager(', 'LiveModel('):
        assert forbidden not in entry, f'Unexpected runtime initializer: {forbidden}'
    assert "freev6/offline_main.dart" in read('lib/main.dart')
    session = read('lib/freev6/session.dart')
    assert 'if (!model.preview && !backend)' in session
    assert 'final guard = GuardedCore(blockedCoreCalls)' in session
    assert 'CoreController.adapter(guard)' in session
    assert 'extends PreviewModel' in session
    assert 'LiveModel(' not in session
    fixture_entry = read('lib/fixture_main.dart')
    assert "bool.fromEnvironment('FREEV6_OFFLINE') || !safeModeBuild" in fixture_entry
    assert 'HttpOverrides.global = OfflineHttpGuard()' in fixture_entry
    assert 'if (!nativeInfo.preview)' in fixture_entry
    assert 'FreeV6OfflineFixture()' in fixture_entry
    fixture = read('lib/freev6/offline_fixture.dart')
    for forbidden in ('IoTransport(', 'HttpClient(', 'Process.start', 'Process.run', 'WindowsHost('):
        assert forbidden not in fixture, f'Fixture escaped its injectable boundary: {forbidden}'
    assert 'LiveModel(' in fixture and 'FixtureTransport()' in fixture and 'FixtureHost()' in fixture
    live = read('lib/live_main.dart')
    assert "bool.fromEnvironment('FREEV6_BACKEND')" in live
    assert 'LiveModel(' in live and 'PreviewModel(' not in live
    assert 'if ((await host.describe()).preview)' in live
    native = read('windows/runner/CMakeLists.txt')
    assert 'flutter_ui/windows/runner' in native and 'host_bridge.cpp' in native
    assert 'if(FREEV6_LIVE)' in native and 'requireAdministrator' in native
    pubspec = read('pubspec.yaml')
    assert pubspec.count('build_assets: false') == 2
    assert 'path: ../flutter_ui' in pubspec
    cmake = read('windows/CMakeLists.txt')
    for forbidden in ('CORE_ARTIFACTS_DIR', 'EnableLoopback.exe', 'Stop-Process',
                      'FlClashCore.exe', 'FlClashHelper.exe'):
        assert forbidden not in cmake, f'Unexpected native build action: {forbidden}'
    assert 'asInvoker' in read('windows/runner/runner.exe.manifest')
    assert '--clear-stale-proxy' not in read('windows/runner/main.cpp')
    arbs = [json.loads(file.read_text(encoding='utf-8')) for file in (APP / 'arb').glob('*.arb')]
    keys = [{key for key in arb if key.startswith('freev6')} for arb in arbs]
    assert len(keys) == 7 and all(keyset == keys[0] for keyset in keys)
    print(f'FlClash sources: {len(upstream["files"])} pinned files, '
          f'{len(patches["files"])} recorded patches; offline boundary verified')


if __name__ == '__main__':
    check()
