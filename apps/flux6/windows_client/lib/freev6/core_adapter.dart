import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/core/desktop/model.dart';
import 'package:freev6_windows/app/client_model.dart';
import 'package:freev6_windows/app/live_model.dart';

/// Only the Windows host/helper owns the core process and network restoration.
class WindowsCoreAdapter extends CoreHandlerInterface {
  WindowsCoreAdapter(this.model);
  final ClientModel model;
  int routeEpoch = 1;
  String? _routeKey;
  void syncRoute(String key) {
    if (_routeKey == key) return;
    _routeKey = key;
    routeEpoch++;
  }

  Map<String, Object> get routeStamp => {
    'core-epoch': routeEpoch,
    'route-version': routeEpoch,
  };

  Never _lifecycle() =>
      throw StateError('Use the Windows connection controller');
  @override
  Future<CoreLifecycleResult> start() async => _lifecycle();
  @override
  Future<CoreLifecycleResult> restart() async => _lifecycle();
  @override
  Future<CoreLifecycleResult> stop() async => _lifecycle();
  @override
  Future<CoreLifecycleResult> close() async => _lifecycle();

  @override
  Future<Object?> invokeMethod({
    required CoreMethod method,
    Object? arguments,
    Duration? timeout,
  }) async {
    final live = model is LiveModel ? model as LiveModel : null;
    final args = arguments is Map ? arguments : const {};
    switch (method) {
      case CoreMethod.routeWatch:
        return routeStamp;
      case CoreMethod.routeCheck:
        return {
          ...routeStamp,
          'held': [for (final _ in args['routes'] as List? ?? []) false],
        };
      case CoreMethod.probeOutboundIp:
      case CoreMethod.probeServices:
        final stamp = routeStamp;
        if ((args['proxy-name'] as String? ?? '').isNotEmpty) {
          throw const CoreMethodException(
            code: 'unsupported_operation',
            message: 'Windows probes follow the active routing policy',
          );
        }
        if (live == null || !live.connected) {
          return method == CoreMethod.probeServices
              ? <Object>[]
              : {...stamp, 'error': 'disconnected'};
        }
        final result = await live.helper.call(
          '/diagnostics/probe',
          method: 'POST',
          body: {
            'kind': method == CoreMethod.probeServices ? 'services' : 'ip',
            'session': live.downloadSession,
            if (method == CoreMethod.probeServices)
              'names': args['names'] ?? [],
          },
          timeout: const Duration(seconds: 45),
        );
        return method == CoreMethod.probeServices
            ? [
                for (final item in result['items'] as List? ?? [])
                  {...item as Map, ...stamp},
              ]
            : {...result, ...stamp};
      case CoreMethod.coreInitialized:
        return model.connected;
      case CoreMethod.connectionList:
        return live != null && model.connected
            ? await live.controller.call(['connections'])
            : {'connections': []};
      case CoreMethod.connectionCount:
        return live?.connections.length ?? 0;
      case CoreMethod.connectionClose:
        if (live != null && model.connected) {
          await live.controller.call([
            'connections',
            args['id'] as String,
          ], method: 'DELETE');
          await live.pollTraffic();
        }
        return null;
      case CoreMethod.connectionCloseAll:
        if (live != null && model.connected) {
          await live.controller.call(['connections'], method: 'DELETE');
          await live.pollTraffic();
        }
        return null;
      case CoreMethod.dnsClearCache:
        if (live != null && model.connected) {
          await live.controller.call(['cache', 'dns', 'flush'], method: 'POST');
        }
        return null;
      case CoreMethod.coreMemory:
        return {
          'rss': model.runtime['coreRss'] ?? 0,
          'heap-inuse': model.runtime['coreMemory'] ?? 0,
        };
      case CoreMethod.trafficTotal:
        return {
          'up': live?.sessionUpload ?? 0,
          'down': live?.sessionDownload ?? 0,
        };
      case CoreMethod.trafficCurrent:
        return {
          'up': model.uploadHistory.lastOrNull?.round() ?? 0,
          'down': model.downloadHistory.lastOrNull?.round() ?? 0,
        };
      case CoreMethod.logStart:
      case CoreMethod.logStop:
        return null;
      default:
        throw CoreMethodException(
          code: 'unsupported_operation',
          message: 'Windows adapter does not expose ${method.wireName}',
        );
    }
  }
}
