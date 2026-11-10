import 'dart:convert';
import 'dart:ui' show ImageFilter;

import 'package:fl_clash/ui/ui.dart';
import 'package:flutter/widgets.dart';
import 'package:freev6_windows/app/client_model.dart';

class FreeV6Background extends StatelessWidget {
  const FreeV6Background({super.key, required this.model, required this.child});
  final ClientModel model;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = context.colorScheme.brightness == Brightness.dark;
    final black = dark && model.preference('freev6-pure-black') == '1';
    final source = model.preference('freev6-wallpaper');
    final wallpaper =
        !black &&
        model.preference('freev6-bg-mode') == 'wallpaper' &&
        source.startsWith('data:image/');
    final native =
        !black && ['mica', 'acrylic'].contains(model.runtime['backdrop']);
    if (!wallpaper && !native) return child;
    Widget? image;
    if (wallpaper) {
      try {
        image = Image.memory(
          base64Decode(source.substring(source.indexOf(',') + 1)),
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => const SizedBox(),
        );
      } on FormatException {
        image = null;
      }
    }
    final scheme = context.colorScheme;
    final transparent = scheme.copyWith(
      surface: dark ? Colors.transparent : scheme.surface,
      surfaceContainer: dark ? scheme.surfaceContainer : Colors.transparent,
    );
    final glass = model.preference('freev6-webgl-glass', '1') == '1';
    return Stack(
      fit: StackFit.expand,
      children: [
        ?image,
        if (image != null && glass)
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: const SizedBox.expand(),
          ),
        ColoredBox(
          color: (dark ? const Color(0xff121212) : const Color(0xfff1f0f3))
              .withValues(alpha: glass ? .72 : .92),
        ),
        Theme(
          data: Theme.of(context).copyWith(colorScheme: transparent),
          child: child,
        ),
      ],
    );
  }
}
