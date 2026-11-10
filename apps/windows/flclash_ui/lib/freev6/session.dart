import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/core/desktop/model.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/outbound_ip.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/providers/routed_probe.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart' show Color;
import 'package:freev6_windows/app/client_model.dart' show ClientModel;
import 'package:freev6_windows/app/live_model.dart' show LiveModel;
import 'package:freev6_windows/app/preview_model.dart' show PreviewModel;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:prism_ui/prism_ui.dart' show ThemeMode, BannerLevel;

const accessGroup = '接入点';
const chainGroup = '链式代理';

final freev6SessionProvider = Provider<FreeV6Session>(
  (ref) => throw StateError('FreeV6 session missing'),
);
final freev6RevisionProvider = NotifierProvider<FreeV6Revision, int>(
  FreeV6Revision.new,
);

class FreeV6Revision extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

ClientModel watchFreeV6(WidgetRef ref) {
  ref.watch(freev6RevisionProvider);
  return ref.read(freev6SessionProvider).model;
}

class OfflineFreeV6Model extends PreviewModel {
  OfflineFreeV6Model() {
    settings.addAll({
      'autoStart': false,
      'silentStart': false,
      'autoRunProxy': false,
      'hotkeyEnabled': false,
      'hotspotShare': false,
    });
  }
  @override
  List<String> get nodes => proxyTab == 'chain'
      ? (chain['names'] as List? ?? []).whereType<String>().toList()
      : super.nodes;
}

class FreeV6Session {
  FreeV6Session(this.model, {this.backend = false, this.offline = true}) {
    if (!model.preview && !backend) {
      throw ArgumentError('This target only accepts an offline FreeV6 model');
    }
    final guard = GuardedCore(blockedCoreCalls);
    container = ProviderContainer(
      overrides: [
        freev6SessionProvider.overrideWithValue(this),
        coreHandlerProvider.overrideWithValue(CoreController.adapter(guard)),
        appSettingProvider.overrideWithBuild(
          (_, _) => const AppSettingProps(
            locale: 'zh_CN',
            autoCheckUpdate: false,
            openLogs: true,
            dashboardWidgets: [
              DashboardWidget.currentOutbound,
              DashboardWidget.networkSpeed,
              DashboardWidget.outboundMode,
              DashboardWidget.profiles,
              DashboardWidget.proxyGroups,
            ],
          ),
        ),
        profilesProvider.overrideWith(() => OfflineProfiles(this)),
        currentProfileIdProvider.overrideWithBuild((_, _) => 1),
        initProvider.overrideWithBuild((_, _) => true),
        groupsProvider.overrideWithBuild((_, _) => _groups),
        coreStatusProvider.overrideWithBuild((_, _) => _coreStatus),
        coreActionProvider.overrideWith(() => FreeV6CoreAction(this)),
        systemActionProvider.overrideWith(() => FreeV6SystemAction(this)),
        logsProvider.overrideWith(() => FreeV6Logs(this)),
        setupActionProvider.overrideWith(() => FreeV6SetupAction(this)),
        proxiesActionProvider.overrideWith(() => FreeV6ProxiesAction(this)),
        outboundIpProbeProvider.overrideWith(OfflineOutbound.new),
        scriptsProvider.overrideWithBuild((_, _) => Stream.value(const [])),
        globalRulesProvider.overrideWithBuild((_, _) => Stream.value(const [])),
        iconSetsProvider.overrideWithBuild((_, _) => Stream.value(const [])),
        clashProvidersProvider.overrideWithBuild(
          (_, _) => Stream.value(const []),
        ),
        mitmModulesProvider.overrideWithBuild((_, _) => Stream.value(const [])),
      ],
    );
    globalState.container = container;
    globalState.appEnv = 'stable';
    globalState.packageInfo = PackageInfo(
      appName: 'FreeV6',
      packageName: 'dev.freev6.windows.offline',
      version: model.runtime['appVersion']?.toString() ?? '0.5.3',
      buildNumber: '0',
    );
    _hold = container.listen(configProvider, (_, _) {});
    model.addListener(sync);
    sync();
  }
  final ClientModel model;
  final bool backend, offline;
  bool bannerQueued = false;
  String? batchGroup;
  late final ProviderContainer container;
  late final ProviderSubscription<Config> _hold;
  final commands = <String>[];
  final blockedCoreCalls = <String>[];
  String group = accessGroup;
  Set<String> unfolded = {accessGroup};
  bool _closed = false;
  bool _wasConnected = false;
  final _nodeCache = <String, List<String>>{};
  final _selectionCache = <String, String?>{};
  Future<void> _nodeActions = Future.value();
  String? _appearanceKey;

