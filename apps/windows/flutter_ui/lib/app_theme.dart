import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:prism_ui/prism_ui.dart' as prism;
import 'prism_localizations.dart';

const _accent = Color(0xff007aff);
final _prismPalettes = {
  for (final brightness in Brightness.values)
    brightness: prism.ColorScheme.fromSeed(
      seedColor: _accent,
      brightness: brightness,
      style: prism.ColorStyle.vivid,
    ),
};

class FreeV6Theme extends StatelessWidget {
  const FreeV6Theme({
    super.key,
    required this.title,
    required this.home,
    this.appearance = ThemeMode.system,
    this.reduceMotion = false,
  });
  final String title;
  final Widget home;
  final ThemeMode appearance;
  final bool reduceMotion;
  ThemeData _material(Brightness brightness) {
    final palette = _prismPalettes[brightness]!;
    final colors = ColorScheme.fromSeed(
      seedColor: _accent,
      brightness: brightness,
      primary: palette.primary,
      onPrimary: palette.onPrimary,
      primaryContainer: palette.primaryContainer,
      onPrimaryContainer: palette.onPrimaryContainer,
      surface: palette.surface,
      onSurface: palette.onSurface,
      onSurfaceVariant: palette.onSurfaceVariant,
      surfaceContainer: palette.surfaceContainer,
      surfaceContainerLow: palette.surfaceContainerLow,
      surfaceContainerHigh: palette.surfaceContainerHigh,
      surfaceContainerHighest: palette.surfaceContainerHighest,
      outline: palette.outline,
      outlineVariant: palette.outlineVariant,
    );
    return ThemeData(
      colorScheme: colors,
      useMaterial3: true,
      visualDensity: VisualDensity.compact,
      platform: TargetPlatform.windows,
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: title,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: const [
        ...GlobalMaterialLocalizations.delegates,
        PrismStringsDelegate(),
      ],
      themeMode: appearance,
      theme: _material(Brightness.light),
      darkTheme: _material(Brightness.dark),
      builder: (context, child) {
        final brightness = Theme.of(context).brightness;
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            disableAnimations: reduceMotion || media.disableAnimations,
          ),
          child: prism.Theme(
            data: prism.ThemeData(colorScheme: _prismPalettes[brightness]!),
            child: child!,
          ),
        );
      },
      home: home,
    );
  }
}
