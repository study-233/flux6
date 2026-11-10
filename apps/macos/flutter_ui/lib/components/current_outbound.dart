// Adapted from FlClash v0.9.3, licensed under GPLv3. See vendor/UPSTREAM.md.
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart';
import 'package:prism_ui/shapes/shapes.dart';

import 'app_glyphs.dart';
import 'dashboard_card.dart';
import 'dashboard_layout.dart';
import 'dashboard_style.dart';

const _decorationGrowth = 0.12;

const _decorationTurn = 2 * math.pi / 12;

class CurrentOutboundCard extends StatelessWidget {
  const CurrentOutboundCard({
    super.key,
    required this.running,
    this.busy = false,
    this.phaseLabel,
    this.actionLabel,
    required this.node,
    required this.mode,
    required this.runtime,
    required this.onToggle,
  });

  final bool running;
  final bool busy;
  final String? phaseLabel, actionLabel;
  final String node;
  final String mode;
  final String runtime;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final density = DashboardDensityScope.of(context);
    final metrics = _OutboundMetrics.of(density);
    final colorScheme = context.colorScheme;
    final colors = DashboardColors.of(context);
    final state =
        phaseLabel ??
        (busy ? (running ? '正在断开' : '正在连接') : (running ? '已连接' : '未连接'));
    return DashboardCard(
      padding: EdgeInsets.zero,
      semanticLabel: '连接状态',
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipPath(
              clipper: ShapeBorderClipper(
                shape: AppShape.all(dashboardCardRadius(density)),
                textDirection: Directionality.of(context),
              ),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  PositionedDirectional(
                    end: metrics.decorationEnd,
                    top: metrics.decorationTop,
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(end: running ? 1 : 0),
                      duration: context.motionDuration(_morphDuration),
                      curve: Curves.easeOutBack,
                      builder: (_, progress, _) => Transform.rotate(
                        angle: _decorationTurn * progress,
                        child: Transform.scale(
                          scale: 1 + _decorationGrowth * progress,
                          child: ShapeBadge(
                            shape: MaterialShapes.cookie12Sided,
                            color: Color.lerp(
                              colors.tone,
                              Color.alphaBlend(
                                colorScheme.primary.withValues(alpha: 0.1),
                                colors.card,
                              ),
                              progress.clamp(0, 1),
                            )!,
                            size: metrics.decorationSize,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: metrics.padding,
            child: Row(
              spacing: metrics.gap,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      DashboardCardHeader(
                        glyph: AppGlyphs.status,
                        title: '连接状态',
                        leading: [
                          DashboardChip(
                            label: state,
                            tone: busy
                                ? DashboardChipTone.warn
                                : running
                                ? DashboardChipTone.ok
                                : DashboardChipTone.idle,
                            dot: running,
                          ),
                        ],
                      ),
                      SizedBox(height: metrics.ipTop),
                      Row(
                        children: [
                          ShapeBadge(
                            shape: MaterialShapes.clover4Leaf,
                            size: metrics.badgeSize,
                            color: colors.tone2,
                            child: GlyphIcon(
                              AppGlyphs.proxies,
                              size: metrics.badgeSize * .5,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  node,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: DashboardText.figure(
                                    context,
                                    metrics.ip,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  running ? '当前接入节点' : '下次连接使用',
                                  style: DashboardText.label(context),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (density.isDesktop)
                        const Spacer()
                      else
                        const SizedBox(height: 16),
                      Row(
                        spacing: metrics.cellGap,
                        children: [
                          Flexible(
                            child: _Cell(
                              label: '运行时间',
                              value: _CellText(running ? runtime : '—'),
                            ),
                          ),
                          Flexible(
                            child: _Cell(label: '工作模式', value: _CellText(mode)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: metrics.buttonSlot,
                  child: Center(
                    child: _StartToggle(
                      size: metrics.buttonSize,
                      enabled: !busy,
                      actionLabel: actionLabel,
                      running: running,
                      onToggle: onToggle,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _OutboundMetrics {
  const _OutboundMetrics({
    required this.padding,
    required this.gap,
    required this.ipTop,
    required this.cellGap,
    required this.badgeSize,
    required this.ip,
    required this.buttonSize,
    required this.buttonSlot,
    required this.decorationSize,
    required this.decorationEnd,
    required this.decorationTop,
  });

  factory _OutboundMetrics.of(DashboardDensity density) => switch (density) {
    DashboardDensity.standard => _OutboundMetrics(
      padding: dashboardCardPadding(density),
      gap: 16,
      ipTop: 10,
      cellGap: 28,
      badgeSize: 48,
      ip: AppTextStyle.title1,
      buttonSize: 104,
      buttonSlot: 120,
      decorationSize: 290,
      decorationEnd: -64,
      decorationTop: -87,
    ),
    DashboardDensity.compact => _OutboundMetrics(
      padding: dashboardCardPadding(density),
      gap: 16,
      ipTop: 8,
      cellGap: 22,
      badgeSize: 40,
      ip: AppTextStyle.title2,
      buttonSize: 84,
      buttonSlot: 100,
      decorationSize: 250,
      decorationEnd: -64,
      decorationTop: -75,
    ),
    DashboardDensity.mobile => const _OutboundMetrics(
      padding: EdgeInsetsDirectional.fromSTEB(20, 18, 16, 18),
      gap: 10,
      ipTop: 12,
      cellGap: 24,
      badgeSize: 48,
      ip: AppTextStyle.title2,
      buttonSize: 88,
      buttonSlot: 88,
      decorationSize: 240,
      decorationEnd: -60,
      decorationTop: -66,
    ),
  };

  final EdgeInsetsGeometry padding;
  final double gap;
  final double ipTop;
  final double cellGap;
  final double badgeSize;
  final AppTextStyle ip;
  final double buttonSize;
  final double buttonSlot;
  final double decorationSize;
  final double decorationEnd;
  final double decorationTop;
}

class _Cell extends StatelessWidget {
  const _Cell({required this.label, required this.value});

  final String label;
  final Widget value;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: DashboardText.label(context),
        ),
        const SizedBox(height: 2),
        value,
      ],
    );
  }
}

TextStyle _cellStyle(BuildContext context) =>
    AppTextStyle.subheadline.of(context, emphasized: true).toTabular;

class _CellText extends StatelessWidget {
  const _CellText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: _cellStyle(context),
    );
  }
}

const _morphDuration = Duration(milliseconds: 450);
const _stateDuration = Duration(milliseconds: 150);

final _startMorph = Morph(MaterialShapes.circle, MaterialShapes.cookie9Sided);

Path _morphPath(double progress) => _startMorph.toPath(progress: progress);

double _morphTurn(double progress) => progress * 2 * math.pi / 9;

/// A circle with a play glyph while stopped that grows the cookie-9 of a
/// running tunnel, the way the M3 Expressive loader morphs between shapes.
class _StartToggle extends StatefulWidget {
  const _StartToggle({
    this.actionLabel,
    required this.size,
    required this.enabled,
    required this.running,
    required this.onToggle,
  });

  final double size;
  final String? actionLabel;
  final bool enabled;
  final bool running;
  final VoidCallback onToggle;

  @override
  State<_StartToggle> createState() => _StartToggleState();
}

class _StartToggleState extends State<_StartToggle>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _morphDuration,
    value: widget.running ? 1 : 0,
  );
  late final CurvedAnimation _progress = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutBack,
    reverseCurve: Curves.easeInCubic,
  );
  var _hovered = false;
  var _pressed = false;
  var _focused = false;

  /// The M3 state layer, painted inside the shape: the card's decoration
  /// covers the button, so ink on the card would never show.
  double get _overlay => !widget.enabled
      ? 0
      : _pressed
      ? 0.12
      : _focused
      ? 0.1
      : _hovered
      ? 0.08
      : 0;

  @override
  void didUpdateWidget(_StartToggle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.running != widget.running) {
      if (context.disableAnimations) {
        _controller.value = widget.running ? 1 : 0;
      } else {
        widget.running ? _controller.forward() : _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _progress.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _toggle() {
    widget.onToggle();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final glass = LiquidGlassScope.of(context);
    final size = widget.size;
    final enabled = widget.enabled;
    final fill = enabled
        ? colorScheme.primary
        : DashboardColors.of(context).tone2;
    final ink = enabled ? colorScheme.onPrimary : colorScheme.onSurfaceVariant;
    final tooltip = widget.actionLabel ?? (widget.running ? '断开连接' : '连接');
    final stateDuration = context.motionDuration(_stateDuration);
    return Tooltip(
      message: tooltip,
      excludeFromSemantics: true,
      child: Semantics(
        container: true,
        button: true,
        enabled: enabled,
        label: tooltip,
        onTap: enabled ? _toggle : null,
        child: PressRegion(
          onTap: enabled ? _toggle : null,
          onHover: (value) => setState(() => _hovered = value),
          onPressedChanged: (value) => setState(() => _pressed = value),
          onFocusChange: (value) => setState(() => _focused = value),
          child: ElasticPress(
            enabled: enabled && !context.disableAnimations,
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: _overlay),
              duration: stateDuration,
              builder: (_, overlay, child) => AnimatedBuilder(
                animation: _progress,
                builder: (_, child) {
                  final progress = _progress.value;
                  final color = Color.alphaBlend(
                    ink.withValues(alpha: overlay),
                    fill,
                  );
                  return CustomPaint(
                    painter: _MorphPainter(
                      progress: progress,
                      color: glass ? null : color,
                      shadow: enabled
                          ? colorScheme.primary.withValues(alpha: 0.3)
                          : Colors.transparent,
                      ring: _focused
                          ? focusRingSide(colorScheme, standsOff: true)
                          : null,
                    ),
                    child: glass
                        ? LiquidGlass(
                            style: LiquidGlassStyle.tinted(colorScheme, color),
                            clipper: _MorphClipper(progress),
                            pressed: _pressed,
                            child: child,
                          )
                        : child,
                  );
                },
                child: child,
              ),
              child: SizedBox.square(
                dimension: size,
                child: Center(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(end: widget.running ? 1 : 0),
                    duration: context.motionDuration(_morphDuration),
                    curve: Curves.easeOutBack,
                    builder: (_, progress, _) => GlyphIcon(
                      AppGlyphs.playPause(progress),
                      size: size * 0.34,
                      color: ink,
                      fill: 1,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Fills the morph, or with no [color] leaves its inside to glass and casts
/// [shadow] only outside it, as one under glass would show through.
class _MorphPainter extends CustomPainter {
  const _MorphPainter({
    required this.progress,
    required this.color,
    required this.shadow,
    required this.ring,
  });

  static const _shadowOffset = Offset(0, 6);
  static const _shadowBlur = 14.0;

  final double progress;
  final Color? color;
  final Color shadow;
  final BorderSide? ring;

  @override
  void paint(Canvas canvas, Size size) {
    final path = _morphPath(progress);
    final color = this.color;
    canvas
      ..save()
      ..translate(size.width / 2, size.height / 2)
      ..rotate(_morphTurn(progress))
      ..scale(size.width, size.height)
      ..translate(-0.5, -0.5);
    if (shadow.a > 0) {
      canvas.save();
      if (color == null) {
        canvas.clipPath(
          Path()
            ..fillType = PathFillType.evenOdd
            ..addRect(const Rect.fromLTRB(-1, -1, 2, 2))
            ..addPath(path, Offset.zero),
        );
      }
      canvas
        ..translate(
          _shadowOffset.dx / size.width,
          _shadowOffset.dy / size.height,
        )
        ..drawPath(
          path,
          Paint()
            ..color = shadow
            ..maskFilter = MaskFilter.blur(
              BlurStyle.normal,
              _shadowBlur / 2 / size.width,
            ),
        )
        ..restore();
    }
    if (color != null) {
      canvas.drawPath(path, Paint()..color = color);
    }
    if (ring case final ring?) {
      strokeUnitShape(canvas, path, size.width, ring);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MorphPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.color != color ||
      oldDelegate.shadow != shadow ||
      oldDelegate.ring != ring;
}

class _MorphClipper extends CustomClipper<Path> {
  const _MorphClipper(this.progress);

  final double progress;

  @override
  Path getClip(Size size) {
    final transform =
        Matrix4.translationValues(size.width / 2, size.height / 2, 0)
          ..rotateZ(_morphTurn(progress))
          ..scaleByDouble(size.width, size.height, 1, 1)
          ..translateByDouble(-0.5, -0.5, 0, 1);
    return _morphPath(progress).transform(transform.storage);
  }

  @override
  bool shouldReclip(_MorphClipper oldClipper) =>
      oldClipper.progress != progress;
}
