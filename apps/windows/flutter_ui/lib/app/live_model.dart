import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../backend/api.dart' hide JsonMap;
import '../dashboard_model.dart';
import '../platform/legacy_preferences.dart';
import '../platform/preferences_store.dart';
import '../platform/windows_host.dart';
import 'client_model.dart';

/// Real client, with all IO dependencies injectable for offline regression tests.
class LiveModel extends ClientModel {
  LiveModel({
    required this.helper,
    required this.transport,
    required this.host,
    required this.store,
    required this.version,
    this.polling = true,
    this.pause = Future<void>.delayed,
  }) {
    controller = ControllerApi(transport, () => _secret);
  }
  final HelperApi helper;
  final Transport transport;
  final DesktopHost host;
  final PreferencesStore store;
  final String version;
  final bool polling;
  final Future<void> Function(Duration) pause;
  late final ControllerApi controller;
  @override
  Stream<String> get events => host.events;
  @override
  bool get preview => false;
  @override
  final JsonMap settings = {};
  @override
  final Map<String, String> preferences = {};
  @override
  final JsonMap chain = {};
  @override
  final JsonMap cloud = {};
  @override
  final JsonMap runtime = {};
  @override
  final JsonMap coreDownload = {};
  @override
  final JsonMap update = {};
  @override
  final List<JsonMap> notices = [];
  @override
  String proxyTab = 'access';
  @override
  final traffic = ValueNotifier<int>(0);
  final _logs = <PreviewLog>[];
  final _pending = <String>{};
  final _delays = <String, int>{}, _measuring = <String>{};
  final _nodes = <String>[];
  final _uploads = <double>[], _downloads = <double>[];
  final _timers = <Timer>[];
  StreamSubscription<String>? _subscription;
  String? _message, _current;
  String _secret = '';
  bool _disposed = false, _connected = false, _busy = false, _online = false;
  bool _monthly = true, _knownStopped = false, _statusPolling = false;
  bool _nodesPolling = false, _trafficPolling = false, _writing = false;
  bool _exclusive = false;
  Future<void>? _registration;
  int _settingsGen = 0, _runGen = 0, _nodeGen = 0, _autoGen = 0;
  int _lastUp = 0, _lastDown = 0;
  DateTime? _started, _sampleTime;
  JsonMap _stats = {
    'total': {'up': 0, 'down': 0},
    'months': <String, dynamic>{},
  };
  @override
  String? get message => _message;
  @override
  void dismissMessage() {
    _message = null;
    _notify();
  }

  @override
  bool pending(String action) => _pending.contains(action);
  @override
  bool get connected => _connected;
  @override
  bool get busy => _busy || _exclusive;
  @override
  bool get canConnectAction => !busy && _online;
  @override
  bool get canChangeMode => !busy && !_writing;
  @override
  bool get canSelectNode => connected && !busy;
  @override
  bool get monthly => _monthly;
  @override
  String get mode => switch (settings['mode']) {
    'global' => '全局',
    'direct' => '直连',
    _ => '规则',
  };
  @override
  String get profileName => setting('cloudEnabled') ? '备用配置' : '校园 IPv6';
  @override
  String get phaseLabel => !_online
      ? '本地组件未连接'
      : busy
      ? '处理中'
      : connected
      ? '已连接'
      : '未连接';
  @override
  String? get modeHint => connected ? '模式与配置变更将在重新连接后生效' : null;
  @override
  String get displayNode => _current ?? '自动选择';
  @override
  String? get currentNode => _current;
  @override
  String? get preferredNode => _current;
  @override
  List<String> get nodes => List.unmodifiable(_nodes);
  @override
  Duration get uptime =>
      _started == null ? Duration.zero : DateTime.now().difference(_started!);
  @override
  bool get uptimeKnown => connected && _started != null;
  @override
  List<double> get uploadHistory => List.unmodifiable(_uploads);
  @override
  List<double> get downloadHistory => List.unmodifiable(_downloads);
  String get _month =>
      '${DateTime.now().year}-${DateTime.now().month.toString().padLeft(2, '0')}';
  JsonMap get _usage => monthly
      ? object(object(_stats['months'])[_month])
      : object(_stats['total']);
  @override
  int get usageUpload => (_usage['up'] as num? ?? 0).toInt();
  @override
  int get usageDownload => (_usage['down'] as num? ?? 0).toInt();
  @override
  List<PreviewLog> get logs => List.unmodifiable(_logs);
  @override
  int? latency(String node) => _delays[node];
  @override
  bool measuring(String node) => _measuring.contains(node);
  String get _group => proxyTab == 'chain' ? '🔗 链式代理' : '♻️ 自动选择';
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _log(String value, {bool warning = false}) {
    if (_disposed) return;
    _logs.insert(
      0,
      PreviewLog(DateTime.now(), value, level: warning ? '警告' : '信息'),
    );
    if (_logs.length > 300) _logs.removeLast();
    _notify();
  }

