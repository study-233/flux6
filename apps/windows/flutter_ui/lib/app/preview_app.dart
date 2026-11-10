import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../dashboard.dart';
import 'preview_model.dart';

class PreviewApplication extends StatefulWidget {
  const PreviewApplication({super.key});
  @override
  State<PreviewApplication> createState() => _PreviewApplicationState();
}

class _PreviewApplicationState extends State<PreviewApplication> {
  final model = PreviewModel();
  final scroll = ScrollController();
  @override
  void dispose() {
    scroll.dispose();
    model.dispose();
    super.dispose();
  }

  void _nodes(BuildContext context) => showDialog<void>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('选择演示节点'),
      children: [
        for (final node in model.nodes)
          SimpleDialogOption(
            onPressed: () {
              model.selectNode(node);
              Navigator.pop(context);
            },
            child: Text(node),
          ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) => FreeV6Theme(
    title: 'FreeV6 Windows Preview',
    home: Builder(
      builder: (context) => Scaffold(
        appBar: AppBar(
          title: const Text('FreeV6'),
          actions: const [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Center(child: Text('演示模式 · 不连接网络')),
            ),
          ],
        ),
        body: PreviewDashboard(
          model: model,
          scroll: scroll,
          onNodes: () => _nodes(context),
          onPage: (_) => _nodes(context),
        ),
      ),
    ),
  );
}
