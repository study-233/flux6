import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/features/features.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freev6_windows/app/live_model.dart';

import 'session.dart';

class FreeV6PortForm extends ConsumerStatefulWidget {
  const FreeV6PortForm({super.key});
  @override
  ConsumerState<FreeV6PortForm> createState() => _PortState();
}

class _PortState extends ConsumerState<FreeV6PortForm> {
  static const defaults = {
    'mixedPort': 7890,
    'httpPort': 0,
    'socksPort': 0,
    'dnsPort': 1053,
  };
  late final fields = {
    for (final entry in defaults.entries)
      entry.key: TextEditingController(
        text: '${options[entry.key] ?? entry.value}',
      ),
  };
  Map<String, dynamic> get options {
    final model = ref.read(freev6SessionProvider).model;
    return model is LiveModel ? model.networkOptions : {};
  }

  bool saving = false;
  String? saveError;

  String? issue(String key) {
    final port = int.tryParse(fields[key]!.text.trim());
    final l = context.appLocalizations;
    if ((key == 'httpPort' || key == 'socksPort') && port == 0) return null;
    if (port == null || port < 1 || port > 65535) return l.freev6PortRange;
    if (port == 9090 ||
        fields.entries.any(
          (e) => e.key != key && int.tryParse(e.value.text.trim()) == port,
        )) {
      return l.freev6PortConflict;
    }
    return null;
  }

  Future<void> save() async {
    if (saving || fields.keys.any((key) => issue(key) != null)) return;
    setState(() {
      saving = true;
      saveError = null;
    });
    final ok = await ref.read(freev6SessionProvider).act('network.save', {
      for (final entry in fields.entries)
        entry.key: int.parse(entry.value.text.trim()),
    });
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      saving = false;
      saveError = context.appLocalizations.freev6SaveFailed;
    });
  }

  @override
  void dispose() {
    for (final controller in fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.appLocalizations;
    final labels = {
      'mixedPort': l.mixedPort,
      'httpPort': 'HTTP',
      'socksPort': l.socksPort,
      'dnsPort': 'DNS',
    };
    final errors = {for (final key in fields.keys) key: issue(key)};
    return PopScope(
      canPop: !saving,
      child: FormPage(
        title: l.freev6Ports,
        onSave: save,
        saving: saving,
        error: saveError ?? errors.values.whereType<String>().firstOrNull,
        children: [
          generateSection(
            footer: l.freev6PortsHint,
            items: [
              for (final entry in fields.entries)
                FormRow(
                  title: labels[entry.key]!,
                  invalid: errors[entry.key] != null,
                  trailing: FormRowTextField(
                    controller: entry.value,
                    keyboardType: TextInputType.number,
                    inputFormatters: TextInputLimits.digitsOnly(
                      TextInputLimits.port,
                    ),
                    onChanged: (_) => setState(() {}),
                    onFieldSubmitted: (_) => save(),
                  ),
                ),
            ],
          ),
          generateSection(
            items: [
              FormRow(
                title: l.reset,
                onPressed: saving
                    ? null
                    : () {
                        setState(() {
                          for (final entry in defaults.entries) {
                            fields[entry.key]!.text = '${entry.value}';
                          }
                        });
                      },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