  void _failure(Object error) {
    _message = error.toString();
    _log(_message!, warning: true);
  }

  void _readStats() {
    final raw = preferences['freev6-traffic-stats'];
    if (raw == null) return;
    // Reuse the migration validator before using counters in arithmetic.
    LegacyPreferences.decode(
      jsonEncode({
        'format': 'freev6-ui-preferences',
        'version': 1,
        'values': {'freev6-traffic-stats': raw},
      }),
    );
    _stats = object(jsonDecode(raw));
  }

  Future<void> initialize() async {
    runtime['appVersion'] = version;
    preferences.addAll(await store.load());
    _readStats();
    // Helper is a child process and may need a moment to bind its chosen port.
    Object? last;
    for (var i = 0; i < 30 && !_disposed; i++) {
      try {
        await refreshStatus(strict: true);
        last = null;
        break;
      } catch (e) {
        last = e;
        await pause(const Duration(milliseconds: 300));
      }
    }
    if (last != null) throw last;
    if (_disposed) return;
    await refreshResources();
    try {
      await host.call('hotkey', {'enabled': setting('hotkeyEnabled')});
    } catch (e) {
      _failure(e);
    }
    await _appearance();
    _subscription = events.listen((event) {
      if (event == 'helperExited') {
        _online = false;
        _knownStopped = false;
        _setRunning(false);
        _failure('本地组件已退出。请退出后重新打开 FreeV6；若此前已连接，请先检查网络恢复状态。');
      }
      if (event == 'appearanceChanged') unawaited(_appearance());
    });
    if (polling) {
      _timers.add(
        Timer.periodic(
          const Duration(seconds: 3),
          (_) => unawaited(refreshStatus()),
        ),
      );
      _timers.add(
        Timer.periodic(
          const Duration(seconds: 1),
          (_) => unawaited(pollTraffic()),
        ),
      );
      _timers.add(
        Timer.periodic(
          const Duration(seconds: 5),
          (_) => unawaited(refreshNodes()),
        ),
      );
      _timers.add(
        Timer.periodic(
          const Duration(seconds: 10),
          (_) => unawaited(_flushSafely()),
        ),
      );
      unawaited(_startup());
    }
    _log('本地组件已连接');
  }

  Future<void> refreshStatus({bool strict = false}) async {
    if (_statusPolling || _disposed) return;
    _statusPolling = true;
    final settingsGen = _settingsGen, runGen = _runGen;
    try {
      final status = await helper.call('/status');
      if (_disposed) return;
      _online = true;
      if (runGen == _runGen && !_busy)
        _secret = status['controllerSecret']?.toString() ?? _secret;
      runtime['warpRegistered'] = object(status['warp'])['registered'] == true;
      runtime['admin'] = status['admin'];
      runtime['hotspot'] = status['hotspot'];
      if (settingsGen == _settingsGen && !_writing) {
        settings
          ..clear()
          ..addAll(object(status['settings']));
      }
      if (runGen == _runGen && !_busy) {
        _knownStopped = object(status['proxy'])['running'] == false;
        _setRunning(object(status['proxy'])['running'] == true);
      }
      _notify();
    } catch (e) {
      if (runGen == _runGen && !_busy) {
        _online = false;
        _knownStopped = false;
        _setRunning(false);
      }
      if (strict) rethrow;
      _notify();
    } finally {
      _statusPolling = false;
    }
  }

