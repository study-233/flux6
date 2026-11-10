import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../dashboard_model.dart';
export '../dashboard_model.dart' show PreviewLog;

enum _Session { offline, connecting, online, disconnecting }

/// The P1 app owns only this synthetic state file. It never contacts a network
/// controller, reads production preferences, or samples real network traffic.
class FixtureModel extends DashboardModel {
  FixtureModel._(this._file, {required bool periodicSampling})
    : _periodicSampling = periodicSampling;

  static const modes = ['规则', '全局', '直连'];
  final nodes = const ['东区', '西区', '北区'];
  static const _maxLogs = 100;
  static const _maxHistory = 48;
  final profileName = '校园 IPv6';
  final File? _file;
  final bool _periodicSampling;
  final traffic = ValueNotifier<int>(0);
  final _latencies = <String, int>{};
  final _measuring = <String>{};
  final _logs = <PreviewLog>[];
  final _up = <double>[];
  final _down = <double>[];
  Timer? _timer;
  bool _closed = false;
  bool _zero = false;
  int _tick = 0;
  int _sessionID = 0;
  DateTime? _started;
  _Session _session = _Session.online;
  String _mode = '规则';
  String? _preferred;
  bool _monthly = true;
  String? _storageWarning;

  static Future<FixtureModel> load({
    Directory? directory,
    bool periodicSampling = true,
  }) async {
    final home = Platform.environment['HOME'];
    final folder =
        directory ??
        (home == null
            ? Directory(
                '${Directory.systemTemp.path}/dev.freev6.flutter-preview',
              )
            : Directory(
                '$home/Library/Application Support/dev.freev6.flutter-preview',
              ));
    final model = FixtureModel._(
      File('${folder.path}/fixture-v1.json'),
      periodicSampling: periodicSampling,
    );
    try {
      final file = model._file!;
      if (await file.exists()) {
        final data = jsonDecode(await file.readAsString());
        if (data is Map && data['version'] == 1) model._restore(data);
      } else {
        model._add('已载入校园 IPv6 演示配置');
        model._add('已连接 · 自动选择东区');
      }
    } on Object {
      model._storageWarning = '预览记录无法读取，已使用初始场景';
      model._add(model._storageWarning!, level: '警告');
    }
    model._startSampler();
    return model;
  }

  @visibleForTesting
  factory FixtureModel.memory({bool online = true}) {
    final model = FixtureModel._(null, periodicSampling: false);
    model._session = online ? _Session.online : _Session.offline;
    model._startSampler();
    return model;
  }

  bool get connected => _session == _Session.online;
  bool get busy =>
      _session == _Session.connecting || _session == _Session.disconnecting;
  bool get monthly => _monthly;
  bool get zeroRate => _zero;
  String get mode => _mode;
  String? get preferredNode => _preferred;
  String? get currentNode => connected ? (_preferred ?? nodes.first) : null;
  String get displayNode => currentNode ?? _preferred ?? '自动选择';
  String get phaseLabel => switch (_session) {
    _Session.offline => '未连接',
    _Session.connecting => '连接中',
    _Session.online => '已连接',
    _Session.disconnecting => '断开中',
  };
  Duration get uptime => connected && _started != null
      ? DateTime.now().difference(_started!)
      : Duration.zero;
  List<PreviewLog> get logs => List.unmodifiable(_logs);
  String? get storageWarning => _storageWarning;
  List<double> get uploadHistory => List.unmodifiable(_up);
  List<double> get downloadHistory => List.unmodifiable(_down);
  double? get uploadRate => _up.lastOrNull;
  double? get downloadRate => _down.lastOrNull;
  int get usageUpload => monthly ? 85600000 : 1930000000;
  int get usageDownload => monthly ? 336000000 : 7640000000;
  int? latency(String node) => _latencies[node];
  bool measuring(String node) => _measuring.contains(node);

