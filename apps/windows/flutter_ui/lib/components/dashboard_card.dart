// Adapted from FlClash v0.9.3, licensed under GPLv3. See vendor/UPSTREAM.md.
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart';
import 'package:prism_ui/shapes/shapes.dart';

import 'app_glyphs.dart';
import 'dashboard_layout.dart';
import 'dashboard_style.dart';

EdgeInsets dashboardCardPadding(DashboardDensity density) => switch (density) {
  DashboardDensity.standard => const EdgeInsets.symmetric(
    horizontal: 22,
    vertical: 20,
  ),
  DashboardDensity.compact => const EdgeInsets.symmetric(
    horizontal: 20,
    vertical: 16,
  ),
  DashboardDensity.mobile => const EdgeInsets.symmetric(
    horizontal: 20,
    vertical: 18,
  ),
};

double dashboardCardRadius(DashboardDensity density) => density.isDesktop
    ? DashboardCorner.desktopCard
    : DashboardCorner.mobileCard;

class DashboardCard extends StatelessWidget {
  const DashboardCard({
    super.key,
    this.padding,
    this.onTap,
    this.semanticLabel,
    this.clipBehavior = Clip.none,
    this.side = BorderSide.none,
    required this.child,
  });

  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;
  final String? semanticLabel;

  /// Drawn over the content, which may bleed to the card's edge.
  final BorderSide side;

  /// Off by default so a control swelling under an [ElasticPress] can paint
  /// past the card's edge; only a card whose own content bleeds clips.
  final Clip clipBehavior;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final density = DashboardDensityScope.of(context);
    final shape = AppShape.all(dashboardCardRadius(density));
    final content = Padding(
      padding: padding ?? dashboardCardPadding(density),
      child: child,
    );
    final onTap = this.onTap;
    final card = Container(
      clipBehavior: clipBehavior,
      decoration: ShapeDecoration(
        color: DashboardColors.of(context).card,
        shape: shape,
        shadows: DashboardShadows.e1(context),
      ),
      foregroundDecoration: side == BorderSide.none
          ? null
          : ShapeDecoration(shape: shape.copyWith(side: side)),
      child: onTap == null
          ? content
          : PressSurface(
              fill: Colors.transparent,
              shape: shape,
              onPressed: onTap,
              childFills: true,
              child: Semantics(label: semanticLabel, child: content),
            ),
    );
    if (onTap != null) {
      return card;
    }
    return Semantics(container: true, label: semanticLabel, child: card);
  }
}

class DashboardCardHeader extends StatelessWidget {
  const DashboardCardHeader({
    super.key,
    this.glyph,
    required this.title,
    this.leading = const [],
    this.trailing = const [],
    this.chevron = false,
  });

  static const height = 24.0;
  static const glyphSize = 18.0;

  final Glyph? glyph;
  final String title;

  /// Sits right after the title, before the space that pushes [trailing] out.
  final List<Widget> leading;
  final List<Widget> trailing;
  final bool chevron;