  Future<void> refreshResources() async {
    for (final pair in [
      ('/runtime', runtime),
      ('/chain-proxy', chain),
      ('/notice', <String, dynamic>{}),
      ('/cloud-config', cloud),
    ]) {
      try {
        final value = await helper.call(pair.$1);
        if (_disposed) return;
        pair.$2.addAll(value);
        if (pair.$1 == '/notice') {
          notices
            ..clear()
            ..addAll((value['notices'] as List? ?? []).map(object));
        }
      } catch (e) {
        _log('读取${pair.$1}失败：$e', warning: true);
      }
    }
    _notify();
  }

  void _clearNodes() {
    _nodeGen++;
    _nodes.clear();
    _delays.clear();
    _measuring.clear();
    _current = null;
  }

  void _setRunning(bool value) {
    if (_connected == value) return;
    _connected = value;
    _runGen++;
    _started = value ? DateTime.now() : null;
    _sampleTime = null;
    _lastUp = 0;
    _lastDown = 0;
    _uploads.clear();
    _downloads.clear();
    _clearNodes();
    if (!_disposed) traffic.value++;
    _notify();
  }

  Future<void> refreshNodes() async {
    if (!connected || _nodesPolling || _disposed) return;
    _nodesPolling = true;
    final generation = _nodeGen, run = _runGen, group = _group;
    try {
      final data = await controller.call(['proxies']);
      if (_disposed || generation != _nodeGen || run != _runGen || !connected)
        return;
      final info = object(object(data['proxies'])[group]);
      _nodes
        ..clear()
        ..addAll((info['all'] as List? ?? []).whereType<String>());
      _current = info['now'] as String?;
      _notify();
    } catch (_) {
      /* transient controller startup/stop; status remains authoritative */
    } finally {
      _nodesPolling = false;
    }
  }

  Future<void> pollTraffic() async {
    if (!connected || _trafficPolling || _disposed) return;
    _trafficPolling = true;
    final generation = _runGen;
    try {
      final data = await controller.call(['connections']);
      if (_disposed || generation != _runGen || !connected) return;
      var up = 0, down = 0;
      for (final connection in (data['connections'] as List? ?? [])) {
        final value = object(connection);
        up += (value['upload'] as num? ?? 0).toInt();
        down += (value['download'] as num? ?? 0).toInt();
      }
      final now = DateTime.now();
      final elapsed = _sampleTime == null
          ? 1.0
          : math.max(.001, now.difference(_sampleTime!).inMilliseconds / 1000);
      final du = _lastUp > 0 ? math.max(0, up - _lastUp) : 0;
      final dd = _lastDown > 0 ? math.max(0, down - _lastDown) : 0;
      _lastUp = up;
      _lastDown = down;
      _sampleTime = now;
      JsonMap add(Object? raw) {
        final v = object(raw);
        return {
          'up': (v['up'] as num? ?? 0) + du,
          'down': (v['down'] as num? ?? 0) + dd,
        };
      }

      _stats['total'] = add(_stats['total']);
      final months = object(_stats['months']);
      months[_month] = add(months[_month]);
      _stats['months'] = months;
      _uploads.add(du / elapsed);
      _downloads.add(dd / elapsed);
      if (_uploads.length > 60) {
        _uploads.removeAt(0);
        _downloads.removeAt(0);
      }
      traffic.value++;
      _notify();
    } catch (_) {
      /* keep the last valid sample */
    } finally {
      _trafficPolling = false;
    }
  }

  Future<void> _flush() async {
    preferences['freev6-traffic-stats'] = jsonEncode(_stats);
    await store.save(preferences);
  }

  Future<void> _flushSafely() async {
    try {
      await _flush();
    } catch (e) {
      _failure('保存界面偏好失败：$e');
    }
  }

  Future<void> _preference(String key, String value) async {
    final next = {...preferences, key: value};
    await store.save(next);
    preferences
      ..clear()
      ..addAll(next);
    _notify();
  }

