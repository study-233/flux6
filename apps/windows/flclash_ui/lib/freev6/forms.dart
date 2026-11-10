import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:flutter/widgets.dart';

class FreeV6InputDialog extends StatefulWidget {
  const FreeV6InputDialog({
    super.key,
    required this.title,
    required this.value,
    required this.save,
    this.validate,
    this.multiline = false,
  });
  final String title, value;
  final Future<bool> Function(String) save;
  final String? Function(String)? validate;
  final bool multiline;
  @override
  State<FreeV6InputDialog> createState() => _FreeV6InputDialogState();
}

class _FreeV6InputDialogState extends State<FreeV6InputDialog> {
  late final controller = TextEditingController(text: widget.value);
  bool saving = false;
  String? error;
  Future<void> submit() async {
    final value = controller.text.trim();
    final invalid = widget.validate?.call(value);
    if (invalid != null) {
      setState(() => error = invalid);
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    final success = await widget.save(value);
    if (!mounted) return;
    if (success) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      saving = false;
      error = context.appLocalizations.freev6SaveFailed;
    });
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: AlertDialog(
      title: widget.title,
      actions: [
        TextButton(
          onPressed: saving ? null : () => Navigator.of(context).pop(false),
          child: Text(context.appLocalizations.cancel),
        ),
        TextButton(
          onPressed: saving ? null : submit,
          child: Text(
            saving
                ? context.appLocalizations.freev6Working
                : context.appLocalizations.confirm,
          ),
        ),
      ],
      child: TextFormField(
        controller: controller,
        autofocus: true,
        enabled: !saving,
        minLines: widget.multiline ? 3 : 1,
        maxLines: widget.multiline ? 8 : 1,
        decoration: InputDecoration(errorText: error),
        onFieldSubmitted: saving || widget.multiline ? null : (_) => submit(),
      ),
    ),
  );
}