  @override
  Widget build(BuildContext context) {
    final mobile = !DashboardDensityScope.of(context).isDesktop;
    final scale = DashboardDensityScope.scaleOf(context);
    final colorScheme = context.colorScheme;
    final iconColor = colorScheme.onSurfaceVariant;
    final style = mobile
        ? DashboardText.mobileCardTitle(context)
        : DashboardText.cardTitle(context);
    final end = [
      ...trailing,
      if (chevron)
        GlyphIcon(
          AppGlyphs.chevronForward,
          size: 18,
          color: colorScheme.onSurfaceVariant,
        ),
    ];
    final start = Row(
      spacing: 8,
      children: [
        Flexible(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
        ...leading,
      ],
    );
    return SizedBox(
      height: (mobile ? 26 : height) * scale,
      child: Row(
        spacing: 8,
        children: [
          if (glyph case final glyph?)
            GlyphIcon(glyph, size: glyphSize, color: iconColor),
          Expanded(
            child: end.isEmpty
                ? start
                : DashboardCappedRow(
                    start: start,
                    end: Row(
                      mainAxisSize: MainAxisSize.min,
                      spacing: 8,
                      children: end,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Lays [end] out first at its own width, up to [share] of the row and scaled
/// down past that, so long translations or large text never overflow; [start]
/// takes what is left.
class DashboardCappedRow extends StatelessWidget {
  const DashboardCappedRow({
    super.key,
    required this.start,
    required this.end,
    this.share = 0.5,
    this.spacing = 8,
  });

  final Widget start;
  final Widget end;
  final double share;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => Row(
        spacing: spacing,
        children: [
          Expanded(child: start),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: math.max(0, constraints.maxWidth - spacing) * share,
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerEnd,
              child: SizedBox(
                height: constraints.hasBoundedHeight
                    ? constraints.maxHeight
                    : null,
                child: end,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

const _connectedSelectDuration = Duration(milliseconds: 240);

/// A row of [DashboardConnectedButton]s; the one pressed last paints on top.
class DashboardConnectedGroup extends StatelessWidget {
  const DashboardConnectedGroup({
    super.key,
    this.crossAxisAlignment = CrossAxisAlignment.center,
    required this.children,
  });

  final CrossAxisAlignment crossAxisAlignment;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return _RaisedRow(
      crossAxisAlignment: crossAxisAlignment,
      spacing: 3,
      children: children,
    );
  }
}

class _RaisedRow extends Flex {
  const _RaisedRow({
    super.crossAxisAlignment,
    super.spacing,
    required super.children,
  }) : super(direction: Axis.horizontal);

  @override
  RenderFlex createRenderObject(BuildContext context) {
    return _RenderRaisedRow(
      direction: direction,
      mainAxisAlignment: mainAxisAlignment,
      mainAxisSize: mainAxisSize,
      crossAxisAlignment: crossAxisAlignment,
      textDirection: getEffectiveTextDirection(context),
      verticalDirection: verticalDirection,
      textBaseline: textBaseline,
      clipBehavior: clipBehavior,
      spacing: spacing,
    );
  }
}

class _RenderRaisedRow extends RenderFlex {
  _RenderRaisedRow({
    super.direction,
    super.mainAxisAlignment,
    super.mainAxisSize,
    super.crossAxisAlignment,
    super.textDirection,
    super.verticalDirection,
    super.textBaseline,
    super.clipBehavior,
    super.spacing,
  });

  RenderBox? _raised;

  @override
  void handleEvent(PointerEvent event, BoxHitTestEntry entry) {
    if (event is! PointerDownEvent) {
      return;
    }
    for (var child = firstChild; child != null; child = childAfter(child)) {
      final offset = (child.parentData! as FlexParentData).offset;
      if ((offset & child.size).contains(entry.localPosition)) {
        if (child != _raised) {
          _raised = child;
          markNeedsPaint();
        }
        return;
      }
    }
  }

  @override
  void dropChild(RenderObject child) {
    if (child == _raised) {
      _raised = null;
    }
    super.dropChild(child);
  }

  @override
  void defaultPaint(PaintingContext context, Offset offset) {
    void paint(RenderBox child) => context.paintChild(
      child,
      (child.parentData! as FlexParentData).offset + offset,
    );
    for (var child = firstChild; child != null; child = childAfter(child)) {
      if (child != _raised) {
        paint(child);
      }
    }
    if (_raised case final raised?) {
      paint(raised);
    }
  }
}

/// M3 Expressive connected buttons: the ends round off the group, the inner
/// corners stay tight, and the selected one turns into a full pill. Each one
/// swells under a press.
class DashboardConnectedButton extends StatelessWidget {
  const DashboardConnectedButton({
    super.key,
    required this.selected,
    required this.first,
    required this.last,
    required this.outer,
    required this.inner,
    required this.background,
    required this.onTap,
    required this.semanticLabel,
    required this.builder,
  });

  final bool selected;
  final bool first;
  final bool last;
  final double outer;
  final double inner;
  final Color background;
  final VoidCallback? onTap;
  final String semanticLabel;
  final Widget Function(Color foreground) builder;

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final startRest = first ? outer : inner;
    final endRest = last ? outer : inner;
    final colorScheme = context.colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      enabled: onTap != null,
      inMutuallyExclusiveGroup: true,
      onTap: onTap,
      label: selected ? '$semanticLabel，已选中' : semanticLabel,
      excludeSemantics: true,
      child: ElasticPress(
        enabled: onTap != null && !context.disableAnimations,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: selected ? 1 : 0),
          duration: context.motionDuration(_connectedSelectDuration),
          curve: Curves.easeOutCubic,
          builder: (context, amount, child) {
            final start = lerpDouble(startRest, outer, amount)!;
            final end = lerpDouble(endRest, outer, amount)!;
            final shape = AppShape.of(
              BorderRadius.horizontal(
                left: Radius.circular(rtl ? end : start),
                right: Radius.circular(rtl ? start : end),
              ),
            );
            return FocusRing(
              shape: shape,
              standsOff: selected,
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: ShapeDecoration(
                  color: Color.lerp(background, colorScheme.primary, amount),
                  shape: shape,
                ),
                child: PressRegion(
                  shape: shape,
                  overlay: PressRegion.hoverOverlay,
                  onTap: onTap,
                  child: child!,
                ),
              ),
            );
          },
          child: builder(
            selected ? colorScheme.onPrimary : colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

enum DashboardChipTone { idle, ok, warn }

class DashboardChip extends StatelessWidget {
  const DashboardChip({
    super.key,
    required this.label,
    this.tone = DashboardChipTone.idle,
    this.dot = false,
    this.large = false,
  });

  final String label;
  final DashboardChipTone tone;
  final bool dot;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final colors = DashboardColors.of(context);
    final (background, foreground) = switch (tone) {
      DashboardChipTone.idle => (colors.tone, colorScheme.onSurfaceVariant),
      DashboardChipTone.ok => (colors.okContainer, colors.onOkContainer),
      DashboardChipTone.warn => (colors.warnContainer, colors.onWarnContainer),
    };
    return Container(
      height: large ? 28 : 24,
      padding: EdgeInsets.symmetric(horizontal: large ? 12 : 10),
      decoration: ShapeDecoration(color: background, shape: AppShape.full),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 6,
        children: [
          if (dot)
            DecoratedBox(
              decoration: ShapeDecoration(
                color: foreground,
                shape: AppShape.circle,
              ),
              child: const SizedBox.square(dimension: 6),
            ),
          Text(
            label,
            maxLines: 1,
            style: AppTextStyle.caption1
                .of(context, emphasized: true)
                .toTabular
                .copyWith(color: foreground),
          ),
        ],
      ),
    );
  }
}

/// A block inside a card, one tone off the card itself.
class DashboardBlock extends StatelessWidget {
  const DashboardBlock({
    super.key,
    required this.radius,
    this.color,
    this.padding = EdgeInsets.zero,
    this.onTap,
    this.semanticLabel,
    required this.child,
  });

  final double radius;
  final Color? color;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final String? semanticLabel;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final shape = AppShape.all(radius);
    final content = Padding(padding: padding, child: child);
    final fill = color ?? DashboardColors.of(context).tone;
    final onTap = this.onTap;
    if (onTap == null) {
      return DecoratedBox(
        decoration: ShapeDecoration(color: fill, shape: shape),
        child: content,
      );
    }
    return PressSurface(
      fill: fill,
      shape: shape,
      onPressed: onTap,
      childFills: true,
      child: Semantics(label: semanticLabel, child: content),
    );
  }
}

/// An M3 Expressive shape, filled, with [child] centered on it.
class ShapeBadge extends StatelessWidget {
  const ShapeBadge({
    super.key,
    required this.shape,
    required this.color,
    required this.size,
    this.rotation = 0,
    this.ring,
    this.child,
  });

  final RoundedPolygon shape;
  final Color color;
  final double size;

  /// Turns the shape alone, leaving [child] upright.
  final double rotation;
  final BorderSide? ring;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: ShapePainter(
        path: shapePathOf(shape),
        color: color,
        rotation: rotation,
        ring: ring,
      ),
      child: SizedBox.square(
        dimension: size,
        child: child == null ? null : Center(child: child),
      ),
    );
  }
}

final _shapePaths = Expando<Path>();

Path shapePathOf(RoundedPolygon shape) => _shapePaths[shape] ??= shape.toPath();

/// Paints a path laid out in the unit square, the space [MaterialShapes]
/// are normalized to.
class ShapePainter extends CustomPainter {
  const ShapePainter({
    required this.path,
    required this.color,
    this.rotation = 0,
    this.ring,
  });

  final Path path;
  final Color color;
  final double rotation;
  final BorderSide? ring;

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..save()
      ..translate(size.width / 2, size.height / 2)
      ..rotate(rotation)
      ..scale(size.width, size.height)
      ..translate(-0.5, -0.5)
      ..drawPath(path, Paint()..color = color);
    if (ring case final ring?) {
      strokeUnitShape(canvas, path, size.width, ring);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(ShapePainter oldDelegate) =>
      oldDelegate.path != path ||
      oldDelegate.color != color ||
      oldDelegate.rotation != rotation ||
      oldDelegate.ring != ring;
}

/// Strokes [side] along a unit-square [path] drawn at [extent], placing it by
/// [BorderSide.strokeAlign] with a scale about the center rather than an offset.
void strokeUnitShape(Canvas canvas, Path path, double extent, BorderSide side) {
  final scale = 1 + side.width * side.strokeAlign / extent;
  canvas
    ..save()
    ..translate(0.5, 0.5)
    ..scale(scale)
    ..translate(-0.5, -0.5)
    ..drawPath(path, side.toPaint()..strokeWidth = side.width / extent / scale)
    ..restore();
}
