// Adapted from FlClash v0.9.3, licensed under GPLv3. See vendor/UPSTREAM.md.
import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart';

import 'app_glyphs.dart';
import 'dashboard_card.dart';
import 'dashboard_layout.dart';
import 'dashboard_style.dart';

const _chartBleed = 3.0;

(String, String) _rate(double bytes) {
  if (bytes < 1000) return (bytes.round().toString(), 'B/s');
  if (bytes < 1000000) return ((bytes / 1000).toStringAsFixed(1), 'KB/s');
  if (bytes < 1000000000) return ((bytes / 1000000).toStringAsFixed(1), 'MB/s');
  return ((bytes / 1000000000).toStringAsFixed(1), 'GB/s');
}

class _Figure extends StatelessWidget {
  const _Figure({
    required this.value,
    required this.unit,
    required this.style,
    required this.unitStyle,
  });

  final String value;
  final String unit;
  final AppTextStyle style;
  final AppTextStyle unitStyle;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: value, style: DashboardText.figure(context, style)),
          TextSpan(
            text: ' $unit',
            style: DashboardText.unit(context, unitStyle),
          ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.clip,
    );
  }
}

/// Desktop upload or download card. Empty samples mean that no speed was measured.
class SpeedCard extends StatelessWidget {
  const SpeedCard({
    super.key,
    required this.upload,
    required this.samples,
    required this.total,
    this.revision,
    this.capacity = 36,
  }) : assert(capacity > 1);

  final bool upload;
  final List<double> samples;
  final String total;
  final int? revision;
  final int capacity;

  @override
  Widget build(BuildContext context) {
    final density = DashboardDensityScope.of(context);
    final compact = density.isCompact;
    final scale = DashboardDensityScope.scaleOf(context);
    final padding = dashboardCardPadding(density);
    final label = upload ? '上传' : '下载';
    final color = upload
        ? DashboardColors.of(context).series2
        : context.colorScheme.primary;
    final peak = samples.fold<double>(0, (a, b) => a > b ? a : b);
    final (peakValue, peakUnit) = _rate(peak);
    final peakText = samples.isEmpty ? '峰值 —' : '峰值 $peakValue $peakUnit';
    final (value, unit) = samples.isEmpty ? ('—', '') : _rate(samples.last);
    final description = samples.isEmpty
        ? '暂无采样，$total'
        : '$value $unit，$peakText，$total';
    // macOS exposes passive text through AXValue using its label.
    return Semantics(
      container: true,
      excludeSemantics: true,
      label: '${label}速度，$description',
      child: DashboardCard(
        padding: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Positioned(
              left: -_chartBleed,
              right: -_chartBleed,
              bottom: -_chartBleed,
              height: compact ? 62 : 88,
              child: RepaintBoundary(
                child: samples.isEmpty
                    ? Stack(
                        children: [
                          Positioned(
                            left: 3,
                            right: 3,
                            bottom: 17,
                            child: Container(
                              height: 1,
                              color: color.withValues(alpha: .26),
                            ),
                          ),
                        ],
                      )
                    : LineChart(
                        key: revision == null
                            ? ValueKey(Object.hashAll(samples))
                            : null,
                        values: samples,
                        revision: revision ?? samples.length,
                        capacity: capacity,
                        minScale: 8 * 1024,
                        color: color,
                        baselineRatio: 1,
                      ),
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
                          upload ? AppGlyphs.arrowUp : AppGlyphs.arrowDown,
                          size: 18,
                          color: upload
                              ? context.colorScheme.onSurfaceVariant
                              : context.colorScheme.primary,
                        ),
                        Text(
                          label,
                          maxLines: 1,
                          style: DashboardText.cardTitle(context),
                        ),
                        Expanded(
                          child: Text(
                            peakText,
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
                    value: value,
                    unit: unit,
                    style: compact
                        ? AppTextStyle.largeTitle
                        : AppTextStyle.display,
                    unitStyle: AppTextStyle.subheadline,
                  ),
                  const SizedBox(height: 2),
                  Text(total, maxLines: 1, style: DashboardText.label(context)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
