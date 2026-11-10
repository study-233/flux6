import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:freev6_windows/app/live_model.dart';
import 'package:freev6_windows/backend/api.dart';
import 'package:freev6_windows/platform/preferences_store.dart';
import 'package:freev6_windows/platform/windows_host.dart';
import 'package:freev6_windows/features/window_background.dart';

class Request {
  Request(this.method, this.uri, this.headers, this.body);
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final String? body;
}

class FixtureTransport extends Transport {
  final requests = <Request>[];
  Future<WireReply> Function(Request)? intercept;
  bool running = false, stopFails = false, saveFails = false;
  JsonMap settings = {
    'mode': 'rule',
    'devMode': true,
    'hotkeyEnabled': false,
    'custom': 'keep',
    'campusCidrs': ['edu.cn'],
  };
  final proxyNames = List.generate(14, (i) => '节点 / $i');
  @override
  Future<WireReply> send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final request = Request(method, uri, headers, body);
    requests.add(request);
    if (intercept != null) return intercept!(request);
    return response(request);
  }

  Future<WireReply> response(Request r) async {
    Object body = {};
    var status = 200;
    switch (r.uri.path) {
      case '/api/v1/status':
        body = {
          'settings': Map.of(settings),
          'proxy': {'running': running},
          'warp': {'registered': true},
          'controllerSecret': 'controller-secret',
          'admin': true,
        };
      case '/api/v1/runtime':
        body = {'present': true};
      case '/api/v1/notice':
        body = {'notices': []};
      case '/api/v1/settings':
        if (saveFails) {
          status = 500;
          body = {'error': 'save failed'};
        } else {
          settings = object(jsonDecode(r.body!));
          body = settings;
        }
      case '/api/v1/proxy/start':
        running = true;
        body = {'running': true, 'controllerSecret': 'controller-secret'};
      case '/api/v1/proxy/stop':
        if (stopFails) {
          status = 500;
          body = {'error': 'DNS restore failed'};
        } else {
          running = false;
          body = {'running': false};
        }
      case '/api/v1/warp/register':
        body = {'registered': true};
      case '/api/v1/update/latest':
        body = {
          'update': true,
          'version': '0.5.4',
          'download': 'https://github.com/example/update.exe',
          'sha256': 'a' * 64,
        };
      case '/api/v1/update/progress':
        body = {'state': 'done', 'path': 'fixture-setup.exe'};
      case '/proxies':
        body = {
          'proxies': {
            '♻️ 自动选择': {'now': proxyNames.first, 'all': proxyNames},
            '🔗 链式代理': {
              'now': '链节点',
              'all': ['链节点'],
            },
          },
        };
      case '/connections':
        body = {
          'connections': [
            {'upload': 100, 'download': 200},
          ],
        };
      default:
        if (r.uri.path.endsWith('/delay'))
          body = {'delay': 12};
        else if (r.method == 'PUT' && r.uri.port == 9090)
          return const WireReply(204, '');
    }
    return WireReply(status, jsonEncode(body));
  }
}

class FixtureHost extends DesktopHost {
  final calls = <String>[];
  final stream = StreamController<String>.broadcast();
  bool hotkeyFails = false;
  String? selectedFile;
  @override
  Stream<String> get events => stream.stream;
  @override
  Future<Object?> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    calls.add('$method:${args['enabled'] ?? ''}');
    if (method == 'file.pick') return selectedFile;
    if (method == 'hotkey' && args['enabled'] == true && hotkeyFails)
      throw const ApiFailure('F6 occupied');
    return null;
  }
}

Future<(LiveModel, FixtureTransport, FixtureHost)> fixture({
  bool running = false,
}) async {
  final wire = FixtureTransport()..running = running, host = FixtureHost();
  final model = LiveModel(
    helper: HelperApi(
      wire,
      () async => const HelperCredentials(8123, 'helper-token'),
    ),
    transport: wire,
    host: host,
    store: MemoryPreferences(),
    version: '0.5.3',
    polling: false,
  );
  await model.initialize();
  addTearDown(model.dispose);
  addTearDown(host.stream.close);
  return (model, wire, host);
}

