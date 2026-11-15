import 'dart:math' as math;

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/views/dashboard/layout.dart';
import 'package:fl_clash/views/dashboard/style.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';

import 'card.dart';
import 'network_speed_chart.dart';

const _minSpeedScale = 8 * 1024.0;

const _chartBleed = 3.0;

enum TrafficDirection {
  upload,
  download;

  num of(Traffic traffic) => this == upload ? traffic.up : traffic.down;

  Glyph get glyph => this == upload ? AppGlyphs.arrowUp : AppGlyphs.arrowDown;

  Color colorOf(BuildContext context) => this == upload
      ? DashboardColors.of(context).series2
      : context.colorScheme.primary;

  Color glyphColorOf(BuildContext context) => this == upload
      ? context.colorScheme.onSurfaceVariant
      : context.colorScheme.primary;

  String labelOf(BuildContext context) => this == upload
      ? context.appLocalizations.upload
      : context.appLocalizations.download;
}

class _Figure extends StatelessWidget {
  const _Figure({
    required this.show,
    required this.style,
    required this.unitStyle,
  });

  final TrafficShow show;
  final AppTextStyle style;
  final AppTextStyle unitStyle;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: show.value,
            style: DashboardText.figure(context, style),
          ),
          TextSpan(
            text: ' ${show.unit}/s',
            style: DashboardText.unit(context, unitStyle),
          ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.clip,
    );
  }
}

/// The zero line is the chart's bottom: a card lets the chart bleed past its
/// edge so idle traffic, or none sampled yet, leaves no line.
class _SpeedChart extends StatelessWidget {
  const _SpeedChart({required this.direction, required this.traffics});

  final TrafficDirection direction;
  final FixedList<Traffic> traffics;

  @override
  Widget build(BuildContext context) {
    return LineChart(
      values: [
        for (final traffic in traffics.list) direction.of(traffic).toDouble(),
      ],
      revision: traffics.revision,
      capacity: traffics.maxLength,
      minScale: _minSpeedScale,
      baselineRatio: 1,
      color: direction.colorOf(context),
    );
  }
}

/// The upload or the download on its own desktop card.
class SpeedCard extends ConsumerWidget {
  const SpeedCard({super.key, required this.direction});

