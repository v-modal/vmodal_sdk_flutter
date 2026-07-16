import 'package:flutter_test/flutter_test.dart';
import 'package:vmodal_example/main.dart';

void main() {
  testWidgets('example requires runtime injection', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const VmodalExampleApp());
    expect(find.textContaining('runtime API key'), findsWidgets);
    expect(find.text('Configure client'), findsOneWidget);
    expect(find.text('Search'), findsOneWidget);
    expect(find.text('Upload'), findsOneWidget);
  });
}