  void _startSampler() {
    if (connected) {
      _started = DateTime.now().subtract(const Duration(hours: 2, minutes: 13));
      _seedChart();
    }
    if (_periodicSampling) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (connected) _sample();
      });
    }
  }

  void _restore(Map data) {
    if (modes.contains(data['mode'])) _mode = data['mode'] as String;
    if (nodes.contains(data['node'])) _preferred = data['node'] as String;
    _session = data['online'] == false ? _Session.offline : _Session.online;
    _monthly = data['monthly'] != false;
    if (data['logs'] case final List records) {
      _logs.addAll(
        records.map(PreviewLog.fromJson).whereType<PreviewLog>().take(_maxLogs),
      );
    }
  }

  void _persist() {
    final file = _file;
    if (file == null) return;
    final data = jsonEncode({
      'version': 1,
      'mode': _mode,
      'node': _preferred,
      'online': connected,
      'monthly': monthly,
      'logs': _logs.map((item) => item.toJson()).toList(),
    });
    try {
      // Small, bounded writes only on explicit actions; completed even if the
      // user quits immediately after clicking a preference. Samples never write.
      file.parent.createSync(recursive: true);
      final next = File('${file.path}.new');
      next.writeAsStringSync(data);
      next.renameSync(file.path);
      _storageWarning = null;
    } on FileSystemException {
      if (_storageWarning == null) _add('预览偏好未能保存', level: '警告');
      _storageWarning = '预览偏好未能保存';
    }
  }

  void _add(String message, {String level = '信息'}) {
    _logs.insert(0, PreviewLog(DateTime.now(), message, level: level));
    if (_logs.length > _maxLogs) _logs.removeLast();
  }

  void _seedChart() {
    _up.clear();
    _down.clear();
    for (var i = 0; i < _maxHistory; i++) {
      _sample(notify: false);
    }
  }

  void _sample({bool notify = true}) {
    _tick++;
    final t = _tick / 4.0;
    final up = math.max(
      0.0,
      46000 + 14200 * math.sin(t) + 8400 * math.cos(t * 0.52),
    );
    final down = math.max(
      0.0,
      1580000 + 482000 * math.sin(t * 0.65 + 1) + 339000 * math.cos(t * 1.43),
    );
    _up.add(_zero ? 0 : up);
    _down.add(_zero ? 0 : down);
    if (_up.length > _maxHistory) _up.removeAt(0);
    if (_down.length > _maxHistory) _down.removeAt(0);
    if (notify) traffic.value++;
  }

  void selectMode(String value) {
    if (busy || !modes.contains(value) || _mode == value) return;
    _mode = value;
    _add(connected ? '已切换至${value}模式' : '下次连接使用${value}模式');
    _persist();
    notifyListeners();
  }

  void selectNode(String? node) {
    if (busy || (node != null && !nodes.contains(node)) || node == _preferred)
      return;
    _preferred = node;
    final target = node ?? '自动选择';
    _add(connected ? '当前接入节点已切换 · $target' : '下次连接的接入节点 · $target');
    _persist();
    notifyListeners();
  }

  void setMonthly(bool value) {
    if (value == _monthly) return;
    _monthly = value;
    _persist();
    notifyListeners();
  }

  Future<void> toggleConnection() async {
    if (busy) return;
    final online = !connected;
    final request = ++_sessionID;
    _session = online ? _Session.connecting : _Session.disconnecting;
    _up.clear();
    _down.clear();
    _measuring.clear();
    notifyListeners();
    traffic.value++;
    await Future<void>.delayed(const Duration(milliseconds: 440));
    if (!_closed && request == _sessionID) setOnline(online);
  }

  /// A direct scenario switch may supersede a pending simulated connection.
  void setOnline(bool value) {
    ++_sessionID;
    _measuring.clear();
    _latencies.clear();
    _up.clear();
    _down.clear();
    _session = value ? _Session.online : _Session.offline;
    _started = value ? DateTime.now() : null;
    if (value) {
      _seedChart();
      _add('已连接 · $currentNode · $_mode模式');
    } else {
      _add('已断开连接');
    }
    _persist();
    notifyListeners();
    traffic.value++;
  }

  void setZeroRate(bool value) {
    if (_zero == value) return;
    _zero = value;
    if (connected) _sample();
    notifyListeners();
  }

  Future<void> measure(String node) async {
    if (!connected || !nodes.contains(node) || !_measuring.add(node)) return;
    final request = _sessionID;
    notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 280));
    if (_closed || request != _sessionID || !connected) return;
    _latencies[node] = [24, 18, 37][nodes.indexOf(node)];
    _measuring.remove(node);
    _add('$node · 延迟 ${_latencies[node]} ms');
    _persist();
    notifyListeners();
  }

  Future<void> measureAll() async {
    await Future.wait(nodes.map(measure));
  }

  void clearLogs() {
    _logs.clear();
    _persist();
    notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    _timer?.cancel();
    traffic.dispose();
    super.dispose();
  }
}
