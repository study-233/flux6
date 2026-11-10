// Adapted from FlClash v0.9.3 lib/views/proxies/card.dart (GPLv3).
import 'package:flutter/material.dart' show IconButton, Icons, Icon, Tooltip;
import 'package:flutter/widgets.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'app_glyphs.dart';

/// The upstream selected card, title, selection badge and details row use the
/// host's confirmed node, preference and delay instead of FlClash providers.
class HostProxyCard extends StatelessWidget {
  const HostProxyCard({
    super.key,
    required this.name,
    this.keyboardTarget = false,
    required this.selected,
    required this.active,
    required this.status,
    required this.delay,
    required this.onSelect,
    required this.showMeasure,
    required this.measuring,
    required this.onMeasure,
    this.showDownload = false,
    this.downloading = false,
    this.download = '未测速',
    this.downloadDetail = '',
    this.onDownload,
  });
  final String name, status, delay;
  final bool keyboardTarget;
  final bool selected, active, measuring, showMeasure;
  final VoidCallback? onSelect, onMeasure;
  final bool showDownload, downloading;
  final String download, downloadDetail;
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) {
    final colors = prism.Theme.of(context).colorScheme;
    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(prism.AppCorner.lg),
        border: keyboardTarget
            ? Border.all(color: colors.primary, width: 2)
            : null,
      ),
      child: prism.Card(
        radius: prism.AppCorner.lg,
        enterActionsOnRight: true,
        onPressed: onSelect,
        isSelected: active,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 4,
              children: [
                Expanded(
                  child: Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: prism.AppTextStyle.subheadline.of(
                      context,
                      emphasized: true,
                    ),
                  ),
                ),
                if (selected)
                  prism.SelectionBadge(glyph: AppGlyphs.pin, tonal: !active)
                else if (active)
                  const prism.SelectionBadge(),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: prism.AppTextStyle.caption2
                        .of(context)
                        .copyWith(color: colors.onSurfaceVariant),
                  ),
                ),
                if (showMeasure) ...[
                  Text(
                    delay,
                    style: prism.AppTextStyle.caption2
                        .of(context)
                        .copyWith(color: colors.onSurfaceVariant),
                  ),
                  IconButton(
                    tooltip: '测量${name}延迟',
                    onPressed: onMeasure,
                    icon: Icon(
                      measuring
                          ? Icons.hourglass_top_rounded
                          : Icons.bolt_rounded,
                      semanticLabel: '测量${name}延迟',
                      size: 16,
                    ),
                  ),
                ],
              ],
            ),
            if (showDownload)
              Row(
                children: [
                  Expanded(
                    child: Tooltip(
                      message: downloadDetail,
                      child: Text(
                        download,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: prism.AppTextStyle.caption2
                            .of(context)
                            .copyWith(color: colors.onSurfaceVariant),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: downloading ? '取消${name}下载测速' : '测试${name}下载速度',
                    onPressed: onDownload,
                    icon: Icon(
                      downloading
                          ? Icons.stop_circle_outlined
                          : Icons.download_rounded,
                      size: 17,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
