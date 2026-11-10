import 'dart:async';

import 'package:fl_clash/common/cat_icon.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/views/theme_preview.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';

class CatIconPicker extends StatefulWidget {
  const CatIconPicker({super.key, this.controller});
  final CatIconController? controller;

  @override
  State<CatIconPicker> createState() => _CatIconPickerState();
}

class _CatIconPickerState extends State<CatIconPicker> {
  late final CatIconController controller =
      widget.controller ?? catIconController;
  bool busy = true;
  bool failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() async {
    try {
      await controller.load();
    } catch (_) {
      failed = true;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> select(CatIcon icon) async {
    if (busy) return;
    setState(() {
      busy = true;
      failed = false;
    });
    try {
      await controller.select(icon);
    } catch (_) {
      failed = true;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<CatIcon>(
    valueListenable: controller,
    builder: (context, selected, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExcludeFocus(
          excluding: busy,
          child: IgnorePointer(
            ignoring: busy,
            child: PreviewChoiceGroup<CatIcon>(
              info: Info(
                label: context.appLocalizations.appIcon,
                glyph: AppGlyphs.palette,
              ),
              value: selected,
              choices: [
                for (final icon in CatIcon.values)
                  PreviewChoice(
                    value: icon,
                    label: icon.label,
                    pictogram: Image.asset(icon.asset, width: 64, height: 64),
                  ),
              ],
              onChanged: select,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            failed
                ? context.appLocalizations.appIconChangeFailed
                : context.appLocalizations.appIconHint,
          ),
        ),
      ],
    ),
  );
}
