// Drives the traffic tab at a human pace, for a screen recording. Not a test of
// anything: no screenshots, no assertions beyond needing the app to work.
//
//   xcrun simctl pbcopy booted < key.txt
//   xcrun simctl io booted recordVideo out.mov &
//   flutter drive --driver test_driver/integration_test.dart \
//     --target integration_test/demo_traffic_test.dart -d <device>
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sightline/main.dart';

import 'dart:io';

import 'demo_pace.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// The key the capture script left for this run. Never in the repo.
  String demoKey() {
    final File file = File(
      '${Directory.systemTemp.parent.path}/Documents/.demo_key',
    );
    return file.existsSync() ? file.readAsStringSync().trim() : '';
  }

  testWidgets('traffic camera, at a human pace', (WidgetTester tester) async {
    await tester.pumpWidget(const SightlineApp());
    await tester.pumpAndSettle();
    await pause(tester, 1800);

    // read the panel first, the way someone new to it would
    await tapGently(tester, find.byIcon(Icons.info_outline).first);
    await pause(tester, 3200);
    await tapGently(tester, find.text('Got it'));

    // setup: the key, then a collection to work in, then ask it to remember.
    // Typed rather than pasted: iOS interrupts a programmatic clipboard read
    // with a permission prompt, which stalls a recording.
    await tapGently(tester, find.text('Add your key'));
    await pause(tester, 900);
    await typeLikeAPerson(
      tester,
      find.byKey(const Key('setup-api-key')),
      demoKey(),
      perCharMs: 25,
    );
    await pause(tester, 600);
    await typeLikeAPerson(
      tester,
      find.byKey(const Key('setup-collection')),
      'traffic_camera',
    );
    await pause(tester, 700);
    await tapGently(tester, find.byType(Switch).first);
    await pause(tester, 1200);
    await tapGently(tester, find.widgetWithText(FilledButton, 'Connect'));
    await waitFor(tester, find.text('KEY ACTIVE'));
    await pause(tester, 1500);

    // send the clip up and watch it index
    if (find.text('Upload and index').evaluate().isNotEmpty) {
      await tapGently(tester, find.text('Upload and index'));
      await waitFor(tester, find.text('SEARCHABLE'), timeout: 300);
      await pause(tester, 1500);
    }

    // three searches, reading the results between each
    for (final String query in <String>[
      'pedestrians on a zebra crossing',
      'a bus waiting at the junction',
    ]) {
      await tapGently(tester, find.text(query));
      await pause(tester, 3500);
      await scrollDown(tester, 320);
      await pause(tester, 2500);
      await scrollUp(tester, 320);
    }

    // open one frame full size
    await tapGently(tester, find.byType(Image).first);
    await pause(tester, 3000);
    await tester.tapAt(const Offset(20, 60));
    await pause(tester, 1200);

    // a colour, then something that is not there at all
    await typeLikeAPerson(tester, find.byType(TextField).first, 'a red car');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await pause(tester, 4000);

    await typeLikeAPerson(tester, find.byType(TextField).first, 'a giraffe');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await pause(tester, 4000);
  });
}
