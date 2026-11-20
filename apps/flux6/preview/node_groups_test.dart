import 'package:fl_clash/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows members of the selected Flux6 fixture group', (
    tester,
  ) async {
    final groups = await loadPreviewGroups();
    expect(
      groups.firstWhere((group) => group.name == '♻️ 自动选择').all,
      hasLength(28),
    );
    await tester.pumpWidget(NodePreview(groups: groups));
    await tester.pumpAndSettle();
    await tester.tap(find.text('☑️ 手动切换').first);
    await tester.pumpAndSettle();
    expect(find.text('103-1-443'), findsOneWidget);
  });
}
