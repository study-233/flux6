import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:fl_clash/common/ip_quality.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/route_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freev6_windows/app/live_model.dart';

import 'session.dart';

// Windows observes the host's connection; it does not subscribe to an Android core.
class WindowsRouteTracker extends RouteTracker {
  RouteState get snapshot {
    final session = ref.read(freev6SessionProvider);
    return RouteState(
      coreEpoch: session.coreAdapter.routeEpoch,
      routeVersion: session.coreAdapter.routeEpoch,
      hostEpoch: session.coreAdapter.routeEpoch,
      proxied: session.model.connected,
      synced: true,
      live: session.model.connected,
    );
  }

  @override
  RouteState build() {
    ref.listen(freev6RevisionProvider, (_, _) {
      scheduleMicrotask(() {
        if (ref.mounted && state != snapshot) state = snapshot;
      });
    });
    return snapshot;
  }

  @override
  void attach() {}
  @override
  void detach() {}
  @override
  void resync() {
    if (ref.mounted) state = snapshot;
  }
}

Future<IpQuality> windowsIpQuality(Ref ref, String ip) async {
  final session = ref.read(freev6SessionProvider);
  if (session.offline) {
    return IpQuality(
      ip: ip,
      source: IpQualitySource.identMe,
      type: IpType.hosting,
      organization: 'Preview Network',
      asn: 64512,
    );
  }
  final model = session.model;
  if (model is! LiveModel || !model.connected) {
    throw StateError('Connect before inspecting the exit IP');
  }
  final config = await model.controller.call(['configs']);
  final port = config['mixed-port'];
  if (!model.connected || port is! int || port < 1 || port > 65535) {
    throw StateError('Proxy listener unavailable');
  }
  final dio = Dio()
    ..httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () =>
          HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:$port',
    );
  final token = CancelToken();
  ref.onDispose(() {
    token.cancel();
    dio.close(force: true);
  });
  try {
    return await lookupIpQuality(dio, ip, cancelToken: token);
  } finally {
    dio.close(force: true);
  }
}
