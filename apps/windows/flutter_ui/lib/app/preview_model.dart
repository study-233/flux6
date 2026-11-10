import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../dashboard_model.dart';

/// Memory-only fixture. This library deliberately has no IO or HTTP imports.
class PreviewModel extends DashboardModel {
  PreviewModel() {
    _logs.add(PreviewLog(DateTime(2026, 11, 10, 12), '已载入演示数据，不会连接网络'));
  }
  bool _connected = false, _busy = false, _monthly = true, _disposed = false;
  String _mode = '规则';
  String? _preferred;
  final _delays = <String, int>{};
  final _measuring = <String>{};
  final _logs = <PreviewLog>[];
  @override
  final traffic = ValueNotifier<int>(0);
  @override
  final nodes = const ['东区 · IPv6', '西区 · IPv6', '北区 · IPv6'];
  @override
  String get profileName => '校园 IPv6';
  @override
  bool get connected => _connected;
  @override
  bool get busy => _busy;
  @override
  bool get monthly => _monthly;
  @override
  String get mode => _mode;
  @override
  String get phaseLabel =>
      _busy ? (_connected ? '断开中' : '连接中') : (_connected ? '已连接' : '未连接');
  @override
  String? get preferredNode => _preferred;
  @override
  String? get currentNode => connected ? (_preferred ?? nodes.first) : null;
  @override
  String get displayNode => currentNode ?? _preferred ?? '自动选择';
  @override
  Duration get uptime => connected ? const Duration(minutes: 8) : Duration.zero;
  @override
  List<double> get uploadHistory => _samples(32000);
  @override
  List<double> get downloadHistory => _samples(780000);
  List<double> _samples(double base) => connected
      ? List.generate(48, (i) => base * (1.2 + math.sin(i * .37) * .6))
      : const [];
  @override
  int get usageUpload => monthly ? 85600000 : 1930000000;
  @override
  int get usageDownload => monthly ? 336000000 : 7640000000;
  @override
  List<PreviewLog> get logs => List.unmodifiable(_logs);
  @override
  int? latency(String node) => _delays[node];
  @override
  bool measuring(String node) => _measuring.contains(node);
  void _log(String message) {
    _logs.insert(0, PreviewLog(DateTime.now(), message));
    if (_logs.length > 100) _logs.removeLast();
    notifyListeners();
  }

  @override
  void selectMode(String value) {
    if (!DashboardModel.modeNames.contains(value) || busy) return;
    _mode = value;
    _log('演示模式：$value');
  }

  @override
  void selectNode(String? node) {
    if (busy || (node != null && !nodes.contains(node))) return;
    _preferred = node;
    _log('演示接入点：${node ?? '自动选择'}');
  }

  @override
  void setMonthly(bool value) {
    _monthly = value;
    notifyListeners();
  }

  @override
  Future<void> toggleConnection() async {
    if (busy || _disposed) return;
    _busy = true;
    notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (_disposed) return;
    _connected = !_connected;
    _busy = false;
    traffic.value++;
    _log(connected ? '演示连接已建立' : '演示连接已断开');
  }

  @override
  Future<void> measure(String node) async {
    if (!canMeasure || !nodes.contains(node) || !_measuring.add(node)) return;
    notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (_disposed) return;
    _measuring.remove(node);
    if (connected) _delays[node] = 24 + nodes.indexOf(node) * 17;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    traffic.dispose();
    super.dispose();
  }
}
