import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

String _androidAttribute(String source, String element, String attribute) {
  final elementTag = RegExp('<$element\\b[^>]*>').firstMatch(source)!.group(0)!;
  return RegExp(
    'android:$attribute="([^"]+)"',
  ).firstMatch(elementTag)!.group(1)!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('TV launcher icons meet density-specific minimum sizes', () async {
    const expectedSizes = {
      'mdpi': 80,
      'hdpi': 120,
      'xhdpi': 160,
      'xxhdpi': 240,
      'xxxhdpi': 320,
    };

    for (final MapEntry(key: density, value: size) in expectedSizes.entries) {
      final file = File(
        'android/app/src/main/res/'
        'mipmap-television-$density/ic_launcher.webp',
      );
      expect(file.existsSync(), isTrue, reason: 'missing ${file.path}');

      final codec = await ui.instantiateImageCodec(await file.readAsBytes());
      final frame = await codec.getNextFrame();
      expect(
        (frame.image.width, frame.image.height),
        (size, size),
        reason: file.path,
      );
      frame.image.dispose();
      codec.dispose();
    }
  });

  test(
    'adaptive cats fit the circular safe area and only cow is enabled',
    () async {
      for (final id in ['cow', 'orange', 'prism', 'four_color', 'earth']) {
        final resource =
            'android/app/src/main/res/drawable-nodpi/cat_${id}_foreground.png';
        final codec = await ui.instantiateImageCodec(
          await File(resource).readAsBytes(),
        );
        final frame = await codec.getNextFrame();
        final bytes = (await frame.image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        expect((frame.image.width, frame.image.height), (432, 432));
        for (var y = 0; y < 432; y++) {
          for (var x = 0; x < 432; x++) {
            if (bytes.getUint8((y * 432 + x) * 4 + 3) > 127) {
              final dx = (x + 0.5 - 216) / 4;
              final dy = (y + 0.5 - 216) / 4;
              expect(
                dx * dx + dy * dy,
                lessThanOrEqualTo(33 * 33),
                reason: resource,
              );
            }
          }
        }
        frame.image.dispose();
        codec.dispose();
      }
      final manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      final aliases = RegExp(
        r'<activity-alias\b[^>]*>',
      ).allMatches(manifest).map((m) => m.group(0)!).toList();
      expect(aliases, hasLength(5));
      final enabled = aliases
          .where((s) => s.contains('android:enabled="true"'))
          .toList();
      expect(enabled, hasLength(1));
      expect(enabled.single, contains('.LauncherCow'));
      expect(
        _androidAttribute(manifest, 'application', 'icon'),
        '@mipmap/cat_cow',
      );
    },
  );
}
