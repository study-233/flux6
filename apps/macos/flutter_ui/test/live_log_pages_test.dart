import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:freev6_flutter_preview/live/live_model.dart';
import 'package:freev6_flutter_preview/live/log_pages.dart';

class _LogHost extends LiveModel {
  final requests = <({StateMap args, Completer<StateMap> result})>[];
  @override
  Future<StateMap> command(String action, [StateMap args = const {}]) {
    expect(action, 'logs.page');
    final result = Completer<StateMap>();
    requests.add((args: args, result: result));
    return result.future;
  }
}

StateMap view(String epoch, int newest, int count, {int oldest = 1}) => {
  'epoch': epoch,
  'newest': newest,
  'count': count,
  'floors': {'应用': oldest},
};
StateMap row(int cursor, String name) => {
  'id': '$name-$cursor',
  'source': '应用',
  'cursor': cursor,
  'message': name,
};
StateMap reply(StateMap view, List<StateMap> rows) => {
  'ok': true,
  'data': {'view': view, 'rows': rows, 'reset': false},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'hidden logs stay lazy and a late older page cannot resurrect a cleared row',
    () async {
      final host = _LogHost(), pages = LiveLogPages(host);
      final old = view('old', 42, 42);
      pages.sync(old, active: false);
      expect(host.requests, isEmpty);
      pages.sync(old, active: true);
      host.requests[0].result.complete(
        reply(old, [for (var c = 42; c >= 11; c--) row(c, 'old')]),
      );
      await Future<void>.delayed(Duration.zero);
      expect(pages.rows.length, 32);
      final loading = pages.older();
      expect(host.requests[1].args['before'], 11);
      final latest = view('cleared', 1, 1);
      pages.sync(latest, active: true);
      expect(pages.rows, isEmpty);
      host.requests[2].result.complete(reply(latest, [row(1, 'new')]));
      await Future<void>.delayed(Duration.zero);
      host.requests[1].result.complete(
        reply(old, [for (var c = 10; c > 0; c--) row(c, 'old')]),
      );
      await loading;
      expect(pages.rows.map((r) => r['message']), ['new']);
      pages.dispose();
      host.dispose();
    },
  );

  test(
    'incremental reads follow the newest cursor and remove evicted rows',
    () async {
      final host = _LogHost(), pages = LiveLogPages(host);
      var state = view('same', 2, 2);
      pages.sync(state, active: true);
      host.requests[0].result.complete(
        reply(state, [row(2, 'b'), row(1, 'a')]),
      );
      await Future<void>.delayed(Duration.zero);
      state = view('same', 4, 3, oldest: 2);
      pages.sync(state, active: true);
      expect(host.requests.last.args['after'], 2);
      host.requests.last.result.complete(reply(state, [row(3, 'c')]));
      await Future<void>.delayed(Duration.zero);
      expect(host.requests.last.args['after'], 3);
      host.requests.last.result.complete(reply(state, [row(4, 'd')]));
      await Future<void>.delayed(Duration.zero);
      expect(pages.rows.map((r) => r['cursor']), [4, 3, 2]);
      expect(pages.hasOlder, isFalse);
      pages.dispose();
      host.dispose();
    },
  );
}
