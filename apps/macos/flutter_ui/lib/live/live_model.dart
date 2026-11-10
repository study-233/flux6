import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../dashboard_model.dart';

typedef StateMap = Map<String, dynamic>;

dynamic _normalize(dynamic value) => switch (value) {
  Map() => {
    for (final entry in value.entries)
      if (entry.key is String) entry.key as String: _normalize(entry.value),
  },
  List() => value.map(_normalize).toList(growable: false),
  _ => value,
};
StateMap readMap(dynamic input) =>
    input is Map ? _normalize(input) as StateMap : {};
List<StateMap> readRecords(dynamic input) => input is List
    ? input.whereType<Map>().map(readMap).toList(growable: false)
    : [];
List<String> readStrings(dynamic input) =>
    input is List ? input.whereType<String>().toList() : [];

class LiveCommandError implements Exception {
  const LiveCommandError(this.message, [this.code]);
  final String message;
  final String? code;
  @override
  String toString() => message;
}

/// Each engine subscribes before reading the first snapshot. Native revisions
/// are authoritative across windows, including when a reply arrives late.
class LiveModel extends DashboardModel with WidgetsBindingObserver {
  LiveModel({
    this.channel = const MethodChannel('dev.freev6.host/v1'),
    this.events = const EventChannel('dev.freev6.host/v1/events'),
    this.windowRole = 'main',
  });
  final MethodChannel channel;
  final EventChannel events;
  final String windowRole;
  StateMap state = {};
  final _random = Random.secure();
  String _requestId() {
    final bytes = List.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  int _cursor = -1;
  int _lastSample = -1;
  String? _sampleSession;
  String? message;
  bool _disposed = false, _started = false, _refreshing = false, _dirty = false;
  final traffic = ValueNotifier<int>(0);
  final _actions = StreamController<String>.broadcast();
  Stream<String> get uiActions => _actions.stream;
  void deliverUiAction(String action) {
    if (!_disposed) _actions.add(action);
  }

  final draftHandlers = <String, Future<bool> Function(bool)>{};
  final _measures = <String>{};
  final _pending = <String>{};
  final _selections =
      <
        String,
        ({
          String action,
          StateMap args,
          Object? session,
          Completer<bool> result,
        })
      >{};
  bool _writingSelection = false;

  StreamSubscription<dynamic>? _subscription;
  Timer? _retry;
  bool _monthly = true;

  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    channel.setMethodCallHandler(_handleNative);
    _listen();
    await resync();
  }

  void _listen() {
    if (_disposed) return;
    _subscription = events
        .receiveBroadcastStream({'version': 1})
        .listen(
          (raw) {
            final event = readMap(raw);
            if (event['version'] != 1) {
              _report('宿主版本不兼容，请重新打开验收应用。');
              return;
            }
            final next = readMap(event['snapshot']);
            final gap =
                _cursor >= 0 &&
                event['cursor'] is int &&
                event['cursor'] > _cursor + 1;
            final kind = event['kind'] as String? ?? 'state';
            if (kind == 'traffic') {
              if (event['cursor'] is! int || event['cursor'] <= _cursor) return;
              if (gap ||
                  state.isEmpty ||
                  next['sessionId'] != state['sessionId']) {
                unawaited(resync());
                return;
              }
              const trafficFields = {
                'sampleTime',
                'sampleSeq',
                'startedAt',
                'trafficError',
                'uploadRate',
                'downloadRate',
                'uploadHistory',
                'downloadHistory',
                'usage',
                'uptimeSeconds',
              };
              _apply({
                ...state,
                'cursor': event['cursor'],
                for (final field in trafficFields)
                  if (next.containsKey(field)) field: next[field],
              }, kind: 'traffic');
            } else {
              _apply(next);
              if (gap) unawaited(resync());
            }
          },
          onError: (Object error) {
            _report('状态订阅中断，正在重新同步。');
            _relisten();
          },
          onDone: _relisten,
        );
  }

