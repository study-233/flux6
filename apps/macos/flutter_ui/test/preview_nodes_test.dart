import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/preview/fixture_model.dart';
import '../lib/preview/node_picker.dart';
import '../lib/preview/secondary_pages.dart';

void main() {
  testWidgets('search and confirm a node without connecting from offline', (
    tester,
  ) async {
    final model = FixtureModel.memory(online: false);
    addTearDown(model.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showFixtureNodePicker(context, model),
              child: const Text('选择接入节点'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('选择接入节点'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '西');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(model.preferredNode, '西区');
    expect(model.currentNode, isNull);
  });

  testWidgets('testing a different node does not select it', (tester) async {
    final model = FixtureModel.memory();
    addTearDown(model.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: FixtureNodesPage(model: model)),
      ),
    );
    await tester.tap(find.byTooltip('测量西区延迟'));
    await tester.pump(const Duration(milliseconds: 320));
    await tester.pumpAndSettle();
    expect(model.latency('西区'), 18);
    expect(model.preferredNode, isNull);
    expect(model.currentNode, '东区');
  });
}
