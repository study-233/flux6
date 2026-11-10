import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../app/client_model.dart';

class WindowBackground extends StatefulWidget {
  const WindowBackground({super.key, required this.model, required this.child});
  final ClientModel model;
  final Widget child;
  @override
  State<WindowBackground> createState() => _WindowBackgroundState();
}

class _WindowBackgroundState extends State<WindowBackground> {
  String? last;
  Uint8List? bytes;
  @override
  Widget build(BuildContext context) {
    final m = widget.model,
        dark = Theme.of(context).brightness == Brightness.dark;
    final black = dark && m.preference('freev6-pure-black') == '1';
    final source = m.preference('freev6-wallpaper');
    if (source != last) {
      last = source;
      bytes = null;
      try {
        if (source.startsWith('data:image/'))
          bytes = base64Decode(source.substring(source.indexOf(',') + 1));
      } on FormatException {
        /* use the opaque background for damaged data */
      }
    }
    final wallpaper =
        !black &&
        m.preference('freev6-bg-mode') == 'wallpaper' &&
        bytes != null;
    final native =
        !black && ['mica', 'acrylic'].contains(m.runtime['backdrop']);
    final glass = m.preference('freev6-webgl-glass', '1') == '1';
    final color = black ? Colors.black : Theme.of(context).colorScheme.surface;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (wallpaper)
          Image.memory(
            bytes!,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => ColoredBox(color: color),
          ),
        if (wallpaper && glass)
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: const SizedBox.expand(),
          ),
        ColoredBox(
          color: color.withValues(
            alpha: wallpaper || native ? (glass ? .72 : .92) : 1,
          ),
        ),
        widget.child,
      ],
    );
  }
}

bool halloweenEnabled(DateTime date, String force) =>
    force == '1' || (date.month == 10 && date.day == 31);
String halloweenDateKey(DateTime date) =>
    '${date.year}-${date.month}-${date.day}';

class SeasonalButton extends StatefulWidget {
  const SeasonalButton({super.key, required this.model, this.now});
  final ClientModel model;
  final DateTime? now;
  @override
  State<SeasonalButton> createState() => _SeasonalButtonState();
}

class _SeasonalButtonState extends State<SeasonalButton>
    with SingleTickerProviderStateMixin {
  late final animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final date = widget.now ?? DateTime.now(), m = widget.model;
      if (halloweenEnabled(date, m.preference('freev6-halloween-force')) &&
          m.preference('freev6-halloween-greeted') != halloweenDateKey(date)) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('万圣节快乐 🎃')));
        await m.act('preferences.set', {
          'key': 'freev6-halloween-greeted',
          'value': halloweenDateKey(date),
        });
      }
    });
  }

  @override
  void dispose() {
    animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!halloweenEnabled(
      widget.now ?? DateTime.now(),
      widget.model.preference('freev6-halloween-force'),
    ))
      return const SizedBox.shrink();
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(
          tooltip: '万圣节彩蛋：不给糖就捣蛋',
          onPressed: () => animation.forward(from: 0),
          icon: const Text('🎃', style: TextStyle(fontSize: 22)),
        ),
        AnimatedBuilder(
          animation: animation,
          builder: (_, __) => IgnorePointer(
            child: ExcludeSemantics(
              child: Opacity(
                opacity: animation.isAnimating ? 1 - animation.value : 0,
                child: Transform.translate(
                  offset: Offset(
                    0,
                    MediaQuery.disableAnimationsOf(context)
                        ? 0
                        : animation.value * 80,
                  ),
                  child: const Text('🍬 🦇 👻', style: TextStyle(fontSize: 20)),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
