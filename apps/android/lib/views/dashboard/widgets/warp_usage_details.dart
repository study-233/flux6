import 'dart:math' as math;

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:flutter/widgets.dart';

import '../style.dart';
import 'card.dart';
import 'warp_usage_chart.dart';

enum _Period { session, month, total }

class WarpUsageDetails extends StatefulWidget {
  const WarpUsageDetails({
    super.key,
    required this.session,
    required this.month,
    required this.total,
    this.status,
  });

  final Traffic session;
  final Traffic? month;
  final Traffic? total;
  final Widget? status;

  @override
  State<WarpUsageDetails> createState() => _WarpUsageDetailsState();
}

class _WarpUsageDetailsState extends State<WarpUsageDetails> {
  var _selected = _Period.month;

  @override
  Widget build(BuildContext context) {
    final labels = context.appLocalizations;
    final periods = [
      (_Period.session, labels.warpSessionUsage, widget.session),
      (_Period.month, labels.trafficThisMonth, widget.month),
      (_Period.total, labels.trafficAllTime, widget.total),
    ];
    final (_, label, traffic) = periods[_selected.index];
    final largest = periods.fold<num>(
      0,
      (value, period) => math.max(value, period.$3?.speed ?? 0),
    );
    final scale = math.max(1.0, MediaQuery.textScalerOf(context).scale(1));
    return Scaffold(
      title: labels.trafficUsage,
      body: Builder(
        builder: (context) => ListView(
          padding: EdgeInsets.fromLTRB(
            16,
            context.contentTopPadding,
            16,
            context.bottomInset + 16,
          ),
          children: [
            SegmentedControl<_Period>(
              segments: [
                for (final (period, label, _) in periods) (period, label),
              ],
              value: _selected,
              onChanged: (period) => setState(() => _selected = period),
              size: TonalButtonSize.bar,
              stretches: true,
            ),
            const SizedBox(height: 12),
            DashboardBlock(
              radius: AppCorner.xl,
              padding: const EdgeInsets.all(16),
              color: DashboardColors.of(context).card,
              child: WidthBuilder(
                builder: (context, width) {
                  final stacked = width < 264 * scale;
                  final diameter = math.min(
                    stacked ? width : width * .48,
                    168 * scale,
                  );
                  final ring = UsageRing(
                    traffic: traffic,
                    size: diameter,
                    center: Semantics(
                      label: label,
                      value: traffic == null
                          ? labels.noData
                          : dashboardTraffic(traffic.speed),
                      excludeSemantics: true,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              labels.total,
                              style: DashboardText.label(context),
                            ),
                            Text(
                              traffic == null
                                  ? '—'
                                  : dashboardTraffic(traffic.speed),
                              style: DashboardText.figure(
                                context,
                                AppTextStyle.title1,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                  final legend = UsageLegend(traffic: traffic);
                  return stacked
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          spacing: 16,
                          children: [
                            Center(child: ring),
                            legend,
                          ],
                        )
                      : Row(
                          spacing: 16,
                          children: [
                            ring,
                            Expanded(child: legend),
                          ],
                        );
                },
              ),
            ),
            const SizedBox(height: 12),
            DashboardBlock(
              radius: AppCorner.xl,
              color: DashboardColors.of(context).card,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 14,
                children: [
                  Text(labels.overview, style: DashboardText.rowTitle(context)),
                  for (final (_, label, sample) in periods)
                    _ComparisonBar(
                      label: label,
                      sample: sample,
                      largest: largest,
                    ),
                ],
              ),
            ),
            if (widget.status case final status?) ...[
              const SizedBox(height: 12),
              status,
            ],
          ],
        ),
      ),
    );
  }
}

class _ComparisonBar extends StatelessWidget {
  const _ComparisonBar({
    required this.label,
    required this.sample,
    required this.largest,
  });

  final String label;
  final Traffic? sample;
  final num largest;

  @override
  Widget build(BuildContext context) {
    final sample = this.sample;
    final amount = sample == null ? '—' : dashboardTraffic(sample.speed);
    final labels = context.appLocalizations;
    return Semantics(
      excludeSemantics: true,
      label: label,
      value: sample == null
          ? labels.noData
          : '$amount, ${labels.upload} ${dashboardTraffic(sample.up)}, ${labels.download} ${dashboardTraffic(sample.down)}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 5,
        children: [
          DashboardCappedRow(
            start: Text(label, style: DashboardText.label(context)),
            end: Text(
              amount,
              style: DashboardText.figure(context, AppTextStyle.footnote),
            ),
          ),
          SizedBox(
            height: 8,
            child: DecoratedBox(
              decoration: ShapeDecoration(
                color: DashboardColors.of(context).tone2,
                shape: AppShape.full,
              ),
              child: sample == null || sample.speed <= 0 || largest <= 0
                  ? null
                  : FractionallySizedBox(
                      widthFactor: (sample.speed / largest).clamp(0.0, 1.0),
                      alignment: AlignmentDirectional.centerStart,
                      child: ClipRSuperellipse(
                        borderRadius: AppRadius.full,
                        child: ColoredBox(
                          color: usageDownloadColor(context),
                          child: FractionallySizedBox(
                            widthFactor: (sample.up / sample.speed).clamp(
                              0.0,
                              1.0,
                            ),
                            alignment: AlignmentDirectional.centerStart,
                            child: ColoredBox(color: usageUploadColor(context)),
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
