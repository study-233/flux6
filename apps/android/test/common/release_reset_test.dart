import 'dart:io';
import 'package:fl_clash/common/release_reset.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a legacy portable folder clears only Flux6-owned records', () async {
    final root = await Directory.systemTemp.createTemp('flux6-portable');
    addTearDown(() => root.delete(recursive: true));
    final state = await Directory('${root.path}/state').create();
    final credentials = await File(
      '${state.path}/warp.json',
    ).writeAsString('fixture');
    final unrelated = await File(
      '${state.path}/notes.txt',
    ).writeAsString('keep');
    final recovery = await File(
      '${state.path}/network-snapshot.json',
    ).writeAsString('recovery');
    await clearLegacyWindowsFiles(root.path);
    expect(await credentials.exists(), isTrue);
    await File('${root.path}/freev6-desktop.exe').create();
    await File('${root.path}/flux6-helper.exe').create();
    await clearLegacyWindowsFiles(root.path);
    expect(await credentials.exists(), isFalse);
    expect(await unrelated.exists(), isTrue);
    expect(await recovery.exists(), isTrue);
  });

  test(
    'interrupted reset finishes once and keeps new profiles and external links safe',
    () async {
      final temp = await Directory.systemTemp.createTemp('flux6-reset-test');
      addTearDown(() => temp.delete(recursive: true));
      final home = await Directory('${temp.path}/data').create();
      final outside = await Directory('${temp.path}/external').create();
      final preserved = await File(
        '${outside.path}/keep',
      ).writeAsString('external');
      final lock = await File(
        '${home.path}/FlClash.lock',
      ).writeAsString('held');
      final profile = await File('${home.path}/profile').writeAsString('old');
      if (!Platform.isWindows) {
        await Link('${home.path}/external').create(outside.path);
      }
      await expectLater(
        resetReleaseDirectory(
          home,
          clearOtherStores: () async => throw StateError('locked'),
        ),
        throwsStateError,
      );
      var writes = 0;
      Future<void> clear() async {
        writes++;
      }

      await resetReleaseDirectory(home, clearOtherStores: clear);
      expect(await profile.exists(), isFalse);
      await profile.writeAsString('new');
      await resetReleaseDirectory(home, clearOtherStores: clear);
      expect(writes, 1);
      expect(await profile.readAsString(), 'new');
      expect(await preserved.readAsString(), 'external');
      expect(await lock.readAsString(), 'held');
    },
  );
}