  Future<void> _appearance() async {
    try {
      final result = await helper.call('/appearance');
      runtime['accent'] = result['color'];
      runtime['backdrop'] = await host.call('appearance', {
        'mode': preference('freev6-bg-mode', 'default'),
        'dark': preference('freev6-theme') == 'dark',
        'system': preference('freev6-theme', 'system') == 'system',
        'black': preference('freev6-pure-black') == '1',
      });
      _notify();
    } catch (_) {
      /* default opaque theme is always usable */
    }
  }

  Future<void> _saveSettings(JsonMap change) async {
    if (_writing) throw const ApiFailure('设置正在保存，请稍后再试');
    final previous = Map<String, dynamic>.of(settings);
    final next = {...settings, ...change};
    if (next['devMode'] != true && next['mode'] == 'direct')
      next['mode'] = 'rule';
    _writing = true;
    _settingsGen++;
    _notify();
    var hotkeyChanged = false;
    try {
      if (change.containsKey('hotkeyEnabled')) {
        await host.call('hotkey', {'enabled': next['hotkeyEnabled'] == true});
        hotkeyChanged = true;
      }
      final saved = await helper.call('/settings', method: 'PUT', body: next);
      settings
        ..clear()
        ..addAll(saved);
      chain['enabled'] = setting('chainEnabled');
      cloud['enabled'] = setting('cloudEnabled');
      _log(connected ? '设置已保存；网络配置将在重新连接后生效' : '设置已保存');
    } catch (_) {
      if (hotkeyChanged) {
        try {
          await host.call('hotkey', {
            'enabled': previous['hotkeyEnabled'] == true,
          });
        } catch (e) {
          _log('F6 状态恢复失败：$e', warning: true);
        }
      }
      rethrow;
    } finally {
      _writing = false;
      _settingsGen++;
      _notify();
    }
  }

  Future<void> _start({bool automatic = false}) async {
    if (_busy || _disposed) return;
    _busy = true;
    _runGen++;
    _notify();
    try {
      if (runtime['present'] != true)
        throw const ApiFailure('缺少运行核心，请在设置中下载核心', code: 'runtime');
      if (!setting('devMode')) {
        final reply = await transport.send(
          'GET',
          Uri.parse('https://api-ipv6.ip.sb/ip'),
          timeout: const Duration(seconds: 8),
        );
        if (reply.status != 200 || !campusIPv6(reply.body))
          throw const ApiFailure('未检测到教育网 IPv6，请连接校园网后重试', code: 'ipv6');
      }
      if (!setting('cloudEnabled') && runtime['warpRegistered'] != true)
        await _register();
      final response = await helper.call(
        '/proxy/start',
        method: 'POST',
        body: {
          'mode': settings['mode'] ?? 'rule',
          'campusCidrs': settings['campusCidrs'] ?? [],
          'devMode': setting('devMode'),
        },
        timeout: const Duration(seconds: 90),
      );
      _secret = response['controllerSecret']?.toString() ?? _secret;
      _knownStopped = false;
      _setRunning(response['running'] == true);
      if (!connected) throw const ApiFailure('组件未确认连接成功，请刷新状态后重试');
      final hotspot = object(response['hotspot']);
      _log('连接已建立');
      if (hotspot['error'] != null || hotspot['reason'] != null)
        _log(
          '热点共享：${hotspot['error'] ?? hotspot['reason']}',
          warning: hotspot['error'] != null,
        );
      await refreshNodes();
    } finally {
      _busy = false;
      _runGen++;
      _notify();
    }
  }

  Future<void> _stop() async {
    if (_busy) throw const ApiFailure('连接操作正在进行，请稍后重试');
    _busy = true;
    _runGen++;
    _notify();
    try {
      final result = await helper.call(
        '/proxy/stop',
        method: 'POST',
        timeout: const Duration(seconds: 90),
      );
      if (result['running'] != false) throw const ApiFailure('本地组件未确认停止，已保留窗口');
      _knownStopped = true;
      _setRunning(false);
      _log('连接已停止');
      if (result['restoreSkipped'] != null)
        _log('网络恢复提示：${result['restoreSkipped']}', warning: true);
      await _flush();
    } finally {
      _busy = false;
      _runGen++;
      _notify();
    }
  }

