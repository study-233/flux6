import 'dart:math' as math;

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/warp_setup.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../layout.dart';
import '../style.dart';
import 'card.dart';
import 'traffic.dart';
import 'warp_usage_chart.dart';
import 'warp_usage_details.dart';

class WarpUsageCard extends ConsumerStatefulWidget {
  const WarpUsageCard({super.key}) : _details = false;
  const WarpUsageCard._details() : _details = true;

  final bool _details;

  @override
  ConsumerState<WarpUsageCard> createState() => _WarpUsageCardState();
}

class _WarpUsageCardState extends ConsumerState<WarpUsageCard>
    with WidgetsBindingObserver, ActivePollingMixin<WarpUsageCard> {
  ({Traffic month, Traffic total})? usage;
  bool? _onlyProxy;

  @override
  Duration get pollInterval => const Duration(seconds: 5);

  @override
  Future<void> poll(PollGuard isCurrent) async {
    if (!ref.read(initProvider)) return;
    final onlyProxy = ref.read(appSettingProvider).onlyStatisticsProxy;
    final result = await ref
        .read(coreHandlerProvider)
        .getTrafficUsage(onlyProxy);
    if (isCurrent() && (result != usage || _onlyProxy != onlyProxy)) {
      setState(() {
        usage = result;
        _onlyProxy = onlyProxy;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final labels = context.appLocalizations;
    final onlyProxy = ref.watch(
      appSettingProvider.select((v) => v.onlyStatisticsProxy),
    );
    final data = _onlyProxy == onlyProxy ? usage : null;
    final state = ref.watch(warpSetupProvider);
    final failure = switch (state) {
      WarpSetupStatus.storageFailed => labels.warpStoreFailed,
      WarpSetupStatus.registrationFailed => labels.warpRegisterFailed,
      WarpSetupStatus.profileFailed => labels.warpSetupFailed,
      _ => null,
    };
    final preparing = state == WarpSetupStatus.preparing;
    if (widget._details) {
      return WarpUsageDetails(
        session: ref.watch(totalTrafficProvider),
        month: data?.month,
        total: data?.total,
        status: failure != null
            ? TextButton(
                onPressed: () => ref.read(warpSetupProvider.notifier).prepare(),
                child: Text('$failure · ${labels.retry}'),
              )
            : preparing || state == WarpSetupStatus.ready
            ? Text(preparing ? labels.freev6Preparing : labels.warpReady)
            : null,
      );
    }
    final status = failure ?? (preparing ? labels.freev6Preparing : null);
    return DashboardCard(
      onTap: () => showSheet<void>(
        context: context,
        builder: (_) => const WarpUsageCard._details(),
      ),
      semanticLabel: labels.trafficUsage,
      child: _MonthChart(
        traffic: data?.month,
        status: status,
        failed: failure != null,
      ),
    );
  }
}

class _MonthChart extends StatelessWidget {
  const _MonthChart({
    required this.traffic,
    required this.status,
    required this.failed,
  });

  final Traffic? traffic;
  final String? status;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final labels = context.appLocalizations;
    final scale = DashboardDensityScope.scaleOf(context);
    final total = traffic == null ? '—' : dashboardTraffic(traffic!.speed);
    final header = DashboardCardHeader(
      glyph: AppGlyphs.dataUsage,
      title: labels.trafficUsage,
      trailing: [
        if (status case final message?)
          Tooltip(
            message: message,
            child: Semantics(
              label: message,
              child: GlyphIcon(
                failed ? AppGlyphs.warning : AppGlyphs.clock,
                size: 16,
                color: failed
                    ? context.colorScheme.warning
                    : context.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
      chevron: true,
    );
    final caption = Text(
      labels.trafficThisMonth,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: DashboardText.label(context),
    );
    final amount = Text(
      total,
      maxLines: 1,
      style: DashboardText.figure(context, AppTextStyle.title2),
    );
    Widget ring(double size) => UsageRing(
      traffic: traffic,
      size: size,
      center: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [caption, amount],
        ),
      ),
    );

    return LayoutBuilder(
      builder: (context, room) {
        final width = room.maxWidth / scale;
        final height = room.maxHeight / scale;
        if (width >= 490 && height < 116) {
          return Row(
            spacing: 20,
            children: [
              Expanded(child: header),
              ring(math.min(96 * scale, room.maxHeight)),
              Expanded(child: UsageLegend(traffic: traffic)),
            ],
          );
        }
        if (height < 156) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              Expanded(
                child: Row(
                  spacing: 10,
                  children: [
                    UsageRing(
                      traffic: traffic,
                      size: math.min(62 * scale, room.maxHeight - 26 * scale),
                    ),
                    Expanded(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: AlignmentDirectional.centerStart,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          spacing: 2,
                          children: [
                            Row(spacing: 5, children: [caption, amount]),
                            Row(
                              spacing: 8,
                              children: [
                                for (final direction in TrafficDirection.values)
                                  Semantics(
                                    label: direction.labelOf(context),
                                    child: Row(
                                      spacing: 2,
                                      children: [
                                        GlyphIcon(
                                          direction.glyph,
                                          size: 12,
                                          color: direction.glyphColorOf(
                                            context,
                                          ),
                                        ),
                                        Text(
                                          traffic == null
                                              ? '—'
                                              : dashboardTraffic(
                                                  direction.of(traffic!),
                                                ),
                                          style: DashboardText.label(context),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        }
        if (width >= 278) {
          final size = math.min(148 * scale, room.maxWidth * 0.44);
          return Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              SizedBox(height: 12 * scale),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                spacing: 20,
                children: [
                  ring(math.min(size, room.maxHeight - 40 * scale)),
                  Flexible(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: 200 * scale),
                      child: UsageLegend(traffic: traffic),
                    ),
                  ),
                ],
              ),
            ],
          );
        }
        final plot = LayoutBuilder(
          builder: (context, area) => Center(
            child: ring(
              math.min(152 * scale, math.min(area.maxWidth, area.maxHeight)),
            ),
          ),
        );
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            SizedBox(height: 8 * scale),
            if (room.hasBoundedHeight)
              Expanded(child: plot)
            else
              SizedBox(height: 144 * scale, child: plot),
            SizedBox(height: 8 * scale),
            UsageLegend(traffic: traffic, direction: Axis.horizontal),
          ],
        );
      },
    );
  }
}
