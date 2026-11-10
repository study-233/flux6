import 'package:flutter/material.dart';

import 'client_app.dart';
import 'preview_model.dart';

class PreviewApplication extends StatefulWidget {
  const PreviewApplication({super.key});
  @override
  State<PreviewApplication> createState() => _PreviewApplicationState();
}

class _PreviewApplicationState extends State<PreviewApplication> {
  final model = PreviewModel();
  @override
  void dispose() {
    model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClientApplication(model: model);
}
