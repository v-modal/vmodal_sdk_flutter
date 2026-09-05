import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sightline/main.dart';

void main() {
  testWidgets('both demos are reachable and each brings its own look', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const SightlineApp());

    expect(find.text('Traffic camera'), findsOneWidget);
    final Color dark = tester
        .widget<MaterialApp>(find.byType(MaterialApp))
        .theme!
        .scaffoldBackgroundColor;

    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();

    expect(find.text('Find the correct video'), findsOneWidget);
    final Color light = tester
        .widget<MaterialApp>(find.byType(MaterialApp))
        .theme!
        .scaffoldBackgroundColor;

    expect(light, isNot(dark));
  });

  testWidgets('nothing can be searched before setup', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const SightlineApp());

    expect(find.text('Add your key'), findsOneWidget);
    expect(find.text('Upload and index'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField).first).enabled,
      isFalse,
    );
  });
}
