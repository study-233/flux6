import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:prism_ui/sidebar.dart' as sidebar;

import '../app_theme.dart';
import '../components/flclash.dart';
import '../dashboard.dart';
import '../features/pages.dart';
import '../features/window_background.dart';
import 'client_model.dart';

class ClientApplication extends StatelessWidget {
  const ClientApplication({super.key, required this.model});
  final ClientModel model;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (_, __) => FreeV6Theme(
      title: 'Flux6',
      appearance: switch (model.preference('freev6-theme')) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      },
      reduceMotion: model.preference('reduce-motion') == '1',
      pureBlack: model.preference('freev6-pure-black') == '1',
      seedColor: model.preference('freev6-dynamic-color') == '1'
          ? Color(
              0xff000000 |
                  (int.tryParse(
                        '${model.runtime['accent'] ?? ''}'.replaceFirst(
                          '#',
                          '',
                        ),
                        radix: 16,
                      ) ??
                      0x007aff),
            )
          : const Color(0xff007aff),
      home: ClientWindow(model: model),
    ),
  );
}

class ClientWindow extends StatefulWidget {
  const ClientWindow({super.key, required this.model});
  final ClientModel model;
  @override
  State<ClientWindow> createState() => _ClientWindowState();
}

class _ClientWindowState extends State<ClientWindow> {
  static const destinations = [
    sidebar.SidebarDestination(glyph: AppGlyphs.dashboard, label: '仪表盘'),
    sidebar.SidebarDestination(glyph: AppGlyphs.proxies, label: '节点'),
    sidebar.SidebarDestination(glyph: AppGlyphs.profiles, label: '配置'),
    sidebar.SidebarDestination(glyph: AppGlyphs.logs, label: '日志'),
  ];
  int page = 0;
  bool? expanded;
  final scroll = ScrollController();
  final windowFocus = FocusNode(debugLabel: 'Flux6 navigation');
  StreamSubscription<String>? subscription;
  bool exitDialog = false;
  @override
  void initState() {
    super.initState();
    subscription = widget.model.events.listen((event) {
      if (event == 'exitRequested') unawaited(quit());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          !widget.model.preview &&
          widget.model.preference('freev6-guide-done') != '1')
        unawaited(guide());
    });
  }

  Future<void> guide() async {
    await showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('欢迎使用 Flux6'),
        content: const Text(
          '连接校园网后，在仪表盘启动连接。首次使用会准备 WARP；缺少运行核心时，请在设置中下载。\n\n关闭窗口会保留在系统托盘，退出时会先停止连接。原 Windows 界面偏好可在设置中导入备份。',
        ),
        actions: [
          TextButton(
            onPressed: () => widget.model.act('external.open', {
              'url': 'https://github.com/study-233/flux6/blob/main/docs/agreement.md',
            }),
            child: const Text('用户协议'),
          ),
          TextButton(
            onPressed: () => widget.model.act('external.open', {
              'url': 'https://github.com/study-233/flux6/blob/main/docs/privacy.md',
            }),
            child: const Text('隐私政策'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('开始使用'),
          ),
        ],
      ),
    );
    await widget.model.act('preferences.set', {
      'key': 'freev6-guide-done',
      'value': '1',
    });
  }

  Future<void> quit() async {
    if (exitDialog || !mounted) return;
    exitDialog = true;
    try {
      final model = widget.model;
      if (model.busy || model.pending('update.install')) return;
      if (!model.connected ||
          await confirm(context, '停止并退出', '退出前将停止连接并恢复网络设置。')) {
        await model.act('app.quit');
      }
    } finally {
      exitDialog = false;
    }
  }

  @override
  void dispose() {
    scroll.dispose();
    windowFocus.dispose();
    subscription?.cancel();
    super.dispose();
  }

  void navigate(int next) {
    windowFocus.requestFocus();
    setState(() => page = next);
  }

  Future<void> settings() => showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 880, maxHeight: 700),
        child: SettingsPage(model: widget.model),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final colors = prism.Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: WindowBackground(
        model: model,
        child: CallbackShortcuts(
          bindings: {
            for (final key in [
              LogicalKeyboardKey.digit1,
              LogicalKeyboardKey.digit2,
              LogicalKeyboardKey.digit3,
              LogicalKeyboardKey.digit4,
            ].indexed)
              SingleActivator(key.$2, control: true): () => navigate(key.$1),
            const SingleActivator(LogicalKeyboardKey.comma, control: true):
                settings,
          },
          child: Focus(
            focusNode: windowFocus,
            autofocus: true,
            child: LayoutBuilder(
              builder: (context, room) {
                final wide = expanded ?? room.maxWidth >= 1080;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: colors.chromeSurface,
                        border: Border(
                          right: BorderSide(
                            color: colors.onSurface.withValues(alpha: .08),
                          ),
                        ),
                      ),
                      child: sidebar.NavigationSidebar(
                        destinations: destinations,
                        selectedIndex: page,
                        expanded: wide,
                        onSelected: navigate,
                        windowControls: Size.zero,
                        onToggle: () => setState(() => expanded = !wide),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Semantics(
                                    header: true,
                                    child: Text(
                                      destinations[page].label,
                                      style: TextStyle(
                                        fontSize: 23,
                                        fontWeight: FontWeight.w700,
                                        color: colors.onSurface,
                                      ),
                                    ),
                                  ),
                                ),
                                if (model.preview && room.maxWidth > 850)
                                  const Text('演示模式 · 不连接网络'),
                                SeasonalButton(model: model),
                                IconButton(
                                  tooltip: model.connected ? '断开连接' : '连接',
                                  onPressed: model.canConnectAction
                                      ? model.toggleConnection
                                      : null,
                                  icon: Icon(
                                    model.connected
                                        ? Icons.stop_circle_outlined
                                        : Icons.play_circle_outline,
                                  ),
                                ),
                                IconButton(
                                  tooltip: '刷新状态',
                                  onPressed: model.pending('refresh')
                                      ? null
                                      : () => model.act('refresh'),
                                  icon: const Icon(Icons.refresh_rounded),
                                ),
                                IconButton(
                                  tooltip: '公告',
                                  onPressed: () => showNotices(context, model),
                                  icon: Badge(
                                    isLabelVisible: model.unreadNotices > 0,
                                    label: Text('${model.unreadNotices}'),
                                    child: const Icon(
                                      Icons.notifications_none_rounded,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: '设置',
                                  onPressed: settings,
                                  icon: const Icon(Icons.settings_outlined),
                                ),
                              ],
                            ),
                          ),
                          if (model.preview && room.maxWidth <= 850)
                            const Padding(
                              padding: EdgeInsets.only(left: 20, bottom: 4),
                              child: Text('演示模式 · 不连接网络'),
                            ),
                          if (model.message case final String message)
                            MaterialBanner(
                              content: Text(
                                message,
                                maxLines: 5,
                                overflow: TextOverflow.ellipsis,
                              ),
                              actions: [
                                TextButton(
                                  onPressed: model.dismissMessage,
                                  child: const Text('关闭'),
                                ),
                              ],
                            ),
                          Expanded(
                            child: IndexedStack(
                              index: page,
                              children: [
                                PreviewDashboard(
                                  model: model,
                                  scroll: scroll,
                                  onPage: navigate,
                                  onNodes: () => navigate(1),
                                ),
                                NodesPage(model: model),
                                ConfigurationPage(model: model),
                                LogsPage(model: model),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
