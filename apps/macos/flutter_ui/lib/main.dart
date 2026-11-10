import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:prism_ui/sidebar.dart' as sidebar;

import 'components/flclash.dart';
import 'dashboard.dart';
import 'preview/fixture_model.dart';
import 'preview/secondary_pages.dart';
import 'preview/node_picker.dart';
import 'app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final model = await FixtureModel.load();
  runApp(FreeV6Preview(model: model));
}

class FreeV6Preview extends StatefulWidget {
  const FreeV6Preview({super.key, required this.model});
  final FixtureModel model;
  @override
  State<FreeV6Preview> createState() => _FreeV6PreviewState();
}

class _FreeV6PreviewState extends State<FreeV6Preview> {
  ThemeMode appearance = ThemeMode.system;
  bool reduceMotion = false;

  @override
  Widget build(BuildContext context) {
    return FreeV6Theme(
      title: 'Flux6 Flutter Preview',
      appearance: appearance,
      reduceMotion: reduceMotion,
      home: PreviewWindow(
        model: widget.model,
        appearance: appearance,
        reduceMotion: reduceMotion,
        onReduceMotion: () => setState(() => reduceMotion = !reduceMotion),
        onAppearance: (mode) => setState(() => appearance = mode),
      ),
    );
  }
}

enum _Scenario {
  online,
  offline,
  zero,
  normal,
  wide,
  medium,
  compact,
  reduced,
  system,
  light,
  dark,
}

class PreviewWindow extends StatefulWidget {
  const PreviewWindow({
    super.key,
    required this.model,
    required this.appearance,
    required this.onAppearance,
    required this.reduceMotion,
    required this.onReduceMotion,
  });
  final FixtureModel model;
  final ThemeMode appearance;
  final ValueChanged<ThemeMode> onAppearance;
  final bool reduceMotion;
  final VoidCallback onReduceMotion;
  @override
  State<PreviewWindow> createState() => _PreviewWindowState();
}

