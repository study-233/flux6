// Layout adapted from FlClash v0.9.3's desktop dashboard. The source revision
// and GPL license are recorded in vendor/flclash/.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart' as prism;

import 'components/flclash.dart';
import 'dashboard_model.dart';

String formattedBytes(num bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var index = 0;
  while (value >= 1000 && index < units.length - 1) {
    value /= 1000;
    index++;
  }
  final number = value.toStringAsFixed(
    value >= 100 || value == value.roundToDouble() ? 0 : 1,
  );
  return '$number ${units[index]}';
}

String _runtime(Duration value) {
  String digits(int n) => n.toString().padLeft(2, '0');
  return '${digits(value.inHours)}:${digits(value.inMinutes % 60)}:${digits(value.inSeconds % 60)}';
}

class PreviewDashboard extends StatelessWidget {
  const PreviewDashboard({
    super.key,
    required this.model,
    required this.scroll,
    required this.onPage,
    required this.onNodes,
    this.connectionKey,
    this.onEditLayout,
    this.onPrepare,
  });
  final DashboardModel model;
  final ScrollController scroll;
  final ValueChanged<int> onPage;
  final VoidCallback onNodes;
  final Key? connectionKey;
  final VoidCallback? onEditLayout, onPrepare;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, room) {
      final scale = math.max(1.0, MediaQuery.textScalerOf(context).scale(1));
      final logicalWidth = room.maxWidth / scale;
      final int columns = logicalWidth < 560
          ? 1
          : dashboardColumnsOf(logicalWidth);
      final density = DashboardDensity.of(
        Size(logicalWidth, room.maxHeight / scale),
      );
      final desktopDensity = density == DashboardDensity.mobile
          ? DashboardDensity.compact
          : density;
      final compact = desktopDensity == DashboardDensity.compact;
      final topHeight = (compact ? 176.0 : 208.0) * scale;
      final controlHeight = (compact ? 56.0 : 64.0) * scale;
      final gap = MediaQuery.sizeOf(context).width >= 1080 ? 16.0 : 12.0;
      final middleHeight = (compact ? 152.0 : 176.0) * scale;
      final summaryHeight = columns == 4
          ? (room.maxHeight -
                    40 -
                    gap * 3 -
                    topHeight -
                    controlHeight -
                    middleHeight)
                .clamp(192.0 * scale, 300.0 * scale)
                .toDouble()
          : 200.0 * scale;

      Widget row(List<(int, Widget)> items, double height) => SizedBox(
        height: height,
        child: LayoutBuilder(
          builder: (context, bounds) {
            final units = items.fold<int>(0, (n, tile) => n + tile.$1);
            final column = (bounds.maxWidth - gap * (units - 1)) / units;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, tile) in items.indexed) ...[
                  if (i > 0) SizedBox(width: gap),
                  SizedBox(
                    width: column * tile.$1 + gap * (tile.$1 - 1),
                    child: RepaintBoundary(child: tile.$2),
                  ),
                ],
              ],
            );
          },
        ),
      );

      Widget speed(bool upload) => ListenableBuilder(
        listenable: model.traffic,
        builder: (_, __) => SpeedCard(
          upload: upload,
          samples: upload ? model.uploadHistory : model.downloadHistory,
          capacity: 48,
          revision: model.traffic.value,
          total:
              '${model.monthly ? "本月" : "累计"} ${model.usageKnown ? formattedBytes(upload ? model.usageUpload : model.usageDownload) : "—"}',
        ),
      );
      Widget outbound() => ListenableBuilder(
        listenable: model.traffic,
        builder: (_, __) => CurrentOutboundCard(
          key: connectionKey,
          running: model.connected,
          busy: onPrepare == null && !model.canConnectAction,
          phaseLabel: model.phaseLabel,
          actionLabel: onPrepare != null ? '准备服务' : model.actionLabel,
          node: model.displayNode == '自动选择'
              ? '自动选择'
              : '${model.profileName} · ${model.displayNode}',
          mode: model.mode,
          runtime: model.uptimeKnown ? _runtime(model.uptime) : '—',
          onToggle: onPrepare ?? model.toggleConnection,
        ),
      );

      return DashboardDensityScope(
        density: desktopDensity,
        scale: scale,
        child: AnimatedBuilder(
          animation: model,
          builder: (_, __) {
            final mode = OutboundModeBar(
              allowDirect: model.allowDirectMode,
              selected: DashboardModel.modeNames.indexOf(model.mode),
              onChanged: model.canChangeMode
                  ? (index) => model.selectMode(DashboardModel.modeNames[index])
                  : null,
            );
            final node = _ActionCard(
              glyph: AppGlyphs.proxies,
              title: '接入节点',
              value: model.displayNode,
              onTap: onNodes,
            );
            final profile = _ActionCard(
              glyph: AppGlyphs.profiles,
              title: '配置',
              value: model.profileName,
              onTap: () => onPage(2),
            );
            final usage = ListenableBuilder(
              listenable: model.traffic,
              builder: (_, __) => _UsageCard(model: model),
            );
            final latency = _LatencyCard(model: model);
            final recent = _RecentCard(model: model, onTap: () => onPage(3));
            final groups = _NodesCard(model: model, onTap: () => onPage(1));
            final layout = model.customLayout;
            final rows = layout != null
                ? <Widget>[
                    if (layout.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 40),
                        child: Center(
                          child: OutlinedButton.icon(
                            onPressed: onEditLayout,
                            icon: const Icon(
                              Icons.dashboard_customize_outlined,
                            ),
                            label: const Text('添加首页组件'),
                          ),
                        ),
                      )
                    else
                      LayoutBuilder(
                        builder: (context, bounds) {
                          final available = bounds.maxWidth;
                          final half = (available - gap) / 2;
                          return Wrap(
                            spacing: gap,
                            runSpacing: gap,
                            children: [
                              for (final tile in layout)
                                Builder(
                                  builder: (context) {
                                    final kind = tile['kind'];
                                    final minWidth = kind == 'mode'
                                        ? 420.0
                                        : kind == 'connection'
                                        ? 370.0
                                        : kind == 'speed'
                                        ? 420.0
                                        : 240.0;
                                    final width =
                                        tile['size'] == 'wide' ||
                                            half < minWidth
                                        ? available
                                        : half;
                                    final (height, child) = switch (kind) {
                                      'connection' => (topHeight, outbound()),
                                      'speed' => (
                                        topHeight,
                                        row([
                                          (1, speed(true)),
                                          (1, speed(false)),
                                        ], topHeight),
                                      ),
                                      'mode' => (controlHeight, mode),
                                      'node' => (controlHeight, node),
                                      'usage' => (middleHeight, usage),
                                      _ => (0.0, const SizedBox.shrink()),
                                    };
                                    return SizedBox(
                                      width: width,
                                      height: height,
                                      child: RepaintBoundary(child: child),
                                    );
                                  },
                                ),
                            ],
                          );
                        },
                      ),
                  ]
                : <Widget>[
                    if (columns == 4) ...[
                      row([
                        (2, outbound()),
                        (1, speed(true)),
                        (1, speed(false)),
                      ], topHeight),
                      row([(2, mode), (1, node), (1, profile)], controlHeight),
                    ] else ...[
                      row([(1, outbound())], topHeight),
                      if (columns == 2)
                        row([(1, speed(true)), (1, speed(false))], topHeight)
                      else ...[
                        row([(1, speed(true))], topHeight),
                        row([(1, speed(false))], topHeight),
                      ],
                      row([(1, mode)], controlHeight),
                      if (columns == 2)
                        row([(1, node), (1, profile)], controlHeight)
                      else ...[
                        row([(1, node)], controlHeight),
                        row([(1, profile)], controlHeight),
                      ],
                    ],
                    if (columns > 1) ...[
                      row([(1, usage), (1, latency)], middleHeight),
                      row([(3, recent), (2, groups)], summaryHeight),
                    ] else ...[
                      row([(1, usage)], 162 * scale),
                      row([(1, latency)], 162 * scale),
                      row([(1, recent)], 198 * scale),
                      row([(1, groups)], 198 * scale),
                    ],
                  ];
            return SingleChildScrollView(
              controller: scroll,
              padding: EdgeInsets.fromLTRB(16, 16, columns == 4 ? 20 : 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, child) in rows.indexed) ...[
                    if (i != 0) SizedBox(height: gap),
                    child,
                  ],
                ],
              ),
            );
          },
        ),
      );
    },
  );
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.glyph,
    required this.title,
    required this.value,
    required this.onTap,
  });
  final Glyph glyph;
  final String title, value;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final colors = prism.Theme.of(context).colorScheme;
    return DashboardCard(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      semanticLabel: '$title，$value',
      onTap: onTap,
      child: Row(
        children: [
          GlyphIcon(glyph, size: 17, color: colors.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: colors.onSurface,
            ),
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ),
          GlyphIcon(
            AppGlyphs.chevronForward,
            size: 15,
            color: colors.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}

class _TitleRow extends StatelessWidget {
  const _TitleRow(this.glyph, this.title, {this.trailing});
  final Glyph glyph;
  final String title;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final scheme = prism.Theme.of(context).colorScheme;
    return Row(
      children: [
        GlyphIcon(glyph, size: 16, color: scheme.onSurfaceVariant),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

class _UsageCard extends StatelessWidget {
  const _UsageCard({required this.model});
  final DashboardModel model;
  @override
  Widget build(BuildContext context) {
    final scheme = prism.Theme.of(context).colorScheme;
    final total = model.usageUpload.toDouble() + model.usageDownload.toDouble();
    final downloadShare = total > 0
        ? (10000 * model.usageDownload / total).round().clamp(0, 10000)
        : 5000;
    return DashboardCard(
      padding: const EdgeInsets.symmetric(horizontal: 19, vertical: 15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TitleRow(
            AppGlyphs.status,
            '用量统计',
            trailing: Container(
              decoration: BoxDecoration(
                color: prism.SurfaceLevel.block.colorOf(scheme),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final monthly in [true, false])
                    Semantics(
                      selected: model.monthly == monthly,
                      button: true,
                      child: InkWell(
                        onTap: () => model.setMonthly(monthly),
                        borderRadius: BorderRadius.circular(18),
                        child: AnimatedContainer(
                          duration: MediaQuery.disableAnimationsOf(context)
                              ? Duration.zero
                              : const Duration(milliseconds: 145),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: model.monthly == monthly
                                ? scheme.primary
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Text(
                            monthly ? '本月' : '累计',
                            semanticsLabel: model.monthly == monthly
                                ? (monthly ? '本月，已选中' : '累计，已选中')
                                : null,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: model.monthly == monthly
                                  ? scheme.onPrimary
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const Spacer(),
          Text(
            model.usageKnown ? formattedBytes(total) : '—',
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: 28,
              height: 1.05,
              fontWeight: FontWeight.w700,
              letterSpacing: -.7,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: Row(
              children: [
                Expanded(
                  flex: downloadShare,
                  child: ColoredBox(
                    color: total > 0
                        ? scheme.primary
                        : scheme.surfaceContainerHighest,
                    child: const SizedBox(height: 5),
                  ),
                ),
                Expanded(
                  flex: 10000 - downloadShare,
                  child: ColoredBox(
                    color: total > 0
                        ? scheme.primary.withValues(alpha: .40)
                        : scheme.surfaceContainerHighest,
                    child: const SizedBox(height: 5),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            model.usageKnown
                ? '↓ ${formattedBytes(model.usageDownload)}　 ↑ ${formattedBytes(model.usageUpload)}'
                : '暂无用量报告',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _LatencyCard extends StatelessWidget {
  const _LatencyCard({required this.model});
  final DashboardModel model;
  @override
  Widget build(BuildContext context) {
    final scheme = prism.Theme.of(context).colorScheme;
    final current = model.currentNode;
    final delay = current == null ? null : model.latency(current);
    final busy = current != null && model.measuring(current);
    return DashboardCard(
      padding: const EdgeInsets.symmetric(horizontal: 19, vertical: 15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TitleRow(
            AppGlyphs.proxies,
            '节点延迟',
            trailing: IconButton(
              tooltip: '测量当前节点',
              visualDensity: VisualDensity.compact,
              onPressed: model.canMeasure && current != null && !busy
                  ? () => model.measure(current)
                  : null,
              icon: const Icon(
                Icons.speed_rounded,
                size: 19,
                semanticLabel: '测量当前节点',
              ),
            ),
          ),
          const Spacer(),
          Text(
            busy
                ? '测速中'
                : delay == null
                ? '—'
                : delay < 0
                ? (delay == -1 ? '超时' : '不可用')
                : '$delay ms',
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: 28,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            current != null ? '当前节点 · $current' : '连接后可测速',
            style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _RecentCard extends StatelessWidget {
  const _RecentCard({required this.model, required this.onTap});
  final DashboardModel model;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final scheme = prism.Theme.of(context).colorScheme;
    final logs = model.logs.take(3).toList();
    return DashboardCard(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      semanticLabel: '最近事件，打开日志',
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TitleRow(
            AppGlyphs.logs,
            '最近事件',
            trailing: GlyphIcon(AppGlyphs.chevronForward, size: 16),
          ),
          const SizedBox(height: 12),
          if (logs.isEmpty)
            Text(
              '暂无日志',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
          for (final log in logs)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: _SummaryRow(
                leading:
                    '${log.time.hour.toString().padLeft(2, '0')}:${log.time.minute.toString().padLeft(2, '0')}',
                label: log.message,
              ),
            ),
        ],
      ),
    );
  }
}

class _NodesCard extends StatelessWidget {
  const _NodesCard({required this.model, required this.onTap});
  final DashboardModel model;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => DashboardCard(
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
    semanticLabel: '接入节点列表',
    onTap: onTap,
    child: Column(
      children: [
        _TitleRow(
          AppGlyphs.layers,
          '接入节点',
          trailing: GlyphIcon(AppGlyphs.chevronForward, size: 16),
        ),
        const SizedBox(height: 12),
        for (final node in model.nodes.take(3))
          Padding(
            padding: const EdgeInsets.only(bottom: 5),
            child: _SummaryRow(
              leading: node,
              label: model.currentNode == node
                  ? '使用中'
                  : model.preferredNode == node
                  ? '下次连接'
                  : '可选',
            ),
          ),
      ],
    ),
  );
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.leading, required this.label});
  final String leading, label;
  @override
  Widget build(BuildContext context) {
    final colors = prism.Theme.of(context).colorScheme;
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 11),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(11),
        color: prism.SurfaceLevel.block.colorOf(colors),
      ),
      child: LayoutBuilder(
        builder: (context, room) => Row(
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: room.maxWidth * .62),
              child: Tooltip(
                message: leading,
                child: Text(
                  leading,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.onSurface,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