  CoreStatus get _coreStatus =>
      model.preview || model.canConnectAction || model.busy
      ? CoreStatus.connected
      : CoreStatus.disconnected;

  Future<void> inGroup(String name, Future<void> Function() operation) {
    final next = _nodeActions.then((_) async {
      if (_closed) return;
      final tab = name == chainGroup ? 'chain' : 'access';
      if (model.proxyTab != tab && !await act('node.group', {'tab': tab})) {
        return;
      }
      group = name;
      await operation();
      sync();
    });
    _nodeActions = next.catchError((Object error) {
      dialogs.showBanner(error.toString(), level: BannerLevel.error);
    });
    return next;
  }

  List<Profile> get _profiles => [
    Profile(
      id: 1,
      label: model.profileName,
      currentGroupName: group,
      autoUpdateDuration: Duration.zero,
      autoUpdate: false,
      selectedMap: {
        for (final item in _selectionCache.entries) item.key: item.value ?? '',
      },
      unfoldSet: unfolded,
    ),
  ];
  List<Group> get _groups => [
    Group(
      type: GroupType.Selector,
      hidden: false,
      name: accessGroup,
      now: _selectionCache[accessGroup],
      all: (_nodeCache[accessGroup] ?? const <String>[])
          .map((n) => Proxy(name: n, type: 'MASQUE'))
          .toList(),
    ),
    if ((model.chain['count'] as num? ?? 0) > 0)
      Group(
        type: GroupType.Selector,
        hidden: false,
        name: chainGroup,
        now: _selectionCache[chainGroup],
        all: (_nodeCache[chainGroup] ?? const <String>[])
            .map((n) => Proxy(name: n, type: 'SOCKS5'))
            .toList(),
      ),
  ];

  Future<bool> act(
    String action, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    commands.add(action);
    final result = await model.act(action, arguments);
    if (result &&
        (action == 'chain.clear' || action == 'settings.reset') &&
        model.proxyTab == 'chain') {
      await model.act('node.group', {'tab': 'access'});
    }
    sync();
    return result;
  }

