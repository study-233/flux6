import 'package:flutter/material.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'package:prism_ui/sidebar.dart' as sidebar;

import '../components/app_glyphs.dart';
import 'client_model.dart';

// Keep geometry aligned with macOS live_main.dart; Windows keeps its caption.
class DesktopSidebar extends StatelessWidget {
  const DesktopSidebar({
    super.key,
    required this.expanded,
    required this.page,
    required this.model,
    required this.onSelected,
    required this.onSettings,
    this.onToggle,
  });
  final bool expanded;
  final int page;
  final ClientModel model;
  final ValueChanged<int> onSelected;
  final VoidCallback onSettings;
  final VoidCallback? onToggle;

  static const destinations = [
    sidebar.SidebarDestination(glyph: AppGlyphs.dashboard, label: '仪表盘'),
    sidebar.SidebarDestination(glyph: AppGlyphs.proxies, label: '节点'),
    sidebar.SidebarDestination(glyph: AppGlyphs.profiles, label: '配置'),
    sidebar.SidebarDestination(glyph: AppGlyphs.logs, label: '日志'),
  ];

  @override
  Widget build(BuildContext context) {
    final colors = prism.Theme.of(context).colorScheme;
    return DecoratedBox(
      key: const ValueKey('desktop-sidebar'),
      decoration: BoxDecoration(
        color: colors.chromeSurface,
        border: BorderDirectional(
          end: BorderSide(color: colors.onSurface.withValues(alpha: .08)),
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
              onSelected: onSelected,
              // Mac's compact rail, without reserving traffic-light height.
              windowControls: const Size(78, 0),
              onToggle: onToggle,
            ),
          ),
          Positioned(
            left: 12,
            right: 12,
            bottom: 10,
            child: LayoutBuilder(
              builder: (context, room) {
                final showLabel = expanded && room.maxWidth > 120;
                return Tooltip(
                  message: '设置',
                  child: prism.PressSurface(
                    fill: Colors.transparent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    onPressed: onSettings,
                    child: SizedBox(
                      height: 40,
                      child: Row(
                        mainAxisAlignment: showLabel
                            ? MainAxisAlignment.start
                            : MainAxisAlignment.center,
                        children: [
                          if (showLabel) const SizedBox(width: 15),
                          GlyphIcon(
                            AppGlyphs.settings,
                            size: 22,
                            color: colors.onSurfaceVariant,
                          ),
                          if (showLabel) ...[
                            const SizedBox(width: 12),
                            Text(
                              '设置',
                              style: prism.AppTextStyle.subheadline
                                  .of(context)
                                  .copyWith(color: colors.onSurface),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class DesktopHeader extends StatelessWidget {
  const DesktopHeader({
    super.key,
    required this.page,
    required this.model,
    required this.onNotices,
    required this.seasonal,
  });
  final int page;
  final ClientModel model;
  final VoidCallback onNotices;
  final Widget seasonal;

  @override
  Widget build(BuildContext context) {
    final colors = prism.Theme.of(context).colorScheme;
    return SizedBox(
      height: 68,
      child: Padding(
        padding: const EdgeInsetsDirectional.only(start: 18, end: 14, top: 7),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  DesktopSidebar.destinations[page].label,
                  style: TextStyle(
                    fontSize: 23,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -.6,
                    color: colors.onSurface,
                  ),
                ),
              ),
            ),
            if (model.preview)
              Tooltip(
                message: '演示模式 · 不连接网络',
                child: Text(
                  '离线预览',
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            seasonal,
            if (page != 0)
              TextButton.icon(
                onPressed: model.canConnectAction
                    ? model.toggleConnection
                    : null,
                icon: const Icon(Icons.power_settings_new_rounded, size: 18),
                label: Text(model.connected ? '断开' : '连接'),
              ),
            PopupMenuButton<String>(
              tooltip: '更多操作',
              icon: Badge(
                isLabelVisible: model.unreadNotices > 0,
                smallSize: 6,
                child: const Icon(Icons.more_horiz_rounded, size: 21),
              ),
              onSelected: (value) {
                if (value == 'refresh') model.act('refresh');
                if (value == 'notices') onNotices();
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'refresh',
                  enabled: !model.pending('refresh'),
                  child: const Text('刷新状态'),
                ),
                PopupMenuItem(
                  value: 'notices',
                  child: Text(
                    '公告${model.unreadNotices > 0 ? '（${model.unreadNotices}）' : ''}',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
