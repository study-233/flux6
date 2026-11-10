import 'dart:async';
import 'dart:convert';

import 'package:freev6_windows/app/live_model.dart';
import 'package:freev6_windows/backend/api.dart';
import 'package:freev6_windows/platform/preferences_store.dart';
import 'package:freev6_windows/platform/windows_host.dart';

class FixtureRequest {
  const FixtureRequest(this.method, this.uri, this.headers, this.body);
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final JsonMap body;
}

class FreeV6OfflineFixture {
  FreeV6OfflineFixture({bool polling = true, MemoryPreferences? preferences}) {
    model = LiveModel(
      helper: HelperApi(
        transport,
        () async => const HelperCredentials(18213, 'offline-fixture-token'),
      ),
      transport: transport,
      host: host,
      store:
          preferences ??
          (MemoryPreferences()..values['freev6-guide-done'] = '1'),
      version: '0.5.3',
      polling: polling,
      pause: (_) => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  final transport = FixtureTransport();
  final host = FixtureHost();
  late final LiveModel model;
}

class FixtureTransport extends Transport {
  final requests = <FixtureRequest>[];
  final settings = <String, dynamic>{
    'mode': 'rule',
    'devMode': false,
    'campusCidrs': ['edu.cn'],
    'autoStart': false,
    'silentStart': false,
    'autoRunProxy': false,
    'hotkeyEnabled': false,
    'hotspotShare': false,
    'chainEnabled': false,
    'cloudEnabled': false,
  };
  bool running = false, present = true, registered = true, cloudLocked = false;
  bool stopFails = false, saveFails = false, closed = false;
  int samples = 0;
  String campusAddress = '2001:da8::1';
  final chain = <String, dynamic>{'count': 0, 'names': <String>[]};
  final cloud = <String, dynamic>{'count': 0};
  final nodes = ['东区 / IPv6', '西区 · IPv6', '北区 · IPv6'];
  final selections = <String, String>{'♻️ 自动选择': '东区 / IPv6'};
  Future<WireReply?> Function(FixtureRequest)? intercept;

  WireReply reply(Object data, [int status = 200]) =>
      WireReply(status, jsonEncode(data));

  @override
  Future<WireReply> send(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    String? body,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (closed) throw StateError('Fixture transport is closed');
    final request = FixtureRequest(
      method,
      uri,
      headers,
      body == null ? {} : object(jsonDecode(body)),
    );
    requests.add(request);
    final helper =
        uri.scheme == 'http' &&
        uri.host == '127.0.0.1' &&
        uri.port == 18213 &&
        uri.path.startsWith('/api/v1/');
    final controller =
        uri.scheme == 'http' && uri.host == '127.0.0.1' && uri.port == 9090;
    final campus =
        uri.toString() == 'https://api-ipv6.ip.sb/ip' && method == 'GET';
    if (!helper && !controller && !campus) {
      throw StateError('Unrecognized fixture request: $uri');
    }
    if (helper && headers['Authorization'] != 'Bearer offline-fixture-token') {
      return reply({'error': 'unauthorized'}, 401);
    }
    if (controller &&
        headers['Authorization'] != 'Bearer offline-controller-token') {
      return reply({'error': 'unauthorized'}, 401);
    }
    final custom = await intercept?.call(request);
    if (custom != null) return custom;
    if (campus) return WireReply(200, campusAddress);
    if (controller) {
      final path = uri.pathSegments;
      if (path.length == 1 && path.first == 'proxies') {
        return reply({
          'proxies': {
            '♻️ 自动选择': {'now': selections['♻️ 自动选择'], 'all': nodes},
            '🔗 链式代理': {'now': selections['🔗 链式代理'], 'all': chain['names']},
          },
        });
      }
      if (path.length == 2 && path.first == 'proxies' && method == 'PUT') {
        selections[path[1]] = request.body['name'] as String;
        return const WireReply(204, '');
      }
      if (path.length == 3 && path.last == 'delay') {
        return reply({'delay': 24 + path[1].length});
      }
      if (path.length == 1 && path.first == 'connections') {
        samples++;
        return reply({
          'connections': [
            {'upload': samples * 1024, 'download': samples * 8192},
          ],
        });
      }
    }
    final data = request.body;
    switch (uri.path.replaceFirst('/api/v1', '')) {
      case '/status':
        return reply({
          'settings': settings,
          'proxy': {'running': running},
          'warp': {'registered': registered},
          'controllerSecret': 'offline-controller-token',
          'admin': true,
          'hotspot': {'enabled': settings['hotspotShare'] == true && running},
        });
      case '/runtime':
        return reply({'present': present});
      case '/appearance':
        return reply({'color': '007aff'});
      case '/settings':
        if (method == 'PUT') {
          if (saveFails) return reply({'error': '离线夹具：设置保存失败'}, 500);
          settings
            ..clear()
            ..addAll(data);
        }
        return reply(settings);
      case '/proxy/start':
        running = true;
        return reply({
          'running': true,
          'controllerSecret': 'offline-controller-token',
          'hotspot': {},
        });
      case '/proxy/stop':
        if (stopFails) return reply({'error': '离线夹具：网络恢复未确认'}, 500);
        running = false;
        return reply({'running': false});
      case '/chain-proxy':
        if (method == 'PUT') {
          chain
            ..clear()
            ..addAll({
              'count': 2,
              'names': ['链式 / A', '链式 · B'],
              'source': data['url'] ?? '本地 YAML',
            });
          selections['🔗 链式代理'] = '链式 / A';
        }
        if (method == 'DELETE') {
          chain
            ..clear()
            ..addAll({'count': 0, 'names': <String>[]});
          settings['chainEnabled'] = false;
        }
        return reply(chain);
      case '/cloud-config':
        if (method == 'PUT') {
          if (cloudLocked) {
            return reply({'error': '请先阅读公告', 'code': 'noticeRequired'}, 403);
          }
          cloud
            ..clear()
            ..addAll({'count': 2, 'portalHost': data['portalHost']});
        }
        if (method == 'DELETE') {
          cloud
            ..clear()
            ..addAll({'count': 0});
          settings['cloudEnabled'] = false;
        }
        return reply({...cloud, 'locked': cloudLocked});
      case '/notice':
        return reply({
          'notices': [
            {
              'id': 'offline-backend',
              'title': '离线功能验收',
              'body': '当前运行真实 FreeV6 Dart 后端，所有请求由内存夹具回答，不会联网。',
            },
          ],
        });
      case '/warp/register':
        registered = true;
        return reply({'registered': true});
      case '/runtime/download':
        return reply({'started': true});
      case '/runtime/download/progress':
        present = true;
        return reply({'state': 'done', 'done': 1024, 'total': 1024});
      case '/settings/reset':
        settings.updateAll((key, value) => value is bool ? false : value);
        settings['mode'] = 'rule';
        chain
          ..clear()
          ..addAll({'count': 0, 'names': <String>[]});
        cloud
          ..clear()
          ..addAll({'count': 0});
        return reply({'ok': true});
      case '/update/latest':
        return reply({
          'update': true,
          'version': '0.5.4',
          'notes': '离线更新夹具',
          'download': 'https://example.invalid/freev6.exe',
          'sha256': List.filled(64, 'a').join(),
        });
      case '/update/download':
        return reply({'started': true});
      case '/update/progress':
        return reply({
          'state': 'done',
          'done': 1024,
          'total': 1024,
          'path': 'offline-fixture-setup.exe',
        });
    }
    throw StateError('No fixture for $method $uri');
  }

  @override
  void close() {
    closed = true;
  }
}

class FixtureHost extends DesktopHost {
  final calls = <(String, Map<String, dynamic>)>[];
  final stream = StreamController<String>.broadcast();
  bool hotkeyFails = false, quitRequested = false, updateRequested = false;
  String? selectedFile;
  @override
  Stream<String> get events => stream.stream;
  @override
  Future<Object?> call(
    String method, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    calls.add((method, Map.of(arguments)));
    switch (method) {
      case 'bootstrap':
        return {'port': 18213, 'token': 'offline-fixture-token'};
      case 'hotkey':
        if (hotkeyFails && arguments['enabled'] == true) {
          throw const ApiFailure('离线夹具：F6 已被占用');
        }
        return null;
      case 'appearance':
        return arguments['mode'] ?? 'default';
      case 'file.pick':
        return selectedFile;
      case 'app.quit':
        quitRequested = true;
        return null;
      case 'update.apply':
        updateRequested = true;
        return null;
      case 'external.open':
        return null;
      case 'window.show':
        return null;
      default:
        throw StateError('No fixture host method: $method');
    }
  }

  @override
  void dispose() {
    unawaited(stream.close());
  }
}
