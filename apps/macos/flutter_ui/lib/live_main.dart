import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:prism_ui/icons/icons.dart' show GlyphIcon;
import 'package:prism_ui/sidebar.dart' as sidebar;

import 'app_theme.dart';
import 'components/flclash.dart';
import 'dashboard.dart';
import 'live/live_model.dart';
import 'live/nodes_page.dart';
import 'live/pages.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.freev6.host/v1');
  String role = arguments.contains('/settings') ? 'settings' : 'main';
  try {
    role = await channel.invokeMethod<String>('windowRole') ?? role;
  } on PlatformException {
    /* The retry view will expose a failed handshake. */
  } on MissingPluginException {
    /* A detached host can be retried in place. */
  }
  final model = LiveModel(windowRole: role);
  runApp(HostApplication(model: model));
  unawaited(model.start());
}

class HostApplication extends StatefulWidget {
  const HostApplication({super.key, required this.model});
  final LiveModel model;
  @override
  State<HostApplication> createState() => _HostApplicationState();
}

class _HostApplicationState extends State<HostApplication> {
  ThemeMode appearance = ThemeMode.system;
  bool reduced = false;
  @override
  void initState() {
    super.initState();
    widget.model.addListener(_preferences);
  }

  void _preferences() {
    final prefs = readMap(
      readMap(widget.model.state['settings'])['preferences'],
    );
    final theme = switch (prefs['appearance']) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    final reduce = prefs['reduceMotion'] == true;
    if (appearance != theme || reduced != reduce)
      setState(() {
        appearance = theme;
        reduced = reduce;
      });
  }