  Future<void> _register() => _registration ??= _registerOnce().whenComplete(
    () => _registration = null,
  );
  Future<void> _registerOnce() async {
    final value = await helper.call(
      '/warp/register',
      method: 'POST',
      body: {'name': 'freev6-windows'},
      timeout: const Duration(seconds: 60),
    );
    runtime['warpRegistered'] = value['registered'] == true;
    if (runtime['warpRegistered'] != true) throw const ApiFailure('WARP 注册未完成');
    _log('WARP 注册已完成');
  }

  Future<void> _startup() async {
    final generation = ++_autoGen;
    final automatic = setting('autoRunProxy');
    final deadline = DateTime.now().add(
      Duration(seconds: automatic ? 120 : 60),
    );
    var registrations = 0;
    do {
      if (_disposed || generation != _autoGen || connected || busy) return;
      try {
        if (!setting('cloudEnabled') && runtime['warpRegistered'] != true) {
          if (registrations >= 3) return;
          registrations++;
          await _register();
        }
        if (_disposed || generation != _autoGen) return;
        if (automatic) await _start(automatic: true);
        return;
      } catch (e) {
        _log('启动准备未完成：$e', warning: true);
        if (!automatic || (e is ApiFailure && e.code == 'runtime')) {
          _failure(e);
          return;
        }
      }
      await pause(const Duration(seconds: 5));
    } while (DateTime.now().isBefore(deadline));
    _failure('自动连接等待超时，请确认校园网络后手动连接');
  }

  @override
  Future<void> toggleConnection() async {
    if (!canConnectAction) return;
    _autoGen++;
    try {
      if (connected) {
        await _stop();
      } else {
        await _start();
      }
    } catch (e) {
      _failure(e);
    }
  }

  @override
  void selectMode(String value) {
    if (!canChangeMode ||
        !DashboardModel.modeNames.contains(value) ||
        (value == '直连' && !allowDirectMode))
      return;
    unawaited(
      act('settings.save', {
        'mode': switch (value) {
          '全局' => 'global',
          '直连' => 'direct',
          _ => 'rule',
        },
      }),
    );
  }

  @override
  void selectNode(String? node) {
    if (node == null || !canSelectNode || !_nodes.contains(node)) return;
    unawaited(act('node.select', {'name': node}));
  }

  @override
  void setMonthly(bool value) {
    _monthly = value;
    _notify();
  }

  @override
  Future<void> measure(String node) async {
    if (!canMeasure || !_nodes.contains(node) || !_measuring.add(node)) return;
    final generation = _nodeGen, run = _runGen;
    _notify();
    var delay = 5000;
    try {
      final result = await controller.call(
        ['proxies', node, 'delay'],
        query: {
          'timeout': '5000',
          'url': 'http://www.gstatic.com/generate_204',
        },
      );
      delay = (result['delay'] as num? ?? 5000).toInt();
    } catch (_) {
      /* timeout is represented by 5000 */
    }
    if (_disposed || generation != _nodeGen || run != _runGen || !connected)
      return;
    _measuring.remove(node);
    _delays[node] = delay;
    _notify();
  }

  Future<void> _measureAll() async {
    final queue = List<String>.of(_nodes), generation = _nodeGen, run = _runGen;
    Future<void> worker() async {
      while (queue.isNotEmpty &&
          !_disposed &&
          generation == _nodeGen &&
          run == _runGen &&
          connected) {
        await measure(queue.removeAt(0));
      }
    }

    await Future.wait(
      List.generate(math.min(6, queue.length), (_) => worker()),
    );
  }

  Future<String?> _pick(String kind, {bool save = false}) async =>
      await host.call('file.pick', {'kind': kind, 'save': save}) as String?;
  Future<String> _readFile(String path, int max) async {
    final file = File(path);
    if (await file.length() > max) throw const FormatException('文件超过大小限制');
    return file.readAsString();
  }

