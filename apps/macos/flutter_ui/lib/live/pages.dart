import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:prism_ui/sidebar.dart' as prism;
import '../components/app_glyphs.dart';
import 'live_model.dart';
import 'log_pages.dart';

part 'pages_configuration.dart';
part 'pages_preferences.dart';
part 'setup_page.dart';
part 'pages_logs_layout.dart';

StateMap _settings(LiveModel model) => readMap(model.state['settings']);
StateMap _section(LiveModel model, String key) =>
    readMap(_settings(model)[key]);

Future<bool> _run(
  BuildContext context,
  Future<dynamic> Function() operation,
) async {
  try {
    await operation();
    return true;
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(error.toString())));
    }
    return false;
  }
}

Future<bool> _confirm(
  BuildContext context,
  String title,
  String message,
  String action,
) async {
  return await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.content);
  final String title;
  final List<Widget> content;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: colors.outlineVariant.withValues(alpha: .55)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              ...content,
            ],
          ),
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

class _Action extends StatelessWidget {
  const _Action(this.text, this.perform, {this.icon});
  final String text;
  final Future<dynamic> Function()? perform;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: perform == null ? null : () => _run(context, perform!),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[Icon(icon, size: 16), const SizedBox(width: 5)],
        Text(text),
      ],
    ),
  );
}
