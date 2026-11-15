import 'dart:math' as math;

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/views/dashboard/style.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';

class NetworkSpeedChart extends StatelessWidget {
  const NetworkSpeedChart({
    super.key,
    required this.window,
    required this.minimumScale,
    required this.uploadColor,
    required this.downloadColor,
  });

  final FixedList<Traffic> window;
  final double minimumScale;
  final Color uploadColor;
  final Color downloadColor;

  @override
  Widget build(BuildContext context) {
    final samples = window.list;
    final peak = samples.fold<num>(
      0,
      (peak, sample) => math.max(peak, math.max(sample.up, sample.down)),
    );
    // Keep the scale steady as speeds fluctuate within the same power of two.
    final upper = math.max(minimumScale, peak).ceil();
    final limit = math.pow(2, (upper - 1).bitLength).toDouble();
    final labelStyle = DashboardText.label(context);
    return Semantics(
      excludeSemantics: true,
      label: samples.isEmpty
          ? null
          : context.appLocalizations.trafficPeak('${dashboardTraffic(peak)}/s'),
      child: SizedBox(
        height: math.max(64, MediaQuery.textScalerOf(context).scale(40)),
        child: Row(
          spacing: 8,
          children: [
            Expanded(
              child: RepaintBoundary(
                child: CustomPaint(
                  size: Size.infinite,
                  painter: _TrendPainter(
                    samples: samples,
                    capacity: window.maxLength,
                    limit: limit,
                    upload: uploadColor,
                    download: downloadColor,
                    grid: Divider.colorOf(context),
                  ),
                ),
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('${dashboardTraffic(limit)}/s', style: labelStyle),
                Text('0', style: labelStyle),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  const _TrendPainter({
    required this.samples,
    required this.capacity,
    required this.limit,
    required this.upload,
    required this.download,
    required this.grid,
  });

  final List<Traffic> samples;
  final int capacity;
  final double limit;
  final Color upload;
  final Color download;
  final Color grid;

  @override
  void paint(Canvas canvas, Size size) {
    const inset = 3.0;
    final bottom = size.height - inset;
    final height = bottom - inset;
    final right = size.width - inset;
    if (right <= inset || height <= 0) return;
    final gridPaint = Paint()..color = grid;
    for (final y in [inset, inset + height / 2, bottom]) {
      canvas.drawLine(Offset(inset, y), Offset(right, y), gridPaint);
    }
    if (samples.isEmpty) return;

    final step = (right - inset) / math.max(1, capacity - 1);
    final first = right - (samples.length - 1) * step;
    final up = Path();
    final down = Path();
    double y(num speed) => bottom - height * (speed / limit);
    for (var i = 0; i < samples.length; i++) {
      final x = first + i * step;
      final sample = samples[i];
      if (i == 0) {
        up.moveTo(x, y(sample.up));
        down.moveTo(x, y(sample.down));
      } else {
        up.lineTo(x, y(sample.up));
        down.lineTo(x, y(sample.down));
      }
    }
    final area = Path.from(down)
      ..lineTo(right, bottom)
      ..lineTo(first, bottom)
      ..close();
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            download.withValues(alpha: 0.18),
            download.withValues(alpha: 0.02),
          ],
        ).createShader(Offset.zero & size),
    );

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2
      ..color = download;
    canvas.drawPath(down, stroke);
    final dashes = Path();
    for (final metric in up.computeMetrics()) {
      for (double offset = 0; offset < metric.length; offset += 8) {
        dashes.addPath(metric.extractPath(offset, offset + 4), Offset.zero);
      }
    }
    canvas.drawPath(dashes, stroke..color = upload);
    canvas.drawCircle(
      Offset(right, y(samples.last.down)),
      inset,
      Paint()..color = download,
    );
    canvas.drawCircle(
      Offset(right, y(samples.last.up)),
      inset - 1,
      Paint()..color = upload,
    );
  }

  @override
  bool shouldRepaint(_TrendPainter old) =>
      samples != old.samples ||
      capacity != old.capacity ||
      limit != old.limit ||
      upload != old.upload ||
      download != old.download ||
      grid != old.grid;
}