void main() {
  test('helper and controller use separate credentials and encode group/node paths', () async {
    final (model, wire, _) = await fixture(running: true);
    await model.refreshNodes();
    await model.measure('节点 / 0');
    expect(
      wire.requests
          .where((r) => r.uri.port == 8123)
          .every((r) => r.headers['Authorization'] == 'Bearer helper-token'),
      isTrue,
    );
    final request = wire.requests.last;
    expect(request.headers['Authorization'], 'Bearer controller-secret');
    expect(request.uri.pathSegments, ['proxies', '节点 / 0', 'delay']);
  });
  test('401 refreshes both ephemeral token and port exactly once', () async {
    final wire = FixtureTransport();
    var credentials = 0;
    wire.intercept = (r) async => r.uri.port == 1
        ? const WireReply(401, '{"error":"expired"}')
        : const WireReply(200, '{"ok":true}');
    final api = HelperApi(
      wire,
      () async =>
          HelperCredentials(++credentials, credentials == 1 ? 'old' : 'new'),
    );
    expect((await api.call('/status'))['ok'], true);
    expect(wire.requests.map((r) => r.uri.port), [1, 2]);
    expect(wire.requests.last.headers['Authorization'], 'Bearer new');
  });
  test('invalid responses and version/IPv6 boundaries are handled', () {
    expect(
      () => decodeReply(const WireReply(200, '[]')),
      throwsA(isA<ApiFailure>()),
    );
    expect(
      () => decodeReply(const WireReply(502, '<html>')),
      throwsA(isA<ApiFailure>()),
    );
    expect(compareVersions('v0.10.0', '0.9.9+4'), greaterThan(0));
    expect(compareVersions('0.5.3', '0.5.3+0'), 0);
    for (final ip in ['2001:da8::1', '2001:250:ffff::1']) {
      expect(campusIPv6(ip), true);
    }
    for (final ip in [
      '2001:da9::1',
      '2001:251::1',
      '127.0.0.1',
      'not an address',
    ]) {
      expect(campusIPv6(ip), false);
    }
  });
  test(
    'settings preserve helper fields and roll back failed hotkey persistence',
    () async {
      final (model, wire, host) = await fixture();
      expect(await model.act('settings.save', {'silentStart': true}), true);
      expect(wire.settings['custom'], 'keep');
      wire.saveFails = true;
      expect(await model.act('settings.save', {'hotkeyEnabled': true}), false);
      expect(model.settings['hotkeyEnabled'], false);
      expect(host.calls.sublist(host.calls.length - 2), [
        'hotkey:true',
        'hotkey:false',
      ]);
      wire.saveFails = false;
      host.hotkeyFails = true;
      final previous = wire.requests.length;
      expect(await model.act('settings.save', {'hotkeyEnabled': true}), false);
      expect(wire.requests.length, previous);
    },
  );
  test('late status cannot roll settings back across a write', () async {
    final (model, wire, _) = await fixture();
    final stale = Completer<WireReply>();
    wire.intercept = (r) =>
        r.uri.path.endsWith('/status') ? stale.future : wire.response(r);
    final poll = model.refreshStatus();
    expect(await model.act('settings.save', {'silentStart': true}), true);
    stale.complete(
      const WireReply(
        200,
        '{"settings":{"silentStart":false},"proxy":{"running":false}}',
      ),
    );
    await poll;
    expect(model.settings['silentStart'], true);
  });
  test('late nodes and delay results cannot repopulate after stop', () async {
    final (model, wire, _) = await fixture(running: true);
    await model.refreshNodes();
    final late = Completer<WireReply>();
    wire.intercept = (r) =>
        r.uri.path.endsWith('/delay') ? late.future : wire.response(r);
    final measuring = model.measure(model.nodes.first);
    await model.toggleConnection();
    late.complete(const WireReply(200, '{"delay":1}'));
    await measuring;
    expect(model.nodes, isEmpty);
    expect(model.latency('节点 / 0'), null);
    await model.toggleConnection();
    final stale = Completer<WireReply>();
    wire.intercept = (r) =>
        r.uri.path == '/proxies' ? stale.future : wire.response(r);
    final poll = model.refreshNodes();
    await model.toggleConnection();
    stale.complete(
      const WireReply(200, '{"proxies":{"♻️ 自动选择":{"all":["stale"]}}}'),
    );
    await poll;
    expect(model.nodes, isEmpty);
  });
  test('switching groups discards earlier group response', () async {
    final (model, wire, _) = await fixture(running: true);
    final stale = Completer<WireReply>();
    wire.intercept = (r) =>
        r.uri.path == '/proxies' ? stale.future : wire.response(r);
    final poll = model.refreshNodes();
    await model.act('node.group', {'tab': 'chain'});
    stale.complete(
      const WireReply(200, '{"proxies":{"♻️ 自动选择":{"all":["wrong"]}}}'),
    );
    await poll;
    expect(model.nodes, isEmpty);
    wire.intercept = null;
    await model.refreshNodes();
    expect(model.nodes, ['链节点']);
  });
  test('batch delay tests use at most six requests concurrently', () async {
    final (model, wire, _) = await fixture(running: true);
    await model.refreshNodes();
    var active = 0, peak = 0;
    wire.intercept = (r) async {
      if (r.uri.path.endsWith('/delay')) {
        active++;
        if (active > peak) peak = active;
        await Future<void>.delayed(const Duration(milliseconds: 2));
        active--;
      }
      return wire.response(r);
    };
    expect(await model.act('nodes.measure'), true);
    expect(peak, 6);
    expect(model.nodes.every((node) => model.latency(node) == 12), true);
  });
  test(
    'failed controller selection does not claim the node was selected',
    () async {
      final (model, wire, _) = await fixture(running: true);
      await model.refreshNodes();
      wire.intercept = (r) async => r.method == 'PUT'
          ? const WireReply(500, '{"error":"rejected"}')
          : wire.response(r);
      final current = model.currentNode;
      expect(await model.act('node.select', {'name': model.nodes.last}), false);
      expect(model.currentNode, current);
    },
  );
  test('exit and update never launch after a failed stop', () async {
    final (model, wire, host) = await fixture(running: true);
    wire.stopFails = true;
    expect(await model.act('app.quit'), false);
    expect(host.calls.any((v) => v.startsWith('app.quit')), false);
    expect(model.connected, true);
    await model.act('update.check');
    expect(await model.act('update.install'), false);
    expect(host.calls.any((v) => v.startsWith('update.apply')), false);
    wire.stopFails = false;
    expect(await model.act('update.install'), true);
    expect(model.connected, false);
    expect(host.calls.last, 'update.apply:');
  });
  test(
    'reset is blocked while running and direct mode requires developer mode',
    () async {
      final (model, wire, _) = await fixture(running: true);
      expect(await model.act('settings.reset'), false);
      expect(
        wire.requests.any((r) => r.uri.path.endsWith('/settings/reset')),
        false,
      );
      await model.act('settings.save', {'devMode': false, 'mode': 'direct'});
      expect(model.mode, '规则');
    },
  );
  test('preference writes are serialized and recover the previous valid generation', () async {
    final dir = await Directory.systemTemp.createTemp('freev6-prefs-test-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/state/flutter-ui.json'),
        store = FilePreferences(File('${dir.path}/state/flutter-ui.json'));
    await Future.wait([
      store.save({'theme': 'light'}),
      store.save({'theme': 'dark'}),
    ]);
    expect(await store.load(), {'theme': 'dark'});
    await file.writeAsString('incomplete');
    expect(await store.load(), {'theme': 'light'});
    await store.save({'theme': 'system'});
    expect(await store.load(), {'theme': 'system'});
    await file.delete();
    expect(await store.load(), {'theme': 'light'});
  });
  test('missing core and non-campus IPv6 prevent proxy start', () async {
    final (model, wire, _) = await fixture();
    model.runtime['present'] = false;
    await model.toggleConnection();
    expect(
      wire.requests.any((r) => r.uri.path.endsWith('/proxy/start')),
      false,
    );
    model.runtime['present'] = true;
    await model.act('settings.save', {'devMode': false});
    wire.intercept = (r) async => r.uri.host == 'api-ipv6.ip.sb'
        ? const WireReply(200, '2001:db8::1')
        : wire.response(r);
    await model.toggleConnection();
    expect(model.connected, false);
    expect(
      wire.requests.any((r) => r.uri.path.endsWith('/proxy/start')),
      false,
    );
    wire.intercept = (r) async => r.uri.host == 'api-ipv6.ip.sb'
        ? const WireReply(200, '2001:da8::1')
        : wire.response(r);
    await model.toggleConnection();
    expect(model.connected, true);
  });
  test('repeated migration replaces counters and rejects unknown fields without changing preferences', () async {
    final (model, _, host) = await fixture();
    final directory = await Directory.systemTemp.createTemp(
      'freev6-import-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/fixture.json');
    host.selectedFile = file.path;
    await file.writeAsString(
      jsonEncode({
        'format': 'freev6-ui-preferences',
        'version': 1,
        'values': {
          'freev6-theme': 'dark',
          'freev6-traffic-stats': jsonEncode({
            'total': {'up': 100, 'down': 200},
            'months': {},
          }),
        },
      }),
    );
    expect(await model.act('preferences.import'), true);
    expect(await model.act('preferences.import'), true);
    model.setMonthly(false);
    expect(model.usageUpload, 100);
    expect(model.usageDownload, 200);
    final previous = Map.of(model.preferences);
    await file.writeAsString(
      jsonEncode({
        'format': 'freev6-ui-preferences',
        'version': 1,
        'values': {'token': 'synthetic'},
      }),
    );
    expect(await model.act('preferences.import'), false);
    expect(model.preferences, previous);
  });
  test(
    'concurrent preference actions merge after earlier durable writes',
    () async {
      final (model, _, _) = await fixture();
      await Future.wait([
        model.act('preferences.set', {'key': 'freev6-theme', 'value': 'dark'}),
        model.act('notice.read'),
        model.act('wallpaper.clear'),
      ]);
      expect(model.preferences['freev6-theme'], 'dark');
      expect(model.preferences['freev6-notice-read'], '[]');
      expect(model.preferences['freev6-bg-mode'], 'default');
    },
  );
  test('seasonal activation and greeting keys use the supplied local date', () {
    expect(halloweenEnabled(DateTime(2026, 10, 31), ''), true);
    expect(halloweenEnabled(DateTime(2026, 11, 1), ''), false);
    expect(halloweenEnabled(DateTime(2026, 11, 1), '1'), true);
    expect(halloweenDateKey(DateTime(2026, 10, 31)), '2026-10-31');
  });
  test(
    'late resource refresh cannot restore a cleared configuration',
    () async {
      final (model, wire, _) = await fixture();
      final entered = Completer<void>(), late = Completer<WireReply>();
      var reads = 0;
      wire.intercept = (r) {
        if (r.uri.path == '/api/v1/chain-proxy' &&
            r.method == 'GET' &&
            ++reads == 1) {
          entered.complete();
          return late.future;
        }
        return wire.response(r);
      };
      final refresh = model.refreshResources();
      await entered.future;
      expect(await model.act('chain.clear'), true);
      late.complete(const WireReply(200, '{"count":99}'));
      await refresh;
      expect(model.chain['count'] ?? 0, 0);
    },
  );
  test('late status cannot undo a completed credential registration', () async {
    final (model, wire, _) = await fixture();
    final stale = Completer<WireReply>();
    wire.intercept = (r) =>
        r.uri.path.endsWith('/status') ? stale.future : wire.response(r);
    final poll = model.refreshStatus();
    expect(await model.act('warp.register'), true);
    stale.complete(
      const WireReply(
        200,
        '{"warp":{"registered":false},"proxy":{"running":false}}',
      ),
    );
    await poll;
    expect(model.runtime['warpRegistered'], true);
  });
}