  @override
  void dispose() {
    widget.model.removeListener(_preferences);
    widget.model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FreeV6Theme(
    title: 'Flux6',
    appearance: appearance,
    reduceMotion: reduced,
    home: _HostWindow(key: ObjectKey(widget.model), model: widget.model),
  );
}

enum _Tool { settings, layout, prepare, notices, scenarios }

class _HostWindow extends StatefulWidget {
  const _HostWindow({super.key, required this.model});
  final LiveModel model;
  @override
  State<_HostWindow> createState() => _HostWindowState();
}

class _HostWindowState extends State<_HostWindow>
    with SingleTickerProviderStateMixin {
  static const destinations = [
    sidebar.SidebarDestination(glyph: AppGlyphs.dashboard, label: '仪表盘'),
    sidebar.SidebarDestination(glyph: AppGlyphs.proxies, label: '节点'),
    sidebar.SidebarDestination(glyph: AppGlyphs.profiles, label: '配置'),
    sidebar.SidebarDestination(glyph: AppGlyphs.logs, label: '日志'),
  ];
  final scroll = ScrollController();
  final hero = GlobalKey(), header = GlobalKey();
  bool hidden = false, checkQueued = false;
  bool? expandedOverride;
  int page = 0;
  StreamSubscription<String>? actions;
  late final transition = AnimationController(
    vsync: this,
    value: 1,
    duration: const Duration(milliseconds: 160),
  );
  late final enter = Tween<double>(
    begin: .72,
    end: 1,
  ).animate(CurvedAnimation(parent: transition, curve: Curves.easeOut));
  LiveModel get model => widget.model;
  // IndexedStack preserves State. Reuse the child widget as well so switching
  // destinations does not rebuild hidden node cards, charts or form fields.
  late final nodesPage = LiveNodesPage(model: model);
  late final dashboardPages = {
    for (final needsPreparation in [false, true])
      needsPreparation: PreviewDashboard(
        model: model,
        scroll: scroll,
        connectionKey: hero,
        onPage: showPage,
        onNodes: () => openLiveNodePicker(context, model),
        onEditLayout: () => openTool(_Tool.layout),
        onPrepare: needsPreparation ? () => openTool(_Tool.prepare) : null,
      ),
  };
  late final configurationPages = {
    for (final active in [false, true])
      active: LiveConfigurationPage(model: model, active: active),
  };
  late final logPages = {
    for (final active in [false, true])
      active: LiveLogsPage(model: model, active: active),
  };
  @override
  void initState() {
    super.initState();
    actions = model.uiActions.listen((action) {
      if (!mounted || model.windowRole == 'settings') return;
      final tool = switch (action) {
        'editLayout' => _Tool.layout,
        'showNotices' => _Tool.notices,
        'showPreparation' => _Tool.prepare,
        'showScenarios' => _Tool.scenarios,
        _ => null,
      };
      if (tool != null) {
        if (readMap(model.state['settings'])['accepted'] == true &&
            ModalRoute.of(context)?.isCurrent == true) {
          unawaited(openTool(tool));
        }
        return;
      }
      const pages = ['dashboard', 'nodes', 'config', 'logs'];
      if (action.startsWith('goto.') && pages.contains(action.substring(5)))
        showPage(pages.indexOf(action.substring(5)));
      final target = switch (action) {
        'import' => 2,
        'find' => 1,
        _ => null,
      };
      if (target != null && page != target) {
        showPage(target);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) model.deliverUiAction(action);
        });
      }
      if (action == 'save') unawaited(model.finishDrafts(true));
    });
    scroll.addListener(_queueVisibility);
  }

  @override
  void dispose() {
    actions?.cancel();
    scroll.dispose();
    transition.dispose();
    super.dispose();
  }

  void _queueVisibility() {
    if (checkQueued) return;
    checkQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      checkQueued = false;
      if (!mounted || page != 0) return;
      final card = hero.currentContext?.findRenderObject();
      final bar = header.currentContext?.findRenderObject();
      if (bar is! RenderBox || !bar.hasSize) return;
      final top = bar.localToGlobal(Offset(0, bar.size.height)).dy;
      final obscured =
          card is! RenderBox ||
          !card.hasSize ||
          card.localToGlobal(Offset(0, card.size.height / 2)).dy < top ||
          card.localToGlobal(Offset(0, card.size.height / 2)).dy >
              MediaQuery.sizeOf(context).height;
      if (hidden != obscured) setState(() => hidden = obscured);
    });
  }

  void showPage(int value) {
    if (page == value) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => page = value);
    if (!MediaQuery.disableAnimationsOf(context)) transition.forward(from: 0);
    if (value == 0) _queueVisibility();
  }

  Future<void> openTool(_Tool tool) async {
    if (tool == _Tool.settings) {
      await model.platform('openSettings');
      return;
    }
    if (tool == _Tool.scenarios) {
      final selected = await showDialog<String>(
        context: context,
        builder: (dialog) => SimpleDialog(
          title: const Text('隔离验收场景'),
          children: [
            for (final entry in const {
              'normal': '恢复正常状态',
              'occupied': '模拟其他用户占用（需先断开）',
              'recovering': '模拟等待恢复（需先连接）',
              'zeroRate': '在线零速率（需先连接）',
              'rejectNextWrite': '拒绝下一次控制写入',
            }.entries)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(dialog, entry.key),
                child: Text(entry.value),
              ),
          ],
        ),
      );
      if (selected != null) await model.perform('scenario', {'name': selected});
      return;
    }
    final (label, child) = switch (tool) {
      _Tool.layout => ('首页布局', LiveLayoutPage(model: model)),
      _Tool.prepare => (
        '服务与恢复',
        LivePreparationPage(model: model, maintenance: true),
      ),
      _ => ('公告', LiveNoticesPage(model: model)),
    };
    if (!mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          body: Padding(
            padding: const EdgeInsets.only(top: 32),
            child: Column(
              children: [
                AppBar(title: Text(label)),
                Expanded(child: child),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _error() {
    final text = model.message ?? model.state['error']?.toString();
    if (text == null || text.isEmpty) return const SizedBox.shrink();
    return Material(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
        child: Row(
          children: [
            const Icon(Icons.info_outline, size: 17),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text, maxLines: 3, overflow: TextOverflow.ellipsis),
            ),
            TextButton(
              onPressed: () => model.resync(),
              child: const Text('重试'),
            ),
            if (model.message != null)
              IconButton(
                tooltip: '关闭提示',
                onPressed: model.dismissMessage,
                icon: const Icon(Icons.close, size: 16),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) {
      if (model.state.isEmpty)
        return Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (model.message == null)
                  const CircularProgressIndicator()
                else
                  Text(model.message!),
                TextButton(
                  onPressed: model.resync,
                  child: const Text('重新读取状态'),
                ),
              ],
            ),
          ),
        );
      final settings = readMap(model.state['settings']);
      if (settings['accepted'] == false || settings['setupCompleted'] == false)
        return Scaffold(
          body: Column(
            children: [
              _error(),
              Expanded(child: LivePreparationPage(model: model)),
            ],
          ),
        );
      if (model.windowRole == 'settings')
        return Scaffold(
          body: Column(
            children: [
              _error(),
              Expanded(child: LiveSettingsPage(model: model)),
            ],
          ),
        );
      final palette = prism.Theme.of(context).colorScheme;
      _queueVisibility();
      return Scaffold(
        backgroundColor: prism.SurfaceLevel.page.colorOf(palette),
        body: CallbackShortcuts(
          bindings: {
            for (final item in [
              LogicalKeyboardKey.digit1,
              LogicalKeyboardKey.digit2,
              LogicalKeyboardKey.digit3,
              LogicalKeyboardKey.digit4,
            ].indexed)
              SingleActivator(item.$2, meta: true): () => showPage(item.$1),
            const SingleActivator(LogicalKeyboardKey.comma, meta: true): () =>
                openTool(_Tool.settings),
            const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () =>
                model.finishDrafts(true),
          },
          child: Focus(
            autofocus: true,
            child: LayoutBuilder(
              builder: (context, box) {
                final expanded = expandedOverride ?? box.maxWidth >= 1080;
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: palette.chromeSurface,
                        border: BorderDirectional(
                          end: BorderSide(
                            color: palette.onSurface.withValues(alpha: .08),
                          ),
                        ),
                      ),
                      child: Stack(
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(bottom: 56),
                            child: sidebar.NavigationSidebar(
                              key: MediaQuery.disableAnimationsOf(context)
                                  ? ValueKey((expanded, page))
                                  : const ValueKey('navigation'),
                              destinations: destinations,
                              selectedIndex: page,
                              expanded: expanded,
                              onSelected: showPage,
                              windowControls: const Size(78, 32),
                              onToggle: () =>
                                  setState(() => expandedOverride = !expanded),
                            ),
                          ),
                          Positioned(
                            left: 12,
                            right: 12,
                            bottom: 10,
                            child: LayoutBuilder(
                              builder: (context, room) {
                                final showLabel =
                                    expanded && room.maxWidth > 120;
                                return Tooltip(
                                  message: '设置（⌘,）',
                                  excludeFromSemantics: true,
                                  child: prism.PressSurface(
                                    fill: Colors.transparent,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    onPressed: () => openTool(_Tool.settings),
                                    child: Semantics(
                                      label: '设置',
                                      excludeSemantics: true,
                                      child: SizedBox(
                                        height: 40,
                                        child: Row(
                                          mainAxisAlignment: showLabel
                                              ? MainAxisAlignment.start
                                              : MainAxisAlignment.center,
                                          children: [
                                            if (showLabel)
                                              const SizedBox(width: 15),
                                            GlyphIcon(
                                              AppGlyphs.settings,
                                              size: 22,
                                              color: palette.onSurfaceVariant,
                                            ),
                                            if (showLabel) ...[
                                              const SizedBox(width: 12),
                                              Text(
                                                '设置',
                                                style: prism
                                                    .AppTextStyle
                                                    .subheadline
                                                    .of(context)
                                                    .copyWith(
                                                      color: palette.onSurface,
                                                    ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            key: header,
                            height: 68,
                            child: Padding(
                              padding: const EdgeInsetsDirectional.only(
                                start: 18,
                                end: 14,
                                top: 7,
                              ),
                              child: Row(
                                children: [
                                  Semantics(
                                    header: true,
                                    child: Text(
                                      destinations[page].label,
                                      style: TextStyle(
                                        fontSize: 23,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: -.6,
                                        color: palette.onSurface,
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: Listener(
                                      behavior: HitTestBehavior.opaque,
                                      onPointerDown: (event) {
                                        if (event.buttons == 1)
                                          unawaited(
                                            model.platform('startDragging'),
                                          );
                                      },
                                      child: const SizedBox.expand(),
                                    ),
                                  ),
                                  if (page != 0 ||
                                      hidden ||
                                      model.needsPreparation)
                                    TextButton.icon(
                                      onPressed: model.needsPreparation
                                          ? () => openTool(_Tool.prepare)
                                          : model.canConnectAction
                                          ? model.toggleConnection
                                          : null,
                                      icon: const Icon(
                                        Icons.power_settings_new_rounded,
                                        size: 18,
                                      ),
                                      label: Text(
                                        model.needsPreparation
                                            ? '准备服务'
                                            : model.connectionAction,
                                      ),
                                    )
                                  else
                                    Tooltip(
                                      message: model.phaseLabel,
                                      child: Semantics(
                                        label: '连接状态：${model.phaseLabel}',
                                        child: CircleAvatar(
                                          radius: 15,
                                          backgroundColor: model.connected
                                              ? const Color(0xff96f598)
                                              : palette.surfaceContainerHighest,
                                          child: Icon(
                                            model.connected
                                                ? Icons.check_rounded
                                                : Icons.remove_rounded,
                                            size: 18,
                                            color: model.connected
                                                ? const Color(0xff195d25)
                                                : palette.onSurfaceVariant,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          _error(),
                          if (model.modeHint != null)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                              ),
                              child: Text(model.modeHint!),
                            ),
                          Expanded(
                            child: FadeTransition(
                              opacity: enter,
                              child: IndexedStack(
                                index: page,
                                sizing: StackFit.expand,
                                children: [
                                  dashboardPages[model.needsPreparation]!,
                                  nodesPage,
                                  configurationPages[page == 2]!,
                                  logPages[page == 3]!,
                                ],
                              ),
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
      );
    },
  );
}
