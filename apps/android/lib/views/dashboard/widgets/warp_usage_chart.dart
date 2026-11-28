import 'dart:math' as math;

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart' show NumberFormat;

import '../style.dart';
import 'card.dart';
import 'traffic.dart';

Color usageUploadColor(BuildContext context) =>
    TrafficDirection.upload.colorOf(context);

Color usageDownloadColor(BuildContext context) =>
    TrafficDirection.download.colorOf(context);

class UsageRing extends StatelessWidget {
  const UsageRing({
    super.key,
    required this.traffic,
    required this.size,
    this.center,
  });

  final Traffic? traffic;
  final double size;
  final Widget? center;

  @override
  Widget build(BuildContext context) {
    final sample = traffic;
    final total = sample?.speed ?? 0;
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _SplitRingPainter(
          uploadFraction: total > 0
              ? (sample!.up / total).clamp(0.0, 1.0)
              : null,
          upload: usageUploadColor(context),
          download: usageDownloadColor(context),
          track: DashboardColors.of(context).track,
        ),
        child: center == null
            ? null
            : Center(
                child: FractionallySizedBox(
                  widthFactor: 0.70,
                  heightFactor: 0.64,
                  child: Center(child: center),
                ),
              ),
      ),
    );
  }
}

class _SplitRingPainter extends CustomPainter {
  const _SplitRingPainter({
    required this.uploadFraction,
    required this.upload,
    required this.download,
    required this.track,
  });

  final double? uploadFraction;
  final Color upload;
  final Color download;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide;
    if (side <= 0) return;
    final stroke = side * 0.092;
    final radius = (side - stroke) / 2;
    final center = size.center(Offset.zero);
    final rect = Rect.fromCircle(center: center, radius: radius);
    final brush = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    final fraction = uploadFraction;
    if (fraction == null || fraction == 0 || fraction == 1) {
      canvas.drawOval(
        rect,
        brush
          ..color = fraction == null
              ? track
              : fraction == 0
              ? download
              : upload,
      );
      return;
    }

    const turn = 2 * math.pi;
    const top = -math.pi / 2;
    final split = turn * fraction;
    final gap = math.min(4 / radius, math.min(split, turn - split) * 0.2);
    final capAngle = math.asin(stroke / (2 * radius));

    void drawPart(double start, double angle, Color color) {
      final visible = angle - gap;
      if (visible <= 2 * capAngle) {
        // A full-width round cap would overstate a tiny nonzero transfer.
        final midpoint = start + angle / 2;
        final position = center + Offset.fromDirection(midpoint, radius);
        canvas.drawCircle(
          position,
          radius * math.sin(visible / 2),
          Paint()..color = color,
        );
        return;
      }
      canvas.drawArc(
        rect,
        start + gap / 2 + capAngle,
        visible - 2 * capAngle,
        false,
        brush..color = color,
      );
    }

    drawPart(top, split, upload);
    drawPart(top + split, turn - split, download);
  }

  @override
  bool shouldRepaint(_SplitRingPainter oldDelegate) =>
      uploadFraction != oldDelegate.uploadFraction ||
      upload != oldDelegate.upload ||
      download != oldDelegate.download ||
      track != oldDelegate.track;
}

class UsageLegend extends StatelessWidget {
  const UsageLegend({
    super.key,
    required this.traffic,
    this.direction = Axis.vertical,
  });

  final Traffic? traffic;
  final Axis direction;

  @override
  Widget build(BuildContext context) {
    final percent = NumberFormat.percentPattern(
      Localizations.localeOf(context).toString(),
    );
    final data = traffic;
    final total = data?.speed ?? 0;
    final entries = <Widget>[];
    for (final series in TrafficDirection.values) {
      final amount = data == null ? null : series.of(data);
      final value = amount == null ? '—' : dashboardTraffic(amount);
      final fraction = total > 0 ? amount! / total : null;
      final share = switch (fraction) {
        null => null,
        > 0 && < 0.01 => '<${percent.format(0.01)}',
        > 0.99 && < 1 => '>${percent.format(0.99)}',
        _ => percent.format(fraction),
      };
      final label = series.labelOf(context);
      entries.add(
        Semantics(
          label: [
            label,
            amount == null ? context.appLocalizations.noData : value,
            ?share,
          ].join(', '),
          excludeSemantics: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                spacing: 5,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: series.colorOf(context),
                      shape: BoxShape.circle,
                    ),
                    child: const SizedBox.square(dimension: 7),
                  ),
                  Flexible(
                    child: Text(
                      [label, ?share].join('  '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: DashboardText.label(context),
                    ),
                  ),
                ],
              ),
              DashboardFitText(
                value,
                style: DashboardText.figure(context, AppTextStyle.headline),
              ),
            ],
          ),
        ),
      );
    }
    return direction == Axis.horizontal
        ? Row(
            spacing: 10,
            children: [for (final entry in entries) Expanded(child: entry)],
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12,
            children: entries,
          );
  }
}