  void sync() {
    if (_closed) return;
    if (_wasConnected && !model.connected) {
      _nodeCache.clear();
      _selectionCache.clear();
      container.read(delayDataSourceProvider.notifier).value = {};
    }
    _wasConnected = model.connected;
    group = model.proxyTab == 'chain' ? chainGroup : accessGroup;
    _nodeCache[group] = model.nodes.toList();
    _selectionCache[group] = model.currentNode ?? model.preferredNode;
    if ((model.chain['count'] as num? ?? 0) == 0) {
      _nodeCache.remove(chainGroup);
      _selectionCache.remove(chainGroup);
    }
    container.read(coreStatusProvider.notifier).value = _coreStatus;
    _syncAppearance();
    (container.read(profilesProvider.notifier) as OfflineProfiles).replace(
      _profiles,
    );
    container.read(groupsProvider.notifier).value = _groups;
    container.read(runTimeProvider.notifier).value = model.connected
        ? model.uptime.inMilliseconds
        : null;
    container
        .read(patchClashConfigProvider.notifier)
        .update(
          (p) => p.copyWith(
            mode: switch (model.mode) {
              '全局' => Mode.global,
              '直连' => Mode.direct,
              _ => Mode.rule,
            },
          ),
        );
    container.read(totalTrafficProvider.notifier).value = Traffic(
      up: model.usageUpload,
      down: model.usageDownload,
    );
    final up = model.uploadHistory, down = model.downloadHistory;
    container.read(trafficsProvider.notifier).value = FixedList(
      trafficSampleLength,
      list: [
        for (var i = 0; i < up.length && i < down.length; i++)
          Traffic(up: up[i].round(), down: down[i].round()),
      ],
    );
    container.read(logsProvider.notifier).value = FixedList(
      maxLogsLength,
      list: [
        for (final log in model.logs.reversed)
          Log(
            logLevel: log.level == '警告' ? LogLevel.warning : LogLevel.info,
            payload: log.message,
            dateTime: log.time.toIso8601String(),
          ),
      ],
    );
    for (final node in model.nodes) {
      final value = model.latency(node);
      if (value != null) {
        container
            .read(delayDataSourceProvider.notifier)
            .setDelay(Delay(name: node, value: value, url: defaultTestUrl));
      }
    }
    container.read(pendingDelayTestsProvider.notifier).value = {
      for (final node in model.nodes)
        if (model.measuring(node) ||
            (model.pending('nodes.measure') &&
                batchGroup == group &&
                model.latency(node) == null))
          delayTestKey(defaultTestUrl, node): model.measuring(node)
              ? DelayTestPhase.running
              : DelayTestPhase.queued,
    };
    container.read(delayTestingGroupsProvider.notifier).value = {
      if (model.pending('nodes.measure') && batchGroup != null) batchGroup!,
    };
    container.read(freev6RevisionProvider.notifier).bump();
  }

  void _syncAppearance() {
    final theme = model.preference('freev6-theme', 'system');
    final black = model.preference('freev6-pure-black') == '1';
    final dynamic = model.preference('freev6-dynamic-color') == '1';
    final accent = int.tryParse(
      '${model.runtime['accent'] ?? ''}'.replaceFirst('#', ''),
      radix: 16,
    );
    final key = '$theme/$black/$dynamic/$accent';
    if (_appearanceKey == key) return;
    _appearanceKey = key;
    container
        .read(themeSettingProvider.notifier)
        .update(
          (p) => p.copyWith(
            themeMode: switch (theme) {
              'dark' => ThemeMode.dark,
              'light' => ThemeMode.light,
              _ => ThemeMode.system,
            },
            pureBlack: black,
            primaryColor: dynamic ? null : 0xff007aff,
          ),
        );
    container
        .read(dynamicColorProvider.notifier)
        .seed(accentColor: Color(0xff000000 | (accent ?? 0x007aff)));
  }

  void dispose() {
    _closed = true;
    model.removeListener(sync);
    _hold.close();
    container.dispose();
    model.dispose();
  }
}

class GuardedCore extends CoreHandlerInterface {
  GuardedCore(this.calls);
  final List<String> calls;
  Never _blocked(String operation) {
    calls.add(operation);
    throw StateError(
      'Offline target refused upstream Core operation: $operation',
    );
  }

  @override
  Future<CoreLifecycleResult> start() async => _blocked('start');
  @override
  Future<CoreLifecycleResult> restart() async => _blocked('restart');
  @override
  Future<CoreLifecycleResult> stop() async => _blocked('stop');
  @override
  Future<CoreLifecycleResult> close() async => _blocked('close');
  @override
  Future<Object?> invokeMethod({
    required CoreMethod method,
    Object? arguments,
    Duration? timeout,
  }) async => _blocked(method.wireName);
}

class FreeV6CoreAction extends CoreAction {
  FreeV6CoreAction(this.session);
  final FreeV6Session session;
  @override
  Future<bool> restartCore() => session.act('refresh');
}

class FreeV6SetupAction extends SetupAction {
  FreeV6SetupAction(this.session);
  final FreeV6Session session;
  @override
  void build() {}
  @override
  Future<bool> setRunning(bool running, {bool initialize = false}) async {
    if (session.model.busy) return false;
    session.commands.add(running ? 'proxy.start' : 'proxy.stop');
    if (session.model.connected != running) {
      await session.model.toggleConnection();
    }
    session.sync();
    return session.model.connected == running;
  }

