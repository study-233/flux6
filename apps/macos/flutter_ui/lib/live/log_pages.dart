import 'dart:async';

import 'package:flutter/foundation.dart';

import 'live_model.dart';

/// A cursor is valid only in its host generation. Never apply an older window's reply after a filter, pause, or clear.
class LiveLogPages extends ChangeNotifier {
  LiveLogPages(this.model);
  final LiveModel model;
  final _entries = <int, StateMap>{};
  StateMap view = {};
  String? epoch, error;
  int _latest = 0, _request = 0;
  bool _retryOlder = false;
  bool active = false,
      loading = false,
      initialized = false,
      _disposed = false,
      _waitingForReset = false;

  List<StateMap> get rows {
    final cursors = _entries.keys.toList()..sort((a, b) => b.compareTo(a));
    return [for (final cursor in cursors) _entries[cursor]!];
  }

  bool get hasOlder =>
      initialized && _entries.length < (view['count'] as int? ?? 0);

  void sync(StateMap next, {required bool active}) {
    this.active = active;
    final generation = next['epoch'] as String?;
    if (generation != epoch) {
      epoch = generation;
      _request++;
      _latest = 0;
      loading = false;
      initialized = false;
      error = null;
      _waitingForReset = false;
      _retryOlder = false;
      _entries.clear();
    }
    // A direct page read may observe a new entry before its event reaches the engine.
    if ((next['newest'] as int? ?? 0) >= (view['newest'] as int? ?? 0) ||
        next['epoch'] != view['epoch']) {
      view = next;
    }
    _trim();
    _catchUp();
  }

  void _trim() {
    final floors = readMap(view['floors']);
    _entries.removeWhere((cursor, row) {
      final oldest = floors[row['source']] as int?;
      return oldest == null || cursor < oldest;
    });
  }

  void _catchUp() {
    if (_disposed ||
        !active ||
        epoch == null ||
        loading ||
        error != null ||
        _waitingForReset)
      return;
    if (!initialized || _latest < (view['newest'] as int? ?? 0)) {
      unawaited(_read(initialized ? {'after': _latest} : {}));
    }
  }

  Future<void> older() async {
    if (loading || !hasOlder || !active || _entries.isEmpty) return;
    await _read({'before': _entries.keys.reduce((a, b) => a < b ? a : b)});
  }

  void retry() {
    error = null;
    _waitingForReset = false;
    if (_retryOlder && hasOlder) {
      _retryOlder = false;
      unawaited(older());
    } else {
      _catchUp();
    }
    notifyListeners();
  }

  Future<void> _read(StateMap range) async {
    final ticket = ++_request, expected = epoch;
    loading = true;
    error = null;
    try {
      final result = await model.command('logs.page', {
        'epoch': expected,
        ...range,
      });
      if (_disposed || ticket != _request) return;
      final data = readMap(result['data']), actual = readMap(data['view']);
      if (data['reset'] == true || actual['epoch'] != expected) {
        _waitingForReset = true;
        await model.resync();
        if (ticket == _request && !_disposed) error = '日志视图已变化，请重新读取。';
        return;
      }
      if ((actual['newest'] as int? ?? 0) >= (view['newest'] as int? ?? 0))
        view = actual;
      final page = readRecords(data['rows']);
      for (final row in page) {
        final cursor = row['cursor'] as int;
        _entries[cursor] = row;
        if (cursor > _latest) _latest = cursor;
      }
      if (page.isEmpty && !range.containsKey('before'))
        _latest = view['newest'] as int? ?? 0;
      initialized = true;
      _trim();
    } catch (failure) {
      if (!_disposed && ticket == _request) {
        error = failure.toString();
        _retryOlder = range.containsKey('before');
      }
    } finally {
      if (!_disposed && ticket == _request) {
        loading = false;
        notifyListeners();
        _catchUp();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _request++;
    super.dispose();
  }
}