  void _relisten() {
    if (_disposed || (_retry?.isActive ?? false)) return;
    _retry = Timer(const Duration(seconds: 1), () async {
      await _subscription?.cancel();
      if (_disposed) return;
      _listen();
      await resync();
    });
  }

  Future<dynamic> _handleNative(MethodCall call) async {
    if (call.method != 'uiAction') throw MissingPluginException(call.method);
    final fields = readMap(call.arguments);
    final name = fields['action'];
    if (name == 'saveDrafts' || name == 'discardDrafts')
      return finishDrafts(name == 'saveDrafts');
    if (name == 'refresh' || name == 'wake') {
      await resync();
      return true;
    }
    if (name == 'goto') {
      _actions.add('goto.${readMap(fields['args'])['page']}');
    } else if (name is String) {
      _actions.add(name);
    }
    return true;
  }

  Future<bool> finishDrafts(bool save) async {
    try {
      for (final callback in draftHandlers.values.toList()) {
        if (!await callback(save)) return false;
      }
      await command(save ? 'draft.saveAll' : 'draft.discardAll', {
        'window': windowRole,
      });
      return true;
    } on LiveCommandError {
      return false;
    }
  }

  bool _again = false;
  Future<void> resync() async {
    if (_disposed) return;
    if (_refreshing) {
      _again = true;
      return;
    }
    _refreshing = true;
    try {
      final snap = readMap(
        await channel.invokeMethod('snapshot', {'version': 1}),
      );
      _apply(snap, resync: true);
    } on Object {
      _report('无法读取宿主状态，请重试。');
    } finally {
      _refreshing = false;
      if (_again) {
        _again = false;
        unawaited(resync());
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(resync());
  }

  void _apply(StateMap next, {String kind = 'state', bool resync = false}) {
    if (_disposed) return;
    if (next['version'] != 1 || next['cursor'] is! int) {
      _report('无法识别宿主状态版本。');
      return;
    }
    final cursor = next['cursor'] as int;
    if (cursor < _cursor || (cursor == _cursor && !resync)) return;
    final changed = cursor > _cursor;
    _cursor = cursor;
    state = next;
    final seq = (next['sampleSeq'] as num?)?.toInt() ?? -1;
    final session = next['sessionId']?.toString();
    if (seq != _lastSample || session != _sampleSession || kind == 'traffic') {
      _sampleSession = session;
      _lastSample = seq;
      traffic.value++;
    }
    final dirty =
        readMap(readMap(next['settings'])['drafts'])[windowRole] == true;
    if (dirty != _dirty) {
      _dirty = dirty;
      unawaited(platform('setDirty', {'dirty': dirty}).catchError((_) => null));
    }
    if (kind != 'traffic' && (changed || resync)) notifyListeners();
  }

  Future<StateMap> command(String action, [StateMap args = const {}]) async {
    final requestId = _requestId();
    try {
      final result = readMap(
        await channel.invokeMethod('command', {
          'version': 1,
          'id': requestId,
          'name': action,
          'arguments': args,
          'sessionId': state['sessionId'],
          'sessionRevision': state['sessionRevision'],
          'controlToken': state['controlToken'],
          'revision': state['revision'],
        }),
      );
      if (result['snapshot'] is Map) _apply(readMap(result['snapshot']));
      if (result['ok'] != true)
        throw LiveCommandError(
          result['error']?.toString() ?? '操作未完成，请重新读取状态。',
          result['code']?.toString(),
        );
      return result;
    } on LiveCommandError catch (error) {
      _report(error.message);
      rethrow;
    } on PlatformException catch (error) {
      final detail = LiveCommandError(
        error.message ?? '宿主通信失败，请重试。',
        error.code,
      );
      _report(detail.message);
      throw detail;
    } on Object {
      const error = LiveCommandError('无法连接到窗口宿主，请重新打开应用。');
      _report(error.message);
      throw error;
    }
  }

  Future<dynamic> platform(String method, [StateMap args = const {}]) =>
      channel.invokeMethod<dynamic>(method, args);
  void _report(String value) {
    if (!_disposed) {
      message = value;
      notifyListeners();
    }
  }

  void dismissMessage() {
    message = null;
    if (!_disposed) notifyListeners();
  }

  Future<bool> perform(String action, [StateMap args = const {}]) async {
    try {
      await command(action, args);
      return true;
    } on LiveCommandError {
      return false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    channel.setMethodCallHandler(null);
    _subscription?.cancel();
    _actions.close();
    traffic.dispose();
    super.dispose();
  }

  bool get needsPreparation =>
      capability('prepareService') &&
      ['missing', 'needsRepair'].contains(state['service']);
  bool capability(String name) => readMap(state['capabilities'])[name] == true;
  String get phase => state['phase'] as String? ?? 'unknown';
  @override
  bool get connected => phase == 'running';
  @override
  bool get busy =>
      phase == 'connecting' ||
      phase == 'disconnecting' ||
      _pending.contains('connection');
  @override
  bool get canConnectAction =>
      !busy &&
      (capability('connect') ||
          capability('disconnect') ||
          capability('recover') ||
          phase == 'recovering' && capability('retryRecovery'));
  @override
  bool get canChangeMode => capability('mode');
  @override
  bool get canSelectNode => capability('node');
  @override
  bool get canMeasure => capability('measure');
  @override
  String get phaseLabel => switch (phase) {
    'idle' => '未连接',
    'running' => '已连接',
    'connecting' => '连接中',
    'disconnecting' => '断开中',
    'recovering' || 'recoveryRequired' => '待恢复',
    'occupied' => '由其他会话使用',
    _ => '正在读取状态',
  };
  @override
  String get actionLabel => connectionAction;
  String get connectionAction => switch (phase) {
    'running' => '断开',
    'recovering' || 'recoveryRequired' => '重试恢复',
    'idle' => '连接',
    _ => phaseLabel,
  };
  static const modeLabels = {'rule': '规则', 'global': '全局', 'direct': '直连'};
  @override
  String get mode =>
      modeLabels[(connected ? state['liveMode'] : null) ?? state['mode']] ??
      '—';
  @override
  String? get modeHint =>
      connected &&
          state['liveMode'] != null &&
          state['liveMode'] != state['savedMode'] &&
          state['savedMode'] != null
      ? '下次连接使用${modeLabels[state['savedMode']] ?? '—'}模式'
      : null;
  @override
  String get profileName => state['profileName'] as String? ?? '尚未准备配置';
  List<StateMap> get groups => readRecords(state['groups']);
  StateMap groupData(String id) =>
      groups.where((g) => g['id'] == id).firstOrNull ?? {};
  String get group => state['group'] as String? ?? 'access';
  @override
  List<String> get nodes =>
      readStrings(groupData(group)['members'] ?? state['nodes']);
  @override
  String? get preferredNode => state['preferredNode'] as String?;
  @override
  String? get currentNode => connected ? state['currentNode'] as String? : null;
  @override
  String get displayNode =>
      currentNode ?? (connected ? '正在确认' : preferredNode ?? '自动选择');
  @override
  bool get monthly => _monthly;
  StateMap get _usage => readMap(state['usage']);
  String get _prefix => monthly ? 'monthly' : 'total';
  @override
  bool get usageKnown =>
      _usage['${_prefix}Upload'] is num && _usage['${_prefix}Download'] is num;
  @override
  int get usageUpload => (_usage['${_prefix}Upload'] as num?)?.toInt() ?? 0;
  @override
  int get usageDownload => (_usage['${_prefix}Download'] as num?)?.toInt() ?? 0;
  @override
  void setMonthly(bool value) {
    if (_monthly != value) {
      _monthly = value;
      notifyListeners();
    }
  }

  @override
  bool get uptimeKnown =>
      connected &&
      (state['uptimeSeconds'] is num || state['startedAt'] is String);
  @override
  Duration get uptime {
    final start = DateTime.tryParse(state['startedAt']?.toString() ?? '');
    return start != null
        ? DateTime.now().difference(start)
        : Duration(seconds: (state['uptimeSeconds'] as num?)?.toInt() ?? 0);
  }

  List<double> _history(String name) => (state[name] as List? ?? [])
      .whereType<num>()
      .map((v) => v.toDouble())
      .where((v) => v.isFinite && v >= 0)
      .toList();
  @override
  List<double> get uploadHistory =>
      state.containsKey('uploadRate') && state['uploadRate'] == null
      ? []
      : _history('uploadHistory');
  @override
  List<double> get downloadHistory =>
      state.containsKey('downloadRate') && state['downloadRate'] == null
      ? []
      : _history('downloadHistory');
  @override
  List<PreviewLog> get logs => readRecords(
    state['logs'],
  ).map(PreviewLog.fromJson).whereType<PreviewLog>().toList();
  @override
  List<StateMap>? get customLayout {
    final settings = readMap(state['settings']);
    return settings['layoutCustom'] == true
        ? readRecords(settings['layout'])
        : null;
  }

  // The next selection uses the token returned for the previous write. This
  // lets a quick second click win without targeting a different session.
  Future<bool> _select(String key, String action, StateMap args) {
    final result = Completer<bool>();
    _selections.remove(key)?.result.complete(false);
    _selections[key] = (
      action: action,
      args: args,
      session: state['sessionId'],
      result: result,
    );
    if (!_writingSelection) unawaited(_drainSelections());
    return result.future;
  }

  Future<void> _drainSelections() async {
    _writingSelection = true;
    try {
      while (_selections.isNotEmpty) {
        final item = _selections.remove(_selections.keys.first)!;
        if (_disposed || item.session != state['sessionId']) {
          item.result.complete(false);
          if (!_disposed) _report('会话已变更，请重新选择。');
          continue;
        }
        item.result.complete(await perform(item.action, item.args));
      }
    } finally {
      _writingSelection = false;
    }
  }

  @override
  void selectMode(String label) {
    final value = modeLabels.entries
        .where((x) => x.value == label)
        .firstOrNull
        ?.key;
    if (value != null && canChangeMode)
      unawaited(_select('mode', 'setMode', {'mode': value}));
  }

  @override
  void selectNode(String? node) => unawaited(chooseNode(group, node));
  Future<bool> chooseNode(String id, String? node) async =>
      canSelectNode &&
      await _select('node:$id', 'setNode', {'group': id, 'node': node});
  int? groupLatency(String id, String node) {
    final scoped = readMap(groupData(id)['latencies']);
    final value =
        scoped[node] ??
        (id == group ? readMap(state['latencies'])[node] : null);
    return switch (value) {
      num ms => ms.toInt(),
      'timeout' => -1,
      'unavailable' => -2,
      _ => null,
    };
  }

  @override
  int? latency(String node) => groupLatency(group, node);
  @override
  bool measuring(String node) => _measures.contains('$group/$node');
  bool measuringIn(String id, String node) => _measures.contains('$id/$node');
  @override
  Future<void> measure(String node) => measureGroup(group, [node]);
  Future<void> measureGroup(String id, List<String> nodes) async {
    if (!canMeasure) return;
    final list = nodes.where((n) => !measuringIn(id, n)).toList();
    if (list.isEmpty) return;
    final keys = list.map((n) => '$id/$n').toSet();
    _measures.addAll(keys);
    notifyListeners();
    try {
      await perform('measure', {'group': id, 'nodes': list});
    } finally {
      _measures.removeAll(keys);
      if (!_disposed) notifyListeners();
    }
  }

  @override
  Future<void> toggleConnection() async {
    if (!canConnectAction) return;
    final action = connected
        ? 'disconnect'
        : phase == 'recovering' || phase == 'recoveryRequired'
        ? 'retryRecovery'
        : 'connect';
    _pending.add('connection');
    notifyListeners();
    try {
      await perform(action);
    } finally {
      _pending.remove('connection');
      if (!_disposed) notifyListeners();
    }
  }
}