  @override
  void changeMode(Mode mode) {
    if (mode == Mode.direct && !session.model.allowDirectMode) return;
    session.commands.add('mode.${mode.name}');
    session.model.selectMode(switch (mode) {
      Mode.global => '全局',
      Mode.direct => '直连',
      _ => '规则',
    });
  }
}

class FreeV6ProxiesAction extends ProxiesAction {
  FreeV6ProxiesAction(this.session);
  final FreeV6Session session;
  @override
  void build() {}
  @override
  Future<void> updateGroups() async {
    if (session.model case final LiveModel live) await live.refreshNodes();
    session.sync();
  }

  @override
  void updateGroupsDebounce([Duration? duration]) => session.sync();
  @override
  void updateCurrentGroupName(String groupName) {
    unawaited(session.inGroup(groupName, () async {}));
  }

  @override
  void updateCurrentUnfoldSet(Set<String> value) {
    session.unfolded = value;
    session.sync();
  }

  @override
  void changeProxyDebounce(String groupName, String proxyName) =>
      unawaited(changeProxy(groupName: groupName, proxyName: proxyName));
  @override
  Future<void> changeProxy({
    required String groupName,
    required String proxyName,
  }) async {
    await session.inGroup(groupName, () async {
      if (!session.model.canSelectNode ||
          !session.model.nodes.contains(proxyName)) {
        return;
      }
      if (session.model.preview) {
        session.commands.add('node.select');
        session.model.selectNode(proxyName);
      } else {
        await session.act('node.select', {'name': proxyName});
      }
    });
  }

  @override
  Future<void> proxyDelayTest(Proxy proxy, [String? testUrl]) async {
    final groupName =
        session._nodeCache.entries
            .where((entry) => entry.value.contains(proxy.name))
            .map((entry) => entry.key)
            .firstOrNull ??
        session.group;
    await session.inGroup(groupName, () async {});
    session.commands.add('nodes.measure');
    await session.model.measure(proxy.name);
    session.sync();
  }

  @override
  Future<void> delayTest(List<Proxy> proxies, [String? testUrl]) async {
    if (!session.model.canMeasure || session.model.pending('nodes.measure')) {
      return;
    }
    await session.inGroup(session.group, () async {});
    session.batchGroup = session.group;
    try {
      await session.act('nodes.measure');
    } finally {
      session.batchGroup = null;
      session.sync();
    }
    if (ref.mounted) ref.read(sortNumProvider.notifier).add();
  }
}

class OfflineOutbound extends OutboundIpProbe {
  @override
  RoutedProbeState<String, IpInfo> build() => const RoutedProbeState();
  @override
  void watch(String target) {}
  @override
  void unwatch(String target) {}
  @override
  void refresh(Iterable<String> targets) {}
}

class OfflineProfiles extends Profiles {
  OfflineProfiles(this.session);
  final FreeV6Session session;
  @override
  List<Profile> build() => session._profiles;
  void replace(List<Profile> profiles) => state = profiles;
  @override
  void put(Profile profile) => state = [profile];
}

class FreeV6SystemAction extends SystemAction {
  FreeV6SystemAction(this.session);
  final FreeV6Session session;
  @override
  Future<void> handleExit([bool needSave = true]) async {
    if (session.model.preview) {
      if (session.model.connected) await session.model.toggleConnection();
      await windowPort?.close();
    } else {
      if (await session.act('app.quit') && session.offline) {
        await windowPort?.close();
      }
    }
  }

  @override
  Future<void> handleClose([bool exit = true]) async {
    if (session.backend && !session.offline) {
      await windowPort?.close();
    } else {
      await handleExit();
    }
  }
}

class FreeV6Logs extends Logs {
  FreeV6Logs(this.session);
  final FreeV6Session session;
  @override
  Future<bool> exportLogs() async {
    if (session.model.preview) {
      dialogs.showBanner(currentAppLocalizations.freev6PreviewAction);
      return false;
    }
    return session.act('logs.export');
  }
}
