import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api.dart';

/// Node policy stays in the helper; this object observes one session/group.
class NodeTools extends ChangeNotifier {
  NodeTools(this.api);
  final HelperApi api;
  String session = '', group = '♻️ 自动选择';
  JsonMap state = {};
  final results = <String, JsonMap>{};
  String? error, measuring;
  int streams = 1, completed = 0, total = 0;
  int _generation = 0, _downloadGeneration = 0;
  bool _disposed = false, downloading = false;
  bool selecting = false;
  int _policyRevision = 0;
  int? _refreshGeneration;
  Future<void>? _refreshing;
  Transport? _downloadTransport;

  JsonMap get quality => object(state['quality']);
  String get pinned => quality['pinned']?.toString() ?? '';
  List<String> get candidates =>
      (state['candidates'] as List? ?? []).whereType<String>().toList();
  List<String> get activeNodes =>
      (state['activeNodes'] as List? ?? []).whereType<String>().toList();
  JsonMap scope() => {
    'session': session,
    'group': group,
    'profile': state['profile'],
  };

  void bind(String nextSession, String nextGroup) {
    if (session == nextSession && group == nextGroup) return;
    _generation++;
    selecting = false;
    cancelDownload(notify: false);
    session = nextSession;
    group = nextGroup;
    state = {};
    results.clear();
    error = null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> refresh() {
    if (_disposed) return Future.value();
    if (_refreshGeneration == _generation) return _refreshing!;
    _refreshGeneration = _generation;
    return _refreshing = _refresh();
  }

  Future<void> _refresh() async {
    final generation = _generation, revision = _policyRevision;
    try {
      final next = await api.call(
        '/nodes/quality',
        query: {'session': session, 'group': group},
      );
      if (_disposed || generation != _generation || revision != _policyRevision)
        return;
      state = next;
      error = next['problem']?.toString();
      _notify();
    } catch (failure) {
      if (!_disposed &&
          generation == _generation &&
          revision == _policyRevision) {
        error = failure.toString();
        _notify();
      }
    } finally {
      if (_refreshGeneration == generation) _refreshGeneration = null;
    }
  }

  Future<void> select({String? node, int? poolSize}) async {
    if (session.isEmpty) throw const ApiFailure('请连接后再选择节点');
    if (selecting) throw const ApiFailure('节点切换正在进行，请稍后重试');
    final generation = _generation;
    selecting = true;
    _notify();
    try {
      if (state['profile'] == null) await refresh();
      if (_disposed || generation != _generation)
        throw const ApiFailure('连接已变更，请重试');
      if (state['profile'] == null) throw const ApiFailure('节点状态尚未就绪，请刷新重试');
      // A poll begun before the write cannot replace the confirmed selection.
      _policyRevision++;
      final next = await api.call(
        '/nodes/quality',
        method: 'PUT',
        body: {
          ...scope(),
          'mode': node == null ? 'auto' : 'fixed',
          if (node != null) 'node': node,
          if (poolSize != null) 'poolSize': poolSize,
        },
      );
      if (_disposed || generation != _generation)
        throw const ApiFailure('连接已变更，请重试');
      _policyRevision++;
      state = next;
      error = null;
    } finally {
      if (!_disposed && generation == _generation) {
        selecting = false;
        _notify();
      }
    }
  }

  Future<void> download(List<String> nodes) async {
    if (downloading || session.isEmpty || nodes.isEmpty) return;
    if (state['profile'] == null) await refresh();
    if (state['profile'] == null) throw const ApiFailure('节点状态尚未就绪，请刷新重试');
    final generation = _generation, operation = ++_downloadGeneration;
    final count = streams;
    final scopeSnapshot = scope();
    final transport = api.transport.fork();
    _downloadTransport = transport;
    final client = HelperApi(transport, api.credentials);
    downloading = true;
    completed = 0;
    total = nodes.length;
    bool current() =>
        !_disposed &&
        generation == _generation &&
        operation == _downloadGeneration;
    try {
      for (final node in nodes) {
        if (!current()) break;
        measuring = node;
        _notify();
        try {
          JsonMap? result;
          for (var attempt = 0; attempt < 4; attempt++) {
            if (!current()) break;
            try {
              result = await client.call(
                '/nodes/download',
                method: 'POST',
                body: {...scopeSnapshot, 'node': node, 'connections': count},
                timeout: const Duration(seconds: 20),
              );
              break;
            } on ApiFailure catch (failure) {
              if (attempt == 3 ||
                  !{'auto-probe-yield', 'download-busy'}.contains(failure.code))
                rethrow;
              await Future<void>.delayed(const Duration(milliseconds: 400));
            }
          }
          if (current() && result != null) results['$count/$node'] = result;
        } catch (failure) {
          if (current())
            results['$count/$node'] = {'error': failure.toString()};
        }
        if (current()) {
          completed++;
          _notify();
        }
      }
    } finally {
      if (!identical(transport, api.transport)) transport.close();
      if (current()) {
        _downloadTransport = null;
        downloading = false;
        measuring = null;
        _notify();
        await refresh();
      }
    }
  }

  void cancelDownload({bool notify = true}) {
    _downloadGeneration++;
    final transport = _downloadTransport;
    if (transport != null && !identical(transport, api.transport))
      transport.close();
    _downloadTransport = null;
    downloading = false;
    measuring = null;
    if (notify) _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    cancelDownload(notify: false);
    super.dispose();
  }
}
