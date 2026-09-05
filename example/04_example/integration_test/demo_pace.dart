import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Timings that make a driven run look like someone using the app rather than
/// a machine firing taps. Used only by the demo recordings.

/// Pumps for [ms] of real time.
Future<void> pause(WidgetTester tester, int ms) async {
  for (int i = 0; i < ms ~/ 50; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Taps with a beat either side, so the recording does not jump.
Future<void> tapGently(WidgetTester tester, Finder finder) async {
  await pause(tester, 500);
  await tester.tap(finder);
  await pause(tester, 700);
}

/// Types a character at a time, at about the speed of a thumb.
Future<void> typeLikeAPerson(
  WidgetTester tester,
  Finder field,
  String text, {
  int perCharMs = 70,
}) async {
  await tester.tap(field);
  await pause(tester, 400);
  for (int i = 1; i <= text.length; i++) {
    await tester.enterText(field, text.substring(0, i));
    await pause(tester, perCharMs);
  }
  await pause(tester, 400);
}

Future<void> scrollDown(WidgetTester tester, double by) async {
  await tester.drag(find.byType(Scrollable).first, Offset(0, -by));
  await pause(tester, 600);
}

Future<void> scrollUp(WidgetTester tester, double by) async {
  await tester.drag(find.byType(Scrollable).first, Offset(0, by));
  await pause(tester, 600);
}

/// Waits for something to appear, pumping in real time.
Future<bool> waitFor(
  WidgetTester tester,
  Finder finder, {
  int timeout = 120,
}) async {
  for (int i = 0; i < timeout * 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (finder.evaluate().isNotEmpty) return true;
  }
  return false;
}
