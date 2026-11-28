import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freev6_windows/app/live_model.dart';

import 'session.dart';

class FreeV6AutomaticCard extends ConsumerWidget {
  const FreeV6AutomaticCard({
    super.key,
    required this.groupName,
    required this.type,
  });

  final String groupName;
  final ProxyCardType type;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final model = watchFreeV6(ref), l = context.appLocalizations;
    final selected =
        ref.watch(selectedProxyNameProvider(groupName)) == automaticProxyName;
    final live = model is LiveModel ? model : null;
    final changing = live?.nodeTools.selecting == true;
    final currentGroup = ref.read(freev6SessionProvider).group == groupName;
    final active = currentGroup ? live?.nodeTools.activeNodes.length ?? 0 : 0;
    final detail = !model.connected
        ? l.freev6AutoConnect
        : changing && currentGroup
        ? l.freev6Working
        : active > 0 && selected
        ? l.freev6ActiveCount(active)
        : l.freev6AutoShort;
    return Semantics(
      label: l.freev6Automatic,
      selected: selected,
      child: Card(
        radius: AppCorner.lg,
        enterActionsOnRight: true,
        isSelected: selected,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        onPressed: model.canSelectNode && !selected
            ? () => ref
                  .read(proxiesActionProvider.notifier)
                  .changeProxyDebounce(groupName, automaticProxyName)
            : null,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: SizedBox(
                    height:
                        globalState.measure.textHeight(
                          AppTextStyle.subheadline,
                        ) *
                        (type == ProxyCardType.compact ? 1 : 2),
                    child: Text(
                      l.freev6Automatic,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyle.subheadline.of(context),
                    ),
                  ),
                ),
                if (selected) const SelectionBadge(),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height:
                  globalState.measure.textHeight(AppTextStyle.footnote) *
                      (type == ProxyCardType.loose ? 2 : 1) +
                  (type == ProxyCardType.loose ? 6 : 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyle.footnote.of(context).toLight,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const GlyphIcon(AppGlyphs.shuffle, size: 16),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