class _PreviewWindowState extends State<PreviewWindow>
    with SingleTickerProviderStateMixin {
  static const items = [
    sidebar.SidebarDestination(glyph: AppGlyphs.dashboard, label: '仪表盘'),
    sidebar.SidebarDestination(glyph: AppGlyphs.proxies, label: '节点'),
    sidebar.SidebarDestination(glyph: AppGlyphs.profiles, label: '配置'),
    sidebar.SidebarDestination(glyph: AppGlyphs.logs, label: '日志'),
  ];
  final ScrollController homeScroll = ScrollController();
  int page = 0;
  bool? manualExpanded;
  bool offscreen = false;
  late final entry = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 170),
    value: 1,
  );
  late final enterOpacity = Tween<double>(
    begin: .65,
    end: 1,
  ).animate(CurvedAnimation(parent: entry, curve: Curves.easeOutCubic));
  @override
  void initState() {
    super.initState();
    homeScroll.addListener(onHomeScroll);
  }

  @override
  void dispose() {
    homeScroll.dispose();
    entry.dispose();
    super.dispose();
  }

  void onHomeScroll() {
    if (!homeScroll.hasClients) return;
    final hidden = homeScroll.offset >= 180;
    if (hidden != offscreen) setState(() => offscreen = hidden);
  }

  void showPage(int index) {
    if (page != index) {
      FocusManager.instance.primaryFocus?.unfocus();
      setState(() => page = index);
      if (MediaQuery.disableAnimationsOf(context)) {
        entry.value = 1;
      } else {
        entry.forward(from: 0);
      }
    }
  }

  void runScenario(_Scenario choice) {
    switch (choice) {
      case _Scenario.online:
        widget.model.setOnline(true);
      case _Scenario.offline:
        widget.model.setOnline(false);
      case _Scenario.zero:
        widget.model.setOnline(true);
        widget.model.setZeroRate(true);
      case _Scenario.normal:
        widget.model.setOnline(true);
        widget.model.setZeroRate(false);
      case _Scenario.wide:
        resizePreview(const Size(1232, 780));
      case _Scenario.medium:
        resizePreview(const Size(920, 620));
      case _Scenario.compact:
        resizePreview(const Size(720, 480));
      case _Scenario.reduced:
        widget.onReduceMotion();
      case _Scenario.system:
        widget.onAppearance(ThemeMode.system);
      case _Scenario.light:
        widget.onAppearance(ThemeMode.light);
      case _Scenario.dark:
        widget.onAppearance(ThemeMode.dark);
    }
  }

  Future<void> resizePreview(Size size) async {
    setState(() => manualExpanded = null);
    await const MethodChannel(
      'dev.freev6.flutter-preview/window',
    ).invokeMethod<void>('setSize', {
      'width': size.width,
      'height': size.height,
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = prism.Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: prism.SurfaceLevel.page.colorOf(scheme),
      body: CallbackShortcuts(
        bindings: {
          for (final entry in [
            LogicalKeyboardKey.digit1,
            LogicalKeyboardKey.digit2,
            LogicalKeyboardKey.digit3,
            LogicalKeyboardKey.digit4,
          ].indexed)
            SingleActivator(entry.$2, meta: true): () => showPage(entry.$1),
        },
        child: Focus(
          autofocus: true,
          child: LayoutBuilder(
            builder: (context, box) {
              final expanded = manualExpanded ?? box.maxWidth >= 1080;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.chromeSurface,
                      border: BorderDirectional(
                        end: BorderSide(
                          color: scheme.onSurface.withValues(alpha: .08),
                        ),
                      ),
                    ),
                    child: sidebar.NavigationSidebar(
                      key: MediaQuery.disableAnimationsOf(context)
                          ? ValueKey((expanded, page))
                          : const ValueKey('navigation'),
                      destinations: items,
                      selectedIndex: page,
                      expanded: expanded,
                      onSelected: showPage,
                      windowControls: const Size(78, 32),
                      onToggle: () =>
                          setState(() => manualExpanded = !expanded),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
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
                                    items[page].label,
                                    style: TextStyle(
                                      color: scheme.onSurface,
                                      fontSize: 23,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: -.6,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: Listener(
                                    behavior: HitTestBehavior.opaque,
                                    onPointerDown: (event) {
                                      if (event.buttons == 1) {
                                        const MethodChannel(
                                          'dev.freev6.flutter-preview/window',
                                        ).invokeMethod<void>('startDragging');
                                      }
                                    },
                                    child: const SizedBox.expand(),
                                  ),
                                ),
                                AnimatedBuilder(
                                  animation: widget.model,
                                  builder: (context, _) {
                                    final model = widget.model;
                                    final showAction = page != 0 || offscreen;
                                    if (showAction) {
                                      return TextButton.icon(
                                        onPressed: model.busy
                                            ? null
                                            : model.toggleConnection,
                                        icon: Icon(
                                          Icons.power_settings_new_rounded,
                                          size: 17,
                                        ),
                                        label: Text(
                                          model.busy
                                              ? model.phaseLabel
                                              : model.connected
                                              ? '断开'
                                              : '连接',
                                        ),
                                      );
                                    }
                                    return Tooltip(
                                      message: model.phaseLabel,
                                      child: Semantics(
                                        label: '连接状态：${model.phaseLabel}',
                                        child: Container(
                                          width: 30,
                                          height: 30,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: model.connected
                                                ? const Color(0xff96f598)
                                                : scheme
                                                      .surfaceContainerHighest,
                                          ),
                                          child: Icon(
                                            model.connected
                                                ? Icons.check_rounded
                                                : Icons.remove_rounded,
                                            size: 18,
                                            color: model.connected
                                                ? const Color(0xff195d25)
                                                : scheme.onSurfaceVariant,
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                                const SizedBox(width: 4),
                                PopupMenuButton<_Scenario>(
                                  tooltip: '预览场景与外观',
                                  icon: Icon(
                                    Icons.more_horiz_rounded,
                                    semanticLabel: '预览场景与外观',
                                    size: 21,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                  onSelected: runScenario,
                                  itemBuilder: (_) => [
                                    const PopupMenuItem(
                                      value: _Scenario.online,
                                      child: Text('已连接'),
                                    ),
                                    const PopupMenuItem(
                                      value: _Scenario.offline,
                                      child: Text('未连接'),
                                    ),
                                    const PopupMenuItem(
                                      value: _Scenario.zero,
                                      child: Text('在线零速率'),
                                    ),
                                    const PopupMenuItem(
                                      value: _Scenario.normal,
                                      child: Text('恢复流量'),
                                    ),
                                    const PopupMenuDivider(),
                                    const PopupMenuItem(
                                      value: _Scenario.wide,
                                      child: Text('默认窗口'),
                                    ),
                                    const PopupMenuItem(
                                      value: _Scenario.medium,
                                      child: Text('中等窗口'),
                                    ),
                                    const PopupMenuItem(
                                      value: _Scenario.compact,
                                      child: Text('紧凑窗口'),
                                    ),
                                    const PopupMenuDivider(),
                                    for (final (value, name, theme) in [
                                      (
                                        _Scenario.system,
                                        '跟随系统',
                                        ThemeMode.system,
                                      ),
                                      (_Scenario.light, '浅色', ThemeMode.light),
                                      (_Scenario.dark, '深色', ThemeMode.dark),
                                    ])
                                      CheckedPopupMenuItem(
                                        value: value,
                                        checked: widget.appearance == theme,
                                        child: Text(name),
                                      ),
                                    CheckedPopupMenuItem(
                                      value: _Scenario.reduced,
                                      checked: MediaQuery.disableAnimationsOf(
                                        context,
                                      ),
                                      child: const Text('减少动态效果'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                        Expanded(
                          child: FadeTransition(
                            opacity: enterOpacity,
                            child: IndexedStack(
                              index: page,
                              sizing: StackFit.expand,
                              children: [
                                PreviewDashboard(
                                  model: widget.model,
                                  scroll: homeScroll,
                                  onPage: showPage,
                                  onNodes: () => showFixtureNodePicker(
                                    context,
                                    widget.model,
                                  ),
                                ),
                                FixtureNodesPage(model: widget.model),
                                FixtureProfilePage(model: widget.model),
                                FixtureLogsPage(model: widget.model),
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
  }
}
