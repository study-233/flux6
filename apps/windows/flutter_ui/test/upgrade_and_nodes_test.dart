import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:freev6_windows/app/live_model.dart';
import 'package:freev6_windows/backend/api.dart';
import 'package:freev6_windows/backend/node_tools.dart';
import 'package:freev6_windows/platform/preferences_store.dart';

import 'backend_test.dart' show FixtureTransport, FixtureHost;

void main() {
  test(
    'node policy ignores stale polls and keeps the confirmed choice on failure',
    () async {
      final wire = FixtureTransport();
      final nodes = NodeTools(
        HelperApi(wire, () async => const HelperCredentials(8123, 'fixture')),
      )..bind('session', 'access');
      addTearDown(nodes.dispose);
      nodes.state = {'profile': 'network', 'quality': <String, dynamic>{}};
      final pollReply = Completer<WireReply>();
      final writeReply = Completer<WireReply>();
      final pollStarted = Completer<void>(), writeStarted = Completer<void>();
      wire.intercept = (request) {
        if (request.method == 'GET') {
          pollStarted.complete();
          return pollReply.future;
        }
        writeStarted.complete();
        return writeReply.future;
      };
      final poll = nodes.refresh();
      await pollStarted.future;
      final select = nodes.select(node: 'A');
      await writeStarted.future;
      expect(nodes.selecting, true);
      await expectLater(nodes.select(), throwsA(isA<ApiFailure>()));
      writeReply.complete(
        const WireReply(200, '{"profile":"network","quality":{"pinned":"A"}}'),
      );
      await select;
      pollReply.complete(
        const WireReply(200, '{"profile":"network","quality":{}}'),
      );
      await poll;
      expect(nodes.pinned, 'A');
      expect(nodes.selecting, false);
      wire.intercept = (_) async =>
          const WireReply(503, '{"error":"fixture failure"}');
      await expectLater(nodes.select(), throwsA(isA<ApiFailure>()));
      expect(nodes.pinned, 'A');
      expect(nodes.selecting, false);
      wire.intercept = (_) async =>
          const WireReply(200, '{"profile":"network","quality":{}}');
      await nodes.select();
      expect(nodes.pinned, isEmpty);
    },
  );

  test('0.1.3 preferences survive upgrade and completed connections count toward traffic', () async {
    final dir = await Directory.systemTemp.createTemp('flux6-013-upgrade-');
    final file = File('${dir.path}/state/flutter-ui.json');
    await file.parent.create();
    final old = <String, String>{
      'freev6-theme': 'dark',
      'reduce-motion': '1',
      'freev6-guide-done': '1',
      'freev6-notice-read': '["fixture-notice"]',
      'freev6-traffic-stats': jsonEncode({
        'total': {'up': 5, 'down': 100},
        'months': {},
      }),
    };
    // 0.1.3 uses this v1 file directly; the upgrade must not require an export.
    await file.writeAsString(jsonEncode({'version': 1, 'values': old}));
    final wire = FixtureTransport()..running = true;
    final host = FixtureHost();
    final model = LiveModel(
      helper: HelperApi(
        wire,
        () async => const HelperCredentials(8123, 'fixture'),
      ),
      transport: wire,
      host: host,
      store: FilePreferences(file),
      version: '0.1.4',
      polling: false,
    );
    try {
      await model.initialize();
      model.setMonthly(false);
      expect(model.preferences, old);
      var download = 1000;
      wire.intercept = (r) => r.uri.path == '/connections'
          ? Future.value(
              WireReply(
                200,
                jsonEncode({
                  'connections': [],
                  'uploadTotal': 0,
                  'downloadTotal': download,
                }),
              ),
            )
          : wire.response(r);
      await model.pollTraffic();
      download = 1500;
      await model.pollTraffic();
      expect(model.usageUpload, 5);
      expect(model.usageDownload, 600);
      download = 20; // A restarted core cannot subtract previous traffic.
      await model.pollTraffic();
      expect(model.usageDownload, 600);
      await Future.wait([
        model.act('preferences.set', {
          'key': 'flclash-app-settings',
          'value': '{}',
        }),
        model.act('preferences.set', {
          'key': 'flclash-proxy-style',
          'value': '{}',
        }),
      ]);
      await model.act('app.quit');
      final restored = await FilePreferences(file).load();
      for (final key in old.keys.where((k) => k != 'freev6-traffic-stats')) {
        expect(restored[key], old[key]);
      }
      expect(
        restored.keys,
        containsAll(['flclash-app-settings', 'flclash-proxy-style']),
      );
      expect(
        jsonDecode(restored['freev6-traffic-stats']!)['total']['down'],
        600,
      );
    } finally {
      model.dispose();
      await host.stream.close();
      await dir.delete(recursive: true);
    }
  });

  test('download cancellation discards late results and group refresh does not wait on stale responses', () async {
    final wire = FixtureTransport();
    final api = HelperApi(
      wire,
      () async => const HelperCredentials(8123, 'fixture'),
    );
    final tools = NodeTools(api)..bind('session', 'access');
    final late = Completer<WireReply>();
    final entered = Completer<void>();
    wire.intercept = (r) {
      if (r.uri.path.endsWith('/download')) {
        entered.complete();
        return late.future;
      }
      return Future.value(
        WireReply(
          200,
          jsonEncode({
            'profile': r.uri.queryParameters['group'],
            'quality': {},
          }),
        ),
      );
    };
    await tools.refresh();
    final download = tools.download(['node']);
    await entered.future;
    tools.cancelDownload();
    expect(tools.downloading, false);
    tools.bind('session', 'chain');
    await tools.refresh();
    late.complete(const WireReply(200, '{"bytesPerSecond":999}'));
    await download;
    expect(tools.results, isEmpty);
    expect(tools.state['profile'], 'chain');
    tools.dispose();
  });
}
