import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:freev6_windows/app/preview_model.dart';
import 'package:freev6_windows/platform/legacy_preferences.dart';
import 'package:freev6_windows/platform/windows_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  String backup(Map<String, Object> values) => jsonEncode({
    'format': 'freev6-ui-preferences',
    'version': 1,
    'values': values,
  });

  test(
    'modern backup preserves reduced motion and legacy version stays strict',
    () {
      final modern = LegacyPreferences.decode(
        '{"format":"freev6-ui-preferences","version":2,"values":{"reduce-motion":"1"}}',
      );
      expect(modern.values['reduce-motion'], '1');
      expect(LegacyPreferences.decode(modern.encode()).version, 2);
      expect(
        () => LegacyPreferences.decode(
          '{"format":"freev6-ui-preferences","version":1,"values":{"reduce-motion":"1"}}',
        ),
        throwsFormatException,
      );
    },
  );
  test('legacy traffic, appearance and read markers survive round trip', () {
    final source = backup({
      'freev6-theme': 'dark',
      'freev6-guide-done': '1',
      'freev6-notice-read': '["公告一"]',
      'freev6-traffic-stats': jsonEncode({
        'total': {'up': 42, 'down': 99},
        'months': {
          '2026-11': {'up': 12, 'down': 34},
        },
      }),
    });
    final value = LegacyPreferences.decode(source);
    expect(LegacyPreferences.decode(value.encode()).values, value.values);
    expect(
      jsonDecode(value.values['freev6-traffic-stats']!)['total']['up'],
      42,
    );
  });
  test('migration rejects credentials and remote wallpaper', () {
    for (final data in [
      backup({'FREEV6_API_TOKEN': 'do-not-import'}),
      backup({'freev6-wallpaper': 'https://example.invalid/image.jpg'}),
      backup({'freev6-theme': 'unknown'}),
      backup({
        'freev6-traffic-stats': '{"total":{"up":-1,"down":0},"months":{}}',
      }),
      backup({'freev6-notice-read': '[23]'}),
      jsonEncode({'version': 2, 'values': {}}),
    ]) {
      expect(() => LegacyPreferences.decode(data), throwsFormatException);
    }
  });
  test('migration rejects oversized input before parsing', () {
    expect(
      () => LegacyPreferences.decode(' ' * (LegacyPreferences.maxBytes + 1)),
      throwsFormatException,
    );
  });
  test('preview ignores duplicate transitions and survives disposal', () async {
    final model = PreviewModel();
    final first = model.toggleConnection();
    await model.toggleConnection();
    expect(model.busy, true);
    await first;
    expect(model.connected, true);
    final pending = model.measure(model.nodes.first);
    model.dispose();
    await pending;
  });
  test('native handshake validates protocol and preview mode', () async {
    final host = WindowsHost();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      host.channel,
      (call) async => {'version': 1, 'platform': 'windows', 'preview': true},
    );
    addTearDown(() => messenger.setMockMethodCallHandler(host.channel, null));
    expect((await host.describe()).preview, true);
    messenger.setMockMethodCallHandler(
      host.channel,
      (call) async => {'version': 2},
    );
    await expectLater(host.describe(), throwsFormatException);
    messenger.setMockMethodCallHandler(
      host.channel,
      (call) async => throw PlatformException(code: 'unavailable'),
    );
    await expectLater(host.describe(), throwsA(isA<PlatformException>()));
  });
}
