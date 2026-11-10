// Adapted from FlClash v0.9.3, licensed under GPLv3. See vendor/UPSTREAM.md.
import 'package:flutter/widgets.dart';
import 'package:prism_ui/icons/icons.dart';
import 'package:prism_ui/prism_ui.dart';

import 'app_glyphs.dart';
import 'dashboard_card.dart';
import 'dashboard_layout.dart';
import 'dashboard_style.dart';

/// The desktop control row's mode switch; its buttons sit as far in from the
/// card's ends as from its edges so their corners stay concentric.
class OutboundModeBar extends StatelessWidget {
  const OutboundModeBar({
    super.key,
    required this.selected,
    required this.onChanged,
  }) : assert(selected >= -1 && selected < 3);

  final int selected;
  final ValueChanged<int>? onChanged;

  static const _items = [
    (AppGlyphs.rules, '规则'),
    (AppGlyphs.proxies, '全局'),
    (AppGlyphs.target, '直连'),
  ];

  static const _inset = 8.0;

  @override
  Widget build(BuildContext context) {
    final density = DashboardDensityScope.of(context);
    final outer = dashboardCardRadius(density) - _inset;
    final style = AppTextStyle.subheadline.of(context, emphasized: true);
    return DashboardCard(
      semanticLabel: '工作模式',
      padding: EdgeInsetsDirectional.fromSTEB(
        dashboardCardPadding(density).left,
        _inset,
        _inset,
        _inset,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          spacing: 16,
          children: [
            GlyphIcon(
              AppGlyphs.split,
              size: 18,
              color: context.colorScheme.onSurfaceVariant,
            ),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth / 4),
              child: Text(
                '工作模式',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: DashboardText.cardTitle(context),
              ),
            ),
            Expanded(
              child: DashboardConnectedGroup(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (index, item) in _items.indexed)
                    Expanded(
                      child: DashboardConnectedButton(
                        selected: index == selected,
                        first: index == 0,
                        last: index == _items.length - 1,
                        outer: outer,
                        inner: 10,
                        background: DashboardColors.of(context).tone,
                        semanticLabel: item.$2,
                        onTap: onChanged == null
                            ? null
                            : () => onChanged!(index),
                        builder: (foreground) => Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          spacing: 6,
                          children: [
                            GlyphIcon(item.$1, size: 18, color: foreground),
                            Flexible(
                              child: Text(
                                item.$2,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: style.copyWith(color: foreground),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