  Future<void> _download(String path, JsonMap target, {JsonMap? body}) async {
    await helper.call(
      path,
      method: path.startsWith('/update') ? 'PUT' : 'POST',
      body: body,
    );
    final deadline = DateTime.now().add(const Duration(minutes: 25));
    do {
      if (_disposed) throw const ApiFailure('操作已取消');
      final next = await helper.call(
        path.startsWith('/update')
            ? '/update/progress'
            : '/runtime/download/progress',
      );
      target.addAll(next);
      _notify();
      if (next['state'] == 'done') return;
      if (next['state'] == 'error')
        throw ApiFailure(next['error']?.toString() ?? '下载失败');
      await pause(const Duration(milliseconds: 500));
    } while (DateTime.now().isBefore(deadline));
    throw const ApiFailure('下载等待超时，可稍后重新检查');
  }

  @override
  Future<bool> act(String action, [JsonMap arguments = const {}]) async {
    final exclusive = {
      'settings.save',
      'settings.reset',
      'chain.import',
      'chain.file',
      'chain.clear',
      'cloud.import',
      'cloud.clear',
      'core.download',
      'warp.register',
      'update.install',
      'app.quit',
    }.contains(action);
    if (exclusive && busy) {
      _failure('另一项操作正在进行，请稍后重试');
      return false;
    }
    if (_disposed || !_pending.add(action)) return false;
    if (exclusive) _exclusive = true;
    _notify();
    try {
      switch (action) {
        case 'refresh':
          await refreshStatus(strict: true);
          await refreshResources();
          await refreshNodes();
        case 'settings.save':
          _autoGen++;
          await _saveSettings(arguments);
        case 'preferences.set':
          await _preference(
            arguments['key'] as String,
            arguments['value'] as String,
          );
          await _appearance();
        case 'node.group':
          proxyTab = arguments['tab'] == 'chain' ? 'chain' : 'access';
          _clearNodes();
          await refreshNodes();
        case 'node.select':
          final gen = ++_nodeGen, run = _runGen;
          _measuring.clear();
          await controller.call(
            ['proxies', _group],
            method: 'PUT',
            body: {'name': arguments['name']},
          );
          if (gen == _nodeGen && run == _runGen && connected) {
            _current = arguments['name'] as String;
            _log('接入点已切换');
          }
        case 'nodes.measure':
          await _measureAll();
        case 'chain.import' ||
            'cloud.import' ||
            'chain.file' ||
            'chain.clear' ||
            'cloud.clear':
          final cloudAction = action.startsWith('cloud');
          final endpoint = cloudAction ? '/cloud-config' : '/chain-proxy';
          JsonMap? body = arguments;
          if (action == 'chain.file') {
            final path = await _pick('yaml');
            if (path == null) return false;
            body = {'content': await _readFile(path, 2 * 1024 * 1024)};
          }
          _settingsGen++;
          _writing = true;
          try {
            await helper.call(
              endpoint,
              method: action.endsWith('.clear') ? 'DELETE' : 'PUT',
              body: body,
              timeout: const Duration(seconds: 90),
            );
          } finally {
            _settingsGen++;
            _writing = false;
          }
          await refreshStatus(strict: true);
          await refreshResources();
          _log(connected ? '配置已保存，重新连接后生效' : '配置已保存');
        case 'core.download':
          if (connected) throw const ApiFailure('请先断开连接再更新运行核心');
          await _download('/runtime/download', coreDownload);
          runtime.addAll(await helper.call('/runtime'));
        case 'warp.register':
          if (connected) throw const ApiFailure('请先断开连接再重新注册 WARP');
          _autoGen++;
          await _register();
        case 'settings.reset':
          if (connected || !_knownStopped)
            throw const ApiFailure('请先确认连接已停止，再恢复默认设置');
          _autoGen++;
          _settingsGen++;
          _writing = true;
          try {
            await helper.call('/settings/reset', method: 'POST');
          } finally {
            _settingsGen++;
            _writing = false;
          }
          await host.call('hotkey', {'enabled': false});
          await refreshStatus(strict: true);
          await refreshResources();
        case 'preferences.import':
          final path = await _pick('json');
          if (path == null) return false;
          final imported = LegacyPreferences.decode(
            await _readFile(path, LegacyPreferences.maxBytes),
          );
          final next = {
            ...preferences,
            ...imported.values,
            'legacy-imported': '1',
          };
          await store.save(next);
          preferences
            ..clear()
            ..addAll(next);
          _readStats();
          await _appearance();
          _log('界面备份已导入');
        case 'preferences.export':
          await _flush();
          final path = await _pick('json', save: true);
          if (path == null) return false;
          final content = jsonEncode({
            'format': 'freev6-ui-preferences',
            'version': 1,
            'values': {
              for (final entry in preferences.entries)
                if (LegacyPreferences.keys.contains(entry.key))
                  entry.key: entry.value,
            },
          });
          final validated = LegacyPreferences.decode(content).encode();
          await File(path).writeAsString(validated, flush: true);
          _log('界面备份已导出');
        case 'wallpaper.choose':
          final path = await _pick('image');
          if (path == null) return false;
          final file = File(path);
          if (await file.length() > 4 * 1024 * 1024)
            throw const FormatException('壁纸不能超过 4 MiB');
          final bytes = await file.readAsBytes();
          final png =
              bytes.length >= 8 &&
              bytes[0] == 137 &&
              bytes[1] == 80 &&
              bytes[2] == 78 &&
              bytes[3] == 71;
          final jpg =
              bytes.length >= 3 &&
              bytes[0] == 255 &&
              bytes[1] == 216 &&
              bytes[2] == 255;
          if (!png && !jpg) throw const FormatException('请选择 PNG 或 JPEG 壁纸');
          await _preference(
            'freev6-wallpaper',
            'data:image/${png ? 'png' : 'jpeg'};base64,${base64Encode(bytes)}',
          );
          await _preference('freev6-bg-mode', 'wallpaper');
        case 'wallpaper.clear':
          final next = {...preferences}..remove('freev6-wallpaper');
          next['freev6-bg-mode'] = 'default';
          await store.save(next);
          preferences
            ..clear()
            ..addAll(next);
        case 'notice.read':
          await _preference(
            'freev6-notice-read',
            jsonEncode(
              notices
                  .map((n) => n['id']?.toString() ?? '')
                  .where((id) => id.isNotEmpty)
                  .take(50)
                  .toList(),
            ),
          );
        case 'update.check':
          final info = await helper.call(
            '/update/latest',
            timeout: const Duration(seconds: 60),
          );
          if (info['error'] != null) throw ApiFailure(info['error'].toString());
          update
            ..clear()
            ..addAll(info)
            ..['available'] =
                info['update'] == true &&
                compareVersions(info['version']?.toString() ?? '', version) > 0;
        case 'update.skip':
          await _preference(
            'freev6-skip-version',
            update['version']?.toString() ?? '',
          );
          update['available'] = false;
        case 'update.install':
          _autoGen++;
          if (update['available'] != true) throw const ApiFailure('请先检查更新');
          await _download(
            '/update/download',
            update,
            body: {'url': update['download'], 'sha256': update['sha256']},
          );
          // Restore DNS/hotspot before launching the installer. Failure keeps UI alive.
          if (connected || !_knownStopped) await _stop();
          await _flush();
          await host.call('update.apply', {
            'path': update['path'],
            'sha256': update['sha256'],
          });
        case 'app.quit':
          _autoGen++;
          if (connected || !_knownStopped) await _stop();
          await _flush();
          await host.call('app.quit');
        case 'external.open':
          await host.call('external.open', arguments);
        case 'logs.clear':
          _logs.clear();
        default:
          throw ApiFailure('未知操作：$action');
      }
      return true;
    } catch (e) {
      _failure(e);
      return false;
    } finally {
      _pending.remove(action);
      if (exclusive) _exclusive = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _autoGen++;
    for (final timer in _timers) {
      timer.cancel();
    }
    _subscription?.cancel();
    transport.close();
    traffic.dispose();
    super.dispose();
  }
}
