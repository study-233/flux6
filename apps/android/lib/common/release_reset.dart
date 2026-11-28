import 'dart:io';

import 'package:fl_clash/common/path.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

/// The bootstrap has exclusive ownership of this directory before Drift opens.
Future<void> resetLegacyFlux6() async {
  final home = Directory(await appPath.homeDirPath);
  final leaf = path.basename(home.path);
  final parent = path.basename(home.parent.path);
  final owned = switch (Platform.operatingSystem) {
    'android' =>
      leaf == 'files' &&
          (parent == 'dev.freev6.mobile' || parent == 'dev.freev6.mobile.dev'),
    'macos' => leaf == 'dev.freev6.desktop',
    'windows' => leaf == 'Flux6' && parent == 'Flux6',
    _ => false,
  };
  if (!owned) {
    throw const FileSystemException('Unrecognized Flux6 data directory');
  }
  final prefs = await SharedPreferences.getInstance();
  await resetReleaseDirectory(
    home,
    clearOtherStores: () async {
      if (Platform.isAndroid || Platform.isMacOS) {
        await const MethodChannel(
          'dev.freev6.mobile/storage',
        ).invokeMethod<void>('clearLegacy');
      }
      if (Platform.isWindows) {
        final local = Platform.environment['LOCALAPPDATA'];
        for (final base in {local, Platform.environment['APPDATA']}.nonNulls) {
          if (path.isAbsolute(base)) {
            await _deleteOwned(path.join(base, 'dev.freev6.desktop'));
          }
        }
        final installations = {
          File(Platform.resolvedExecutable).parent.path,
          if (local != null) path.join(local, 'FreeV6'),
        };
        for (final key in ['Flux6', 'FreeV6']) {
          for (final view in [32, 64]) {
            final record = await Process.run('reg.exe', [
              'query',
              'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\$key',
              '/v',
              'InstallLocation',
              '/reg:$view',
            ]);
            if (record.exitCode == 0) {
              final match = RegExp(
                r'InstallLocation\s+REG_SZ\s+(.+)',
                caseSensitive: false,
              ).firstMatch(record.stdout.toString());
              if (match != null) {
                installations.add(match[1]!.trim().replaceAll('"', ''));
              }
            }
          }
        }
        for (final install in installations) {
          await clearLegacyWindowsFiles(install);
        }
      }
      if (!await prefs.clear()) {
        throw const FileSystemException('Could not reset Flux6 preferences');
      }
    },
  );
}

/// A portable install can share a folder with the user's own files.
Future<void> clearLegacyWindowsFiles(String install) async {
  if (!path.isAbsolute(install) ||
      await FileSystemEntity.type(install, followLinks: false) !=
          FileSystemEntityType.directory) {
    return;
  }
  Future<bool> file(String name) async =>
      await FileSystemEntity.type(
        path.join(install, name),
        followLinks: false,
      ) ==
      FileSystemEntityType.file;
  if (!await file('freev6-desktop.exe') ||
      !(await file('flux6-helper.exe') || await file('freev6-helper.exe'))) {
    return;
  }
  for (final group in {
    'config': [
      'settings.json',
      'network-options.json',
      'chain-proxy.yaml',
      'cloud-profile-study-233-free-v6.yaml',
    ],
    'state': [
      'warp.json',
      'mihomo.yaml',
      'flutter-ui.json',
      'node-quality.json',
      'cloud-config.log',
      'mihomo.log',
      'mihomo-controller.secret',
      'cache.db',
    ],
  }.entries) {
    final parent = path.join(install, group.key);
    if (await FileSystemEntity.type(parent, followLinks: false) !=
        FileSystemEntityType.directory) {
      continue;
    }
    for (final name in group.value) {
      final target = path.join(parent, name);
      if (await FileSystemEntity.type(target, followLinks: false) ==
          FileSystemEntityType.file) {
        await File(target).delete();
      }
    }
  }
}

Future<void> resetReleaseDirectory(
  Directory home, {
  required Future<void> Function() clearOtherStores,
}) async {
  if (await FileSystemEntity.type(home.path, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw const FileSystemException('Expected an application data directory');
  }
  final marker = File(path.join(home.path, '.flux6-data-v2'));
  if (await FileSystemEntity.type(marker.path, followLinks: false) ==
          FileSystemEntityType.file &&
      await marker.readAsString() == '2') {
    return;
  }
  // The lock belongs to this running process and must retain its inode.
  await for (final entity in home.list(followLinks: false)) {
    if (path.basename(entity.path) == 'FlClash.lock') continue;
    await _deleteOwned(entity.path);
  }
  await clearOtherStores();
  final next = File(path.join(home.path, '.flux6-data-v2.tmp'));
  await next.writeAsString('2', flush: true);
  await next.rename(marker.path);
}

Future<void> _deleteOwned(String target) async {
  final type = await FileSystemEntity.type(target, followLinks: false);
  if (type == FileSystemEntityType.notFound) return;
  if (type == FileSystemEntityType.link) {
    await Link(target).delete();
  } else if (type == FileSystemEntityType.directory) {
    final directory = Directory(target);
    await for (final child in directory.list(followLinks: false)) {
      await _deleteOwned(child.path);
    }
    await directory.delete();
  } else {
    await File(target).delete();
  }
}
