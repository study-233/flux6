import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/common/app_update.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('selfUpdateAssetSuffix', () {
    test('names the APK built for the running ABI', () {
      expect(
        selfUpdateAssetSuffix(Abi.androidArm64, windowsInstalled: false),
        'android-arm64.apk',
      );
      expect(
        selfUpdateAssetSuffix(Abi.androidArm, windowsInstalled: false),
        isNull,
      );
      expect(
        selfUpdateAssetSuffix(Abi.androidX64, windowsInstalled: false),
        isNull,
      );
    });

    test('names the Windows installer only for an installed build', () {
      expect(
        selfUpdateAssetSuffix(Abi.windowsX64, windowsInstalled: true),
        'windows-amd64-setup.exe',
      );
      expect(
        selfUpdateAssetSuffix(Abi.windowsArm64, windowsInstalled: true),
        'windows-arm64-setup.exe',
      );
      expect(
        selfUpdateAssetSuffix(Abi.windowsX64, windowsInstalled: false),
        isNull,
      );
    });

    test('leaves macOS and Linux to the release page', () {
      for (final abi in [
        Abi.macosArm64,
        Abi.macosX64,
        Abi.linuxX64,
        Abi.linuxArm64,
      ]) {
        expect(selfUpdateAssetSuffix(abi, windowsInstalled: true), isNull);
      }
    });
  });

  test('releaseAssetName drops the tag prefix', () {
    expect(
      releaseAssetName('v0.9.3', 'android-arm64.apk'),
      'Flux6-0.9.3-android-arm64.apk',
    );
  });

  test('ARM64 updates use the Flux6 release asset and checksum channel', () {
    final suffix = selfUpdateAssetSuffix(
      Abi.androidArm64,
      windowsInstalled: false,
    )!;
    final name = releaseAssetName('v0.1.1', suffix);
    expect(name, 'Flux6-0.1.1-android-arm64.apk');
    expect(
      releaseAssetUri('v0.1.1', name).toString(),
      'https://github.com/study-233/flux6/releases/download/v0.1.1/$name',
    );
  });

  group('releaseChecksum', () {
    const digest =
        'ff6a953c0f5c12e6bdc97b49428b565b64c4a62d85e50081823ba297407529b1';

    test('reads the entry sha256sum wrote for a file', () {
      final sums =
          '$digest  ./Flux6-0.9.2-android-arm64.apk\n'
          '${'0' * 64}  ./Flux6-0.9.2-windows-amd64-setup.exe\n';

      expect(releaseChecksum(sums, 'Flux6-0.9.2-android-arm64.apk'), digest);
    });

    test('accepts the binary marker, upper case and CRLF', () {
      final sums = '${digest.toUpperCase()} *FlClash.apk\r\n';

      expect(releaseChecksum(sums, 'FlClash.apk'), digest);
    });

    test('answers null for a file the listing does not name', () {
      expect(releaseChecksum('$digest  ./other.apk\n', 'FlClash.apk'), isNull);
      expect(releaseChecksum('not a listing', 'FlClash.apk'), isNull);
    });
  });

  test('fileSha256 hashes the file on disk', () async {
    final directory = await Directory.systemTemp.createTemp('app_update');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/package');
    await file.writeAsString('package');

    expect(
      await fileSha256(file.path),
      sha256.convert(utf8.encode('package')).toString(),
    );
  });

  test('windowsUpdateArguments installs silently on behalf of a pid', () {
    final arguments = windowsUpdateArguments(4242).split(' ');

    expect(arguments, containsAll(['/SILENT', '/SUPPRESSMSGBOXES']));
    expect(arguments, contains('/updatefrom=4242'));
  });
}