  final TrafficDirection direction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final density = DashboardDensityScope.of(context);
    final compact = density.isCompact;
    final scale = DashboardDensityScope.scaleOf(context);
    final padding = dashboardCardPadding(density);
    final appLocalizations = context.appLocalizations;
    final traffics = ref.watch(trafficsProvider);
    final total = ref.watch(
      totalTrafficProvider.select((state) => direction.of(state)),
    );
    final current = direction.of(traffics.list.safeLast(const Traffic()));
    final peak = traffics.list.fold<num>(
      0,
      (peak, traffic) => math.max(peak, direction.of(traffic)),
    );
    final speed = current.traffic;
    return DashboardCard(
      padding: EdgeInsets.zero,
      semanticLabel: direction.labelOf(context),
      onTap: () => _showTrafficUsage(context),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned(
            left: -_chartBleed,
            right: -_chartBleed,
            bottom: -_chartBleed,
            height: compact ? 62 : 88,
            child: RepaintBoundary(
              child: _SpeedChart(direction: direction, traffics: traffics),
            ),
          ),
          Padding(
            padding: padding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 24 * scale,
                  child: Row(
                    spacing: 8,
                    children: [
                      GlyphIcon(
                        direction.glyph,
                        size: 18,
                        color: direction.glyphColorOf(context),
                      ),
                      Text(
                        direction.labelOf(context),
                        maxLines: 1,
                        style: DashboardText.cardTitle(context),
                      ),
                      Expanded(
                        child: Text(
                          appLocalizations.trafficPeak(
                            '${dashboardTraffic(peak)}/s',
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.end,
                          style: DashboardText.label(context),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: compact ? 6 : 10),
                _Figure(
                  show: speed,
                  style: compact
                      ? AppTextStyle.largeTitle
                      : AppTextStyle.display,
                  unitStyle: AppTextStyle.subheadline,
                ),
                const SizedBox(height: 2),
                Text(
                  appLocalizations.trafficSessionUsage(dashboardTraffic(total)),
                  maxLines: 1,
                  style: DashboardText.label(context),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Color _seriesColor(BuildContext context, TrafficDirection direction) =>
    direction == TrafficDirection.upload
    ? context.colorScheme.tertiary
    : context.colorScheme.primary;

class NetworkSpeedCard extends ConsumerWidget {
  const NetworkSpeedCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final traffics = ref.watch(trafficsProvider);
    final total = ref.watch(totalTrafficProvider);
    final latest = traffics.list.safeLast(const Traffic());
    return DashboardCard(
      semanticLabel: context.appLocalizations.networkSpeed,
      onTap: () => _showTrafficUsage(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DashboardCardHeader(
            glyph: AppGlyphs.speed,
            title: context.appLocalizations.networkSpeed,
            chevron: true,
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final half = (constraints.maxWidth - 12) / 2;
              final width = half >= MediaQuery.textScalerOf(context).scale(112)
                  ? half
                  : constraints.maxWidth;
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final direction in TrafficDirection.values)
                    SizedBox(
                      key: ValueKey(direction),
                      width: width,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _DirectionLabel(direction),
                          const SizedBox(height: 2),
                          _Figure(
                            show: direction.of(latest).traffic,
                            style: AppTextStyle.title2,
                            unitStyle: AppTextStyle.footnote,
                          ),
                          Text(
                            context.appLocalizations.trafficSessionUsage(
                              dashboardTraffic(direction.of(total)),
                            ),
                            style: DashboardText.label(context),
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          NetworkSpeedChart(
            window: traffics,
            minimumScale: _minSpeedScale,
            uploadColor: _seriesColor(context, TrafficDirection.upload),
            downloadColor: _seriesColor(context, TrafficDirection.download),
          ),
        ],
      ),
    );
  }
}

class _DirectionLabel extends StatelessWidget {
  const _DirectionLabel(this.direction, {this.value});

  final TrafficDirection direction;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final color = _seriesColor(context, direction);
    final dashed = value == null && direction == TrafficDirection.upload;
    final mark = SizedBox(
      height: 3,
      width: dashed ? 7 : 16,
      child: DecoratedBox(
        decoration: ShapeDecoration(shape: AppShape.full, color: color),
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        mark,
        if (dashed) ...[const SizedBox(width: 2), mark],
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            [direction.labelOf(context), ?value].join(' '),
            style: DashboardText.label(context),
          ),
        ),
      ],
    );
  }
}

void _showTrafficUsage(BuildContext context) {
  showSheet<void>(context: context, builder: (_) => const _TrafficUsageSheet());
}

class _TrafficUsageSheet extends ConsumerStatefulWidget {
  const _TrafficUsageSheet();

  @override
  ConsumerState<_TrafficUsageSheet> createState() => _TrafficUsageSheetState();
}

class _TrafficUsageSheetState extends ConsumerState<_TrafficUsageSheet>
    with WidgetsBindingObserver, ActivePollingMixin<_TrafficUsageSheet> {
  ({Traffic month, Traffic total})? _usage;

  @override
  Duration get pollInterval => const Duration(seconds: 2);

  @override
  Future<void> poll(PollGuard isCurrent) async {
    final onlyProxy = ref.read(appSettingProvider).onlyStatisticsProxy;
    final usage = await ref
        .read(coreHandlerProvider)
        .getTrafficUsage(onlyProxy);
    if (isCurrent() && usage != _usage) setState(() => _usage = usage);
  }

  @override
  Widget build(BuildContext context) {
    final labels = context.appLocalizations;
    final usage = _usage;
    final scale = math.max(usage?.month.speed ?? 0, usage?.total.speed ?? 0);
    return Scaffold(
      title: labels.trafficUsage,
      body: ListView(
        shrinkWrap: true,
        padding: EdgeInsets.fromLTRB(
          16,
          context.contentTopPadding,
          16,
          context.bottomInset + 16,
        ),
        children: [
          _UsageBar(
            title: labels.trafficThisMonth,
            traffic: usage?.month,
            scale: scale,
          ),
          const SizedBox(height: 12),
          _UsageBar(
            title: labels.trafficAllTime,
            traffic: usage?.total,
            scale: scale,
          ),
        ],
      ),
    );
  }
}

class _UsageBar extends StatelessWidget {
  const _UsageBar({
    required this.title,
    required this.traffic,
    required this.scale,
  });

  final String title;
  final Traffic? traffic;
  final num scale;

  @override
  Widget build(BuildContext context) {
    final sample = traffic;
    return Semantics(
      container: true,
      child: DashboardBlock(
        radius: DashboardCorner.block,
        color: DashboardColors.of(context).card,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(title, style: DashboardText.rowTitle(context)),
                ),
                Flexible(
                  child: Semantics(
                    label: context.appLocalizations.total,
                    child: Text(
                      sample == null ? '—' : dashboardTraffic(sample.speed),
                      style: DashboardText.figure(context, AppTextStyle.title3),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRSuperellipse(
              borderRadius: AppRadius.full,
              child: ColoredBox(
                color: DashboardColors.of(context).tone,
                child: SizedBox(
                  height: 10,
                  child: LayoutBuilder(
                    builder: (context, bounds) => Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (sample != null && scale > 0)
                          for (final direction in TrafficDirection.values)
                            SizedBox(
                              width:
                                  bounds.maxWidth *
                                  (direction.of(sample) / scale),
                              child: ColoredBox(
                                color: _seriesColor(context, direction),
                              ),
                            ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 20,
              runSpacing: 4,
              children: [
                for (final direction in TrafficDirection.values)
                  _DirectionLabel(
                    direction,
                    value: sample == null
                        ? '—'
                        : dashboardTraffic(direction.of(sample)),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
